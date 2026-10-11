package onimite_script

import "core:c"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "deps:oksl"
import om "../onimite"
import lua "vendor:lua/5.4"

// Shader layers (fframes' `Shader::sksl` / `Shader::shadertoy`):
//
//     shader(f, { sksl = [[...]] | shadertoy = [[...]] | src = "aurora.sksl" | "torus.glsl",
//                 x, y, w, h,
//                 uniforms = { uSpeed = 0.6, uTint = "#f472b6", uOffset = {1, 2},
//                              uPhoto = "photo.jpg",                    -- a `uniform shader` child
//                              uClip = { src = "clip.mp4", looping = true },
//                              uScene = function() ... end,             -- a group child
//                              uCard = { group = function() ... end, w = 400, h = 300 },
//                              iChannel0 = "photo.jpg" },               -- a Shadertoy channel
//                 time = seconds, opacity = 0.8 })
//
// `f` is the frame whose clock drives iTime/iFrame (pass the scene's frame
// for scene-relative time, as fframes does); `shader{...}` uses the video
// frame. `src` is a shader file in the media, or a path relative to the
// script: `.glsl` is Shadertoy code, anything else SkSL.
//
// A group child's nodes are drawn in its own pixel space: the shader box's
// units (or `w x h`), origin at the box's top-left, so `uScene.eval(coord)`
// shows the group where it was drawn. It renders offscreen at the box's
// on-screen pixel size before the shader runs.
//
// A multipass Shadertoy program (Common + Buffer A-D + Image) is a table
// in place of the `shadertoy` source:
//
//     shadertoy = { common = [[...]] | "common.glsl",
//                   buffer_a = { source = [[...]] | src = "trail.glsl",
//                                channels = { "buffer_a", "photo.jpg", function() ... end } },
//                   image = { src = "image.glsl", channels = { "buffer_a" } } }
//
// A pass is a table, or just its source ("x.glsl" names a file). Channel
// n (iChannel0..3) is a buffer ("buffer_a".."buffer_d": this frame's
// output of an earlier buffer, the previous frame's of itself or a later
// one) or an input as uniforms bind them (a media image or video clip, or
// a group child, drawn at the buffer's resolution). Uniforms are set in
// every pass that declares them.

@(private)
register_shader_api :: proc(s: ^Script) {
	lua.pushlightuserdata(s.L, s)
	lua.pushcclosure(s.L, l_shader, 1)
	lua.setglobal(s.L, "shader")
}

@(private = "file")
l_shader :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	ctx := render_ctx(L, s, "shader")
	f := ctx.frame
	t: c.int = 1
	if lua.gettop(L) >= 2 {
		f = read_frame(L, ctx, 1)
		t = 2
	}
	lua.L_checktype(L, t, i32(lua.Type.TABLE))
	fields_begin(L, t)
	arena := ctx.tree.arena

	p := om.Shader_Params {
		src       = get_str(L, t, "src", ""),
		sksl      = get_str(L, t, "sksl", ""),
		shadertoy = get_str(L, t, "shadertoy", ""),
		x         = get_num(L, t, "x", 0),
		y         = get_num(L, t, "y", 0),
		w         = get_num(L, t, "w", get_num(L, t, "width", 0)),
		h         = get_num(L, t, "h", get_num(L, t, "height", 0)),
		time      = get_maybe(L, t, "time"),
		opacity   = get_maybe(L, t, "opacity"),
	}
	// Checked before the inputs are read: group inputs call back into Lua.
	field_used("uniforms")
	fields_end(L, s, t, "shader")
	field(L, t, "shadertoy")
	if lua.istable(L, -1) {
		if status := read_program(L, s, ctx, lua.gettop(L), &p); status != 0 {
			return c.int(lua.error(L))
		}
	}
	lua.pop(L, 1)
	if !p.multipass && p.sksl == "" && p.shadertoy == "" && p.src != "" {
		if _, in_media := ctx.media.shaders[p.src]; !in_media {
			if src, ok := script_shader_file(s, p.src); ok {
				if strings.has_suffix(p.src, ".glsl") {
					p.shadertoy = src
				} else {
					p.sksl = src
				}
			}
		}
	}

	uniforms := make([dynamic]om.Shader_Uniform, arena)
	field(L, t, "uniforms")
	if lua.istable(L, -1) {
		tbl := lua.absindex(L, -1)
		for key in sorted_keys(L, tbl) {
			push_key(L, tbl, key)
			u := om.Shader_Uniform {
				name = strings.clone(key, arena),
			}
			if group, is_group, status := read_group_input(L, ctx, -1); status != 0 {
				return c.int(lua.error(L))
			} else if is_group {
				u.input = group
			} else if input, is_input := read_input(L, -1, arena); is_input {
				u.input = input
			} else {
				values := make([dynamic]f32, arena)
				read_floats(L, -1, &values)
				u.values = values[:]
			}
			append(&uniforms, u)
			lua.pop(L, 1)
		}
	}
	lua.pop(L, 1)
	p.uniforms = uniforms[:]

	om.shader(ctx, f, p)
	return 0
}

