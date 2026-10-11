package onimite

import "base:runtime"
import "core:hash"
import "core:math"
import "core:strings"
import "core:sync"
import "core:thread"
import vg "deps:ovg"
import "deps:oksl"

// Shader layers (fframes' `Shader::sksl` / `Shader::shadertoy`): an SkSL
// shader or Shadertoy GLSL (both compiled by oksl, GLSL as its own dialect
// with Shadertoy's inputs and mainImage entry) filling a box, composed like
// an image (transforms, clips, masks, opacity). Sources compile once per
// process, cached by source hash; a frame's node carries its packed uniform
// block in the frame arena. Drawing runs the program into a pooled image at
// the box's on-screen pixel size (ovg `run_program`: SDL_GPU, or oksl's CPU
// interpreter on the software backend in row bands across threads) and
// fills the box with it.
//
// Coordinates follow fframes: `half4 main(float2 coord)` gets the box
// position in the box's own units (not pixels), origin top-left, and
// returns premultiplied color; a declared `uniform float3 iResolution` is
// the box size in those units, `iTime`/`iTimeDelta`/`iFrame` the frame's
// clock. `uniform shader` children are bound by name to images, video
// clips or groups of nodes, and sampled with `.eval(p)` in the child's
// pixels. Shadertoy code gets every Shadertoy input (oksl.INPUTS, filled
// here by row: iChannelTime with a video channel's clip time, iSampleRate
// with the mix rate) and binds `iChannel0..3` by name the same way, sampled
// with `texture(iChannelN, uv)` in 0..1 uv. A group child
// (`shader_content_begin`) is drawn into an offscreen image before the
// shader runs; its pixel space is the shader box's units (or its own
// `w x h`) with the group's nodes in those units, origin top-left, so
// `.eval(coord)` shows the group where it was drawn. The image is rendered
// at the box's on-screen pixel size, so it stays sharp.
//
// Multipass Shadertoy programs (Common + Buffer A-D + Image) compile with
// oksl's `compile_program` into a pass table and an edge array; a node
// carries a uniform block and the external channels per pass. Drawing runs
// the buffer passes into half-float feedback buffers, then the Image pass
// like a single-pass shader (feedback.odin: the buffers, their catch-up when
// frames are not drawn in order, and the preview's checkpoints).

// An image or a synced video clip from the media bound to a channel, or a
// group of nodes.
Shader_Input :: struct {
	src:        string,
	// A group child: its content node (`shader_content_begin`), 0 for none,
	// and the size of its pixel space (0: the shader box's).
	content:    i32,
	w, h:       f32,
	// Video clips: playback start on the frame clock, offset into the
	// clip, looping (as `video_clip`).
	start_from: f32,
	clip_start: f32,
	looping:    bool,
}

// A named uniform: numbers (vectors, colors, matrices column by column,
// arrays element by element), or an input bound to the `uniform shader`
// child of that name.
Shader_Uniform :: struct {
	name:   string,
	values: []f32,
	input:  Maybe(Shader_Input),
}

// What a channel of a multipass program's pass reads: a buffer, or an
// image, video clip or group (an external input).
Shader_Pass_Channel :: struct {
	kind:   oksl.Channel_Kind,
	buffer: oksl.Pass_Kind,
	input:  Shader_Input,
}

// A pass of a multipass program: its Shadertoy GLSL ("" for a pass the
// program does not have) and channels (iChannel0..3).
Shader_Pass :: struct {
	source:   string,
	channels: [oksl.CHANNEL_COUNT]Shader_Pass_Channel,
}

Shader_Params :: struct {
	// A shader file in the media: SkSL (`aurora.sksl`), or Shadertoy GLSL
	// when it ends in `.glsl`. Labels an inline source in messages.
	src:        string,
	// Inline SkSL, or inline Shadertoy GLSL; either wins over `src`.
	sksl:       string,
	shadertoy:  string,
	// A multipass Shadertoy program instead (`multipass`): Common's source
	// and the passes. Uniforms are set in every pass that declares them.
	multipass:  bool,
	common:     string,
	passes:     [oksl.Pass_Kind]Shader_Pass,
	x, y, w, h: f32,
	uniforms:   []Shader_Uniform,
	// `iTime` in seconds; default the frame's (scene-relative) time.
	time:       Maybe(f32),
	opacity:    Maybe(f32),
}

