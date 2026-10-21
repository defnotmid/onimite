package onimite

import "base:runtime"
import "core:hash"
import "core:math"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:thread"
import vg "deps:ovg"
import "deps:oksl"

// Shader layers (fframes' `Shader::sksl` / `Shader::shadertoy`): SkSL,
// Shadertoy GLSL or GLSL ES fragment shaders (oksl's three profiles)
// filling a box, composed like an image (transforms, clips, masks,
// opacity). Programs compile once per process, cached by their sources'
// hash; a frame's node carries its packed uniform blocks in the frame
// arena. Drawing runs the program into a pooled image at the box's
// on-screen pixel size (ovg `run_program`: SDL_GPU, or oksl's CPU
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
// with `texture(iChannelN, uv)` in 0..1 uv. A GLSL shader reads the layer's
// uv (`layout(location = 0) in vec2 uv`), gets the clock in uniforms it
// declares with the built-ins' names, and binds its `sampler2D`s by name.
// A group child (`shader_content_begin`) is drawn into an offscreen image
// before the shader runs; its pixel space is the shader box's units (or its
// own `w x h`) with the group's nodes in those units, origin top-left, so
// `.eval(coord)` shows the group where it was drawn. The image is rendered
// at the box's on-screen pixel size, so it stays sharp.
//
// Every program is a list of passes (`Shader_Pass`), each a source in its
// own dialect whose channels read an input, another pass's output of this
// frame, or any pass's output of the last frame: a single source is one
// pass, a Shadertoy multipass table is Common plus its Buffer A-D and Image
// passes. oksl's `make_program` turns the compiled passes into a pass graph
// with an edge array saying what each channel reads. A node carries a
// uniform block and the external channels per pass. Drawing runs the
// passes read as feedback into half-float buffers (feedback.odin: the
// buffers, their catch-up when frames are not drawn in order, and the
// preview's checkpoints), then the output pass into the box.