@(private = "file")
PASS_FIELDS := [oksl.Pass_Kind]cstring {
	.Buffer_A = "buffer_a",
	.Buffer_B = "buffer_b",
	.Buffer_C = "buffer_c",
	.Buffer_D = "buffer_d",
	.Image    = "image",
}

// A multipass program's table into `p` (see the top of the file). On a Lua
// error in a group child the error is left on the stack (status != 0).
@(private = "file")
read_program :: proc(L: ^lua.State, s: ^Script, ctx: ^om.Context, idx: c.int, p: ^om.Shader_Params) -> (status: c.int) {
	p.multipass = true
	arena := ctx.tree.arena
	field(L, idx, "common")
	p.common, _ = read_pass_source(L, s, ctx, -1)
	lua.pop(L, 1)
	for kind in oksl.Pass_Kind {
		field(L, idx, PASS_FIELDS[kind])
		pi := lua.gettop(L)
		file: string
		p.passes[kind].source, file = read_pass_source(L, s, ctx, pi)
		if file != "" && (p.src == "" || kind == .Image) {
			// Messages name the program after its Image pass's file.
			p.src = file
		}
		if lua.istable(L, pi) {
			field(L, pi, "channels")
		} else {
			lua.pushnil(L)
		}
		if lua.istable(L, -1) {
			list := lua.gettop(L)
			for k in 0 ..< oksl.CHANNEL_COUNT {
				lua.rawgeti(L, list, lua.Integer(k + 1))
				ch := &p.passes[kind].channels[k]
				if lua.type(L, -1) == .STRING {
					name := string(lua.tostring(L, -1))
					for b in oksl.Pass_Kind.Buffer_A ..= oksl.Pass_Kind.Buffer_D {
						if name == string(PASS_FIELDS[b]) {
							ch^ = {kind = .Buffer, buffer = b}
						}
					}
				}
				if ch.kind == .None {
					if group, is_group, st := read_group_input(L, ctx, -1); st != 0 {
						return st
					} else if is_group {
						ch^ = {kind = .External, input = group}
					} else if input, is_input := read_input(L, -1, arena); is_input {
						ch^ = {kind = .External, input = input}
					}
				}
				lua.pop(L, 1)
			}
		}
		lua.pop(L, 2)
	}
	return 0
}

// A pass's (or Common's) source at `at`: a string (a file name when it ends
// in `.glsl` on one line), or a table with `source` or `src` (a shader in
// the media or a file beside the script). `file` is the file's name.
@(private = "file")
read_pass_source :: proc(L: ^lua.State, s: ^Script, ctx: ^om.Context, at: c.int) -> (source, file: string) {
	idx := lua.absindex(L, at)
	text: string
	#partial switch lua.type(L, idx) {
	case .STRING:
		text = string(lua.tostring(L, idx))
		if !strings.has_suffix(text, ".glsl") || strings.contains_rune(text, '\n') {
			return text, ""
		}
		file = text
	case .TABLE:
		if src := get_str(L, idx, "source", ""); src != "" {
			return src, ""
		}
		file = get_str(L, idx, "src", "")
	}
	if file == "" {
		return "", ""
	}
	if src, in_media := ctx.media.shaders[file]; in_media {
		return src, file
	}
	if src, ok := script_shader_file(s, file); ok {
		return src, file
	}
	om.report(ctx, .Error, {code = .Missing_Shader, name = file})
	return "", file
}

