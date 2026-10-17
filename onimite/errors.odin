package onimite

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "deps:o3d"
import vg "deps:ovg"
import "deps:oksl"

// Errors and diagnostics are plain values: a code plus the operands it
// needs. Procedures return an `Error` last; problems found while building or
// drawing a frame are `Diagnostic`s. Text is made only at the edge (the
// CLI, the preview, --json) from the tables below. Their placeholders name
// the operands (`OPERAND_NAMES`); `{q:...}` quotes a string, `{r:...}`
// rounds a number, `{hex:...}` and `{X4:...}` write hex digits.

Error :: enum u8 {
	None,
	Scene_Without_Duration,
	Video_Without_Duration,
	Io,
	Invalid_Time_Spec,
	Unknown_Scene,
	// A name several scenes share, without `[n]`.
	Ambiguous_Scene,
	Out_Of_Range,
	// `Scene@offset` beyond the scene's last frame.
	Past_Scene,
	Render_Failed,
	// Video clips (`Video_Failure`).
	No_Video_Decoder,
	No_Video_Track,
	Video_Decode,
}

// Why a clip can not be decoded: the source's code and, for the decoder's
// own failures (`.Video_Decode`), the decoder's name for the error and its
// detail (static strings).
Video_Failure :: struct {
	code:   Error,
	cause:  string,
	detail: string,
}

// Ordered: a finding of a severity is at least as bad as the ones before.
Severity :: enum u8 {
	// Fine on its own, e.g. text entirely off canvas while it animates in.
	Info,
	Warning,
	Error,
}

// What a diagnostic is about. The names are part of the --json output
// (`diagnostic_code_name`): keep them stable.
Diagnostic_Code :: enum u8 {
	None,
	// Media.
	Missing_Image,
	Undecodable_Image,
	Missing_Filter_Image,
	Missing_Svg,
	Missing_Lottie,
	Missing_Video,
	Undecodable_Video,
	Missing_Audio,
	// A track plays a sound the media lacks, or is timed by the length of
	// one (found at load).
	Missing_Track,
	Missing_Track_Time,
	Missing_Subtitles,
	Missing_Captions,
	Missing_Shader,
	Missing_Font,
	Missing_Glyph,
	// Files of the media folder that could not be read or decoded (found
	// when it loads).
	Unreadable_Media,
	Undecodable_Media,
	// Documents.
	Svg_Markup,
	Svg_Warning,
	Svg_Missing_Id,
	Lottie_Data,
	Lottie_Warning,
	Lottie_Missing_Layer,
	// Shaders.
	Shader_Compile,
	Shader_Zero_Size,
	Shader_No_Channel,
	Shader_No_Child,
	Shader_Undeclared_Uniform,
	Shader_Uniform_Count,
	Shader_Unset_Uniform,
	Shader_Unbound_Channel,
	Shader_Pass_Input,
	Shader_Pass_Unbound,
	Shader_Load,
	Shader_Run,
	Shader_Image,
	Shader_Buffer,
	Image_Upload,
	Video_Frame_Image,
	// 3D layers (`view3d{}`).
	Missing_Model,
	Missing_Animation,
	Missing_Morph_Target,
	View3d_Zero_Size,
	Geometry_Growth,
	View3d_Render,
	// Nodes.
	Rect_Zero_Size,
	Circle_Zero_Radius,
	Ellipse_Zero_Radius,
	Invalid_Path,
	Invalid_Clip_Path,
	Text_Clipped,
	Text_Off_Canvas,
	Nan_Transform,
	Empty_Frame,
	// Scripts.
	Script_Error,
	Invalid_Value,
	Unused_Field,
	Animate_No_Stop,
	// Sync points (`id`s and cues).
	Cue_Drift,
	Cue_Alone,
	Cue_No_Hit,
	Outside_Box,
	Text_Overlap,
	// Physics (`physics{}`), found when it simulates.
	Physics_Unsettled,
	Physics_Offscreen,
	Physics_Overlap,
	// The same for `physics3d{}`: metres, the world's bounds.
	Physics3d_Offscreen,
	Physics3d_Overlap,
	// Sound against the music's beat.
	Off_Beat,
	// Spoken lines (`say`), found at load.
	Tts_Unavailable,
	Tts_Noncommercial,
	Tts_Not_Kept,
	// What odawg found reading or composing a song (`song{}`, `sound{}`).
	Song_Finding,
}

