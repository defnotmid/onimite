package onimite

import "core:hash"
import "core:math/linalg"
import "core:mem/virtual"
import "core:reflect"
import "core:thread"
import "deps:o3d"
import vg "deps:ovg"

// The frame's motion over the shutter (the motion table). Frame k is built
// twice: at the shutter's opening (`shift` seconds before the frame's moment,
// Frame.shift) and at its middle (the frame itself, `ctx.tree`). Each draw of
// the middle is paired with its draw at the opening by its place in the
// tree: the children of paired groups are matched from both ends while their
// kind and content (a text's string, an image's file) agree, then, among
// those left, from both ends while their kind does. A group's kind includes
// the script function that draws it (Group.drawn_by): a group that appears
// among its siblings can't take the place of one another function draws.
// Anything else wasn't drawn at the other moment: it doesn't move. The
// shutter never opens before the video or a scene starts.
//
// The table keeps the paired states, not a velocity: per node of the
// middle's tree, where it is at both moments (`motion_placement` through its
// groups' transforms, in video units), so every number derived from it
// (speeds, the opened state a renderer blurs with) comes from one pair.
Motion :: struct {
	// The opening's tree, in its own arena.
	tree:   Tree,
	arena:  virtual.Arena,
	// Seconds from the middle back to the opening (< 0).
	shift:  f64,
	// Per node of `ctx.tree`: whether it is paired, its draw at the
	// opening (an index in `tree`; NO_NODE when unpaired) and its
	// placements at both moments.
	state:  [dynamic]Motion_State,
	pair:   [dynamic]i32,
	opened: [dynamic]vg.Transform2D,
	middle: [dynamic]vg.Transform2D,
}

Motion_State :: enum u8 {
	// A group, or drawn only through a mask or a pattern.
	None,
	// Drawn at the middle without a draw at the opening.
	Unpaired,
	Paired,
}

motion_destroy :: proc(m: ^Motion) {
	tree_destroy(&m.tree)
	virtual.arena_destroy(&m.arena)
	delete(m.state)
	delete(m.pair)
	delete(m.opened)
	delete(m.middle)
	m^ = {}
}

// Where the opening is: half the video's shutter before the frame's moment,
// or half of a 180° one (a quarter frame) when it sets none.
motion_shift :: proc "contextless" (v: ^Video) -> f64 {
	angle := v.shutter if v.shutter > 0 else 180
	return -f64(angle) / 360 / 2 / f64(v.fps)
}

// Builds frame `index` to be drawn: with its motion when the video's shutter
// is open (motion blur), else as `build_frame`.
build_frame_shown :: proc(r: ^Renderer, index: int) {
	if r.video.shutter > 0 {
		build_motion(r, index, motion_shift(r.video))
	} else {
		build_frame(r, index)
	}
}

// Builds frame `index`, as `build_frame`, and its motion: the frame again
// at `shift` seconds, paired with it in `r.motion`. What the opening's build
// reports is dropped: the frame reports its own.
build_motion :: proc(r: ^Renderer, index: int, shift: f64) {
	m := &r.motion
	reported := len(r.ctx.diagnostics)
	r.ctx.tree, m.tree = m.tree, r.ctx.tree
	build_frame_at(r, index, shift, &m.arena)
	r.ctx.tree, m.tree = m.tree, r.ctx.tree
	diagnostics_free(r.ctx.diagnostics[reported:])
	resize(&r.ctx.diagnostics, reported)
	build_frame(r, index)
	m.shift = shift
	n := len(r.ctx.tree.nodes)
	resize(&m.state, n)
	resize(&m.pair, n)
	resize(&m.opened, n)
	resize(&m.middle, n)
	for &s in m.state {
		s = .None
	}
	for &k in m.pair {
		k = NO_NODE
	}
	if len(m.tree.nodes) > 0 {
		motion_pair_children(r, 0, 0, vg.TRANSFORM_IDENTITY, vg.TRANSFORM_IDENTITY)
	}
}

// How far draw `i` moves in video units per frame where it moves most (its
// placement's unit square), and the way its centre moves (middle minus
// opened, per frame); 0 for a draw that isn't paired.
motion_speed :: proc(r: ^Renderer, i: int) -> (speed: f32, direction: Vec2) {
	m := &r.motion
	if m.state[i] != .Paired || m.shift >= 0 {
		return
	}
	per_frame := f32(1 / (f64(r.video.fps) * -m.shift))
	for q in ([4]Vec2{{0, 0}, {1, 0}, {0, 1}, {1, 1}}) {
		d := vg.transform_point(m.middle[i], q.x, q.y) - vg.transform_point(m.opened[i], q.x, q.y)
		speed = max(speed, linalg.length(d) * per_frame)
	}
	direction = (vg.transform_point(m.middle[i], 0.5, 0.5) - vg.transform_point(m.opened[i], 0.5, 0.5)) * per_frame
	return
}

