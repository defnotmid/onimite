package onimite_speech

import "core:fmt"
import "core:os"
import "core:strings"

// Why a line could not be had: a code and its operands. Text is made at the
// edge (`error_message`); `detail` is ottis's own reason.
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

// The failure's text (temp memory).
error_message :: proc(f: Failure) -> string {
	switch f.code {
	case .None:
		return ""
	case .No_Data_Dir:
		return fmt.tprintf("no folder for ottis's files: %s", f.detail)
	case .Fetch:
		return fmt.tprintf("fetching ottis's files into %s: %s", f.path, f.detail)
	case .Engine:
		return fmt.tprintf("loading ONNX Runtime and the models: %s", f.detail)
	case .Unknown_Voice:
		return fmt.tprintf("unknown voice %q (voices: %s)", f.path, voice_names())
	case .Voice_Fetch:
		return fmt.tprintf("fetching voice %s: %s", f.path, f.detail)
	case .Voice_Load:
		return fmt.tprintf("loading voice %s: %s", f.path, f.detail)
	case .Synthesize:
		return f.detail
	case .No_Store_Dir:
		return "no user data directory"
	case .Store_Create:
		return fmt.tprintf("creating %s: %v", f.path, f.os)
	case .Store_Write:
		return fmt.tprintf("writing %s: %v", f.path, f.os)
	case .Store_Rename:
		return fmt.tprintf("renaming %s: %v", f.path, f.os)
	}
	return ""
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