// A problem found while building or drawing a frame. Which operands a code
// uses, and what they mean, its DIAGNOSTIC_TEXT and DIAGNOSTIC_KEY say:
// `name` is what it is about (a media name, font family, shader, text), `a`
// and `b` further names, `n` and `m` numbers, then the causes. Strings are
// owned (`report` clones them) except `video`'s, which are static.
Diagnostic :: struct {
	severity:   Severity,
	code:       Diagnostic_Code,
	frame:      int,
	scene:      string,
	name:       string,
	a, b:       string,
	n, m:       i64,
	x, y, w, h: f32,
	gpu:        vg.Error,
	svg:        vg.Svg_Error,
	lottie:     vg.Lottie_Error,
	video:      Video_Failure,
	shader:     oksl.Error,
	o3d:        o3d.Error,
	// The node of the frame's tree it is about, index + 1 (0: none); a
	// script's `node_source` names the line that made it.
	node:       i32,
}

@(rodata)
DIAGNOSTIC_TEXT := [Diagnostic_Code]string {
	.None                      = "",
	.Missing_Image             = `Image "{name}" is not in the media provider`,
	.Undecodable_Image         = `Image "{name}" can not be decoded`,
	.Missing_Filter_Image      = `Filter image "{name}" is not in the media provider`,
	.Missing_Svg               = `SVG "{name}" is not in the media provider`,
	.Missing_Lottie            = `Lottie "{name}" is not in the media provider`,
	.Missing_Video             = "no video {q:name} in the media",
	.Undecodable_Video         = "video {q:name} can not be decoded: {video}",
	.Missing_Audio             = "no audio {q:name} in the media",
	.Missing_Track             = "{where}: the track plays {q:clip}, which is not in the media",
	.Missing_Track_Time        = "{where}: the track is timed by the length of {q:clip}, which is not in the media",
	.Missing_Subtitles         = "no subtitles {q:name} in the media",
	.Missing_Captions          = "no captions {q:name} in the media",
	.Missing_Shader            = `Shader "{name}" is not in the media provider`,
	.Missing_Font              = `No match for '"{name}"' font-family.`,
	.Missing_Glyph             = `No fonts with a glyph for "{glyph}" (U+{X4:codepoint}) in text "{text}"`,
	.Unreadable_Media          = "can not read media file {q:name} ({reason})",
	.Undecodable_Media         = "media file {q:name} can not be decoded as {what}",
	.Svg_Markup                = "SVG markup does not parse ({svg})",
	.Svg_Warning               = "SVG {q:name}: {warning}",
	.Svg_Missing_Id            = "SVG {q:name} has no element with id {q:id}",
	.Lottie_Data               = "Lottie data does not parse ({lottie})",
	.Lottie_Warning            = "Lottie {q:name}: {warning}",
	.Lottie_Missing_Layer      = "Lottie {q:name} has no layer named {q:layer}",
	.Shader_Compile            = "shader {at}: {error}",
	.Shader_Zero_Size          = "shader {name} with zero size at ({x}, {y}) is skipped",
	.Shader_No_Channel         = "shader {name} samples no channel `{channel}`",
	.Shader_No_Child           = "shader {name} has no `uniform shader {channel}`",
	.Shader_Undeclared_Uniform = "shader {name}: uniform `{uniform}` is not declared",
	.Shader_Uniform_Count      = "shader {name}: uniform `{uniform}` takes {count} values, got {got}",
	.Shader_Unset_Uniform      = "shader {name}: uniform `{uniform}` is not set",
	.Shader_Unbound_Channel    = "shader {name}: `{channel}` has no image bound",
	.Shader_Pass_Input         = "shader {name}: `{uniform}` binds an input; a program of passes binds inputs in its passes",
	.Shader_Pass_Unbound       = "shader {name}: {pass}'s `{channel}` has nothing bound",
	.Shader_Load               = "shader {name} can not be loaded by the renderer: {gpu}",
	.Shader_Run                = "shader {name}: {gpu}",
	.Shader_Image              = "shader image: {gpu}",
	.Shader_Buffer             = "shader buffer {width}x{height}: {gpu}",
	.Image_Upload              = "image {q:name} could not be uploaded: {gpu}",
	.Video_Frame_Image         = "video frame image: {gpu}",
	.Missing_Model             = "no glTF model {q:name} in the media",
	.Missing_Animation         = "glTF model {q:name} has no animation {q:animation}",
	.Missing_Morph_Target      = "glTF model {q:name} has no morph target {q:target}",
	.View3d_Zero_Size          = "view3d with zero size at ({x}, {y}) is skipped",
	.Geometry_Growth           = "{kind} made again with other parameters on a later frame of its scene: each new set of geometry parameters makes and keeps a mesh, so change a size through the mesh's `scale`, not its geometry's parameters",
	.View3d_Render             = "view3d could not be drawn: {o3d}",
	.Rect_Zero_Size            = "rect with zero size at ({x}, {y}) is skipped",
	.Circle_Zero_Radius        = "circle with zero radius at ({x}, {y}) is skipped",
	.Ellipse_Zero_Radius       = "ellipse with zero radius at ({x}, {y}) is skipped",
	.Invalid_Path              = "invalid path data {q:value}",
	.Invalid_Clip_Path         = "invalid clip path {q:value}",
	.Text_Clipped              = "text {q:text} is cut off by the canvas edge (x={r:x} y={r:y} w={r:w} h={r:h})",
	.Text_Off_Canvas           = "text {q:text} is outside the canvas (x={r:x} y={r:y} w={r:w} h={r:h})",
	.Nan_Transform             = `node "{kind}#{index}" has a NaN or infinite transform`,
	.Empty_Frame               = "frame is empty",
	.Script_Error              = "{message}",
	.Invalid_Value             = "invalid {kind} {q:value} (want {want})",
	.Unused_Field              = "{where}: `{field}` is not used{hint}",
	.Animate_No_Stop           = "{where}: animate's last key has no stop, so it jumps to its `to` at {start}s (give it a stop; stop = start for a jump)",
	.Cue_Drift                = "cue {q:cue}: {what}: {ds:drift}s off {ref}",
	.Cue_Alone                = "cue {q:cue}: only {what} has this id, nothing meets it",
	.Cue_No_Hit               = "cue {q:cue}: no sound of {ref} starts within 30 ms of {s:time}s (nearest: {what})",
	.Outside_Box               = "{node} spills {r:w}px out of box {q:box}",
	.Text_Overlap              = "text {q:text} overlaps text {q:other} ({r:w}x{r:h}px)",
	.Physics_Unsettled         = "{where}: physics body {q:body} is still moving at {s:time}s, the end of the simulation: later frames hold it there mid-motion (simulate longer)",
	.Physics_Offscreen         = "{where}: physics body {q:body} leaves the canvas at {s:time}s and does not come back",
	.Physics_Overlap           = "{where}: physics body {q:body} starts {r:depth}px inside {q:with} at {s:time}s, so they fly apart (move it or give it room)",
	.Physics3d_Offscreen       = "{where}: physics3d body {q:body} leaves the world's bounds at {s:time}s and does not come back (widen the simulation's bounds, or leaves = true on the body)",
	.Physics3d_Overlap         = "{where}: physics3d body {q:body} starts {r:depth} cm inside {q:with} at {s:time}s, so they fly apart (move it or give it room)",
	.Off_Beat                  = "{where}: {count} sounds start off the music's beat, the loudest {q:clip} {ds:drift}s off at {s:time}s (the beat: {s:period}s; hits belong on the beat or half-beat)",
	.Tts_Unavailable           = "{where}: say {q:line} can not be spoken ({reason}): it is silent and its word times are estimates",
	.Tts_Noncommercial         = "{where}: say {q:line} uses voice {q:voice}, whose recording is licensed for non-commercial use only",
	.Tts_Not_Kept              = "{where}: say {q:line} was spoken but could not be kept in the store ({reason}): every run speaks it again",
	.Song_Finding              = "{where}: song {q:clip}: {reason}",
}

