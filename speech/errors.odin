package onimite_speech

import "core:fmt"
import "core:os"
import "core:strings"
import om "../onimite"

// Why a line could not be had: a code and its operands. Text is made at the
// edge (`error_message`) from ERROR_TEXT, where `{path}`, `{detail}` (ottis's
// own reason) and `{os}` stand for the `Failure` fields and `{voices}` for
// the voices there are.
Error :: enum u8 {
	None,
	// ottis's files could not be found or fetched (`path` the folder).
	No_Data_Dir,
	Fetch,
	// ONNX Runtime or the models did not load.
	Engine,
	// `path` names the voice.
	Unknown_Voice,
	Voice_Fetch,
	Voice_Load,
	Synthesize,
	// The store: no user data folder, or `path` could not be written.
	No_Store_Dir,
	Store_Create,
	Store_Write,
	Store_Rename,
}

Failure :: struct {
	code:   Error,
	path:   string,
	detail: string,
	os:     os.Error,
}

@(rodata)
ERROR_TEXT := [Error]string {
	.None          = "",
	.No_Data_Dir   = "no folder for ottis's files: {detail}",
	.Fetch         = "fetching ottis's files into {path}: {detail}",
	.Engine        = "loading ONNX Runtime and the models: {detail}",
	.Unknown_Voice = "unknown voice {q:path} (voices: {voices})",
	.Voice_Fetch   = "fetching voice {path}: {detail}",
	.Voice_Load    = "loading voice {path}: {detail}",
	.Synthesize    = "{detail}",
	.No_Store_Dir  = "no user data directory",
	.Store_Create  = "creating {path}: {os}",
	.Store_Write   = "writing {path}: {os}",
	.Store_Rename  = "renaming {path}: {os}",
}

// The failure's text.
error_message :: proc(f: Failure, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	f := f
	om.template_write(&b, ERROR_TEXT[f.code], &f, proc(b: ^strings.Builder, field, mode: string, data: rawptr) -> bool {
		f := (^Failure)(data)
		switch field {
		case "path":
			om.template_string(b, f.path, mode)
		case "detail":
			strings.write_string(b, f.detail)
		case "os":
			fmt.sbprintf(b, "%v", f.os)
		case "voices":
			strings.write_string(b, voice_names())
		case:
			return false
		}
		return true
	})
	return strings.to_string(b)
}

failure_clone :: proc(f: Failure, allocator := context.allocator) -> Failure {
	out := f
	out.path = strings.clone(f.path, allocator)
	out.detail = strings.clone(f.detail, allocator)
	return out
}

failure_destroy :: proc(f: ^Failure, allocator := context.allocator) {
	delete(f.path, allocator)
	delete(f.detail, allocator)
	f^ = {}
}