Shader_Channel_Kind :: enum u8 {
	None,
	Image,
	Video,
	Group,
}

Shader_Channel :: struct {
	kind:    Shader_Channel_Kind,
	// Media image name.
	image:   string,
	// Video clip and the clip time this frame shows.
	clip:    int,
	seconds: f64,
	// Group content node and its pixel space (0: the shader box's).
	content: i32,
	w, h:    f32,
}

// The node. `block` is the uniform block (frame arena) with everything but
// the children's sizes, which drawing fills in.
Shader :: struct {
	program:  int,
	x, y, w, h: f32,
	block:    []u8,
	channels: [oksl.CHANNEL_COUNT]Shader_Channel,
	opacity:  Maybe(f32),
	// A multipass program: per pass (the graph's order), its block and
	// external channels (frame arena); its feedback instance (the program
	// and its occurrence in the frame) and iFrame.
	pass_blocks:   [][]u8,
	pass_channels: [][oksl.CHANNEL_COUNT]Shader_Channel,
	instance:      u64,
	frame:         int,
}

// Compiled shaders by source hash: parallel arrays indexed by program.
Shader_Library :: struct {
	hashes:  [dynamic]u64,
	labels:  [dynamic]string,
	// The module, or the pass graph of a multipass program (the other is
	// nil); on failure it holds the errors and `ok` is false.
	modules: [dynamic]^oksl.Module,
	graphs:  [dynamic]^oksl.Pass_Graph,
	errors:  [dynamic][]oksl.Error,
	ok:      [dynamic]bool,
	by_hash: map[u64]int,
}

shader_library_destroy :: proc(l: ^Shader_Library) {
	for m in l.modules {
		oksl.destroy(m)
	}
	for g in l.graphs {
		oksl.destroy_program(g)
	}
	for s in l.labels {
		delete(s)
	}
	delete(l.hashes)
	delete(l.labels)
	delete(l.modules)
	delete(l.graphs)
	delete(l.errors)
	delete(l.ok)
	delete(l.by_hash)
	l^ = {}
}

// The program for `source` (SkSL, or Shadertoy GLSL), compiling it on first
// use.
shader_library_get :: proc(l: ^Shader_Library, source, label: string, shadertoy := false) -> int {
	h := hash.fnv64a(transmute([]u8)source, 0xcbf29ce484222325 if !shadertoy else 0x84222325cbf29ce4)
	if i, ok := l.by_hash[h]; ok {
		return i
	}
	m: ^oksl.Module
	errors: []oksl.Error
	ok: bool
	if shadertoy {
		m, errors, ok = oksl.compile_shadertoy(source)
	} else {
		m, errors, ok = oksl.compile(source)
	}
	return shader_library_add(l, h, label, m, nil, errors, ok)
}

// The program for a multipass Shadertoy program, compiling it on first use.
shader_library_get_program :: proc(l: ^Shader_Library, desc: oksl.Program_Desc, label: string) -> int {
	h := hash.fnv64a(transmute([]u8)desc.common, 0x9e3779b97f4a7c15)
	for kind in oksl.Pass_Kind {
		h = hash.fnv64a(transmute([]u8)desc.sources[kind], h ~ u64(kind))
		channels := desc.channels[kind]
		h = hash.fnv64a(([^]u8)(&channels)[:size_of(channels)], h)
	}
	if i, ok := l.by_hash[h]; ok {
		return i
	}
	g, errors, ok := oksl.compile_program(desc)
	return shader_library_add(l, h, label, nil, g, errors, ok)
}

@(private = "file")
shader_library_add :: proc(l: ^Shader_Library, h: u64, label: string, m: ^oksl.Module, g: ^oksl.Pass_Graph, errors: []oksl.Error, ok: bool) -> int {
	i := len(l.hashes)
	append(&l.hashes, h)
	append(&l.labels, strings.clone(label))
	append(&l.modules, m)
	append(&l.graphs, g)
	append(&l.errors, errors)
	append(&l.ok, ok)
	l.by_hash[h] = i
	return i
}

