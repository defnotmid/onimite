package onimite_app

import "core:encoding/csv"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import om "../onimite"
import enc "../encode"
import script "../script"
import platform "../platform"
import ui_render "../render"
import vg "deps:ovg"

// Why a command failed: a code and its operands. Commands return the code
// and leave the operands in `app.failure` (`fail`); only the edge (main's
// exit, the CLI's output, batch rows, the preview) makes the text, from
// FAILURE_TEXT: `{path}`, `{spec}`, `{name}`, `{names}`, `{indices}`, `{n}`,
// `{m}`, `{count}` stand for the fields, `{q:...}` for a quoted one, and
// `{os}`, `{json}`, `{csv}`, `{render}`, `{gpu}`, `{script}`, `{encoder}`
// for the causes.

Error :: enum u8 {
	None,
	Props_Read,
	No_Media_Dir,
	Script,
	Renderer,
	// Time specs (`om.parse_frame`, `om.parse_range`).
	Spec_Unknown_Scene,
	Spec_Unknown_Name,
	Spec_No_Scenes,
	Spec_Ambiguous,
	Spec_Out_Of_Range,
	Spec_Past_Scene,
	Spec_Invalid,
	// Files.
	Create_Dir,
	Png_Many_Frames,
	Write,
	// A row its kind's descriptor turns away: outside its domain, or
	// without a register it needs (`command_validate`).
	Command_Domain,
	Command_Needs,
	// Commands.
	No_Sheet_Frames,
	// snapshot: an approved PNG of another size than the frame.
	Snapshot_Size,
	// audio parts --against: a file that isn't an earlier --json of it.
	Parts_Read,
	Encoder,
	Read_Back,
	// Batches.
	Batch_Read,
	Batch_Json,
	Batch_Not_Array,
	Batch_Not_Object,
	Batch_Csv,
	Batch_No_Header,
	Batch_Rows,
	Output_No_Field,
	Output_Not_Scalar,
	// Audio commands.
	No_Track,
	// show.
	No_Path,
	// probe: a media file that can not be read.
	Probe,
	// preview: the window (`window`, SDL's reason in `spec`) or its drawing.
	Window,
	Window_Drawing,
	// render: the script's load found errors (a silent spoken line, a
	// track whose sound is missing).
	Load_Errors,
	// update.
	Update_Platform,
	Update_Dev,
	Update_Fetch,
	Update_Checksum,
	Update_Unpack,
	Update_Broken,
	Update_Install,
}

// The operands `code` uses (FAILURE_TEXT).
Failure :: struct {
	code:        Error,
	path:        string,
	spec:        string,
	name:        string,
	// Scene names or a row's fields; the indices of scenes sharing a name.
	names:       []string,
	indices:     []int,
	n, m, count: int,
	// The rendered frame's width and height.
	frame_size:  [2]int,
	os:          os.Error,
	json:        json.Error,
	csv:         csv.Error,
	render:      om.Error,
	gpu:         vg.Error,
	window:      platform.Error,
	drawing:     ui_render.Error,
	script:      script.Failure,
	encoder:     enc.Failure,
}

