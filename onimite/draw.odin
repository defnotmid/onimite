package onimite

import "core:math"
import "core:mem/virtual"
import "core:sync"
import "core:thread"
import "deps:o3d"
import common "deps:oicut/common"
import "deps:oksl"
import vg "deps:ovg"
import vgsdl "deps:ovg/sdlgpu"
import vglottie "deps:ovg/lottie"
import vgsvg "deps:ovg/svg"

// A canvas image showing a decode of a media image (`Media_Image.key`).
Canvas_Image :: struct {
	id:  vg.Image_Id,
	key: u64,
}

// Builds frames with the video's render procs and draws them with ovg.
// Output is `video size * scale` pixels, premultiplied RGBA8.
Renderer :: struct {
	video:     ^Video,
	media:     ^Media,
	timeline:  Timeline,
	width:     u32,
	height:    u32,
	scale:     f32,
	ctx:       Context,
	canvas:    vg.Canvas,
	software:  vg.Software_Backend,
	// True when drawing with the built-in software backend.
	is_software: bool,
	// True when frames are recorded for a `Frame_Player` (record.odin).
	recording: bool,
	// Recording: the records play on a GPU backend (clip frames convert
	// there, video_yuv.odin). Set by the owner after `renderer_init`.
	plays_on_gpu: bool,
	// Borrowed task pool for fork-join work inside a frame (shader bands,
	// and the software backend's through `work`); nil works serially.
	pool:      ^thread.Pool,
	// `pool` as oicut's Work_Pool, which the software backend takes
	// (software_pool).
	work:      Pool_Work,
	// What the CPU draws this renderer's frames with (renderer_cpu): its
	// own, on `pool`, unless the owner points `cpu` at the one of the player
	// that draws them (a recording renderer's frames played on the CPU).
	cpu:       ^Cpu_Drawing,
	own_cpu:   Cpu_Drawing,
	arena:     virtual.Arena,
	// The frame's motion when built with `build_motion`, and what blurs a
	// frame drawn on the CPU by it (motion.odin).
	motion:    Motion,
	// A presentation's hold (Hold.Alive): the scenes that start at or before
	// frame `held_through` run `clock_offset` seconds ahead, so the held scene
	// keeps moving on its last frame and leaves (its transition) from where
	// the hold left it; the scenes after start on their own clock.
	clock_offset: f64,
	held_through: int,
	blur:      Frame_Blur,
	blur_gpu:  Frame_Blur_Gpu,
	// Canvas images of media images by name (`media_image_id`), and the
	// media's eviction count they were last checked against.
	images:    map[string]Canvas_Image,
	evictions: u64,
	layers:    vg.Layer_Stack,
	path:      vg.Path,
	// Scratch paths of outer shapes while a pattern tile draws (by depth).
	saved_paths: [dynamic]vg.Path,
	pattern_depth: int,
	// Groups with shape-rendering="crispEdges" around the node being drawn.
	crisp_depth:   int,
	// Clipping or masking groups around it: text they cut is cut on purpose.
	clip_depth:    int,
	// The groups' transforms so far, in video units (layers and scale
	// aside), and the boxes nodes should stay in, in video units
	// (Group.box); `offscreen` > 0 while drawing content into its own image.
	xform:         vg.Transform2D,
	boxes:         [dynamic]Box_Check,
	offscreen:     int,
	// The format of the content image being drawn into (`draw_content`):
	// a shader's output there takes it, so a half-float panel keeps a
	// shader's precision.
	content_format: vg.Pixel_Format,
	// The readable texts drawn this frame, in pixels (`check_frame`),
	// and how readable text drawn now is: the groups' opacity, 0 inside
	// blurred or filtered groups (glows and shadows are not read).
	texts:         [dynamic]Text_Seen,
	read_alpha:    f32,
	// Scratch for path bounding boxes (filter regions in bounding-box units).
	bbox_path:     vg.Path,
	// The blur of the group around the shape being drawn when that group
	// is drawn as its one shape with soft edges (`soft_blur`).
	feather:       f32,
	text:      vg.Text_Layout,
	pieces:    [dynamic]vg.Text_Piece,
	readback:  vg.Screenshot,
	// Canvas images showing video clip frames (video_clips.odin).
	video_images: Video_Images,
	// Recording: clip frames to upload when the frame is played.
	video_uploads: [dynamic]Video_Upload,
	// Shader programs and outputs (shader.odin).
	shader_state: Shader_State,
	// 3D layers (view3d.odin), and the GPU they render on: nil for the
	// CPU; a recording renderer leaves them to its player's (set by the
	// owner after `renderer_init`).
	view3d:       View3d_State,
	// While a shader's group input that a depth channel reads is drawn:
	// where its 3D layer leaves its depth image (nil otherwise).
	depth_capture: ^Depth_Capture,
	gpu3d:        ^View3d_Gpu,
	// ovg's SVG and Lottie renderers serve one document each (bound to its
	// images): one per document this renderer has drawn, found by document
	// (parallel arrays), and the overrides of the node being drawn.
	svg_assets:       [dynamic]^Svg_Asset,
	svg_renderers:    [dynamic]vgsvg.Renderer,
	svg_overrides:    [dynamic]vgsvg.Override,
	lottie_docs:      [dynamic]^vglottie.Document,
	lottie_renderers: [dynamic]vglottie.Renderer,
	lottie_overrides: [dynamic]vglottie.Override,
}

// Prepares a renderer drawing with `backend`, or with the software backend
// when `backend` is nil, or, with `recording`, one that records frames on
// any thread for a `Frame_Player` to draw with its backend (record.odin).
renderer_init :: proc(r: ^Renderer, video: ^Video, media: ^Media, scale: f32 = 1, backend: Maybe(vg.Backend) = nil, recording := false) -> Error {
	r.video = video
	r.media = media
	r.scale = scale
	// A scaled size rounds to even, as 4:2:0 video needs (`render --draft`
	// halves 1080x1350 to 540x676); the video's own size is kept as written.
	r.width, r.height = u32(video.width), u32(video.height)
	if scale != 1 {
		r.width = max(2 * u32(math.round(f32(video.width) * scale / 2)), 2)
		r.height = max(2 * u32(math.round(f32(video.height) * scale / 2)), 2)
	}
	r.timeline = resolve_timeline(video, media) or_return
	if err := virtual.arena_init_growing(&r.arena); err != nil {
		return .Render_Failed
	}
	b, has_backend := backend.?
	switch {
	case recording:
		vg.canvas_init_recording(&r.canvas)
		r.recording = true
	case !has_backend:
		vg.software_backend_init(&r.software)
		vg.canvas_init(&r.canvas, vg.software_backend(&r.software))
		r.is_software = true
	case:
		vg.canvas_init(&r.canvas, b)
	}
	r.images = make(map[string]Canvas_Image)
	r.shader_state.feedback.drawn = NO_FRAME
	r.ctx = {video = video, timeline = &r.timeline, media = media, videos = &media.videos, recording = recording}
	return nil
}

