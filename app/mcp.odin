package onimite_app

import "core:bufio"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strings"
import "core:sync"
import "core:thread"
import script "../script"

// `onimite mcp`: the commands as Model Context Protocol tools, JSON-RPC 2.0
// over stdio, one message per line. Stateless: every call fills its
// command's rows from its arguments through its options, as the command
// line does, and runs them on an App_State of its own. What the command prints (its
// `--json` document) is the call's text; frames, strips, onion skins and
// waveforms come back as images too, and what the script prints as text
// (`print`). Warnings and progress stay on stderr.
// `preview` opens the window for the user as a process of its own and
// returns at once. `guide` returns the built-in skill (mcp_guide.odin), which
// the server's instructions tell a client to read first.

// The release (its tag; release builds set it with -define), else "dev".
ONIMITE_VERSION :: #config(ONIMITE_VERSION, "dev")

// The protocol revision answered when the client asks for none.
MCP_PROTOCOL :: "2025-06-18"

// What a client is told when it connects: read the guide before making a
// video, and where relative paths go.
@(private = "file")
MCP_INSTRUCTIONS :: `onimite makes videos from Lua scripts: a video is a video.lua file (plus a media/ folder beside it for fonts, images, sounds, clips, shaders and 3D models) that this server renders, checks and previews. Before writing or changing a video, call the guide tool (topic "skill") and follow it; it names further topics (api, audio, design, media, shaders, filters, 3d, problems) to read when the video needs them. Write video.lua and its media with your file tools. Check your work without watching it: inspect, frame, strip, onion, audio_analyze. Open preview to show the user (it reloads when the files change), and render for the final MP4. Relative paths in every tool, the script's included, are relative to the working folder: %s`

// The work folder when the client gives none: Documents/onimite in the
// user's home (made when the server starts).
mcp_default_dir :: proc() -> string {
	home := os.get_env("USERPROFILE" when ODIN_OS == .Windows else "HOME", context.temp_allocator)
	path, _ := filepath.join({home, "Documents", "onimite"}, context.temp_allocator)
	return path
}

// Serves tools on stdin/stdout until stdin closes. With `dir`, works there
// (made if missing): relative paths in tool calls resolve against it. With
// `update_check` (and not ONIMITE_NO_UPDATE_CHECK), a release build looks
// for a newer release on a thread of its own as it starts.
mcp_serve :: proc(dir := "", update_check := false) {
	if _, released := update_version(ONIMITE_VERSION); released && update_check && !env_set("ONIMITE_NO_UPDATE_CHECK") {
		thread.create_and_start(mcp_update_check, self_cleanup = true)
	}
	if dir != "" {
		_ = os.make_directory_all(dir)
		if err := os.set_working_directory(dir); err != nil {
			fmt.eprintfln("onimite mcp: can not work in %s (%v)", dir, err)
		}
	}
	mcp_protocol_open()
	reader: bufio.Reader
	bufio.reader_init(&reader, os.to_reader(os.stdin), 1 << 16)
	defer bufio.reader_destroy(&reader)
	for {
		line, err := bufio.reader_read_string(&reader, '\n', context.temp_allocator)
		if strings.trim_space(line) != "" {
			if reply := mcp_handle(line); reply != "" {
				if !mcp_protocol_write(strings.concatenate({reply, "\n"}, context.temp_allocator)) {
					return
				}
			}
		}
		free_all(context.temp_allocator)
		if err != nil {
			return
		}
	}
}

// The startup update check: the latest release, when it is newer than this
// onimite, for the next tool result to mention (mcp_answer_json). Never
// waited for: the server may end first.
@(private = "file")
mcp_newer: string
@(private = "file")
mcp_newer_found: bool
@(private = "file")
mcp_newer_told: bool

@(private = "file")
mcp_update_check :: proc() {
	exe, err := os.get_executable_path(context.temp_allocator)
	if dir, root := update_layout(exe); err == nil && root == "" {
		update_leftovers_remove(dir)
	}
	if latest, problem := update_latest(); problem == "" && update_newer(latest.tag, ONIMITE_VERSION) {
		mcp_newer = strings.clone(latest.tag)
		sync.atomic_store(&mcp_newer_found, true)
	}
	free_all(context.temp_allocator)
}