@(rodata)
FAILURE_TEXT := [Error]string {
	.None               = "",
	.Props_Read         = "can not read props {path}: {os}",
	.No_Media_Dir       = "no media directory {path}",
	.Script             = "{script}",
	.Renderer           = "can not set up rendering: {render}",
	.Command_Domain     = "{name} runs only {spec}",
	.Command_Needs      = "{name} needs {spec}",
	.Spec_Unknown_Scene = "no scene {q:name}, available: {names}",
	.Spec_Unknown_Name  = "no scene or cue {q:name}, available: {names}",
	.Spec_No_Scenes     = "no scene {q:name}, the video does not define scenes",
	.Spec_Ambiguous     = "{q:name} matches scenes [{indices}], use {name}[n] or #index",
	.Spec_Out_Of_Range  = "{q:spec} is outside the video (frames 0..{n})",
	.Spec_Past_Scene    = "{q:spec} is past the end of scene {q:name}: it is {n} frames long ({path}), so offsets run @0..@{m} (or @end)",
	.Spec_Invalid       = "can not parse {q:spec}: use a frame (120), time (3.2s, 1:05), percentage (50%), scene (Intro, #3, Intro@1.5s), cue (drop, drop@0.5s; no @50% or @end) or start/end",
	.Create_Dir         = "can not create {path}: {os}",
	.Png_Many_Frames    = "-o {path} is one PNG but {n} frames were asked for; give a directory instead",
	.Write              = "can not write {path}",
	.No_Sheet_Frames    = "no frames for the contact sheet",
	.Snapshot_Size      = "snapshot {path} is {n}x{m} but frame {spec} renders at {frame_size}: check it at the --scale it was approved at, or accept the new size with --update",
	.Encoder            = "{encoder}",
	.Read_Back          = "can not read frame {n} back from the GPU ({gpu})",
	.Parts_Read         = "can not read {path} as `audio parts --json` output",
	.Batch_Read         = "can not read the batch rows {path}: {os}",
	.Batch_Json         = "{path}: invalid JSON ({json})",
	.Batch_Not_Array    = "{path}: the JSON must be an array of objects, one per video",
	.Batch_Not_Object   = "{path}: row {n} is not an object",
	.Batch_Csv          = "{path}: invalid CSV ({csv})",
	.Batch_No_Header    = "{path}: no header row",
	.Batch_Rows         = "rows {n}..{m} are not in {path} ({count} rows)",
	.Output_No_Field    = "no field {q:name} for the output name (fields: {names})",
	.Output_Not_Scalar  = "field {q:name} is not a string or number, it can not name the output",
	.No_Track           = "no audio track {q:name}, the tracks: {names}",
	.No_Path            = "nothing at {q:name}; try: {names}",
	.Probe              = "{encoder}",
	.Window             = "can not open the preview window ({window}: {spec})",
	.Window_Drawing     = "can not set up the preview's drawing ({drawing})",
	.Load_Errors        = "the script's load found errors ({count} in all, `inspect` lists them), the first: {name}",
	.Update_Platform    = "no onimite release is built for {name}; build it from source: https://github.com/defnotmid/onimite#build",
	.Update_Dev         = "this onimite is a development build ({name}); it does not update itself (build it again, or install a release)",
	.Update_Fetch       = "can not fetch {name} from the releases: {spec}",
	.Update_Checksum    = "{name} does not match the release's SHA256SUMS; nothing was changed",
	.Update_Unpack      = "can not unpack {name}: {spec}; nothing was changed",
	.Update_Broken      = "the new onimite ({path}) does not run here; nothing was changed",
	.Update_Install     = "can not install into {path}: {os}",
}

// Keeps `f` as the command's failure (its strings copied) and returns its
// code: `return fail(app, {code = .Write, path = out})`. The first failure
// stays until `failure_clear`.
fail :: proc(app: ^App_State, f: Failure) -> Error {
	if app.failure.code != .None {
		return f.code
	}
	a := virtual.arena_allocator(&app.failure_arena)
	out := f
	out.path = strings.clone(f.path, a)
	out.spec = strings.clone(f.spec, a)
	out.name = strings.clone(f.name, a)
	out.names = make([]string, len(f.names), a)
	for s, i in f.names {
		out.names[i] = strings.clone(s, a)
	}
	out.indices = make([]int, len(f.indices), a)
	copy(out.indices, f.indices)
	out.script = script.failure_clone(f.script, a)
	out.encoder.path = strings.clone(f.encoder.path, a)
	app.failure = out
	return f.code
}

failure_clear :: proc(app: ^App_State) {
	free_all(virtual.arena_allocator(&app.failure_arena))
	app.failure = {}
}