// Adds a shader layer for frame `f` (its time is the frame's, so scene
// frames give scene-relative `iTime`). Compile errors are reported (with
// file:line:col) and the layer is skipped; returns false then.
shader :: proc(ctx: ^Context, f: Frame, p: Shader_Params) -> bool {
	if p.multipass {
		return shader_multipass(ctx, f, p)
	}
	source, shadertoy := p.sksl, false
	if source == "" && p.shadertoy != "" {
		source, shadertoy = p.shadertoy, true
	}
	label := p.src if p.src != "" else "<inline>"
	if source == "" {
		ok: bool
		source, ok = ctx.media.shaders[p.src]
		if !ok {
			report(ctx, .Error, {code = .Missing_Shader, name = p.src})
			return false
		}
		shadertoy = strings.has_suffix(p.src, ".glsl")
	}
	lib := &ctx.shaders
	prog := shader_library_get(lib, source, label, shadertoy)
	if !lib.ok[prog] {
		shader_report_errors(ctx, lib, prog)
		return false
	}
	if p.w <= 0 || p.h <= 0 {
		report(ctx, .Warning, {code = .Shader_Zero_Size, name = label, x = p.x, y = p.y})
		return true
	}
	m := lib.modules[prog]
	n := Shader {
		program = prog,
		x       = p.x,
		y       = p.y,
		w       = p.w,
		h       = p.h,
		opacity = p.opacity,
	}
	n.block = make([]u8, m.block_size, ctx.tree.arena)
	shader_write_builtins(m, n.block, f, p)
	for u in p.uniforms {
		if input, is_input := u.input.?; is_input {
			ch := -1
			for name, k in m.channel_names {
				if name == u.name {
					ch = k
				}
			}
			if ch < 0 {
				report(ctx, .Warning, {code = .Shader_No_Channel if shadertoy else .Shader_No_Child, name = label, a = u.name})
				continue
			}
			n.channels[ch] = shader_channel(ctx, f, label, input)
			if n.channels[ch].kind == .Video {
				oksl.write_input(n.block, .Channel_Time, {f32(n.channels[ch].seconds)}, ch)
			}
			continue
		}
		if !shader_write_uniform(ctx, m, n.block, label, u) {
			report(ctx, .Warning, {code = .Shader_Undeclared_Uniform, name = label, a = u.name})
		}
	}
	shader_report_unset(ctx, m, label, p.uniforms)
	for name, ch in m.channel_names {
		if name != "" && n.channels[ch].kind == .None {
			report(ctx, .Warning, {code = .Shader_Unbound_Channel, name = label, a = name})
		}
	}
	tree_add(&ctx.tree, n)
	return true
}

// A multipass program: compiled as a pass graph; every pass gets its block
// (the same built-ins and uniforms) and its external channels.
@(private = "file")
shader_multipass :: proc(ctx: ^Context, f: Frame, p: Shader_Params) -> bool {
	label := p.src if p.src != "" else "<inline>"
	desc := oksl.Program_Desc {
		common = p.common,
	}
	for kind in oksl.Pass_Kind {
		desc.sources[kind] = p.passes[kind].source
		for ch, i in p.passes[kind].channels {
			switch ch.kind {
			case .None:
			case .Buffer:
				desc.channels[kind][i] = {.Buffer, u8(ch.buffer)}
			case .External:
				desc.channels[kind][i] = {.External, u8(int(kind) * oksl.CHANNEL_COUNT + i)}
			}
		}
	}
	lib := &ctx.shaders
	prog := shader_library_get_program(lib, desc, label)
	if !lib.ok[prog] {
		shader_report_errors(ctx, lib, prog)
		return false
	}
	if p.w <= 0 || p.h <= 0 {
		report(ctx, .Warning, {code = .Shader_Zero_Size, name = label, x = p.x, y = p.y})
		return true
	}
	g := lib.graphs[prog]
	arena := ctx.tree.arena
	n := Shader {
		program       = prog,
		x             = p.x,
		y             = p.y,
		w             = p.w,
		h             = p.h,
		opacity       = p.opacity,
		pass_blocks   = make([][]u8, len(g.passes), arena),
		pass_channels = make([][oksl.CHANNEL_COUNT]Shader_Channel, len(g.passes), arena),
		instance      = shader_instance(ctx, prog),
		frame         = f.index,
	}
	declared := make([]bool, len(p.uniforms), context.temp_allocator)
	for pass, pi in g.passes {
		m := pass.module
		block := make([]u8, m.block_size, arena)
		shader_write_builtins(m, block, f, p)
		for u, k in p.uniforms {
			if u.input != nil {
				report(ctx, .Warning, {code = .Shader_Pass_Input, name = label, a = u.name})
				continue
			}
			declared[k] |= shader_write_uniform(ctx, m, block, label, u)
		}
		shader_report_unset(ctx, m, label, p.uniforms)
		bound: bit_set[0 ..< oksl.CHANNEL_COUNT]
		for e in g.edges[pass.edges.start:][:pass.edges.count] {
			bound += {int(e.channel)}
			if e.source != .External {
				continue
			}
			ch := shader_channel(ctx, f, label, p.passes[pass.kind].channels[e.channel].input)
			n.pass_channels[pi][e.channel] = ch
			if ch.kind == .Video {
				oksl.write_input(block, .Channel_Time, {f32(ch.seconds)}, int(e.channel))
			}
		}
		for ch in m.channels_used - bound {
			name := oksl.SOURCE_NAMES[oksl.pass_source(pass.kind)]
			report(ctx, .Warning, {code = .Shader_Pass_Unbound, name = label, a = m.channel_names[ch], b = name, n = i64(ch)})
		}
		n.pass_blocks[pi] = block
	}
	for u, k in p.uniforms {
		if u.input == nil && !declared[k] {
			report(ctx, .Warning, {code = .Shader_Undeclared_Uniform, name = label, a = u.name})
		}
	}
	tree_add(&ctx.tree, n)
	return true
}