// Answers one message ("" for notifications), in temp memory.
@(private = "file")
mcp_handle :: proc(line: string) -> string {
	msg, perr := json.parse_string(line, parse_integers = true, allocator = context.temp_allocator)
	if perr != nil {
		return mcp_error(nil, -32700, "parse error")
	}
	obj, is_obj := msg.(json.Object)
	if !is_obj {
		return mcp_error(nil, -32600, "invalid request")
	}
	id, has_id := obj["id"]
	method, _ := obj["method"].(json.String)
	params, _ := obj["params"].(json.Object)
	if !has_id {
		return "" // a notification (notifications/initialized, cancelled, ...)
	}
	switch method {
	case "initialize":
		version, _ := params["protocolVersion"].(json.String)
		if version == "" {
			version = MCP_PROTOCOL
		}
		cwd, _ := os.get_working_directory(context.temp_allocator)
		return mcp_result(id, fmt.tprintf(`{{"protocolVersion":%s,"capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"onimite","version":%s}},"instructions":%s}}`, mcp_quote(version), mcp_quote(ONIMITE_VERSION), mcp_quote(fmt.tprintf(MCP_INSTRUCTIONS, cwd))))
	case "ping":
		return mcp_result(id, "{}")
	case "tools/list":
		return mcp_result(id, mcp_tools_list())
	case "tools/call":
		name, _ := params["name"].(json.String)
		args, _ := params["arguments"].(json.Object)
		if name == "guide" {
			return mcp_result(id, mcp_answer_json(mcp_guide(args), name))
		}
		for d, kind in COMMAND_KINDS {
			if .Mcp_Tool in d.flags && command_name(kind) == name {
				return mcp_result(id, mcp_answer_json(mcp_call(kind, args), name))
			}
		}
		return mcp_error(id, -32602, fmt.tprintf("no tool %q", name))
	}
	return mcp_error(id, -32601, fmt.tprintf("no method %q", method))
}

// A tool call's answer: its content items (JSON objects, comma-separated)
// and whether the call failed.
@(private = "file")
Mcp_Answer :: struct {
	content: string,
	failed:  bool,
}

@(private = "file")
mcp_text :: proc(text: string) -> string {
	return fmt.tprintf(`{{"type":"text","text":%s}}`, mcp_quote(text))
}

// The result of tool `name`: its answer, and once, when the startup check
// found a newer release, a line saying so (not on `update` itself).
@(private = "file")
mcp_answer_json :: proc(a: Mcp_Answer, name: string) -> string {
	notice := ""
	if !mcp_newer_told && sync.atomic_load(&mcp_newer_found) {
		mcp_newer_told = true
		if name != command_name(.Update) {
			notice = fmt.tprintf(",%s", mcp_text(fmt.tprintf("onimite %s is out (this server is %s). Tell the user; the update tool installs it, and the app needs a restart to use it.", mcp_newer, ONIMITE_VERSION)))
		}
	}
	return fmt.tprintf(`{{"content":[%s%s],"isError":%v}}`, a.content, notice, a.failed)
}

@(private = "file")
mcp_result :: proc(id: json.Value, result: string) -> string {
	return fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"result":%s}}`, mcp_value(id), result)
}

@(private = "file")
mcp_error :: proc(id: json.Value, code: int, message: string) -> string {
	return fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"error":{{"code":%d,"message":%s}}}}`, mcp_value(id), code, mcp_quote(message))
}

@(private = "file")
mcp_value :: proc(v: json.Value) -> string {
	if v == nil {
		return "null"
	}
	data, _ := json.marshal(v, {}, context.temp_allocator)
	return string(data)
}

@(private = "file")
mcp_quote :: proc(s: string) -> string {
	data, _ := json.marshal(s, {}, context.temp_allocator)
	return string(data)
}