renderer_destroy :: proc(r: ^Renderer) {
	pool_work_destroy(&r.work)
	cpu_drawing_destroy(&r.own_cpu)
	vg.layer_stack_destroy(&r.layers, &r.canvas)
	video_images_destroy(&r.video_images, &r.canvas)
	shader_state_destroy(&r.shader_state, &r.canvas)
	view3d_state_destroy(&r.view3d)
	for &sr in r.svg_renderers {
		vgsvg.renderer_destroy(&sr, &r.canvas)
	}
	delete(r.svg_assets)
	delete(r.svg_renderers)
	delete(r.svg_overrides)
	delete(r.lottie_overrides)
	for &lr in r.lottie_renderers {
		vglottie.renderer_destroy(&lr, &r.canvas)
	}
	delete(r.lottie_docs)
	delete(r.lottie_renderers)
	vg.canvas_destroy(&r.canvas)
	if r.is_software {
		vg.software_backend_destroy(&r.software)
	}
	for key in r.images {
		delete(key)
	}
	delete(r.images)
	vg.text_layout_destroy(&r.text)
	delete(r.pieces)
	delete(r.texts)
	delete(r.boxes)
	delete(r.readback.pixels)
	delete(r.video_uploads)
	vg.path_destroy(&r.path)
	vg.path_destroy(&r.bbox_path)
	for &p in r.saved_paths {
		vg.path_destroy(&p)
	}
	delete(r.saved_paths)
	tree_destroy(&r.ctx.tree)
	diagnostics_clear(&r.ctx)
	delete(r.ctx.diagnostics)
	shader_library_destroy(&r.ctx.shaders)
	delete(r.ctx.shader_uses)
	delete(r.ctx.clip_uses)
	delete(r.ctx.scene_starts)
	placed_audio_destroy(&r.ctx.placed)
	svg_cache_destroy(&r.ctx.svgs)
	lottie_cache_destroy(&r.ctx.lotties)
	timeline_destroy(&r.timeline)
	virtual.arena_destroy(&r.arena)
	motion_destroy(&r.motion)
	frame_blur_destroy(&r.blur)
	if r.blur_gpu.color != nil {
		frame_blur_gpu_destroy(r.gpu3d, &r.blur_gpu)
	}
	r^ = {}
}

// Builds and draws video frame `index`, returning its pixels (borrowed until
// the next call). With `readback = false` a GPU backend leaves the frame in
// its output texture and nil is returned. Diagnostics accumulate in
// `r.ctx.diagnostics`. Frames drawn this way are done when it returns, so it
// first evicts decoded images over the media's budget (`media_evict`).
render_frame :: proc(r: ^Renderer, index: int, output: vg.Render_Output = 0, readback := true) -> []u8 {
	assert(!r.recording, "a recording renderer records frames (record_frame)")
	media_evict(r.media)
	build_frame_shown(r, index)
	feedback_catch_up(r, index)
	draw_frame(r)
	r.software.pool = software_pool(r)
	flush_frame(r, output)
	if r.is_software {
		if r.video.shutter > 0 {
			frame_blur_software(&r.blur, &r.software, r.pool)
		}
		return r.software.pixels
	}
	if r.video.shutter > 0 && r.gpu3d != nil {
		out := (^vgsdl.Output)(uintptr(output))
		if err := frame_blur_gpu(r.gpu3d, &r.blur_gpu, (^vgsdl.SDL_Backend)(r.canvas.backend.data), out.texture if out != nil else nil, {r.width, r.height}); err != nil {
			report(&r.ctx, .Error, {code = .View3d_Render, o3d = err})
		}
	}
	if !readback {
		return nil
	}
	delete(r.readback.pixels)
	r.readback, _ = vg.screenshot(&r.canvas)
	return r.readback.pixels
}

// Runs the render procs for frame `index` into `r.ctx.tree`.
build_frame :: proc(r: ^Renderer, index: int) {
	build_frame_at(r, index, 0, &r.arena)
}

// `build_frame` at `shift` seconds from the frame's moment (Frame.shift),
// the tree in `arena`.
@(private)
build_frame_at :: proc(r: ^Renderer, index: int, shift: f64, arena: ^virtual.Arena) {
	free_all(virtual.arena_allocator(arena))
	tree_reset(&r.ctx.tree, virtual.arena_allocator(arena))
	// The shutter never opens before the video starts.
	f := Frame{index = index, global_index = index, fps = r.video.fps, shift = max(shift, -f64(index) / f64(r.video.fps))}
	r.ctx.hold_offset, r.ctx.held_through = r.clock_offset, r.held_through
	r.ctx.frame = f
	clear(&r.ctx.shader_uses)
	clear(&r.ctx.clip_uses)
	clear(&r.ctx.scene_starts)
	r.ctx.audio_pending = 0
	if r.video.render != nil {
		// one render for the whole video: the hold runs it all on
		f.shift += r.clock_offset
		r.video.render(f, &r.ctx)
	} else {
		render_scenes(f, &r.ctx)
	}
}

// Draws the built frame on the canvas: the background, then the tree at the
// output scale.
draw_frame :: proc(r: ^Renderer) {
	c := &r.canvas
	// Motion blur: the frame keeps each draw's motion (set_motion in
	// draw_node), the screen's from its start (set_size).
	vg.canvas_motion_blur(c, r.video.shutter > 0)
	vg.set_size(c, r.width, r.height)
	vg.reset(c)
	vg.clear_rect(c, 0, 0, r.width, r.height, r.video.background)
	vg.scale(c, r.scale, r.scale)
	drop_evicted_images(r)
	r.shader_state.feedback.drew = false
	draw_tree(r)
	feedback_end_frame(r)
	check_frame(r)
}

