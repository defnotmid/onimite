package onimite_script

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import om "../onimite"

// Why a script did not load: a code and its operands. Text is made at the
// edge (`error_message`) from ERROR_TEXT, where `{path}`, `{os}`, `{json}`
// and `{lua}` stand for the `Failure` fields.

Error :: enum u8 {
	None,
	Read,
	Props_Json,
	Props_Not_Object,
	// A Lua error: its message and traceback.
	Lua,
	No_Video,
	No_Duration,
	// A clip `audio_add(name, fn)` deferred: its function failed (`path`
	// the clip, `lua` the error).
	Audio_Build,
}

Failure :: struct {
	code: Error,
	// Owned.
	path: string,
	// Lua's message (owned).
	lua:  string,
	os:   os.Error,
	json: json.Error,
}

@(rodata)
ERROR_TEXT := [Error]string {
	.None             = "",
	.Read             = "can not read {path}: {os}",
	.Props_Json       = "props: invalid JSON ({json})",
	.Props_Not_Object = `props: the JSON must be an object, e.g. {"title": "Hello"}`,
	.Lua              = "{lua}",
	.No_Video         = "{path}: call video{ width = ..., height = ..., fps = ... } first",
	.No_Duration      = "{path}: the video has no scenes and no duration",
	.Audio_Build      = "audio_add({q:path}): the clip's function failed: {lua}",
}

// The failure's text.
error_message :: proc(f: Failure, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	f := f
	om.template_write(&b, ERROR_TEXT[f.code], &f, proc(b: ^strings.Builder, field, mode: string, data: rawptr) -> bool {
		f := (^Failure)(data)
		switch field {
		case "path":
			om.template_string(b, f.path, mode)
		case "lua":
			strings.write_string(b, f.lua)
		case "os":
			fmt.sbprintf(b, "%v", f.os)
		case "json":
			fmt.sbprintf(b, "%v", f.json)
		case:
			return false
		}
		return true
	})
	return strings.to_string(b)
}

// A copy of `f` with its strings cloned.
failure_clone :: proc(f: Failure, allocator := context.allocator) -> Failure {
	out := f
	out.path = strings.clone(f.path, allocator)
	out.lua = strings.clone(f.lua, allocator)
	return out
}

failure_destroy :: proc(f: ^Failure, allocator := context.allocator) {
	delete(f.path, allocator)
	delete(f.lua, allocator)
	f^ = {}
}