// The frame table (`f`) or a time in seconds.
@(private)
read_frame :: proc(L: ^lua.State, ctx: ^om.Context, idx: c.int) -> om.Frame {
	f := ctx.frame
	if lua.isnumber(L, idx) {
		seconds := f32(lua.tonumber(L, idx))
		f.index = int(seconds * f32(max(f.fps, 1)))
		return f
	}
	if lua.istable(L, idx) {
		f.index = int(get_num(L, idx, "index", f32(f.index)))
		f.fps = max(int(get_num(L, idx, "fps", f32(f.fps))), 1)
	}
	return f
}

// A group child: a function adding nodes, or `{ group = function, w, h }`.
// The function runs now, into a hidden content group; on a Lua error the
// group is closed and the error is left on the stack (status != 0).
@(private = "file")
read_group_input :: proc(L: ^lua.State, ctx: ^om.Context, at: c.int) -> (in_: om.Shader_Input, ok: bool, status: c.int) {
	idx := lua.absindex(L, at)
	if lua.istable(L, idx) {
		field(L, idx, "group")
		if !lua.isfunction(L, -1) {
			lua.pop(L, 1)
			return
		}
		in_.w = get_num(L, idx, "w", get_num(L, idx, "width", 0))
		in_.h = get_num(L, idx, "h", get_num(L, idx, "height", 0))
	} else if lua.isfunction(L, idx) {
		lua.pushvalue(L, idx)
	} else {
		return
	}
	in_.content = om.shader_content_begin(ctx)
	status = lua.pcall(L, 0, 0, 0)
	om.group_end(ctx)
	return in_, true, status
}

// A media input: a name that isn't a color ("photo.jpg"), or a table with
// `src` (and video options).
@(private = "file")
read_input :: proc(L: ^lua.State, idx: c.int, arena := context.allocator) -> (in_: om.Shader_Input, ok: bool) {
	#partial switch lua.type(L, idx) {
	case .STRING:
		name := string(lua.tostring(L, idx))
		if strings.has_prefix(name, "#") || name == "white" || name == "black" || name == "transparent" {
			return {}, false
		}
		return {src = strings.clone(name, arena)}, true
	case .TABLE:
		if !has_field(L, idx, "src") {
			return {}, false
		}
		in_.src = strings.clone(get_str(L, idx, "src", ""), arena)
		in_.start_from = get_num(L, idx, "start_from", 0)
		in_.clip_start = get_num(L, idx, "clip_start", 0)
		field(L, idx, "looping")
		in_.looping = bool(lua.toboolean(L, -1))
		lua.pop(L, 1)
		return in_, true
	}
	return {}, false
}

// Numbers, booleans, colors (`"#rrggbb"`, `rgb(...)`: straight RGBA 0..1,
// like fframes' `.color`) and nested lists, flattened.
@(private = "file")
read_floats :: proc(L: ^lua.State, at: c.int, out: ^[dynamic]f32) {
	idx := lua.absindex(L, at)
	#partial switch lua.type(L, idx) {
	case .NUMBER:
		append(out, f32(lua.tonumber(L, idx)))
	case .BOOLEAN:
		append(out, f32(1) if lua.toboolean(L, idx) else 0)
	case .STRING:
		col := read_color_value(L, idx)
		append(out, col.r, col.g, col.b, col.a)
	case .TABLE:
		if has_field(L, idx, "r") {
			col := read_color_value(L, idx)
			append(out, col.r, col.g, col.b, col.a)
			return
		}
		n := int(lua.rawlen(L, idx))
		for i in 1 ..= n {
			lua.rawgeti(L, idx, lua.Integer(i))
			read_floats(L, -1, out)
			lua.pop(L, 1)
		}
	}
}

// A shader file beside the script, read once per script load.
@(private = "file")
script_shader_file :: proc(s: ^Script, path: string) -> (string, bool) {
	if src, ok := s.shader_files[path]; ok {
		return src, true
	}
	full := path
	if !filepath.is_abs(path) {
		full, _ = filepath.join({filepath.dir(s.path), path}, context.temp_allocator)
	}
	data, err := os.read_entire_file(full, context.allocator)
	if err != nil {
		return "", false
	}
	s.shader_files[strings.clone(path)] = string(data)
	return string(data), true
}