// Deletes the canvas images of media images evicted since the last frame
// (their textures go with them); a later use uploads the new decode.
@(private = "file")
drop_evicted_images :: proc(r: ^Renderer) {
	cache := r.media.cache
	sync.guard(&cache.lock)
	if cache.evictions == r.evictions {
		return
	}
	r.evictions = cache.evictions
	stale :: proc(r: ^Renderer, name: string, e: Canvas_Image) -> bool {
		img := r.media.images[name]
		return img == nil || img.key != e.key
	}
	for name, e in r.images {
		if stale(r, name, e) {
			vg.delete_image(&r.canvas, e.id)
			key, _ := delete_key(&r.images, name)
			delete(key)
		}
	}
	for name, e in r.shader_state.premultiplied {
		if stale(r, name, e) {
			if vg.image_id_valid(e.id) {
				vg.delete_image(&r.canvas, e.id)
			}
			key, _ := delete_key(&r.shader_state.premultiplied, name)
			delete(key)
		}
	}
}

// Draws the tree built for the current frame onto the canvas (whose
// transform and target are set up by the caller).
draw_tree :: proc(r: ^Renderer) {
	r.shader_state.draw_gen += 1
	r.xform = vg.TRANSFORM_IDENTITY
	clear(&r.boxes)
	clear(&r.texts)
	r.read_alpha = 1
	vg.layer_stack_begin(&r.layers, &r.canvas, r.width, r.height, nil, r.ctx.tree.uses_blend)
	draw_children(r, 0)
	vg.layer_stack_end(&r.layers, &r.canvas)
}

// Draws node `i` of the built frame alone (its opacity included) into a
// transparent `pw x ph` image of the area `box` in the node's coordinates,
// and returns its premultiplied pixels, borrowed until the next render.
// The SVG export rasterizes video clips and shaders with it.
render_node :: proc(r: ^Renderer, i: i32, box: vg.Rect, pw, ph: u32) -> []u8 {
	c := &r.canvas
	vg.set_size(c, pw, ph)
	vg.reset(c)
	vg.clear_rect(c, 0, 0, pw, ph, TRANSPARENT)
	vg.scale(c, f32(pw) / box.w, f32(ph) / box.h)
	vg.translate(c, -box.x, -box.y)
	vg.layer_stack_begin(&r.layers, c, pw, ph, nil, false)
	draw_node(r, i)
	vg.layer_stack_end(&r.layers, c)
	flush_frame(r, 0)
	if r.is_software {
		return r.software.pixels
	}
	delete(r.readback.pixels)
	r.readback, _ = vg.screenshot(c)
	return r.readback.pixels
}

// Draws the canvas into `output`, after the frame's 3D renders on the GPU,
// whose images it shows.
@(private = "file")
flush_frame :: proc(r: ^Renderer, output: vg.Render_Output) {
	jobs := &r.view3d.jobs
	if jobs.count == 0 {
		vg.flush(&r.canvas, output)
		return
	}
	list := jobs.list[:jobs.count]
	if r.gpu3d == nil {
		// the CPU renders them at their rows, reading the tables
		sync.shared_lock(&r.media.view3d.lock)
		vg.flush(&r.canvas, output)
		sync.shared_unlock(&r.media.view3d.lock)
		jobs.count = 0
		return
	}
	err, locked := view3d_gpu_prepare(r.gpu3d, &r.media.view3d, list)
	if err != nil {
		report(&r.ctx, .Error, {code = .View3d_Render, o3d = err})
	}
	vg.flush(&r.canvas, output)
	if locked {
		if err := view3d_gpu_done(&r.media.view3d, list); err != nil {
			report(&r.ctx, .Error, {code = .View3d_Render, o3d = err})
		}
	}
	jobs.count = 0
}

@(private = "file")
draw_children :: proc(r: ^Renderer, parent: i32) {
	nodes := r.ctx.tree.nodes[:]
	for i := nodes[parent].first_child; i != NO_NODE; i = nodes[i].next {
		draw_node(r, i)
	}
}

@(private)
Box_Check :: struct {
	rect: vg.Rect,
	name: string,
}

// Reports node `i` when its box leaves the innermost Group.box around it.
@(private = "file")
check_box :: proc(r: ^Renderer, i: i32) {
	if len(r.boxes) == 0 || r.offscreen > 0 {
		return
	}
	b := node_bbox(r, i)
	if b.w < 0 {
		return
	}
	d := rect_transform(b, r.xform)
	box := r.boxes[len(r.boxes) - 1]
	over := max(box.rect.x - d.x, box.rect.y - d.y, (d.x + d.w) - (box.rect.x + box.rect.w), (d.y + d.h) - (box.rect.y + box.rect.h))
	if over <= 2 { // anti-aliasing, a spring's overshoot
		return
	}
	report(&r.ctx, .Warning, {code = .Outside_Box, name = node_label(&r.ctx.tree, i), a = box.name, w = over})
}