// What groups a diagnostic across frames (text moving around stays one
// finding); "" groups by the message.
@(rodata)
DIAGNOSTIC_KEY := [Diagnostic_Code]string {
	.None                      = "",
	.Missing_Image             = "missing_media:{name}",
	.Undecodable_Image         = "undecodable_media:{name}",
	.Missing_Filter_Image      = "missing_media:{name}",
	.Missing_Svg               = "missing_media:{name}",
	.Missing_Lottie            = "missing_media:{name}",
	.Missing_Video             = "{name}",
	.Undecodable_Video         = "{name}",
	.Missing_Audio             = "{name}",
	.Missing_Track             = "",
	.Missing_Track_Time        = "",
	.Missing_Subtitles         = "{name}",
	.Missing_Captions          = "{name}",
	.Missing_Shader            = "missing_shader:{name}",
	.Missing_Font              = "missing_font:{name}",
	.Missing_Glyph             = "missing_glyph:{glyph}",
	.Unreadable_Media          = "unreadable_media:{name}",
	.Undecodable_Media         = "undecodable_media:{name}",
	.Svg_Markup                = "svg_markup:{hex:hash}",
	.Svg_Warning               = "svg:{name}:{warning}",
	.Svg_Missing_Id            = "svg_id:{name}:{id}",
	.Lottie_Data               = "lottie_data:{hex:hash}",
	.Lottie_Warning            = "lottie:{name}:{warning}",
	.Lottie_Missing_Layer      = "lottie_layer:{name}:{layer}",
	.Shader_Compile            = "shader:{at}",
	.Shader_Zero_Size          = "",
	.Shader_No_Channel         = "shader_uniform:{name}:{channel}",
	.Shader_No_Child           = "shader_uniform:{name}:{channel}",
	.Shader_Undeclared_Uniform = "shader_uniform:{name}:{uniform}",
	.Shader_Uniform_Count      = "shader_uniform:{name}:{uniform}",
	.Shader_Unset_Uniform      = "shader_unset:{name}:{uniform}",
	.Shader_Unbound_Channel    = "shader_channel:{name}:{channel}",
	.Shader_Pass_Input         = "shader_uniform:{name}:{uniform}",
	.Shader_Pass_Unbound       = "shader_channel:{name}:{pass}:{slot}",
	.Shader_Load               = "",
	.Shader_Run                = "",
	.Shader_Image              = "",
	.Shader_Buffer             = "",
	.Image_Upload              = "",
	.Video_Frame_Image         = "",
	.Missing_Model             = "missing_media:{name}",
	.Missing_Animation         = "model_animation:{name}:{animation}",
	.Missing_Morph_Target      = "model_morph:{name}:{target}",
	.View3d_Zero_Size          = "",
	.Geometry_Growth           = "geometry_growth:{kind}",
	.View3d_Render             = "",
	.Rect_Zero_Size            = "",
	.Circle_Zero_Radius        = "",
	.Ellipse_Zero_Radius       = "",
	.Invalid_Path              = "",
	.Invalid_Clip_Path         = "",
	.Text_Clipped              = "text_clipped:{text}",
	.Text_Off_Canvas           = "text_off_canvas:{text}",
	.Nan_Transform             = "",
	.Empty_Frame               = "",
	.Script_Error              = "",
	.Invalid_Value             = "{kind} {value}",
	.Unused_Field              = "unused_field:{where}:{field}",
	.Animate_No_Stop           = "animate_no_stop:{where}",
	.Cue_Drift                = "cue_drift:{cue}:{what}",
	.Cue_Alone                = "cue_alone:{cue}",
	.Cue_No_Hit               = "cue_no_hit:{cue}",
	.Outside_Box               = "outside_box:{box}:{node}",
	.Text_Overlap              = "text_overlap:{text}:{other}",
	.Physics_Unsettled         = "physics_unsettled:{where}:{body}",
	.Physics_Offscreen         = "physics_offscreen:{where}:{body}",
	.Physics_Overlap           = "physics_overlap:{where}:{body}:{with}",
	.Physics3d_Offscreen       = "physics3d_offscreen:{where}:{body}",
	.Physics3d_Overlap         = "physics3d_overlap:{where}:{body}:{with}",
	.Off_Beat                  = "off_beat:{where}",
	.Tts_Unavailable           = "tts_unavailable:{line}",
	.Tts_Noncommercial         = "tts_noncommercial:{line}",
	.Tts_Not_Kept              = "tts_not_kept:{line}",
	.Song_Finding              = "song:{clip}:{reason}",
}