// An image or a synced video clip from the media bound to a channel, or a
// group of nodes.
Shader_Input :: struct {
	src:        string,
	// The depth of the 3D layer drawn by the group input of this name: its
	// distance from the camera per pixel (rgb, world units; a = 1 where
	// drawn), from the same render as its colour.
	depth_of:   string,
	// A group child: its content node (`shader_content_begin`), 0 for none,
	// and the size of its pixel space (0: the shader box's).
	content:    i32,
	w, h:       f32,
	// Video clips: playback start on the frame clock, offset into the
	// clip, looping (as `video_clip`).
	start_from: f32,
	clip_start: f32,
	speed:      f32,
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

// What a channel of a pass reads: another pass of the program by name (its
// output of this frame when it runs earlier, else of the last frame;
// `previous`: of the last frame always), or an input. The channel is named
// (a `uniform shader` child, `iChannelN`, a `sampler2D`), or, unnamed, the
// `index`th in declaration order.
Shader_Pass_Input :: struct {
	channel:  string,
	index:    int,
	pass:     string,
	previous: bool,
	input:    Shader_Input,
}

// A pass of a program: its name (in messages and references), its source
// in a dialect (oksl's profile) and what its channels read. A channel no
// input binds reads nothing (transparent black).
Shader_Pass :: struct {
	name:    string,
	source:  string,
	profile: oksl.Profile,
	inputs:  []Shader_Pass_Input,
}

Shader_Params :: struct {
	// A shader file in the media, its dialect by extension
	// (`shader_profile`). Labels the program in messages.
	src:        string,
	// An inline source in dialect `profile`; wins over `src`.
	source:     string,
	profile:    oksl.Profile,
	// Or a program of passes, in running order, which bind their inputs
	// themselves. `common` starts every pass (Shadertoy's Common);
	// `output` names the pass drawn ("": the last). Uniforms are set in
	// every pass that declares them.
	passes:     []Shader_Pass,
	common:     string,
	output:     string,
	x, y, w, h: f32,
	uniforms:   []Shader_Uniform,
	// `iTime` in seconds; default the frame's (scene-relative) time.
	time:       Maybe(f32),
	opacity:    Maybe(f32),
}

// The dialect a shader file's extension names: `.glsl` Shadertoy, `.frag`
// GLSL, anything else SkSL.
shader_profile :: proc(path: string) -> oksl.Profile {
	options, _ := oksl.options_of_path(path)
	return options.profile
}

Shader_Channel_Kind :: enum u8 {
	None,
	Image,
	Video,
	Group,
	// The depth of the 3D layer the group channel `of` draws.
	Depth,
}

Shader_Channel :: struct {
	kind:    Shader_Channel_Kind,
	// Media image name.
	image:   string,
	// Video clip, its stream and the clip time this frame shows.
	clip:    int,
	stream:  int,
	seconds: f64,
	// Group content node and its pixel space (0: the shader box's).
	content: i32,
	w, h:    f32,
	// A group: a depth channel reads its 3D layer's depth. Depth: the group
	// channel it reads.
	capture_depth: bool,
	of:            int,
}

// The node: per pass of its program (the graph's order), the uniform block
// (frame arena; drawing fills in the channels' sizes) and the external
// channels; its feedback instance (the program and its occurrence in the
// frame) and iFrame.
Shader :: struct {
	program:    int,
	x, y, w, h: f32,
	opacity:    Maybe(f32),
	blocks:     [][]u8,
	channels:   [][oksl.CHANNEL_COUNT]Shader_Channel,
	instance:   u64,
	frame:      int,
}

// Passes of a program, by index.
Pass_Set :: bit_set[0 ..< oksl.PASS_MAX;u8]

// A compile error and the pass it is in ("" for a single source; "Common"
// for the source every pass starts with).
Shader_Error :: struct {
	pass:  string,
	error: oksl.Error,
}

// Compiled programs by their sources' hash: parallel arrays indexed by
// program. On failure `errors` lists the problems and `ok` is false.
// `feedback` is the passes that render into feedback buffers; `stateful`
// whether a pass reads a last frame (only then does a frame depend on the
// frames before it). Labels and error lists live in `arena`, the errors'
// text in the graphs.
Shader_Library :: struct {
	hashes:   [dynamic]u64,
	labels:   [dynamic]string,
	graphs:   [dynamic]^oksl.Pass_Graph,
	errors:   [dynamic][]Shader_Error,
	ok:       [dynamic]bool,
	feedback: [dynamic]Pass_Set,
	stateful: [dynamic]bool,
	by_hash:  map[u64]int,
	arena:    virtual.Arena,
}

shader_library_destroy :: proc(l: ^Shader_Library) {
	for g in l.graphs {
		oksl.destroy_program(g)
	}
	delete(l.hashes)
	delete(l.labels)
	delete(l.graphs)
	delete(l.errors)
	delete(l.ok)
	delete(l.feedback)
	delete(l.stateful)
	delete(l.by_hash)
	virtual.arena_destroy(&l.arena)
	l^ = {}
}

// The program of `passes` (with `common`, drawing pass `output`), compiled
// on first use: each pass in its dialect (a Shadertoy pass other than the
// output unclamped, for its float buffer), its channels bound to the passes
// they name, and the graph made of them.
shader_library_get :: proc(l: ^Shader_Library, passes: []Shader_Pass, common: string, output: int, label: string) -> int {
	h := shader_program_hash(passes, common, output)
	if i, ok := l.by_hash[h]; ok {
		return i
	}
	arena := virtual.arena_allocator(&l.arena)
	errors := make([dynamic]Shader_Error, arena)
	specs := make([]oksl.Pass_Spec, len(passes), context.temp_allocator)
	compiled := true
	for pass, pi in passes {
		m, errs, ok := oksl.compile(pass.source, {profile = pass.profile, prelude = common, unclamped = pi != output})
		if m == nil {
			for s in specs[:pi] {
				oksl.destroy(s.module)
			}
			return shader_library_add(l, h, label, nil, errors[:], false)
		}
		specs[pi] = {module = m, name = pass.name}
		compiled &&= ok
		shader_add_errors(&errors, pass.name, errs)
	}
	for &spec, pi in specs {
		spec.channels = shader_channel_refs(passes, pi, spec.module, &errors)
	}
	g, errs, made := oksl.make_program(specs, output)
	shader_add_errors(&errors, "", errs)
	return shader_library_add(l, h, label, g, errors[:], compiled && made && len(errors) == 0)
}

// What each channel of pass `pi` (module `m`) reads: the pass an input
// names (its output of this frame when it runs earlier, else, or when the
// input asks for it, of the last frame), else the host's input. A pass the
// program lacks is an error at the channel's first use.
@(private = "file")
shader_channel_refs :: proc(passes: []Shader_Pass, pi: int, m: ^oksl.Module, errors: ^[dynamic]Shader_Error) -> (refs: [oksl.CHANNEL_COUNT]oksl.Channel_Ref) {
	for &ref, ch in refs {
		ref = {.External, u8(ch)}
	}
	for in_ in passes[pi].inputs {
		ch := shader_input_channel(m, in_)
		if in_.pass == "" || ch < 0 {
			continue
		}
		target := shader_pass_index(passes, in_.pass)
		if target >= 0 {
			refs[ch] = {.Buffer if target < pi && !in_.previous else .Previous, u8(target)}
		} else if ch in m.channels_used {
			missing := oksl.Error{pos = m.channel_pos[ch], code = .Channel_No_Buffer, name = m.channel_names[ch], a = strings.clone(in_.pass, errors.allocator)}
			append(errors, Shader_Error{strings.clone(passes[pi].name, errors.allocator), missing})
		}
	}
	return refs
}

// The hash of what a program is made of: its sources and dialects, the
// passes' names and the channels that read passes.
@(private = "file")
shader_program_hash :: proc(passes: []Shader_Pass, common: string, output: int) -> u64 {
	h := hash.fnv64a(transmute([]u8)common, 0xcbf29ce484222325 ~ u64(output))
	for pass in passes {
		h = hash.fnv64a(transmute([]u8)pass.source, h ~ u64(pass.profile))
		h = hash.fnv64a(transmute([]u8)pass.name, h)
		for in_ in pass.inputs {
			if in_.pass != "" {
				h = hash.fnv64a(transmute([]u8)in_.channel, h ~ u64(in_.index) << 1 ~ u64(in_.previous))
				h = hash.fnv64a(transmute([]u8)in_.pass, h)
			}
		}
	}
	return h
}

// Appends a module's (or the graph's) errors as pass `pass`'s; errors in
// the source every pass starts with are Common's, each kept once.
@(private = "file")
shader_add_errors :: proc(list: ^[dynamic]Shader_Error, pass: string, errs: []oksl.Error) {
	next: for e in errs {
		if e.pos.src != .Prelude {
			append(list, Shader_Error{strings.clone(pass, list.allocator), e})
			continue
		}
		for seen in list {
			if seen.error.pos == e.pos && seen.error.code == e.code && seen.error.name == e.name {
				continue next
			}
		}
		append(list, Shader_Error{"Common", e})
	}
}

@(private = "file")
shader_library_add :: proc(l: ^Shader_Library, h: u64, label: string, g: ^oksl.Pass_Graph, errors: []Shader_Error, ok: bool) -> int {
	i := len(l.hashes)
	append(&l.hashes, h)
	append(&l.labels, strings.clone(label, virtual.arena_allocator(&l.arena)))
	append(&l.graphs, g)
	append(&l.errors, errors)
	append(&l.ok, ok)
	append(&l.feedback, shader_feedback_passes(g) if ok else {})
	append(&l.stateful, ok && shader_stateful(g))
	l.by_hash[h] = i
	return i
}

// The passes of `g` that render into feedback buffers: every pass but the
// output, which renders into the box, unless a pass reads it.
@(private = "file")
shader_feedback_passes :: proc(g: ^oksl.Pass_Graph) -> (set: Pass_Set) {
	for _, pi in g.passes {
		if pi != g.output {
			set += {pi}
		}
	}
	for e in g.edges {
		if e.source == .Buffer || e.source == .Previous {
			set += {int(e.id)}
		}
	}
	return set
}

// Whether a pass of `g` reads a pass's last frame. A pass reading an
// earlier pass's output of this frame only needs a buffer, not the frames
// before.
@(private = "file")
shader_stateful :: proc(g: ^oksl.Pass_Graph) -> bool {
	for e in g.edges {
		if e.source == .Previous {
			return true
		}
	}
	return false
}

// The index of the pass named `name`, or -1.
@(private = "file")
shader_pass_index :: proc(passes: []Shader_Pass, name: string) -> int {
	for pass, pi in passes {
		if pass.name == name {
			return pi
		}
	}
	return -1
}

// The channel of module `m` an input binds: the one of its name, or its
// index; -1 when `m` has no such channel.
@(private = "file")
shader_input_channel :: proc(m: ^oksl.Module, in_: Shader_Pass_Input) -> int {
	if in_.channel == "" {
		return in_.index if in_.index >= 0 && in_.index < oksl.CHANNEL_COUNT else -1
	}
	for name, ch in m.channel_names {
		if name == in_.channel {
			return ch
		}
	}
	return -1
}

// What a pass's input naming no channel of its module reports, by dialect.
@(private = "file")
NO_CHANNEL := [oksl.Profile]Diagnostic_Code {
	.Sksl      = .Shader_No_Child,
	.Shadertoy = .Shader_No_Channel,
	.Glsl      = .Shader_No_Channel,
}

// Adds a shader layer for frame `f` (its time is the frame's, so scene
// frames give scene-relative `iTime`). Compile errors are reported (with
// file:line:col, and the pass) and the layer is skipped; returns false
// then. Every pass gets its block (the same built-ins and uniforms) and its
// external channels.
shader :: proc(ctx: ^Context, f: Frame, p: Shader_Params) -> bool {
	label := p.src if p.src != "" else "<inline>"
	passes := p.passes
	one: [1]Shader_Pass
	if len(passes) == 0 {
		one[0] = shader_one_pass(ctx, p) or_return
		passes = one[:]
	} else {
		for u in p.uniforms {
			if u.input != nil {
				report(ctx, .Warning, {code = .Shader_Pass_Input, name = label, a = u.name})
			}
		}
	}
	output := shader_output(ctx, passes, p.output)
	if output < 0 {
		return false
	}
	lib := &ctx.shaders
	prog := shader_library_get(lib, passes, p.common, output, label)
	if !lib.ok[prog] {
		for e in lib.errors[prog] {
			report(ctx, .Error, {code = .Shader_Compile, name = lib.labels[prog], b = e.pass, shader = e.error})
		}
		return false
	}
	if p.w <= 0 || p.h <= 0 {
		report(ctx, .Warning, {code = .Shader_Zero_Size, name = label, x = p.x, y = p.y})
		return true
	}
	g := lib.graphs[prog]
	arena := ctx.tree.arena
	n := Shader {
		program  = prog,
		x        = p.x,
		y        = p.y,
		w        = p.w,
		h        = p.h,
		opacity  = p.opacity,
		blocks   = make([][]u8, len(g.passes), arena),
		channels = make([][oksl.CHANNEL_COUNT]Shader_Channel, len(g.passes), arena),
		instance = shader_instance(ctx, prog),
		frame    = f.index,
	}
	declared := make([]bool, len(p.uniforms), context.temp_allocator)
	for pass, pi in g.passes {
		m := pass.module
		block := make([]u8, m.block_size, arena)
		shader_write_builtins(m, block, f, p)
		for u, k in p.uniforms {
			if u.input == nil {
				declared[k] |= shader_write_uniform(ctx, m, block, label, u)
			}
		}
		shader_report_unset(ctx, m, label, p.uniforms)
		for in_ in passes[pi].inputs {
			ch := shader_input_channel(m, in_)
			if ch < 0 {
				report(ctx, .Warning, {code = NO_CHANNEL[m.profile], name = shader_pass_label(label, pass.name), a = in_.channel})
			} else if in_.pass == "" && ch in m.channels_used && in_.input.depth_of == "" {
				n.channels[pi][ch] = shader_channel(ctx, f, label, in_.input)
			}
		}
		// Depth channels, once the group channels they read are bound.
		for in_ in passes[pi].inputs {
			ch := shader_input_channel(m, in_)
			if ch < 0 || in_.input.depth_of == "" || ch not_in m.channels_used {
				continue
			}
			of := -1
			for src in passes[pi].inputs {
				if src.channel == in_.input.depth_of {
					of = shader_input_channel(m, src)
				}
			}
			if of < 0 || n.channels[pi][of].kind != .Group {
				report(ctx, .Error, {code = .Shader_Depth_Of, name = label, a = in_.channel, b = in_.input.depth_of})
				continue
			}
			n.channels[pi][of].capture_depth = true
			n.channels[pi][ch] = {kind = .Depth, of = of}
		}
		// Channels reading a pass, or an input that shows this frame.
		bound: bit_set[0 ..< oksl.CHANNEL_COUNT]
		for e in g.edges[pass.edges.start:][:pass.edges.count] {
			ch := n.channels[pi][e.channel]
			if e.source == .External && ch.kind == .None {
				continue
			}
			if ch.kind == .Video {
				oksl.write_input(m, block, .Channel_Time, {f32(ch.seconds)}, int(e.channel))
			}
			bound += {int(e.channel)}
		}
		for ch in m.channels_used - bound {
			if pass.name == "" {
				report(ctx, .Warning, {code = .Shader_Unbound_Channel, name = label, a = m.channel_names[ch]})
			} else {
				report(ctx, .Warning, {code = .Shader_Pass_Unbound, name = label, a = m.channel_names[ch], b = pass.name, n = i64(ch)})
			}
		}
		n.blocks[pi] = block
	}
	for u, k in p.uniforms {
		if u.input == nil && !declared[k] {
			report(ctx, .Warning, {code = .Shader_Undeclared_Uniform, name = label, a = u.name})
		}
	}
	tree_add(&ctx.tree, n)
	return true
}

// A single source as a program of one unnamed pass: inline, or a shader
// file in the media; its inputs are the uniforms that bind one, by channel
// name.
@(private = "file")
shader_one_pass :: proc(ctx: ^Context, p: Shader_Params) -> (pass: Shader_Pass, ok: bool) {
	pass.source, pass.profile = p.source, p.profile
	if pass.source == "" {
		pass.source, ok = ctx.media.shaders[p.src]
		if !ok {
			report(ctx, .Error, {code = .Missing_Shader, name = p.src})
			return
		}
		pass.profile = shader_profile(p.src)
	}
	inputs := make([dynamic]Shader_Pass_Input, context.temp_allocator)
	for u in p.uniforms {
		if input, is_input := u.input.?; is_input {
			append(&inputs, Shader_Pass_Input{channel = u.name, input = input})
		}
	}
	pass.inputs = inputs[:]
	return pass, true
}

// The index of the pass `name` names ("": the last), or -1 (reported).
@(private = "file")
shader_output :: proc(ctx: ^Context, passes: []Shader_Pass, name: string) -> int {
	if name == "" {
		return len(passes) - 1
	}
	if pi := shader_pass_index(passes, name); pi >= 0 {
		return pi
	}
	names := make([]string, len(passes), context.temp_allocator)
	for pass, pi in passes {
		names[pi] = pass.name
	}
	report(ctx, .Error, {code = .Invalid_Value, name = "shader output", a = name, b = strings.join(names, ", ", context.temp_allocator)})
	return -1
}

// A shader's label with a pass of its program (`aurora.sksl: blur`).
@(private = "file")
shader_pass_label :: proc(label, pass: string) -> string {
	return label if pass == "" else strings.concatenate({label, ": ", pass}, context.temp_allocator)
}

// A program's instance in this frame: the program and how many times the
// frame used it before (so two layers of one program keep their own
// feedback buffers).
@(private = "file")
shader_instance :: proc(ctx: ^Context, prog: int) -> u64 {
	for len(ctx.shader_uses) <= prog {
		append(&ctx.shader_uses, 0)
	}
	k := ctx.shader_uses[prog]
	ctx.shader_uses[prog] += 1
	return u64(prog) << 32 | u64(k)
}

// The built-in inputs of frame `f` (the block's start, in the dialects
// that have them), and the built-in names declared with another type or
// in a dialect without them (`uniform float iFrame;`), which are user
// uniforms filled too, as fframes does.
@(private = "file")
shader_write_builtins :: proc(m: ^oksl.Module, block: []u8, f: Frame, p: Shader_Params) {
	fps := f32(max(f.fps, 1))
	time := p.time.? or_else frame_seconds(f)
	oksl.write_builtins(m, block, {resolution = {p.w, p.h, 1}, time = time, time_delta = 1 / fps, frame = i32(f.index), frame_rate = fps, sample_rate = MIX_RATE})
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
		t, showing := video_clip_time(v.infos[i], f, in_.start_from, in_.clip_start, in_.speed, in_.looping)
		if !showing {
			return {}
		}
		stream := clip_stream(ctx, i)
		if v.source.prefetch != nil && !ctx.recording {
			v.source.prefetch(v.source.data, v.handles[i], stream, t)
		}
		return {kind = .Video, clip = i, stream = stream, seconds = t}
	}
	report(ctx, .Error, {code = .Missing_Image, name = in_.src})
	return {}
}