@(private = "file")
draw_node :: proc(r: ^Renderer, i: i32) {
	outer := r.ctx.node
	r.ctx.node = i + 1
	defer r.ctx.node = outer
	node := r.ctx.tree.nodes[i]
	if _, is_group := node.kind.(Group); !is_group {
		check_box(r, i)
		if r.video.shutter > 0 {
			vg.set_motion(&r.canvas, motion_opened(r, int(i)))
		}
	}
	switch n in node.kind {
	case Group:
		draw_group(r, i, n)
	case Rect:
		if n.w <= 0 || n.h <= 0 {
			report(&r.ctx, .Warning, {code = .Rect_Zero_Size, x = n.x, y = n.y})
			return
		}
		p := begin_path(r)
		vg.path_rounded_rect_elliptic(p, n.x, n.y, n.w, n.h, n.rx, n.ry)
		paint_shape(r, n.style)
	case Circle:
		if n.r <= 0 {
			report(&r.ctx, .Warning, {code = .Circle_Zero_Radius, x = n.cx, y = n.cy})
			return
		}
		p := begin_path(r)
		vg.path_circle(p, n.cx, n.cy, n.r)
		paint_shape(r, n.style)
	case Ellipse:
		if n.rx <= 0 || n.ry <= 0 {
			report(&r.ctx, .Warning, {code = .Ellipse_Zero_Radius, x = n.cx, y = n.cy})
			return
		}
		p := begin_path(r)
		vg.path_ellipse(p, n.cx, n.cy, n.rx, n.ry)
		paint_shape(r, n.style)
	case Line:
		p := begin_path(r)
		vg.path_move_to(p, n.x1, n.y1)
		vg.path_line_to(p, n.x2, n.y2)
		paint_shape(r, n.style)
	case Path:
		p := begin_path(r)
		if len(n.points) > 0 {
			vg.path_move_to(p, n.points[0].x, n.points[0].y)
			for q in n.points[1:] {
				vg.path_line_to(p, q.x, q.y)
			}
			if n.closed {
				vg.path_close(p)
			}
		} else if n.asset != nil {
			vg.path_append(p, &n.asset.path)
		} else if !vg.path_svg(p, n.d) {
			report(&r.ctx, .Error, {code = .Invalid_Path, a = n.d})
		}
		paint_shape(r, n.style, n.fill_rule, &n.asset.shape if n.asset != nil && len(n.asset.shape.data) > 0 else nil)
	case Text:
		draw_text(r, n, i)
	case Image:
		draw_image(r, n)
	case Video_Clip:
		draw_video_clip(r, n)
	case Shader:
		draw_shader(r, n)
	case Svg:
		draw_svg(r, n)
	case Lottie:
		draw_lottie(r, n)
	case View3d:
		draw_view3d(r, n)
	}
}

@(private = "file")
draw_group :: proc(r: ^Renderer, i: i32, g: Group) {
	if g.is_mask || g.is_pattern {
		// Drawn by its owner through `draw_mask`.
		return
	}
	c := &r.canvas
	vg.save(c)
	defer vg.restore(c)
	if g.crisp {
		r.crisp_depth += 1
	}
	defer if g.crisp {
		r.crisp_depth -= 1
	}
	_, clipped := g.clip.?
	clipped ||= g.clip_path != "" || g.masked
	if clipped {
		r.clip_depth += 1
	}
	defer if clipped {
		r.clip_depth -= 1
	}
	outer_xform := r.xform
	defer r.xform = outer_xform
	if t, ok := g.transform.?; ok {
		vg.apply_transform(c, transform_matrix(t))
		r.xform = vg.transform_multiply(transform_matrix(t), r.xform)
	}
	if box, ok := g.box.?; ok {
		append(&r.boxes, Box_Check{rect_transform(box, r.xform), g.box_name})
	}
	defer if _, ok := g.box.?; ok {
		pop(&r.boxes)
	}
	if clip, ok := g.clip.?; ok {
		vg.intersect_scissor(c, clip.x, clip.y, clip.w, clip.h)
	}
	opacity := g.opacity.? or_else 1
	if opacity <= 0 {
		return
	}
	_, has_filter := g.filter.?
	outer_alpha := r.read_alpha
	defer r.read_alpha = outer_alpha
	r.read_alpha = 0 if g.blur > 0 || has_filter else r.read_alpha * opacity
	effects := g.blur > 0 || g.clip_path != "" || g.masked || has_filter || g.blend != .Normal
	if !effects {
		if opacity >= 1 {
			draw_children(r, i)
			return
		}
		// One child that paints once: multiplying its alpha is exact and
		// needs no layer.
		node := r.ctx.tree.nodes[i]
		if node.first_child == node.last_child && node.first_child != NO_NODE && paints_once(r.ctx.tree.nodes[node.first_child].kind) {
			vg.set_global_alpha(c, vg.state(c).alpha * opacity)
			draw_children(r, i)
			return
		}
	}

	// A blurred group of one filled shape is that shape with soft edges.
	if sigma, soft := soft_blur(r, i, g); soft {
		vg.set_global_alpha(c, vg.state(c).alpha * opacity)
		r.feather = sigma
		draw_children(r, i)
		r.feather = 0
		return
	}

	// Composite the children as one layer: blurred, clipped, masked.
	params := vg.Layer_Params{opacity = opacity, blur = g.blur, clip_rule = g.clip_rule, blend = g.blend, mask_alpha = g.mask_alpha}
	filter := g.filter
	if fl, ok := &filter.?; ok {
		if fl.region.units == .Object_Bounding_Box {
			fl.region.bbox = children_bbox(r, i)
		}
		if len(g.filter_images) > 0 {
			// Image primitives: media names to canvas images (missing
			// ones make transparent black).
			ids := make([]vg.Image_Id, len(g.filter_images), context.temp_allocator)
			for name, k in g.filter_images {
				if id, found := media_image_id(r, name); found {
					ids[k] = id
				} else {
					report(&r.ctx, .Error, {code = .Missing_Filter_Image, name = name})
				}
			}
			fl.images = ids
		}
		params.filter = fl
	}
	clip: vg.Path
	defer vg.path_destroy(&clip)
	if g.clip_path != "" {
		if !vg.path_svg(&clip, g.clip_path) {
			report(&r.ctx, .Error, {code = .Invalid_Clip_Path, a = g.clip_path})
		}
		params.clip_path = &clip
	}
	vg.layer_push(&r.layers, c, params)
	if g.masked {
		if m := mask_child(r, i); m != NO_NODE {
			vg.layer_mask_begin(&r.layers, c)
			draw_children(r, m)
			vg.layer_mask_end(&r.layers, c)
		}
	}
	draw_children(r, i)
	vg.layer_pop(&r.layers, c)
}

// Whether a node paints once: one fill or one stroke of one shape, an
// image, a video's frame, a shader, a 3D layer. A group's opacity then
// multiplies its alpha exactly. An SVG, a Lottie, or a shape both filled and
// stroked paints several times, and what one paint covers would show
// through another: such a group is composited as a layer.
@(private = "file")
paints_once :: proc "contextless" (k: Node_Kind) -> bool {
	once :: proc "contextless" (fill: Paint, stroke: Stroke) -> bool {
		return fill == nil || stroke.paint == nil || stroke.width <= 0
	}
	switch n in k {
	case Rect:
		return once(n.fill, n.stroke)
	case Circle:
		return once(n.fill, n.stroke)
	case Ellipse:
		return once(n.fill, n.stroke)
	case Line:
		return once(n.fill, n.stroke)
	case Path:
		return once(n.fill, n.stroke)
	case Text:
		return once(n.fill, n.stroke)
	case Image, Video_Clip, Shader, View3d:
		return true
	case Group, Svg, Lottie:
		return false
	}
	return false
}