// The tool list with each tool's input schema, from COMMAND_KINDS and the
// tools' options.
@(private = "file")
mcp_tools_list :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"tools":[`)
	first_tool := true
	for d, kind in COMMAND_KINDS {
		if .Mcp_Tool not_in d.flags {
			continue
		}
		if !first_tool {
			strings.write_byte(&b, ',')
		}
		first_tool = false
		about := fmt.tprintf("%c%s.", d.about[0] - ('a' - 'A'), d.about[1:])
		if d.mcp_note != "" {
			about = fmt.tprintf("%s %s", about, d.mcp_note)
		}
		fmt.sbprintf(&b, `{{"name":%s,"description":%s,"inputSchema":{{"type":"object","properties":{{`, mcp_quote(command_name(kind)), mcp_quote(about))
		required := make([dynamic]string, context.temp_allocator)
		first := true
		for o in command_options(kind) {
			if !o.mcp {
				continue
			}
			if !first {
				strings.write_byte(&b, ',')
			}
			first = false
			fmt.sbprintf(&b, `%s:{{`, mcp_quote(o.name))
			mcp_schema_type(&b, o.type)
			fmt.sbprintf(&b, `,"description":%s`, mcp_quote(option_about(o, true)))
			#partial switch t in o.type.variant {
			case reflect.Type_Info_Slice:
				strings.write_string(&b, `,"items":{`)
				mcp_schema_type(&b, t.elem)
				strings.write_byte(&b, '}')
			case reflect.Type_Info_Map:
				strings.write_string(&b, `,"additionalProperties":{`)
				mcp_schema_type(&b, t.value)
				strings.write_byte(&b, '}')
			case reflect.Type_Info_Enum:
				strings.write_string(&b, `,"enum":[`)
				for name, k in option_choices(o) {
					if k > 0 {
						strings.write_byte(&b, ',')
					}
					strings.write_string(&b, mcp_quote(name))
				}
				strings.write_byte(&b, ']')
			}
			strings.write_byte(&b, '}')
			if option_required(kind, o) {
				append(&required, o.name)
			}
		}
		strings.write_string(&b, `},"required":[`)
		for r, k in required {
			if k > 0 {
				strings.write_byte(&b, ',')
			}
			strings.write_string(&b, mcp_quote(r))
		}
		strings.write_string(&b, `],"additionalProperties":false}}`)
	}
	topics, _ := json.marshal(guide_topics(), {}, context.temp_allocator)
	fmt.sbprintf(&b, `,{{"name":"guide","description":%s,"inputSchema":{{"type":"object","properties":{{"topic":{{"type":"string","enum":%s,"description":"skill (the start: how to make and check a video), or a reference"}}}},"required":[],"additionalProperties":false}}}}`, mcp_quote("How to make videos with onimite: the onimite-video skill (writing the script, design, sound, checking) and its references. Read topic skill first."), string(topics))
	strings.write_string(&b, `]}`)
	return strings.to_string(b)
}

// `"type":...` of a value of type `t`: its JSON Schema type, a list of them
// for a union.
@(private = "file")
mcp_schema_type :: proc(b: ^strings.Builder, t: ^reflect.Type_Info) {
	if u, is_union := reflect.type_info_base(t).variant.(reflect.Type_Info_Union); is_union {
		strings.write_string(b, `"type":[`)
		for v, i in u.variants {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			strings.write_string(b, mcp_quote(mcp_type(v)))
		}
		strings.write_byte(b, ']')
		return
	}
	fmt.sbprintf(b, `"type":%s`, mcp_quote(mcp_type(t)))
}

// The JSON Schema type of a value of type `t`.
@(private = "file")
mcp_type :: proc(t: ^reflect.Type_Info) -> string {
	#partial switch _ in reflect.type_info_base(t).variant {
	case reflect.Type_Info_String, reflect.Type_Info_Enum:
		return "string"
	case reflect.Type_Info_Integer:
		return "integer"
	case reflect.Type_Info_Float:
		return "number"
	case reflect.Type_Info_Boolean:
		return "boolean"
	case reflect.Type_Info_Map:
		return "object"
	case reflect.Type_Info_Slice:
		return "array"
	}
	unreachable()
}

// Runs tool `kind` on an App_State of its own: its command's JSON document
// as text, its images, `isError` when it failed; a check that fails
// (inspect, snapshot: exit code 2) adds `{"failed": true}`.
@(private = "file")
mcp_call :: proc(kind: Command_Kind, args: json.Object) -> Mcp_Answer {
	info := COMMAND_KINDS[kind]
	tool := command_name(kind)
	options := command_options(kind)
	rows := front_rows_make(kind)
	rows[.Output].regs.flag = true
	for name, v in args {
		o, known := mcp_option(options, name)
		if !known {
			return mcp_usage(fmt.tprintf("%s takes no argument %q", tool, name))
		}
		type := mcp_type(o.type)
		if !mcp_type_ok(type, v) {
			return mcp_usage(fmt.tprintf("%s: %s must be %s", tool, name, mcp_type_name(type)))
		}
		problem: string
		#partial switch x in v {
		case json.Object:
			for k, value in x {
				if problem = option_set(&rows, o, {str = fmt.tprintf("%s=%v", k, value)}); problem != "" {
					break
				}
			}
		case json.Array:
			list := make([]string, len(x), context.temp_allocator)
			for s, i in x {
				list[i] = string(s.(json.String))
			}
			problem = option_set(&rows, o, {list = list})
		case:
			str, _ := v.(json.String)
			on, _ := v.(json.Boolean)
			problem = option_set(&rows, o, {str = string(str), num = mcp_number(v), on = bool(on)})
		}
		if problem != "" {
			return mcp_usage(fmt.tprintf("%s: %s %s", tool, name, problem))
		}
	}
	// The positional argument first, then the script.
	for row in Front_Row {
		for o in options {
			if o.mcp && o.row == row && option_required(kind, o) && o.name not_in args {
				return mcp_usage(fmt.tprintf("%s needs %s", tool, o.name))
			}
		}
	}
	if kind == .Preview {
		return mcp_preview(kind, options, args, rows[.Load].regs.path)
	}

	// Images nobody asked to keep are written to a directory of their own
	// and removed after.
	scratch := ""
	if info.images == .Frames || info.images == .Output {
		if rows[.Command].regs.path == "" {
			dir, derr := os.make_directory_temp("", "onimite-mcp-*", context.temp_allocator)
			if derr != nil {
				return mcp_usage("can not make a directory for the images")
			}
			scratch = dir
			rows[.Command].regs.path = dir if info.images == .Frames else filepath.join({dir, fmt.tprintf("%s.png", tool)}, context.temp_allocator) or_else ""
		}
	}
	defer if scratch != "" {
		os.remove_all(scratch)
	}

	out := strings.builder_make(context.temp_allocator)
	// What the script prints comes back too: a client reads no stderr.
	script.print_capture_begin()
	exit_code := front_rows_run(rows, &out)
	printed, dropped := script.print_capture_end(context.temp_allocator)

	text := strings.trim_space(strings.to_string(out))
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, mcp_text(text))
	if printed != "" {
		cut := fmt.tprintf("\n(%d more bytes printed, not kept)", dropped) if dropped > 0 else ""
		fmt.sbprintf(&b, ",%s", mcp_text(fmt.tprintf("the script printed:\n%s%s", strings.trim_right_space(printed), cut)))
	}
	if exit_code == 2 {
		strings.write_string(&b, `,{"type":"text","text":"{\"failed\": true}"}`)
	}
	if exit_code != 1 {
		for path in mcp_image_paths(info.images, text) {
			data, rerr := os.read_entire_file(path, context.temp_allocator)
			if rerr != nil {
				continue
			}
			fmt.sbprintf(&b, `,{{"type":"image","mimeType":"image/png","data":"%s"}}`, base64.encode(data, allocator = context.temp_allocator))
		}
	}
	return {strings.to_string(b), exit_code == 1}
}

// A call that can't run as asked: a tool error the caller can read.
@(private = "file")
mcp_usage :: proc(message: string) -> Mcp_Answer {
	return {mcp_text(fmt.tprintf(`{{"error":%s,"code":"usage"}}`, mcp_quote(message))), true}
}

// The option among a tool's `options` that is its argument `name`.
@(private = "file")
mcp_option :: proc(options: []Option, name: string) -> (Option, bool) {
	for o in options {
		if o.mcp && o.name == name {
			return o, true
		}
	}
	return {}, false
}

@(private = "file")
mcp_type_ok :: proc(type: string, v: json.Value) -> bool {
	switch type {
	case "string":
		_, ok := v.(json.String)
		return ok
	case "boolean":
		_, ok := v.(json.Boolean)
		return ok
	case "integer", "number":
		#partial switch _ in v {
		case json.Integer, json.Float:
			return true
		}
		return false
	case "array":
		list, ok := v.(json.Array)
		if !ok {
			return false
		}
		for x in list {
			if _, is_str := x.(json.String); !is_str {
				return false
			}
		}
		return true
	case "object":
		_, ok := v.(json.Object)
		return ok
	}
	return false
}

@(private = "file")
mcp_type_name :: proc(type: string) -> string {
	switch type {
	case "array":
		return "a list of strings"
	case "integer":
		return "an integer"
	case "object":
		return "an object"
	}
	return fmt.tprintf("a %s", type)
}

@(private = "file")
mcp_number :: proc(v: json.Value) -> f64 {
	#partial switch x in v {
	case json.Integer:
		return f64(x)
	case json.Float:
		return f64(x)
	}
	return 0
}

// The PNGs the command's document names.
@(private = "file")
mcp_image_paths :: proc(images: Mcp_Images, doc: string) -> []string {
	paths := make([dynamic]string, context.temp_allocator)
	if images == .None {
		return nil
	}
	v, err := json.parse_string(doc, allocator = context.temp_allocator)
	if err != nil {
		return nil
	}
	switch images {
	case .None:
	case .Frames:
		list, _ := v.(json.Array)
		for x in list {
			obj, _ := x.(json.Object)
			if p, ok := obj["path"].(json.String); ok {
				append(&paths, string(p))
			}
		}
	case .Output, .Waveform:
		obj, _ := v.(json.Object)
		key := "output" if images == .Output else "waveform"
		if p, ok := obj[key].(json.String); ok && strings.has_suffix(string(p), ".png") {
			append(&paths, string(p))
		}
	}
	return paths[:]
}

// The preview windows this server opened, by script (absolute path).
@(private = "file")
Mcp_Preview :: struct {
	script:  string,
	process: os.Process,
}

@(private = "file")
mcp_previews: [dynamic]Mcp_Preview

// Opens `onimite preview` on the script as a process of its own (its output
// on this server's stderr, no stdin), unless one of this server's previews
// shows the script already: it reloads on save, so one is enough. Its
// command line is the call's arguments, spelled as its `options` say.
@(private = "file")
mcp_preview :: proc(kind: Command_Kind, options: []Option, args: json.Object, path: string) -> Mcp_Answer {
	script, _ := filepath.abs(path, context.temp_allocator)
	for i := 0; i < len(mcp_previews); {
		p := mcp_previews[i]
		if state, err := os.process_wait(p.process, 0); err == nil && state.exited {
			delete(p.script)
			unordered_remove(&mcp_previews, i)
			continue
		}
		if p.script == script {
			return {mcp_text(fmt.tprintf(`{{"script":%s,"pid":%d,"already_open":true}}`, mcp_quote(script), p.process.pid)), false}
		}
		i += 1
	}
	exe, eerr := os.get_executable_path(context.temp_allocator)
	if eerr != nil {
		return mcp_usage("can not find the onimite binary to open the preview with")
	}
	command := make([dynamic]string, context.temp_allocator)
	append(&command, exe, command_cli_name(kind))
	for o in options {
		v, given := args[o.name]
		if !o.mcp || !given {
			continue
		}
		// A positional argument has no spelling.
		spelling, _, _ := strings.partition(o.cli, "|")
		#partial switch _ in o.type.variant {
		case reflect.Type_Info_Boolean:
			if bool(v.(json.Boolean)) {
				append(&command, spelling)
			}
		case reflect.Type_Info_Integer:
			append(&command, spelling, fmt.tprint(int(mcp_number(v))))
		case reflect.Type_Info_Float:
			append(&command, spelling, fmt.tprint(mcp_number(v)))
		case reflect.Type_Info_Map:
			for k, x in v.(json.Object) {
				append(&command, spelling, fmt.tprintf("%s=%v", k, x))
			}
		case reflect.Type_Info_Slice:
			for x in v.(json.Array) {
				append(&command, string(x.(json.String)))
			}
		case:
			if str := string(v.(json.String)); str != "" {
				if spelling != "" {
					append(&command, spelling)
				}
				append(&command, str)
			}
		}
	}
	process, err := os.process_start({command = command[:], stdout = os.stderr, stderr = os.stderr})
	if err != nil {
		return mcp_usage(fmt.tprintf("can not start the preview: %v", err))
	}
	append(&mcp_previews, Mcp_Preview{strings.clone(script), process})
	return {mcp_text(fmt.tprintf(`{{"script":%s,"pid":%d,"already_open":false}}`, mcp_quote(script), process.pid)), false}
}

// The built-in skill: topic "skill" (the default) or a reference.
@(private = "file")
mcp_guide :: proc(args: json.Object) -> Mcp_Answer {
	topic, _ := args["topic"].(json.String)
	text, ok := guide_text(string(topic))
	if !ok {
		names := strings.join(guide_topics(), ", ", context.temp_allocator)
		return mcp_usage(fmt.tprintf("guide has no topic %q; topics: %s", topic, names))
	}
	return {mcp_text(text), false}
}