// ---- drawing ----------------------------------------------------------------------

// Renderer-side shader state: ovg programs per library entry (and pass),
// pooled output images, premultiplied copies of media images with
// transparency (children), multipass feedback buffers, and the task pool
// the CPU interpreter shades bands on (the renderer's, borrowed).
Shader_State :: struct {
	programs:      [dynamic][oksl.PASS_MAX]vg.Program_Id,
	cpu:           [dynamic][oksl.PASS_MAX]^Shader_Cpu,
	// Layers' images (shader outputs, 3D renders; `frame_image`):
	// parallel arrays, reused across frames.
	image:         [dynamic]vg.Image_Id,
	width:         [dynamic]u32,
	height:        [dynamic]u32,
	format:        [dynamic]vg.Pixel_Format,
	used_frame:    [dynamic]int,
	draw_gen:      int,
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
	delete(s.format)
	delete(s.used_frame)
	delete(s.premultiplied)
	delete(s.scratch)
	s^ = {}
}

// A shader: its feedback passes (unless they ran for this frame already),
// then, unless `sim`, its output into the box: the output pass run at the
// box's on-screen pixel size, or its feedback buffer when passes read it.
draw_shader :: proc(r: ^Renderer, n: Shader, sim := false) {
	lib := &r.ctx.shaders
	g := lib.graphs[n.program]
	r.shader_state.pool = r.pool
	outputs, ran := feedback_passes(r, n, g, sim)
	if !ran || sim {
		return
	}
	sx, sy, shown := layer_scale(r)
	if !shown {
		return
	}
	out := g.output
	image := outputs.this[out]
	if out not_in lib.feedback[n.program] {
		prog, ok := shader_program(r, n.program, out, g.passes[out].module)
		if !ok {
			return
		}
		image = frame_image(r, layer_pixels(n.w, n.h, sx, sy))
		if !vg.image_id_valid(image) || !shader_run_pass(r, n, g, out, prog, image, outputs, sx, sy) {
			return
		}
	}
	fill_layer(r, image, {n.x, n.y, n.w, n.h}, n.opacity)
}