// The blur of group `i` when blurring is all it does and its one child is
// a filled shape without a stroke: drawing that shape with edges as soft as
// the blur's (`vg.Paint.feather`) shows the same thing without a layer and
// two blur passes. The group's opacity applies to the shape.
@(private = "file")
soft_blur :: proc(r: ^Renderer, i: i32, g: Group) -> (sigma: f32, ok: bool) {
	if g.clip_path != "" || g.masked || g.blend != .Normal {
		return
	}
	sigma = g.blur
	if f, has := g.filter.?; has {
		if g.blur > 0 || len(f.primitives) != 1 {
			return
		}
		b := f.primitives[0]
		if b.op != .Gaussian_Blur || b.std[0] != b.std[1] || b.has_subregion || (b.in1.kind != .Previous && b.in1.kind != .Source_Graphic) {
			return
		}
		sigma = b.std[0]
	}
	node := r.ctx.tree.nodes[i]
	if sigma <= 0 || node.first_child == NO_NODE || node.first_child != node.last_child {
		return
	}
	no_stroke :: proc(s: Stroke) -> bool {return s.paint == nil || s.width <= 0}
	#partial switch k in r.ctx.tree.nodes[node.first_child].kind {
	case Rect:
		ok = no_stroke(k.stroke) && !k.crisp
	case Circle:
		ok = no_stroke(k.stroke) && !k.crisp
	case Ellipse:
		ok = no_stroke(k.stroke) && !k.crisp
	case Path:
		ok = no_stroke(k.stroke) && !k.crisp
	}
	return
}

// The mask group of a masked group (its first child), or NO_NODE.
@(private = "file")
mask_child :: proc(r: ^Renderer, i: i32) -> i32 {
	first := r.ctx.tree.nodes[i].first_child
	if first == NO_NODE {
		return NO_NODE
	}
	if g, ok := r.ctx.tree.nodes[first].kind.(Group); ok && g.is_mask {
		return first
	}
	return NO_NODE
}

@(private = "file")
begin_path :: proc(r: ^Renderer) -> ^vg.Path {
	vg.path_reset(&r.path)
	return &r.path
}

// The ovg paint for a node paint over a shape with bounds `box`
// (objectBoundingBox units and pattern tiles need it).
@(private = "file")
to_vg_paint :: proc(r: ^Renderer, p: Paint, opacity: Maybe(f32), box: vg.Rect) -> (out: vg.Paint, ok: bool) {
	space: Paint_Space
	switch v in p {
	case Color:
		out = vg.paint_color(v)
	case Linear_Gradient:
		out = vg.paint_linear_gradient_stops(v.x1, v.y1, v.x2, v.y2, v.stops)
		space = v.space
	case Radial_Gradient:
		if f, has_focal := v.focal.?; has_focal {
			out = vg.paint_radial_gradient_focal_stops(v.cx, v.cy, v.r, f.x, f.y, v.inner_r, v.stops)
		} else {
			out = vg.paint_radial_gradient_stops(v.cx, v.cy, v.inner_r, v.r, v.stops)
		}
		space = v.space
	case Pattern:
		out = pattern_paint(r, v, box) or_return
		space = v.space
		space.units = .User // the tile already maps its units
	case:
		return {}, false
	}
	out.spread = space.spread
	t := space.transform.? or_else vg.TRANSFORM_IDENTITY
	if space.units == .Bounding_Box {
		t = vg.transform_multiply(t, vg.Transform2D{box.w, 0, 0, box.h, box.x, box.y})
	}
	if t != vg.TRANSFORM_IDENTITY {
		out.transform = t
	}
	if o, has := opacity.?; has {
		vg.paint_mul_alpha(&out, o)
	}
	return out, true
}

// Renders a pattern's tile (at the current scale, for crisp edges) and
// returns an image paint repeating it.
@(private = "file")
pattern_paint :: proc(r: ^Renderer, pat: Pattern, box: vg.Rect) -> (vg.Paint, bool) {
	x, y, w, h := pat.x, pat.y, pat.w, pat.h
	if pat.units == .Bounding_Box {
		x, y, w, h = box.x + x * box.w, box.y + y * box.h, w * box.w, h * box.h
	}
	if w <= 0 || h <= 0 {
		return {}, false
	}
	c := &r.canvas
	s := vg.transform_average_scale(vg.current_transform(c))
	pw := max(u32(math.ceil(w * s)), 1)
	ph := max(u32(math.ceil(h * s)), 1)
	tile := vg.layer_pattern_begin(&r.layers, c, pw, ph)
	vg.save(c)
	vg.reset_transform(c)
	vg.reset_scissor(c)
	vg.scale(c, f32(pw) / w, f32(ph) / h)
	// The shape being painted owns `r.path`: draw the tile with another.
	for len(r.saved_paths) <= r.pattern_depth {
		append(&r.saved_paths, vg.Path{})
	}
	r.path, r.saved_paths[r.pattern_depth] = r.saved_paths[r.pattern_depth], r.path
	r.pattern_depth += 1
	draw_children(r, pat.content)
	r.pattern_depth -= 1
	r.path, r.saved_paths[r.pattern_depth] = r.saved_paths[r.pattern_depth], r.path
	vg.restore(c)
	vg.layer_pattern_end(&r.layers, c)
	return vg.paint_image(tile, x, y, w, h, 0), true
}