// A multipass program's instance in this frame: the program and how many
// times the frame used it before (so two layers of one program keep their
// own feedback buffers).
@(private = "file")
shader_instance :: proc(ctx: ^Context, prog: int) -> u64 {
	for len(ctx.shader_uses) <= prog {
		append(&ctx.shader_uses, 0)
	}
	k := ctx.shader_uses[prog]
	ctx.shader_uses[prog] += 1
	return u64(prog) << 32 | u64(k)
}

@(private = "file")
shader_report_errors :: proc(ctx: ^Context, lib: ^Shader_Library, prog: int) {
	for e in lib.errors[prog] {
		report(ctx, .Error, {code = .Shader_Compile, name = lib.labels[prog], shader = e})
	}
}

// The built-in inputs of frame `f` (the block's start), and the built-in
// names declared with another type (`uniform float iFrame;`), which are
// user uniforms filled too, as fframes does.
@(private = "file")
shader_write_builtins :: proc(m: ^oksl.Module, block: []u8, f: Frame, p: Shader_Params) {
	fps := f32(max(f.fps, 1))
	time := p.time.? or_else frame_seconds(f)
	oksl.write_builtins(block, {resolution = {p.w, p.h, 1}, time = time, time_delta = 1 / fps, frame = i32(f.index), frame_rate = fps, sample_rate = MIX_RATE})
	autos := shader_auto_values(f, p)
	for &a in autos {
		oksl.set_uniform(m, block, a.name, a.values[:a.count])
	}
}

@(private = "file")
Auto_Value :: struct {
	name:   string,
	values: [3]f32,
	count:  int,
}

@(private = "file")
shader_auto_values :: proc(f: Frame, p: Shader_Params) -> [5]Auto_Value {
	fps := f32(max(f.fps, 1))
	time := p.time.? or_else frame_seconds(f)
	return {{"iResolution", {p.w, p.h, 1}, 3}, {"iTime", {time, 0, 0}, 1}, {"iTimeDelta", {1 / fps, 0, 0}, 1}, {"iFrame", {f32(f.index), 0, 0}, 1}, {"iFrameRate", {fps, 0, 0}, 1}}
}

@(private = "file")
shader_is_auto :: proc(name: string) -> bool {
	switch name {
	case "iResolution", "iTime", "iTimeDelta", "iFrame", "iFrameRate":
		return true
	}
	return false
}

// Writes number uniform `u` if `m` declares it (false otherwise).
@(private = "file")
shader_write_uniform :: proc(ctx: ^Context, m: ^oksl.Module, block: []u8, label: string, u: Shader_Uniform) -> bool {
	info, declared := oksl.find_uniform(m, u.name)
	if !declared {
		return false
	}
	per := int(info.type.rows) * max(int(info.type.cols), 1)
	count := max(info.count, 1)
	if len(u.values) != per && len(u.values) != per * count {
		report(ctx, .Warning, {code = .Shader_Uniform_Count, name = label, a = u.name, n = i64(per), m = i64(len(u.values))})
	}
	for k := 0; k < count && k * per < len(u.values); k += 1 {
		oksl.set_uniform(m, block, u.name, u.values[k * per:min(len(u.values), (k + 1) * per)], k)
	}
	return true
}

