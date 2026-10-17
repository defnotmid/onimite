package onimite_app

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import om "../onimite"
import script "../script"

// What commands print, as fframes prints it: a text summary, or with
// `--json` one JSON document on stdout (progress and warnings go to stderr).
// Field names follow fframes'. Diagnostics carry their code (snake_case,
// `om.diagnostic_code_name`) and the operands of its text.

Reported_Diagnostic :: struct {
	severity: string      `json:"severity"`,
	code:     string      `json:"code"`,
	key:      string      `json:"key"`,
	message:  string      `json:"message"`,
	fields:   json.Object `json:"fields"`,
	// The script line that made the node it is about ("" when none).
	source:   string      `json:"source"`,
}

// The problems found in one frame.
Frame_Report :: struct {
	frame:       int                   `json:"frame"`,
	seconds:     f32                   `json:"seconds"`,
	scenes:      []string              `json:"scenes"`,
	diagnostics: []Reported_Diagnostic `json:"diagnostics"`,
}

Frame_Range :: struct {
	start: int `json:"start"`,
	end:   int `json:"end"`,
}

severity_name :: proc(s: om.Severity) -> string {
	switch s {
	case .Info:
		return "info"
	case .Warning:
		return "warning"
	case .Error:
		return "error"
	}
	return "error"
}

// Names of the scenes playing at video frame `f` (several while they overlap).
scenes_at :: proc(t: ^om.Timeline, f: int) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for s in t.scenes {
		if f >= s.start_frame && f < s.end_frame {
			append(&names, s.scene.name)
		}
	}
	return names[:]
}

scenes_label :: proc(scenes: []string) -> string {
	if len(scenes) == 0 {
		return ""
	}
	return fmt.tprintf(" [%s]", strings.join(scenes, " + ", context.temp_allocator))
}

// The script line that made the node `d` is about, while the script
// records them (`node_sources_on`, during `frame` and `inspect`).
diagnostic_source :: proc(app: ^App_State, d: om.Diagnostic) -> string {
	if d.node == 0 || !app.script.node_sources_on {
		return ""
	}
	return script.node_source(&app.script, int(d.node) - 1)
}

// A diagnostic as printed (in `allocator`).
reported :: proc(d: om.Diagnostic, source := "", allocator := context.temp_allocator) -> Reported_Diagnostic {
	return {
		source   = strings.clone(source, allocator),
		severity = severity_name(d.severity),
		code     = om.diagnostic_code_name(d.code, allocator),
		key      = om.diagnostic_key(d, allocator),
		message  = om.diagnostic_message(d, allocator),
		fields   = om.diagnostic_fields(d, allocator),
	}
}

// Takes the diagnostics accumulated for frame `f` out of the renderer (in
// the temp allocator) and clears them.
take_frame_report :: proc(app: ^App_State, r: ^om.Renderer, f: int) -> Frame_Report {
	diags := make([]Reported_Diagnostic, len(r.ctx.diagnostics), context.temp_allocator)
	for d, i in r.ctx.diagnostics {
		diags[i] = reported(d, diagnostic_source(app, d))
	}
	om.diagnostics_clear(&r.ctx)
	return {f, f32(f) / f32(r.video.fps), scenes_at(&r.timeline, f), diags}
}

frame_report_has_problems :: proc(rep: Frame_Report) -> bool {
	for d in rep.diagnostics {
		if d.severity != "info" {
			return true
		}
	}
	return false
}

// Warnings and errors of a frame, one per line; info findings only counted.
diagnostics_text :: proc(rep: Frame_Report, indent: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	info := 0
	for d in rep.diagnostics {
		if d.severity == "info" {
			info += 1
			continue
		}
		if d.source != "" {
			fmt.sbprintf(&b, "%s%s: %s: %s\n", indent, d.severity, d.source, lower_first(d.message))
		} else {
			fmt.sbprintf(&b, "%s%s: %s\n", indent, d.severity, lower_first(d.message))
		}
	}
	if info > 0 {
		fmt.sbprintf(&b, "%s(%d info findings, e.g. text outside the canvas, see --json)\n", indent, info)
	}
	return strings.to_string(b)
}