// The failure's text.
failure_message :: proc(f: Failure, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	f := f
	om.template_write(&b, FAILURE_TEXT[f.code], &f, proc(b: ^strings.Builder, field, mode: string, data: rawptr) -> bool {
		f := (^Failure)(data)
		switch field {
		case "path":
			om.template_string(b, f.path, mode)
		case "spec":
			om.template_string(b, f.spec, mode)
		case "name":
			om.template_string(b, f.name, mode)
		case "names":
			strings.write_string(b, strings.join(f.names, ", ", context.temp_allocator))
		case "indices":
			for i, k in f.indices {
				fmt.sbprintf(b, "%s%d", ", " if k > 0 else "", i)
			}
		case "n":
			fmt.sbprintf(b, "%d", f.n)
		case "m":
			fmt.sbprintf(b, "%d", f.m)
		case "count":
			fmt.sbprintf(b, "%d", f.count)
		case "frame_size":
			fmt.sbprintf(b, "%dx%d", f.frame_size.x, f.frame_size.y)
		case "os":
			fmt.sbprintf(b, "%v", f.os)
		case "json":
			fmt.sbprintf(b, "%v", f.json)
		case "csv":
			fmt.sbprintf(b, "%v", f.csv)
		case "window":
			fmt.sbprintf(b, "%v", f.window)
		case "drawing":
			fmt.sbprintf(b, "%v", f.drawing)
		case "gpu":
			fmt.sbprintf(b, "%v", f.gpu)
		case "render":
			strings.write_string(b, om.error_message(f.render))
		case "script":
			strings.write_string(b, script.error_message(f.script, context.temp_allocator))
		case "encoder":
			strings.write_string(b, enc.error_message(f.encoder, context.temp_allocator))
		case:
			return false
		}
		return true
	})
	return strings.to_string(b)
}

// The failure for a time spec that doesn't resolve (fframes' messages);
// `times` are the cues and sync ids it could name.
spec_failure :: proc(t: ^om.Timeline, fps: int, spec: string, err: om.Error, times: []om.Named_Time = nil) -> Failure {
	#partial switch err {
	case .Unknown_Scene:
		names := make([dynamic]string, context.temp_allocator)
		for s in t.scenes {
			append(&names, s.scene.name)
		}
		for n in times {
			if !slice.contains(names[:], n.name) {
				append(&names, n.name)
			}
		}
		code := Error.Spec_No_Scenes
		switch {
		case len(times) > 0:
			code = .Spec_Unknown_Name
		case len(names) > 0:
			code = .Spec_Unknown_Scene
		}
		return {code = code, spec = spec, name = strip_at(spec), names = names[:]}
	case .Ambiguous_Scene:
		name := strip_at(spec)
		idx := make([dynamic]int, context.temp_allocator)
		for s, i in t.scenes {
			if strings.equal_fold(s.scene.name, name) {
				append(&idx, i)
			}
		}
		return {code = .Spec_Ambiguous, spec = spec, name = name, indices = idx[:]}
	case .Past_Scene:
		name := strip_at(spec)
		i, _ := om.find_scene_spec(t^, name)
		frames := om.scene_info_frames(t.scenes[i]) if i >= 0 else 0
		return {code = .Spec_Past_Scene, spec = spec, name = name, n = frames, m = max(frames - 1, 0),
			path = fmt.tprintf("%.2fs", f64(frames) / f64(max(fps, 1)))}
	case .Out_Of_Range:
		// The valid frames, both ends included.
		return {code = .Spec_Out_Of_Range, spec = spec, n = t.duration_frames - 1}
	}
	return {code = .Spec_Invalid, spec = spec}
}

@(private)
strip_at :: proc(spec: string) -> string {
	s := strings.trim_space(spec)
	if i := strings.index_byte(s, '@'); i >= 0 {
		s = s[:i]
	}
	if i := strings.index(s, ".."); i >= 0 {
		s = s[:i] if s[:i] != "" else s[i + 2:]
	}
	return s
}