// Declared uniforms nobody set stay zero; say so, as fframes does.
@(private = "file")
shader_report_unset :: proc(ctx: ^Context, m: ^oksl.Module, label: string, uniforms: []Shader_Uniform) {
	unset: for info in m.uniforms {
		if shader_is_auto(info.name) {
			continue
		}
		for u in uniforms {
			if u.name == info.name {
				continue unset
			}
		}
		report(ctx, .Warning, {code = .Shader_Unset_Uniform, name = label, a = info.name})
	}
}

// Opens the content of a group child: a hidden group under the root, drawn
// only by the shader that binds it (`Shader_Input.content`). Close it with
// `group_end`.
shader_content_begin :: proc(ctx: ^Context) -> i32 {
	return pattern_begin(ctx)
}

@(private = "file")
shader_channel :: proc(ctx: ^Context, f: Frame, label: string, in_: Shader_Input) -> Shader_Channel {
	if in_.content > 0 {
		return {kind = .Group, content = in_.content, w = max(in_.w, 0), h = max(in_.h, 0)}
	}
	if in_.src == "" {
		return {}
	}
	if _, ok := ctx.media.images[in_.src]; ok {
		return {kind = .Image, image = strings.clone(in_.src, ctx.tree.arena)}
	}
	v := ctx.videos
	if i, ok := v.by_name[in_.src]; ok {
		if v.handles[i] < 0 {
			report(ctx, .Error, {code = .Undecodable_Video, name = in_.src, video = v.failures[i]})
			return {}
		}
		t, showing := video_clip_time(v.infos[i], f, in_.start_from, in_.clip_start, in_.looping)
		if !showing {
			return {}
		}
		if v.source.prefetch != nil && !ctx.recording {
			v.source.prefetch(v.source.data, v.handles[i], t)
		}
		return {kind = .Video, clip = i, seconds = t}
	}
	report(ctx, .Error, {code = .Missing_Image, name = in_.src})
	return {}
}

// ---- drawing ----------------------------------------------------------------------

// Programs per library entry: one, or one per pass of a multipass program.
SHADER_PASS_MAX :: oksl.BUFFER_COUNT + 1

// Renderer-side shader state: ovg programs per library entry (and pass),
// pooled output images, premultiplied copies of media images with
// transparency (children), multipass feedback buffers, and the task pool
// the CPU interpreter shades bands on (the renderer's, borrowed).
Shader_State :: struct {
	programs:      [dynamic][SHADER_PASS_MAX]vg.Program_Id,
	cpu:           [dynamic][SHADER_PASS_MAX]^Shader_Cpu,
	// Output images: parallel arrays, reused across frames.
	image:         [dynamic]vg.Image_Id,
	width:         [dynamic]u32,
	height:        [dynamic]u32,
	used_frame:    [dynamic]int,
	// By media image name; an invalid id: opaque, the regular texture serves.
	premultiplied: map[string]Canvas_Image,
	feedback:      Feedback,
	pool:          ^thread.Pool,
	// Float rows the CPU interpreter shades half-float targets through.
	scratch:       [dynamic][4]f32,
}

// What the CPU program callback needs.
Shader_Cpu :: struct {
	module: ^oksl.Module,
	state:  ^Shader_State,
}

shader_state_destroy :: proc(s: ^Shader_State, c: ^vg.Canvas) {
	feedback_destroy(&s.feedback, c)
	for ids in s.programs {
		for id in ids {
			if vg.program_id_valid(id) {
				vg.delete_program(c, id)
			}
		}
	}
	for ps in s.cpu {
		for p in ps {
			free(p)
		}
	}
	for id in s.image {
		vg.delete_image(c, id)
	}
	for name, e in s.premultiplied {
		delete(name)
		if vg.image_id_valid(e.id) {
			vg.delete_image(c, e.id)
		}
	}
	delete(s.programs)
	delete(s.cpu)
	delete(s.image)
	delete(s.width)
	delete(s.height)
	delete(s.used_frame)
	delete(s.premultiplied)
	delete(s.scratch)
	s^ = {}
}