@(private)
lower_first :: proc(s: string) -> string {
	// Not an acronym ("SVG ..." keeps its capitals).
	upper :: proc(c: u8) -> bool {return c >= 'A' && c <= 'Z'}
	if len(s) > 1 && upper(s[0]) && !upper(s[1]) && s[1] != ' ' {
		return fmt.tprintf("%c%s", s[0] + 32, s[1:])
	}
	return s
}

// Prints `value` as JSON in JSON mode, else `text` (when not empty).
emit :: proc(app: ^App_State, value: $T, text: string) {
	if app.json {
		value := value
		data, err := json.marshal(value, {pretty = true, use_spaces = true, spaces = 2, sort_maps_by_key = true}, context.temp_allocator)
		if err != nil {
			output_line(app, fmt.tprintf(`{{"error":"can not write the output as JSON (%v)","code":"output"}}`, err))
			app.exit_code = 1
			return
		}
		output_line(app, string(data))
		return
	}
	if text != "" {
		output_line(app, strings.trim_right_space(text))
	}
}

// A line of the command's output: on stdout, or into `app.out`.
@(private)
output_line :: proc(app: ^App_State, s: string) {
	if app.out != nil {
		strings.write_string(app.out, s)
		strings.write_byte(app.out, '\n')
		return
	}
	fmt.println(s)
}

// Prints the command's failure: "error: ..." on stderr, or `{"error": ...,
// "code": ...}` as the JSON document (the code is the `Error` name in lower
// case). Exit code 1 (fframes' ExitCode::FAILURE).
failure_print :: proc(app: ^App_State) {
	message := failure_message(app.failure, context.temp_allocator)
	if app.json {
		Error_Doc :: struct {
			error: string `json:"error"`,
			code:  string `json:"code"`,
		}
		code := strings.to_lower(fmt.tprint(app.failure.code), context.temp_allocator)
		data, _ := json.marshal(Error_Doc{message, code}, {}, context.temp_allocator)
		output_line(app, string(data))
	} else {
		fmt.eprintfln("error: %s", message)
	}
	app.exit_code = 1
}

// A non-fatal note on stderr in both modes.
warn :: proc(format: string, args: ..any) {
	fmt.eprintfln("warning: %s", fmt.tprintf(format, ..args))
}

// What the script's load found (`load_diagnostics`; `m` nil: the media
// was not loaded), one warning line each.
warn_load :: proc(s: ^script.Script, m: ^om.Media) {
	for d in load_diagnostics(s, m) {
		warn("%s", om.diagnostic_message(d, context.temp_allocator))
	}
}

// The frames of a comma or space separated list of specs.
resolve_frames :: proc(app: ^App_State, t: ^om.Timeline, fps: int, specs: string) -> (specs_out: []string, frames: []int, err: Error) {
	names := make([dynamic]string, context.temp_allocator)
	list := make([dynamic]int, context.temp_allocator)
	times := spec_names(app) or_return
	for part in strings.split(specs, ",", context.temp_allocator) {
		for spec in strings.fields(part, context.temp_allocator) {
			f, ferr := om.parse_frame(t^, fps, spec, times, &app.media)
			if ferr != nil {
				return nil, nil, fail(app, spec_failure(t, fps, spec, ferr, times))
			}
			append(&names, spec)
			append(&list, f)
		}
	}
	return names[:], list[:], nil
}

// `[start, end)` of a range spec ("" and "all" = the whole video).
resolve_range :: proc(app: ^App_State, t: ^om.Timeline, fps: int, spec: string) -> (start, end: int, err: Error) {
	times := spec_names(app) or_return
	rerr: om.Error
	start, end, rerr = om.parse_range(t^, fps, spec, times, &app.media)
	if rerr != nil {
		return 0, 0, fail(app, spec_failure(t, fps, spec, rerr, times))
	}
	return start, end, nil
}

// `count` frames evenly spread over a range, first and last included.
spread :: proc(start, end, count: int) -> []int {
	n := clamp(count, 1, max(end - start, 1))
	out := make([]int, n, context.temp_allocator)
	if n == 1 {
		out[0] = start
		return out
	}
	last := end - 1
	for i in 0 ..< n {
		out[i] = start + int(f64(last - start) * f64(i) / f64(n - 1) + 0.5)
	}
	return out
}