// Draws the nodes under `content` (`w x h` units, origin top-left) into a
// pooled `pw x ph` image of `format` and returns it (a shader's group
// child; a view3d panel or label, in half floats).
@(private)
draw_content :: proc(r: ^Renderer, content: i32, w, h: f32, pw, ph: u32, format := vg.Pixel_Format.RGBA8) -> vg.Image_Id {
	c := &r.canvas
	// The content is clipped to its own image, not the frame: text in it is
	// not checked against the frame's edges.
	r.clip_depth += 1
	defer r.clip_depth -= 1
	r.offscreen += 1
	defer r.offscreen -= 1
	img := vg.layer_image_begin(&r.layers, c, pw, ph, format)
	outer_format := r.content_format
	r.content_format = format
	defer r.content_format = outer_format
	vg.save(c)
	vg.reset_transform(c)
	vg.reset_scissor(c)
	vg.set_global_alpha(c, 1)
	vg.scale(c, f32(pw) / w, f32(ph) / h)
	crisp := r.crisp_depth
	r.crisp_depth = 0
	draw_children(r, content)
	r.crisp_depth = crisp
	vg.restore(c)
	vg.layer_image_end(&r.layers, c)
	return img
}

// Fills and strokes the path built in `r.path` with `style`; `shape`, when
// given, is that fill built at load (an outline's), drawn instead of
// building it again.
@(private = "file")
paint_shape :: proc(r: ^Renderer, style: Shape_Style, rule := vg.Fill_Rule.Non_Zero, shape: ^vg.Shape = nil) {
	box := path_box(&r.path)
	anti_alias := !(style.crisp || r.crisp_depth > 0)
	c := &r.canvas
	alpha := vg.state(c).alpha
	if o, ok := style.opacity.?; ok {
		vg.set_global_alpha(c, alpha * o)
	}
	defer vg.set_global_alpha(c, alpha)
	if p, ok := to_vg_paint(r, style.fill, style.fill_opacity, box); ok {
		p.fill_rule = rule
		p.anti_alias = anti_alias
		p.feather = r.feather
		if shape != nil {
			vg.fill_shape(c, shape, p) // built at load: the same fill as r.path's
		} else {
			vg.fill_path(c, &r.path, p)
		}
	}
	stroke := style.stroke
	if p, ok := to_vg_paint(r, stroke.paint, stroke.opacity, box); ok && stroke.width > 0 {
		p.anti_alias = anti_alias
		p.stroke.line_width = stroke.width
		p.stroke.line_join = stroke.join
		p.stroke.miter_limit = stroke.miter_limit if stroke.miter_limit > 0 else 4
		vg.paint_set_line_cap(&p, stroke.cap)
		p.stroke.dash = stroke.dash
		p.stroke.dash_offset = stroke.dash_offset
		p.stroke.path_length = stroke.path_length
		vg.stroke_path(c, &r.path, p)
	}
}

@(private = "file")
layout_text :: proc(r: ^Renderer, t: Text) -> ^vg.Text_Layout {
	// Paint tags: 0 is the text's own fill, i + 1 is span i's.
	clear(&r.pieces)
	style := vg.Text_Style{family = t.font, size = t.size, weight = t.weight, italic = t.italic, letter_spacing = t.letter_spacing, features = t.features, variations = t.variations}
	append(&r.pieces, vg.Text_Piece{t.text, style, 0, 0})
	for span, i in t.spans {
		st := style
		if span.font != "" {st.family = span.font}
		if span.size > 0 {st.size = span.size}
		if span.weight != 0 {st.weight = span.weight}
		if it, ok := span.italic.?; ok {st.italic = it}
		if ls, ok := span.letter_spacing.?; ok {st.letter_spacing = ls}
		if span.features != nil {st.features = span.features}
		st.paint = u32(i + 1)
		append(&r.pieces, vg.Text_Piece{span.text, st, span.dx, span.dy})
	}
	l := &r.text
	fonts := media_text_fonts(r.media, t.font, t.weight, t.italic, t.variations)
	vg.text_layout(fonts, r.pieces[:], {x = t.x, y = t.y, align = vg.Text_Align(t.align), baseline = vg.Text_Baseline(t.baseline), line_height = t.line_height}, l)
	return l
}

@(private = "file")
draw_text :: proc(r: ^Renderer, t: Text, i: i32) {
	if t.text == "" && len(t.spans) == 0 {
		return
	}
	l := layout_text(r, t)
	for family in l.missing {
		report_missing_font(&r.ctx, family)
	}
	if len(l.glyphs) == 0 {
		return
	}
	label := t.text if t.text != "" else t.spans[0].text
	lo, hi := text_frame_box(r, l.min, l.max)
	check_text_bounds(r, label, lo, hi)
	if r.offscreen == 0 && r.read_alpha * (t.opacity.? or_else 1) >= 0.3 {
		if ilo, ihi, ok := text_ink_box(l); ok {
			ilo, ihi = text_frame_box(r, ilo, ihi)
			scene := -1 // the scene that drew it: the last one started at or before node i
			for start, k in r.ctx.scene_starts {
				if start > i {break}
				scene = k
			}
			append(&r.texts, Text_Seen{ilo, ihi, label, scene, i + 1})
		}
	}

	c := &r.canvas
	alpha := vg.state(c).alpha
	if o, ok := t.opacity.?; ok {
		vg.set_global_alpha(c, alpha * o)
	}
	defer vg.set_global_alpha(c, alpha)
	for run in l.runs {
		font := vg.text_layout_font(l, run)
		if font == nil {
			continue
		}
		glyphs := l.glyphs[run.first:][:run.count]
		fill, fill_opacity := t.fill, t.fill_opacity
		if run.paint > 0 {
			span := t.spans[run.paint - 1]
			if span.fill != nil {fill = span.fill}
			if span.fill_opacity != nil {fill_opacity = span.fill_opacity}
		}
		box := vg.Rect{l.min.x, l.min.y, l.max.x - l.min.x, l.max.y - l.min.y}
		if p, ok := to_vg_paint(r, fill, fill_opacity, box); ok {
			vg.fill_glyph_outlines(c, font, glyphs, run.em, p, &r.path)
		}
		if p, ok := to_vg_paint(r, t.stroke.paint, t.stroke.opacity, box); ok && t.stroke.width > 0 {
			p.stroke.line_width = t.stroke.width
			p.stroke.line_join = t.stroke.join
			p.stroke.miter_limit = t.stroke.miter_limit if t.stroke.miter_limit > 0 else 4
			vg.stroke_glyph_outlines(c, font, glyphs, run.em, p, &r.path)
		}
	}
}