draw_shader :: proc(r: ^Renderer, n: Shader) {
	if r.ctx.shaders.graphs[n.program] != nil {
		draw_multipass(r, n)
		return
	}
	lib := &r.ctx.shaders
	prog, ok := shader_program(r, n.program, 0, lib.modules[n.program])
	if !ok {
		return
	}
	r.shader_state.pool = r.pool
	c := &r.canvas
	xf := vg.current_transform(c)
	sx := math.hypot(xf[0], xf[1])
	sy := math.hypot(xf[2], xf[3])
	if !(sx > 0) || !(sy > 0) {
		return
	}
	pw := u32(clamp(math.ceil(n.w * sx), 1, 8192))
	ph := u32(clamp(math.ceil(n.h * sy), 1, 8192))
	target := shader_image(r, pw, ph)
	if !vg.image_id_valid(target) {
		return
	}
	// Children, and their sizes for `.eval` and texelFetch.
	channels: [oksl.CHANNEL_COUNT]vg.Image_Id
	res: [oksl.CHANNEL_COUNT][3]f32
	for ch, i in n.channels {
		channels[i], res[i] = shader_channel_image(r, ch, n.w, n.h, sx, sy)
	}
	shader_run_into(r, n, prog, target, n.block, channels, res)
}

// Runs a program into `target` at the box's on-screen size and fills the
// box with it.
@(private)
shader_run_into :: proc(r: ^Renderer, n: Shader, prog: vg.Program_Id, target: vg.Image_Id, block: []u8, channels: [oksl.CHANNEL_COUNT]vg.Image_Id, res: [oksl.CHANNEL_COUNT][3]f32) {
	c := &r.canvas
	// The block lives in the frame arena; finish it in place.
	res := res
	channels := channels
	for i in 0 ..< oksl.CHANNEL_COUNT {
		oksl.write_input(block, .Channel_Resolution, res[i][:], i)
	}
	if err := vg.run_program(c, prog, target, block, channels[:]); err != nil {
		report(&r.ctx, .Error, {code = .Shader_Run, name = r.ctx.shaders.labels[n.program], gpu = err})
		return
	}
	p := vg.paint_image(target, n.x, n.y, n.w, n.h, 0, n.opacity.? or_else 1)
	vg.path_reset(&r.path)
	vg.path_rect(&r.path, n.x, n.y, n.w, n.h)
	vg.fill_path(c, &r.path, p)
}

// The image a channel binds and its size for `.eval` and texelFetch, for a
// shader `w x h` units big drawn at `sx x sy` pixels per unit (a group
// child is drawn now, so its commands run before the program's).
@(private)
shader_channel_image :: proc(r: ^Renderer, ch: Shader_Channel, w, h, sx, sy: f32) -> (vg.Image_Id, [3]f32) {
	id: vg.Image_Id
	switch ch.kind {
	case .None:
	case .Image:
		id = shader_child_image(r, ch.image)
	case .Video:
		if slot, got := video_clip_image(r, ch.clip, ch.seconds); got {
			id = r.video_images.image[slot]
		}
	case .Group:
		// `.eval` divides by the resolution: the box units, not the pixels.
		cw := ch.w if ch.w > 0 else w
		chh := ch.h if ch.h > 0 else h
		gw := u32(clamp(math.ceil(cw * sx), 1, 8192))
		gh := u32(clamp(math.ceil(chh * sy), 1, 8192))
		return draw_content(r, ch.content, cw, chh, gw, gh), {cw, chh, 1}
	}
	if !vg.image_id_valid(id) {
		return {}, {}
	}
	info, _ := vg.image_info(&r.canvas, id)
	return id, {f32(info.width), f32(info.height), 1}
}

// The ovg program of library entry `i`'s pass `pass` (module `m`),
// registered on first use.
@(private)
shader_program :: proc(r: ^Renderer, i, pass: int, m: ^oksl.Module) -> (vg.Program_Id, bool) {
	s := &r.shader_state
	for len(s.programs) <= i {
		append(&s.programs, [SHADER_PASS_MAX]vg.Program_Id{})
		append(&s.cpu, [SHADER_PASS_MAX]^Shader_Cpu{})
	}
	if vg.program_id_valid(s.programs[i][pass]) {
		return s.programs[i][pass], true
	}
	if s.cpu[i][pass] != nil {
		// Registration failed before (already reported).
		return {}, false
	}
	id, err := shader_register(r, m, &s.cpu[i][pass])
	if err != nil {
		report(&r.ctx, .Error, {code = .Shader_Load, name = r.ctx.shaders.labels[i], gpu = err})
		return {}, false
	}
	s.programs[i][pass] = id
	return id, true
}