// Which operand a placeholder stands for.
Operand :: enum u8 {
	None,
	Name,
	A,
	B,
	N,
	M,
	X,
	Y,
	W,
	H,
	Gpu,
	Svg,
	Lottie,
	Video,
	Shader,
	O3d,
	// Where a compile error is: the shader's name and the error's position.
	At,
	// " (did you mean `b`?)" when `b` is set; not a --json field.
	Hint,
}

// Placeholder names: one per meaning, several per field. They are the keys
// of a diagnostic's --json `fields`.
@(rodata)
OPERAND_NAMES := [?]struct {
	name:    string,
	operand: Operand,
} {
	{"name", .Name},
	{"text", .Name},
	{"kind", .Name},
	{"uniform", .A},
	{"channel", .A},
	{"glyph", .A},
	{"id", .A},
	{"layer", .A},
	{"warning", .A},
	{"value", .A},
	{"message", .A},
	{"pass", .B},
	{"want", .B},
	{"count", .N},
	{"codepoint", .N},
	{"hash", .N},
	{"index", .N},
	{"slot", .N},
	{"width", .N},
	{"got", .M},
	{"height", .M},
	{"x", .X},
	{"y", .Y},
	{"w", .W},
	{"h", .H},
	{"gpu", .Gpu},
	{"svg", .Svg},
	{"lottie", .Lottie},
	{"video", .Video},
	{"error", .Shader},
	{"at", .At},
	{"where", .Name},
	{"field", .A},
	{"suggestion", .B},
	{"start", .X},
	{"hint", .Hint},
	{"cue", .Name},
	{"what", .A},
	{"ref", .B},
	{"time", .X},
	{"drift", .W},
	{"node", .Name},
	{"box", .A},
	{"other", .A},
	{"body", .A},
	{"with", .B},
	{"depth", .W},
	{"clip", .A},
	{"period", .H},
	{"line", .A},
	{"reason", .B},
	{"voice", .B},
	{"animation", .A},
	{"target", .A},
	{"o3d", .O3d},
}