// A text's layout box on the frame, in pixels (after transforms).
@(private = "file")
text_frame_box :: proc(r: ^Renderer, lo_box, hi_box: Vec2) -> (lo, hi: vg.Vec2) {
	xf := vg.current_transform(&r.canvas)
	corners := [4]vg.Vec2 {
		vg.transform_point(xf, lo_box.x, lo_box.y),
		vg.transform_point(xf, hi_box.x, lo_box.y),
		vg.transform_point(xf, lo_box.x, hi_box.y),
		vg.transform_point(xf, hi_box.x, hi_box.y),
	}
	lo, hi = corners[0], corners[0]
	for p in corners[1:] {
		lo = {min(lo.x, p.x), min(lo.y, p.y)}
		hi = {max(hi.x, p.x), max(hi.y, p.y)}
	}
	return
}

// Reports text whose box (pixels) leaves the frame, unless a clipping or
// masking group is around it (a slide or wipe cuts on purpose).
@(private = "file")
check_text_bounds :: proc(r: ^Renderer, text: string, lo, hi: vg.Vec2) {
	if r.clip_depth > 0 {
		return
	}
	w, h := f32(r.width), f32(r.height)
	if lo.x >= -0.5 && lo.y >= -0.5 && hi.x <= w + 0.5 && hi.y <= h + 0.5 {
		return
	}
	// The box in video units, as fframes reports it.
	s := r.scale if r.scale > 0 else 1
	bx, by, bw, bh := lo.x / s, lo.y / s, (hi.x - lo.x) / s, (hi.y - lo.y) / s
	if hi.x <= 0 || hi.y <= 0 || lo.x >= w || lo.y >= h {
		report(&r.ctx, .Info, {code = .Text_Off_Canvas, name = text, x = bx, y = by, w = bw, h = bh})
	} else {
		report(&r.ctx, .Warning, {code = .Text_Clipped, name = text, x = bx, y = by, w = bw, h = bh})
	}
}

// The box of a layout's inked glyphs (its line boxes leave room for
// accents and descenders the text may not have).
@(private = "file")
text_ink_box :: proc(l: ^vg.Text_Layout) -> (lo, hi: Vec2, ok: bool) {
	for run in l.runs {
		font := vg.text_layout_font(l, run)
		if font == nil {
			continue
		}
		for g in l.glyphs[run.first:][:run.count] {
			x0, y0, x1, y1: i32
			if !vg.font_glyph_box(font, g.glyph, &x0, &y0, &x1, &y1) {
				continue // a space
			}
			a := Vec2{g.x + f32(x0) * run.em, g.y - f32(y1) * run.em}
			b := Vec2{g.x + f32(x1) * run.em, g.y - f32(y0) * run.em}
			if !ok {
				lo, hi, ok = a, b, true
			} else {
				lo = {min(lo.x, a.x), min(lo.y, a.y)}
				hi = {max(hi.x, b.x), max(hi.y, b.y)}
			}
		}
	}
	return
}

// A readable text drawn this frame: its ink box in pixels and its string
// (borrowed from the frame's tree).
Text_Seen :: struct {
	lo, hi: vg.Vec2,
	text:   string,
	// Its scene among `Context.scene_starts`, -1 outside scenes.
	scene:  int,
	// Its node, index + 1 (`Diagnostic.node`).
	node:   i32,
}

@(private = "file")
draw_image :: proc(r: ^Renderer, n: Image) {
	if img, decoded := media_image(r.media, n.src, r.ctx.frame.index); img == nil {
		report(&r.ctx, .Error, {code = .Missing_Image, name = n.src})
		return
	} else if !decoded {
		report(&r.ctx, .Error, {code = .Undecodable_Image, name = n.src})
		return
	}
	id, ok := media_image_id(r, n.src)
	if !ok {
		return
	}
	info, _ := vg.image_info(&r.canvas, id)
	box, pic := fit_box(n.x, n.y, n.w, n.h, f32(info.width), f32(info.height), n.fit, n.align)
	p := vg.paint_image(id, pic.x, pic.y, pic.w, pic.h, 0, n.opacity.? or_else 1)
	// Contain draws the picture; cover is clipped to the box.
	shown := box if n.fit == .Cover else pic
	vg.path_reset(&r.path)
	vg.path_rect(&r.path, shown.x, shown.y, shown.w, shown.h)
	vg.fill_path(&r.canvas, &r.path, p)
}

// Bounds of the path's points (control points included), for bounding-box
// paint units.
@(private = "file")
path_box :: proc(p: ^vg.Path) -> vg.Rect {
	if len(p.pts) == 0 {
		return {}
	}
	lo, hi := p.pts[0], p.pts[0]
	for q in p.pts[1:] {
		lo = {min(lo.x, q.x), min(lo.y, q.y)}
		hi = {max(hi.x, q.x), max(hi.y, q.y)}
	}
	return {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}
}

// The union of the children's bounding boxes (fill geometry, no stroke) in
// the parent's coordinates: a group's objectBoundingBox.
@(private = "file")
children_bbox :: proc(r: ^Renderer, parent: i32) -> vg.Rect {
	nodes := r.ctx.tree.nodes[:]
	b := vg.Rect{0, 0, -1, -1}
	for i := nodes[parent].first_child; i != NO_NODE; i = nodes[i].next {
		b = rect_union(b, node_bbox(r, i))
	}
	return b if b.w >= 0 else {}
}

// Node `i`'s box in video units on the frame last built (its groups'
// transforms applied, effects and clips aside); w < 0 when it has none.
node_frame_box :: proc(r: ^Renderer, i: i32) -> vg.Rect {
	nodes := r.ctx.tree.nodes[:]
	parent := make([]i32, len(nodes), context.temp_allocator)
	for &p in parent {
		p = NO_NODE
	}
	for n, k in nodes {
		for c := n.first_child; c != NO_NODE; c = nodes[c].next {
			parent[c] = i32(k)
		}
	}
	m := vg.TRANSFORM_IDENTITY
	for a := parent[i]; a != NO_NODE; a = parent[a] {
		if g, ok := nodes[a].kind.(Group); ok {
			if t, has := g.transform.?; has {
				m = vg.transform_multiply(m, transform_matrix(t))
			}
		}
	}
	b := node_bbox(r, i)
	return rect_transform(b, m) if b.w >= 0 else b
}