// Registers module `m` with the canvas; `cpu` gets its CPU callback data.
@(private)
shader_register :: proc(r: ^Renderer, m: ^oksl.Module, cpu: ^^Shader_Cpu) -> (vg.Program_Id, vg.Error) {
	s := &r.shader_state
	cpu^ = new(Shader_Cpu)
	cpu^^ = {m, s}
	return vg.create_program(
		&r.canvas,
		{
			frag_spirv = ([^]u8)(raw_data(m.spirv))[:len(m.spirv) * size_of(u32)],
			frag_spirv_entry = oksl.SPIRV_ENTRY,
			frag_msl = transmute([]u8)m.msl,
			frag_msl_entry = oksl.MSL_ENTRY,
			vert_spirv = oksl.LAYER_VERTEX_SPIRV,
			vert_spirv_entry = oksl.LAYER_VERTEX_SPIRV_ENTRY,
			vert_msl = transmute([]u8)oksl.LAYER_VERTEX_MSL,
			vert_msl_entry = oksl.LAYER_VERTEX_MSL_ENTRY,
			uniform_size = m.block_size,
			num_samplers = m.num_samplers,
			cpu = shader_cpu_run,
			cpu_user = cpu^,
		},
	)
}

// A `w x h` output image not used yet this frame: one of that size, else
// a free one resized, else a new one.
@(private)
shader_image :: proc(r: ^Renderer, w, h: u32) -> vg.Image_Id {
	s := &r.shader_state
	frame_no := r.ctx.frame.global_index
	free_slot := -1
	for id, k in s.image {
		if s.used_frame[k] == frame_no {
			continue
		}
		if s.width[k] == w && s.height[k] == h {
			s.used_frame[k] = frame_no
			return id
		}
		free_slot = k
	}
	if free_slot >= 0 {
		if vg.realloc_image(&r.canvas, s.image[free_slot], w, h, .RGBA8, {.Premultiplied}) != nil {
			return {}
		}
		s.width[free_slot], s.height[free_slot], s.used_frame[free_slot] = w, h, frame_no
		return s.image[free_slot]
	}
	id, err := vg.create_image_empty(&r.canvas, w, h, .RGBA8, {.Premultiplied})
	if err != nil {
		report(&r.ctx, .Error, {code = .Shader_Image, gpu = err})
		return {}
	}
	append(&s.image, id)
	append(&s.width, w)
	append(&s.height, h)
	append(&s.used_frame, frame_no)
	return id
}

// The canvas image of media image `name` (uploaded on first use, and again
// after the pixels were evicted and decoded anew).
media_image_id :: proc(r: ^Renderer, name: string) -> (vg.Image_Id, bool) {
	img, ok := media_image(r.media, name, r.ctx.frame.index)
	if !ok {
		return {}, false
	}
	e, found := &r.images[name]
	if found && e.key == img.key {
		return e.id, true
	}
	// One texture per decode for all the players of recorded frames; the
	// pixels stay while frames using them are in flight.
	id, err := vg.create_image_shared(&r.canvas, vg.image_source_rgba(img.pixels, u32(img.width), u32(img.height)), img.key, stable = true)
	if found {
		vg.delete_image(&r.canvas, e.id)
		e^ = {}
	}
	if err != nil {
		report(&r.ctx, .Error, {code = .Image_Upload, name = name, gpu = err})
		return {}, false
	}
	if found {
		e^ = {id, img.key}
	} else {
		r.images[strings.clone(name)] = {id, img.key}
	}
	return id, true
}