@(private)
operand_of :: proc(field: string) -> Operand {
	for o in OPERAND_NAMES {
		if o.name == field {
			return o.operand
		}
	}
	return .None
}

@(rodata)
ERROR_TEXT := [Error]string {
	.None                   = "",
	.Scene_Without_Duration = "a scene has no duration (give it one, or give the next scene a start; the last scene with a start needs one or the video's duration)",
	.Video_Without_Duration = "the video has no duration and no scenes that give it one",
	.Io                     = "a file could not be read",
	.Invalid_Time_Spec      = "a time spec does not parse",
	.Unknown_Scene          = "no such scene",
	.Ambiguous_Scene        = "several scenes have that name",
	.Out_Of_Range           = "outside the video",
	.Past_Scene             = "past the end of the scene",
	.Render_Failed          = "the renderer could not be set up",
	.No_Video_Decoder       = "no video decoder",
	.No_Video_Track         = "no video track",
	.Video_Decode           = "the video does not decode",
}

// The error's text.
error_message :: proc(err: Error) -> string {
	return ERROR_TEXT[err]
}

// Why a clip can not be decoded, as text.
video_failure_message :: proc(f: Video_Failure, allocator := context.allocator) -> string {
	if f.code != .Video_Decode {
		return strings.clone(ERROR_TEXT[f.code], allocator)
	}
	return fmt.aprintf("%s %s", f.cause, f.detail, allocator = allocator)
}