// Node `i`'s box in its parent's coordinates (fill geometry, no stroke);
// w < 0 when it has none.
@(private)
node_bbox :: proc(r: ^Renderer, i: i32) -> vg.Rect {
	n, is_group := r.ctx.tree.nodes[i].kind.(Group)
	if !is_group {
		return leaf_bbox(r, &r.ctx.tree.nodes[i].kind)
	}
	if n.is_mask || n.is_pattern {
		return {0, 0, -1, -1}
	}
	b := children_bbox(r, i)
	if t, ok := n.transform.?; ok && b.w >= 0 {
		b = rect_transform(b, transform_matrix(t))
	}
	return b
}

// A drawn node's box in its parent's coordinates, as `node_bbox` (a group
// has none here).
@(private)
leaf_bbox :: proc(r: ^Renderer, kind: ^Node_Kind) -> vg.Rect {
	EMPTY :: vg.Rect{0, 0, -1, -1}
	box :: proc(x0, y0, x1, y1: f32) -> vg.Rect {
		return {min(x0, x1), min(y0, y1), abs(x1 - x0), abs(y1 - y0)}
	}
	switch n in kind^ {
	case Group:
		return EMPTY
	case Rect:
		return {n.x, n.y, n.w, n.h}
	case Circle:
		return {n.cx - n.r, n.cy - n.r, 2 * n.r, 2 * n.r}
	case Ellipse:
		return {n.cx - n.rx, n.cy - n.ry, 2 * n.rx, 2 * n.ry}
	case Line:
		return box(n.x1, n.y1, n.x2, n.y2)
	case Path:
		p := &r.bbox_path
		vg.path_reset(p)
		if len(n.points) > 0 {
			for q in n.points {
				vg.path_line_to(p, q.x, q.y)
			}
		} else if n.asset != nil {
			vg.path_append(p, &n.asset.path)
		} else {
			vg.path_svg(p, n.d)
		}
		return path_box(p) if len(p.pts) > 0 else EMPTY
	case Text:
		if n.text == "" && len(n.spans) == 0 {
			return EMPTY
		}
		l := layout_text(r, n)
		return {l.min.x, l.min.y, l.max.x - l.min.x, l.max.y - l.min.y}
	case Image:
		img := r.media.images[n.src] or_else nil
		if img == nil || img.width <= 0 || img.height <= 0 {
			return EMPTY
		}
		b, _ := fit_box(n.x, n.y, n.w, n.h, f32(img.width), f32(img.height), n.fit, n.align)
		return b
	case Svg:
		if n.asset == nil || n.asset.doc.width <= 0 || n.asset.doc.height <= 0 {
			return EMPTY
		}
		b, _ := fit_box(n.x, n.y, n.w, n.h, n.asset.doc.width, n.asset.doc.height, n.fit, n.align)
		return b
	case Lottie:
		if n.doc == nil || n.doc.width <= 0 || n.doc.height <= 0 {
			return EMPTY
		}
		b, _ := fit_box(n.x, n.y, n.w, n.h, n.doc.width, n.doc.height, n.fit, n.align)
		return b
	case Video_Clip:
		info := r.ctx.videos.infos[n.clip]
		fw, fh := rotated_size(f32(info.width), f32(info.height), info.rotation)
		b, _ := fit_box(n.x, n.y, n.w, n.h, fw, fh, n.fit, n.align)
		return b
	case Shader:
		return {n.x, n.y, n.w, n.h}
	case View3d:
		return {n.x, n.y, n.w, n.h}
	}
	return EMPTY
}

@(private = "file")
rect_union :: proc "contextless" (a, b: vg.Rect) -> vg.Rect {
	if a.w < 0 {
		return b
	}
	if b.w < 0 {
		return a
	}
	x0, y0 := min(a.x, b.x), min(a.y, b.y)
	x1, y1 := max(a.x + a.w, b.x + b.w), max(a.y + a.h, b.y + b.h)
	return {x0, y0, x1 - x0, y1 - y0}
}

@(private = "file")
rect_transform :: proc "contextless" (r: vg.Rect, t: vg.Transform2D) -> vg.Rect {
	lo := vg.Vec2{1e30, 1e30}
	hi := vg.Vec2{-1e30, -1e30}
	for c in ([4]vg.Vec2{{r.x, r.y}, {r.x + r.w, r.y}, {r.x, r.y + r.h}, {r.x + r.w, r.y + r.h}}) {
		q := vg.transform_point(t, c.x, c.y)
		lo = {min(lo.x, q.x), min(lo.y, q.y)}
		hi = {max(hi.x, q.x), max(hi.y, q.y)}
	}
	return {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}
}

// The software backend's bands on the renderer's pool, through oicut's
// Work_Pool (made the first time, again if the owner changed the pool);
// nil when it has none.
@(private)
software_pool :: proc(r: ^Renderer) -> ^common.Work_Pool {
	if r.pool == nil {
		return nil
	}
	if r.work.pool != r.pool {
		pool_work_destroy(&r.work)
		pool_work_init(&r.work, r.pool)
	}
	return &r.work.work_pool
}

// What the CPU draws a renderer's frames with, owned by what draws them:
// the task pool (borrowed), the float rows the shader interpreter shades
// half-float targets through and its working memory by band worker, and
// the 3D software renderer, each grown once and kept. Used by one drawing
// thread at a time.
Cpu_Drawing :: struct {
	pool:     ^thread.Pool,
	scratch:  [dynamic][4]f32,
	runs:     [dynamic]oksl.Scratch,
	software: o3d.Software,
}

cpu_drawing_destroy :: proc(d: ^Cpu_Drawing) {
	delete(d.scratch)
	for &r in d.runs {
		oksl.scratch_destroy(&r)
	}
	delete(d.runs)
	o3d.software_destroy(&d.software)
	d^ = {}
}

// The renderer's Cpu_Drawing: the owner's, else its own on its pool.
@(private)
renderer_cpu :: proc(r: ^Renderer) -> ^Cpu_Drawing {
	if r.cpu != nil {
		return r.cpu
	}
	r.own_cpu.pool = r.pool
	return &r.own_cpu
}
