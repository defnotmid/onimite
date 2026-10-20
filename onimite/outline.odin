package onimite

import "core:math"
import "deps:o3d"
import vg "deps:ovg"

// The outline flattened into `out`, curves split about every `segment`
// outline units, or (0) finely at any scale: about 1/1300 of its size, so a
// 1-unit letter for 3D keeps round bowls. (ovg flattens about every 1.5
// units: the path is scaled to suit first.)
outline_flatten :: proc(a: ^Path_Asset, out: ^vg.Flat_Path, segment: f32 = 0) {
	lo, hi := [2]f32{max(f32), max(f32)}, [2]f32{-max(f32), -max(f32)}
	for v in a.coords {
		lo, hi = {min(lo.x, v.x), min(lo.y, v.y)}, {max(hi.x, v.x), max(hi.y, v.y)}
	}
	span := max(hi.x - lo.x, hi.y - lo.y)
	k: f32 = 1
	if segment > 0 {
		k = 1.5 / segment
	} else if span > 0 && len(a.coords) > 0 {
		k = 2000 / span
	}
	p: vg.Path
	p.verbs.allocator = context.temp_allocator
	p.coords.allocator = context.temp_allocator
	append(&p.verbs, ..a.verbs)
	for v in a.coords {
		append(&p.coords, v * k)
	}
	vg.path_flatten(&p, out)
	for &v in out.points {
		v /= k
	}
}

// The outline's curves as an o3d path, temp allocated; `flip_y` for 3D (y
// up), where text then reads upright. ovg's solid/hole marks are left out:
// the curves fill by their own winding, as path{} draws them.
outline_path :: proc(a: ^Path_Asset, flip_y: bool) -> o3d.Path {
	p: o3d.Path
	p.segments = make([dynamic]o3d.Path_Segment, 0, len(a.verbs), context.temp_allocator)
	fy: f32 = -1 if flip_y else 1
	at := 0
	for verb in a.verbs {
		c := a.coords[at:]
		switch verb {
		case .Move_To:
			o3d.path_move_to(&p, {c[0].x, fy * c[0].y})
		case .Line_To:
			o3d.path_line_to(&p, {c[0].x, fy * c[0].y})
		case .Bezier_To:
			o3d.path_bezier_curve_to(&p, {c[0].x, fy * c[0].y}, {c[1].x, fy * c[1].y}, {c[2].x, fy * c[2].y})
		case .Close:
			o3d.path_close(&p)
		case .Solid, .Hole:
		}
		at += vg.verb_num_coords(verb)
	}
	return p
}

// The outline as o3d shapes (outer contours with their holes), temp
// allocated; `flip_y` for 3D (y up), where text then reads upright.
// `simplify` > 0 drops points within that distance of the line through their
// neighbours (Douglas-Peucker): physics wants corners with a real turn.
outline_shapes :: proc(a: ^Path_Asset, flip_y: bool, segment: f32 = 0, simplify: f32 = 0) -> []o3d.Shape {
	flat: vg.Flat_Path
	flat.points.allocator = context.temp_allocator
	flat.contours.allocator = context.temp_allocator
	outline_flatten(a, &flat, segment)
	pts := make([]o3d.Vec2, len(flat.points), context.temp_allocator)
	for v, i in flat.points {
		pts[i] = {v.x, -v.y if flip_y else v.y}
	}
	contours := make([dynamic][]o3d.Vec2, 0, len(flat.contours), context.temp_allocator)
	for ct in flat.contours {
		ring := pts[ct.first:][:ct.count]
		// Without the closing point (a copy of the first): triangulators
		// drop it, and a hole's indices would then be off by one.
		if len(ring) > 1 && ring[0] == ring[len(ring) - 1] {
			ring = ring[:len(ring) - 1]
		}
		if simplify > 0 {
			ring = simplify_ring(ring, simplify)
		}
		if len(ring) >= 3 {
			append(&contours, ring)
		}
	}
	rule := o3d.Fill_Rule.Even_Odd if a.fill_rule == .Even_Odd else o3d.Fill_Rule.Nonzero
	return o3d.shapes_from_contours(contours[:], rule, context.temp_allocator)
}


// A closed ring with the points within `tol` of the simplified outline left
// out (Douglas-Peucker from the point farthest from the first), temp
// allocated.
@(private)
simplify_ring :: proc(ring: []o3d.Vec2, tol: f32) -> []o3d.Vec2 {
	n := len(ring)
	if n < 4 {
		return ring
	}
	keep := make([]bool, n, context.temp_allocator)
	far, best := 0, f32(-1)
	for p, i in ring {
		d := p - ring[0]
		if dd := d.x * d.x + d.y * d.y; dd > best {
			far, best = i, dd
		}
	}
	keep[0], keep[far] = true, true
	// Spans to refine, as index pairs (the second half wraps to 0 as n).
	stack := make([dynamic][2]int, 0, 32, context.temp_allocator)
	append(&stack, [2]int{0, far}, [2]int{far, n})
	for len(stack) > 0 {
		span := pop(&stack)
		a, b := ring[span[0]], ring[span[1] % n]
		ab := b - a
		l := max(math.sqrt(ab.x * ab.x + ab.y * ab.y), 1e-12)
		worst, at := f32(0), -1
		for i in span[0] + 1 ..< span[1] {
			p := ring[i] - a
			if d := abs(ab.x * p.y - ab.y * p.x) / l; d > worst {
				worst, at = d, i
			}
		}
		if at >= 0 && worst > tol {
			keep[at] = true
			append(&stack, [2]int{span[0], at}, [2]int{at, span[1]})
		}
	}
	out := make([dynamic]o3d.Vec2, 0, n, context.temp_allocator)
	for p, i in ring {
		if keep[i] {
			append(&out, p)
		}
	}
	return out[:]
}