// Runs pass `pi` of shader `n` (ovg program `prog`) into `target`, its
// channels bound to what they read: inputs drawn at `sx x sy` pixels per
// unit, or the program's outputs of this frame and the last; false when it
// fails (reported).
@(private)
shader_run_pass :: proc(r: ^Renderer, n: Shader, g: ^oksl.Pass_Graph, pi: int, prog: vg.Program_Id, target: vg.Image_Id, outputs: Feedback_Outputs, sx, sy: f32) -> bool {
	pass := g.passes[pi]
	channels: [oksl.CHANNEL_COUNT]vg.Image_Id
	res: [oksl.CHANNEL_COUNT][3]f32
	depth: [oksl.CHANNEL_COUNT]Depth_Capture
	for e in g.edges[pass.edges.start:][:pass.edges.count] {
		ch := int(e.channel)
		switch e.source {
		case .None:
			// Transparent black: no image, no size.
			channels[ch], res[ch] = {}, {}
		case .External:
			c := n.channels[pi][ch]
			if c.kind == .Depth {
				continue // once the group it reads is drawn, below
			}
			if c.capture_depth {
				r.depth_capture = &depth[ch]
			}
			channels[ch], res[ch] = shader_channel_image(r, c, n.w, n.h, sx, sy)
			r.depth_capture = nil
		case .Buffer:
			channels[ch], res[ch] = outputs.this[e.id], outputs.size
		case .Previous:
			channels[ch], res[ch] = outputs.last[e.id], outputs.size
		}
	}
	for e in g.edges[pass.edges.start:][:pass.edges.count] {
		ch := int(e.channel)
		if c := n.channels[pi][ch]; e.source == .External && c.kind == .Depth {
			// sampled at the same coordinates as the group it comes from
			channels[ch], res[ch] = depth[c.of].image, res[c.of]
		}
	}
	// The block lives in the frame arena; finish it in place.
	block := n.blocks[pi]
	for k in 0 ..< oksl.CHANNEL_COUNT {
		oksl.write_input(pass.module, block, .Channel_Resolution, res[k][:], k)
	}
	if err := vg.run_program(&r.canvas, prog, target, block, channels[:]); err != nil {
		report(&r.ctx, .Error, {code = .Shader_Run, name = r.ctx.shaders.labels[n.program], gpu = err})
		return false
	}
	return true
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
		if slot, got := video_clip_image(r, ch.clip, ch.stream, ch.seconds); got {
			id = r.video_images.image[slot]
		}
	case .Depth:
		// bound by shader_run_pass from the group channel it reads
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
		append(&s.programs, [oksl.PASS_MAX]vg.Program_Id{})
		append(&s.cpu, [oksl.PASS_MAX]^Shader_Cpu{})
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

// The pixels per unit a layer drawn now shows at (the canvas's current
// transform); false when it does not show (scaled to nothing).
@(private)
layer_scale :: proc(r: ^Renderer) -> (sx, sy: f32, shown: bool) {
	xf := vg.current_transform(&r.canvas)
	sx, sy = math.hypot(xf[0], xf[1]), math.hypot(xf[2], xf[3])
	return sx, sy, sx > 0 && sy > 0
}

// The pixel size of a `w x h` layer at `sx x sy` pixels per unit, which an
// image rendered for it has so that it stays sharp.
@(private)
layer_pixels :: proc "contextless" (w, h, sx, sy: f32) -> (pw, ph: u32) {
	return u32(clamp(math.ceil(w * sx), 1, 8192)), u32(clamp(math.ceil(h * sy), 1, 8192))
}

// Fills a layer's box with its image, rendered at the box's pixel size.
@(private)
fill_layer :: proc(r: ^Renderer, image: vg.Image_Id, box: vg.Rect, opacity: Maybe(f32)) {
	paint := vg.paint_image(image, box.x, box.y, box.w, box.h, 0, opacity.? or_else 1)
	vg.path_reset(&r.path)
	vg.path_rect(&r.path, box.x, box.y, box.w, box.h)
	vg.fill_path(&r.canvas, &r.path, paint)
}

// A `w x h` image for a layer of this frame (a shader's output, a 3D
// render) not used yet this frame: one of that size, else a free one
// resized, else a new one.
@(private)
frame_image :: proc(r: ^Renderer, w, h: u32, format := vg.Pixel_Format.RGBA8) -> vg.Image_Id {
	s := &r.shader_state
	frame_no := s.draw_gen
	free_slot := -1
	for id, k in s.image {
		if s.used_frame[k] == frame_no {
			continue
		}
		if s.width[k] == w && s.height[k] == h && s.format[k] == format {
			s.used_frame[k] = frame_no
			return id
		}
		free_slot = k
	}
	if free_slot >= 0 {
		if vg.realloc_image(&r.canvas, s.image[free_slot], w, h, format, {.Premultiplied} if format == .RGBA8 else {}) != nil {
			return {}
		}
		s.width[free_slot], s.height[free_slot], s.format[free_slot], s.used_frame[free_slot] = w, h, format, frame_no
		return s.image[free_slot]
	}
	id, err := vg.create_image_empty(&r.canvas, w, h, format, {.Premultiplied} if format == .RGBA8 else {})
	if err != nil {
		report(&r.ctx, .Error, {code = .Shader_Image, gpu = err})
		return {}
	}
	append(&s.image, id)
	append(&s.width, w)
	append(&s.height, h)
	append(&s.format, format)
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