// Media image `name` as a shader child. Skia's image shaders give `.eval`
// premultiplied color and media images are straight alpha, so an image with
// transparency gets a premultiplied copy (made once per decode, shared by
// every renderer); an opaque one uses its regular texture.
@(private = "file")
shader_child_image :: proc(r: ^Renderer, name: string) -> vg.Image_Id {
	s := &r.shader_state
	img, ok := media_image(r.media, name, r.ctx.frame.index)
	if !ok {
		return {}
	}
	e, found := &s.premultiplied[name]
	if found && e.key == img.key {
		if vg.image_id_valid(e.id) {
			return e.id
		}
		regular, _ := media_image_id(r, name)
		return regular
	}
	// Shared by all renderers and kept with the pixels: borrowed, not copied.
	pm := media_premultiplied(r.media, name, r.ctx.frame.index)
	id: vg.Image_Id
	if pm != nil {
		err: vg.Error
		id, err = vg.create_image_shared(&r.canvas, vg.image_source_rgba(pm, u32(img.width), u32(img.height)), img.key | 1, stable = true, flags = {.Premultiplied})
		if err != nil {
			report(&r.ctx, .Error, {code = .Image_Upload, name = name, gpu = err})
			return {}
		}
	}
	if found {
		if vg.image_id_valid(e.id) {
			vg.delete_image(&r.canvas, e.id)
		}
		e^ = {id, img.key}
	} else {
		s.premultiplied[strings.clone(name)] = {id, img.key}
	}
	if pm != nil {
		return id
	}
	regular, _ := media_image_id(r, name)
	return regular
}

// ---- CPU interpreter ----------------------------------------------------------------

// Rows per band: oksl shades 8x2 blocks, so bands start on even rows.
@(private = "file")
BAND_ROWS :: 16

@(private = "file")
Shader_Band :: struct {
	module:   ^oksl.Module,
	uniforms: []u8,
	width:    int,
	height:   int,
	out:      []u8,
	stride:   int,
	// RGBA16F targets: shaded as floats into `scratch`, then stored.
	format:   vg.Pixel_Format,
	scratch:  [][4]f32,
	sampler:  vg.Program_Sampler,
	// Next band to shade (rows next * BAND_ROWS ..), shared by workers.
	next:     ^int,
}

// oksl's CPU program over the whole image: pool tasks (and this thread)
// take row bands until none are left.
@(private = "file")
shader_cpu_run :: proc(user: rawptr, uniforms: []u8, width, height: int, out: []u8, stride: int, format: vg.Pixel_Format, sampler: vg.Program_Sampler) {
	sc := (^Shader_Cpu)(user)
	s := sc.state
	next := 0
	band := Shader_Band{sc.module, uniforms, width, height, out, stride, format, nil, sampler, &next}
	if format == .RGBA16F {
		// Grown once and kept: no allocation per frame.
		if len(s.scratch) < width * height {
			resize(&s.scratch, width * height)
		}
		band.scratch = s.scratch[:width * height]
	}
	bands := (height + BAND_ROWS - 1) / BAND_ROWS
	takers := make([]^Shader_Band, clamp(pool_count(s.pool), 1, bands), context.temp_allocator)
	for &t in takers {
		t = &band
	}
	pool_run(s.pool, takers, shader_band_task, context.allocator)
}

@(private = "file")
shader_band_task :: proc(t: thread.Task) {
	shader_bands((^^Shader_Band)(t.data)^)
}

@(private = "file")
shader_bands :: proc(b: ^Shader_Band) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	for {
		i := sync.atomic_add(b.next, 1)
		y := i * BAND_ROWS
		if y >= b.height {
			return
		}
		h := min(BAND_ROWS, b.height - y)
		opts := oksl.Run_Options{sampler = b.sampler.sample, user = b.sampler.data, y = y, w = b.width, h = h}
		if b.format != .RGBA16F {
			oksl.run(&b.module.program, b.uniforms, b.width, b.height, b.out, b.stride, opts)
			continue
		}
		// Pixels the program discards keep the cleared target's values.
		for row in y ..< y + h {
			dst := ([^][4]f16)(&b.out[row * b.stride])[:b.width]
			for x in 0 ..< b.width {
				b.scratch[row * b.width + x] = {f32(dst[x][0]), f32(dst[x][1]), f32(dst[x][2]), f32(dst[x][3])}
			}
		}
		oksl.run_f32(&b.module.program, b.uniforms, b.width, b.height, b.scratch, opts)
		for row in y ..< y + h {
			dst := ([^][4]f16)(&b.out[row * b.stride])[:b.width]
			for x in 0 ..< b.width {
				v := b.scratch[row * b.width + x]
				dst[x] = {f16(v[0]), f16(v[1]), f16(v[2]), f16(v[3])}
			}
		}
	}
}