// The diagnostic's text.
diagnostic_message :: proc(d: Diagnostic, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	write_template(&b, DIAGNOSTIC_TEXT[d.code], d)
	return strings.to_string(b)
}

// What groups the diagnostic across frames: its key, else its message.
diagnostic_key :: proc(d: Diagnostic, allocator := context.allocator) -> string {
	if DIAGNOSTIC_KEY[d.code] == "" {
		return diagnostic_message(d, allocator)
	}
	b := strings.builder_make(allocator)
	write_template(&b, DIAGNOSTIC_KEY[d.code], d)
	return strings.to_string(b)
}

// The code as --json spells it: the enum name in lower case
// (`.Missing_Image` -> "missing_image").
diagnostic_code_name :: proc(code: Diagnostic_Code, allocator := context.allocator) -> string {
	return strings.to_lower(fmt.tprint(code), allocator)
}

// The operands the code's text and key use, by placeholder name: numbers as
// numbers, the rest (causes included) as their text.
diagnostic_fields :: proc(d: Diagnostic, allocator := context.allocator) -> json.Object {
	fields := make(json.Object, allocator = allocator)
	for text in ([2]string{DIAGNOSTIC_TEXT[d.code], DIAGNOSTIC_KEY[d.code]}) {
		rest := text
		for {
			open := strings.index_byte(rest, '{')
			if open < 0 {
				break
			}
			close := strings.index_byte(rest[open:], '}')
			if close < 0 {
				break
			}
			field := rest[open + 1:open + close]
			rest = rest[open + close + 1:]
			if colon := strings.index_byte(field, ':'); colon >= 0 {
				field = field[colon + 1:]
			}
			if field in fields || operand_of(field) == .Hint {
				continue
			}
			value: json.Value
			#partial switch operand_of(field) {
			case .N:
				value = json.Integer(d.n)
			case .M:
				value = json.Integer(d.m)
			case .X:
				value = json.Float(d.x)
			case .Y:
				value = json.Float(d.y)
			case .W:
				value = json.Float(d.w)
			case .H:
				value = json.Float(d.h)
			case:
				b := strings.builder_make(allocator)
				if !write_field(&b, field, "", d) {
					continue
				}
				value = json.String(strings.to_string(b))
			}
			fields[strings.clone(field, allocator)] = value
		}
	}
	return fields
}