// How draw `i` moved over the shutter, as vg.set_motion takes it: what maps
// a point of it at the middle to where it was at the opening, in the
// frame's pixels (the identity when it isn't paired: it doesn't move).
motion_opened :: proc(r: ^Renderer, i: int) -> vg.Transform2D {
	m := &r.motion
	if i >= len(m.state) || m.state[i] != .Paired {
		return vg.TRANSFORM_IDENTITY
	}
	s := vg.transform_scaling(r.scale, r.scale)
	mid := vg.transform_multiply(m.middle[i], s)
	open := vg.transform_multiply(m.opened[i], s)
	return vg.transform_multiply(vg.transform_inverse(mid), open)
}

// What blurring a 2D frame by its motion needs on the CPU, kept by whoever
// draws frames there (a renderer, or a render's players, which draw one at
// a time): o3d's tile tables and the frame as light (`color`) and blurred.
Frame_Blur :: struct {
	tables:     o3d.Motion_Tables,
	color, out: [dynamic][4]f32,
}

frame_blur_destroy :: proc(b: ^Frame_Blur) {
	o3d.motion_tables_destroy(&b.tables)
	delete(b.color)
	delete(b.out)
	b^ = {}
}

// Blurs the software backend's last frame (premultiplied RGBA8) by the
// motion its draws left (o3d's reconstruction filter, the pass a 3D view
// blurs with): nothing when it kept none. The frame is blurred as it is
// blended, as ovg composites 2D, so a streak over half a pixel's time is
// half its opacity, as a draw at half opacity is.
frame_blur_software :: proc(b: ^Frame_Blur, sw: ^vg.Software_Backend, pool: ^thread.Pool) {
	velocity, nearness := vg.software_backend_velocity(sw)
	w, h := int(sw.width), int(sw.height)
	if len(velocity) < w * h || w * h == 0 {
		return
	}
	resize(&b.color, w * h)
	resize(&b.out, w * h)
	px := sw.pixels
	for &c, k in b.color {
		c = {f32(px[4 * k]), f32(px[4 * k + 1]), f32(px[4 * k + 2]), f32(px[4 * k + 3])} / 255
	}
	params := o3d.Motion_Blur{max_blur = o3d.MOTION_MAX_BLUR * f32(h), depth_scale = FRAME_BLUR_DEPTH_SCALE}
	o3d.motion_blur(&b.tables, b.color[:], velocity, nearness, w, h, params, b.out[:], pool)
	for c, k in b.out {
		for j in 0 ..< 4 {
			px[4 * k + j] = u8(clamp(c[j] * 255 + 0.5, 0, 255))
		}
	}
}

// A 2D frame's nearness rises by one surface per draw (vg.set_motion):
// draws half a step apart are one surface.
FRAME_BLUR_DEPTH_SCALE :: 0.5

// Where a drawn node is in its parent's space: an affine from a reference
// shape. The unit square onto its box (rects, circles, ellipses, images,
// SVG, Lottie, video, shaders, 3D views); an em at its anchor (text: its
// string may change, its anchor and size are where it is); a segment's own
// frame (lines); a path's own coordinates (a path whose points change moves
// only by its groups).
@(private)
motion_placement :: proc(r: ^Renderer, kind: ^Node_Kind) -> vg.Transform2D {
	#partial switch n in kind^ {
	case Text:
		return {n.size, 0, 0, n.size, n.x, n.y}
	case Line:
		d := Vec2{n.x2 - n.x1, n.y2 - n.y1}
		if d == {} {
			return {1, 0, 0, 1, n.x1, n.y1}
		}
		return {d.x, d.y, -d.y, d.x, n.x1, n.y1}
	case Path:
		return vg.TRANSFORM_IDENTITY
	}
	b := leaf_bbox(r, kind)
	if b.w < 0 {
		return vg.TRANSFORM_IDENTITY
	}
	return {b.w if b.w > 0 else 1, 0, 0, b.h if b.h > 0 else 1, b.x, b.y}
}

// Pairs the children of group `mid` (in `ctx.tree`) with those of `open`
// (in the opening's tree), the groups' transforms so far `wm` and `wo`:
// from both ends while kind and content agree, then, in what is left, from
// both ends while the kind does (a text whose string changed; a group drawn
// by the same function).
@(private = "file")
motion_pair_children :: proc(r: ^Renderer, mid, open: i32, wm, wo: vg.Transform2D) {
	a := child_list(&r.ctx.tree, mid)
	b := child_list(&r.motion.tree, open)
	lo, ha, hb := 0, len(a), len(b)
	for content in ([2]bool{true, false}) {
		for lo < ha && lo < hb && same_draw(r, a[lo], b[lo], content) {
			motion_pair(r, a[lo], b[lo], wm, wo)
			lo += 1
		}
		for ha > lo && hb > lo && same_draw(r, a[ha - 1], b[hb - 1], content) {
			ha, hb = ha - 1, hb - 1
			motion_pair(r, a[ha], b[hb], wm, wo)
		}
	}
	for k in lo ..< ha {
		mark_unpaired(r, a[k])
	}
}

@(private = "file")
motion_pair :: proc(r: ^Renderer, mid, open: i32, wm, wo: vg.Transform2D) {
	m := &r.motion
	km := &r.ctx.tree.nodes[mid].kind
	if g, is_group := km^.(Group); is_group {
		if g.is_mask || g.is_pattern {
			return
		}
		go := r.motion.tree.nodes[open].kind.(Group)
		tm, to := wm, wo
		if t, ok := g.transform.?; ok {
			tm = vg.transform_multiply(transform_matrix(t), wm)
		}
		if t, ok := go.transform.?; ok {
			to = vg.transform_multiply(transform_matrix(t), wo)
		}
		motion_pair_children(r, mid, open, tm, to)
		return
	}
	pm := vg.transform_multiply(motion_placement(r, km), wm)
	if vg.transform_singular(pm) {
		// Nothing shows at the middle (a zero size): nothing to move.
		m.state[mid] = .Unpaired
		return
	}
	m.state[mid] = .Paired
	m.pair[mid] = open
	m.middle[mid] = pm
	m.opened[mid] = vg.transform_multiply(motion_placement(r, &r.motion.tree.nodes[open].kind), wo)
}

// Node `i` and everything under it (masks and patterns aside) drawn without
// a pair.
@(private = "file")
mark_unpaired :: proc(r: ^Renderer, i: i32) {
	nodes := r.ctx.tree.nodes[:]
	g, is_group := nodes[i].kind.(Group)
	if !is_group {
		r.motion.state[i] = .Unpaired
		return
	}
	if g.is_mask || g.is_pattern {
		return
	}
	for c := nodes[i].first_child; c != NO_NODE; c = nodes[c].next {
		mark_unpaired(r, c)
	}
}

@(private = "file")
child_list :: proc(t: ^Tree, parent: i32) -> []i32 {
	list := make([dynamic]i32, context.temp_allocator)
	for c := t.nodes[parent].first_child; c != NO_NODE; c = t.nodes[c].next {
		append(&list, c)
	}
	return list[:]
}


// Whether node `a` of the middle and `b` of the opening are the same draw:
// of a kind, and with `content`, showing the same. A group's key is part of
// its kind: who draws it.
@(private = "file")
same_draw :: proc(r: ^Renderer, a, b: i32, content: bool) -> bool {
	ka, kb := &r.ctx.tree.nodes[a].kind, &r.motion.tree.nodes[b].kind
	_, is_group := ka^.(Group)
	return reflect.union_variant_typeid(ka^) == reflect.union_variant_typeid(kb^) && (!content && !is_group || draw_key(ka) == draw_key(kb))
}

// What a draw shows, apart from where and how it is painted: a text's
// string, an image's file, a path's points; a group's function and role.
@(private = "file")
draw_key :: proc(k: ^Node_Kind) -> u64 {
	#partial switch n in k^ {
	case Group:
		return n.drawn_by ~ (u64(n.is_mask) | u64(n.is_pattern) << 1 | u64(n.masked) << 2)
	case Text:
		return hash.fnv64a(transmute([]u8)n.text)
	case Image:
		return hash.fnv64a(transmute([]u8)n.src)
	case Svg:
		return hash.fnv64a(transmute([]u8)n.src)
	case Path:
		if n.asset != nil {
			return n.asset.key
		}
		return hash.fnv64a(transmute([]u8)n.d)
	}
	return 0
}