// Writes `text` with every `{field}` or `{mode:field}` in it replaced by
// what `write` writes for it (each module's error text uses this); a
// `write` returning false leaves the `{` as text.
template_write :: proc(b: ^strings.Builder, text: string, data: rawptr, write: proc(b: ^strings.Builder, field, mode: string, data: rawptr) -> bool) {
	for i := 0; i < len(text); {
		if text[i] != '{' {
			strings.write_byte(b, text[i])
			i += 1
			continue
		}
		end := strings.index_byte(text[i:], '}')
		if end < 0 {
			strings.write_string(b, text[i:])
			return
		}
		field := text[i + 1:i + end]
		mode := ""
		if colon := strings.index_byte(field, ':'); colon >= 0 {
			mode, field = field[:colon], field[colon + 1:]
		}
		if !write(b, field, mode, data) {
			// Not a field (`{` in a message).
			strings.write_byte(b, '{')
			i += 1
			continue
		}
		i += end + 1
	}
}

// Writes `s`, quoted for the `q` mode.
template_string :: proc(b: ^strings.Builder, s: string, mode: string) {
	if mode == "q" {
		fmt.sbprintf(b, "%q", s)
	} else {
		strings.write_string(b, s)
	}
}

@(private)
write_template :: proc(b: ^strings.Builder, text: string, d: Diagnostic) {
	d := d
	template_write(b, text, &d, proc(b: ^strings.Builder, field, mode: string, data: rawptr) -> bool {
		return write_field(b, field, mode, (^Diagnostic)(data)^)
	})
}

// Writes one operand; false if `field` names none.
@(private)
write_field :: proc(b: ^strings.Builder, field: string, mode: string, d: Diagnostic) -> bool {
	str: string
	switch operand_of(field) {
	case .None:
		return false
	case .Name:
		str = d.name
	case .A:
		str = d.a
	case .B:
		str = d.b
	case .N, .M:
		v := d.n if operand_of(field) == .N else d.m
		switch mode {
		case "hex":
			fmt.sbprintf(b, "%x", u64(v))
		case "X4":
			fmt.sbprintf(b, "%04X", v)
		case:
			fmt.sbprintf(b, "%d", v)
		}
		return true
	case .X, .Y, .W, .H:
		o := operand_of(field)
		v := d.x if o == .X else d.y if o == .Y else d.w if o == .W else d.h
		switch mode {
		case "r":
			fmt.sbprintf(b, "%.0f", v)
		case "s": // seconds
			fmt.sbprintf(b, "%.3f", v)
		case "ds": // a signed difference in seconds
			fmt.sbprintf(b, "%+.3f", v)
		case:
			fmt.sbprintf(b, "%v", v)
		}
		return true
	case .Gpu:
		fmt.sbprintf(b, "%v", d.gpu)
		return true
	case .Svg:
		fmt.sbprintf(b, "%v", d.svg)
		return true
	case .Lottie:
		fmt.sbprintf(b, "%v", d.lottie)
		return true
	case .Video:
		strings.write_string(b, video_failure_message(d.video, context.temp_allocator))
		return true
	case .Shader:
		if d.a != "" {
			strings.write_string(b, d.a)
		} else {
			strings.write_string(b, oksl.error_message(d.shader, context.temp_allocator))
		}
		return true
	case .O3d:
		fmt.sbprintf(b, "%v", d.o3d)
		return true
	case .Hint:
		if d.b != "" {
			fmt.sbprintf(b, " (did you mean `%s`?)", d.b)
		}
		return true
	case .At:
		// `name:line:col`, with the pass of a program of passes
		// (`name: Buffer A:line:col`; the pass is `b`), or a pre-formatted
		// `Stage:line:col` in `name` when `pos.line == 0`.
		pos := d.shader.pos
		if pos.line == 0 {
			if d.b != "" {
				fmt.sbprintf(b, "%s: %s", d.name, d.b)
			} else {
				strings.write_string(b, d.name)
			}
		} else if d.b != "" {
			fmt.sbprintf(b, "%s: %s:%d:%d", d.name, d.b, pos.line, pos.col)
		} else {
			fmt.sbprintf(b, "%s:%d:%d", d.name, pos.line, pos.col)
		}
		return true
	}
	template_string(b, str, mode)
	return true
}
