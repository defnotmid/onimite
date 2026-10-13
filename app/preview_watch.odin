package onimite_app

import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// Watches the script's folder (every file, recursively: required modules,
// shaders read through SCRIPT_DIR, data files) and the media folder on a
// dedicated thread, so the UI never stats files. The UI takes the changes
// with `file_watcher_take` and pushes a reload.

WATCH_INTERVAL :: 250 * time.Millisecond
// Bounds a walk of a huge folder (the script is in the wrong place).
WATCH_MAX_FILES :: 4096
WATCH_MAX_DEPTH :: 8

Watch_Change :: enum u32 {
	Script,
	Media,
}
Watch_Changes :: bit_set[Watch_Change;u32]

File_Watcher :: struct {
	script_dir: string,
	media_dir:  string,
	thread:     ^thread.Thread,
	quit:       bool,
	// Watch_Changes bits seen since the last take (atomic).
	changes:    u32,
}

file_watcher_start :: proc(w: ^File_Watcher, script_path, media_dir: string) {
	w^ = {}
	w.script_dir = os_path(filepath.dir(script_path))
	w.media_dir = os_path(media_dir)
	w.thread = thread.create_and_start_with_poly_data(w, watch_loop)
}

// `path` as directory listings spell it (macOS lists /var as
// /private/var): the media folder is skipped by comparing those spellings.
@(private = "file")
os_path :: proc(path: string) -> string {
	if fi, err := os.stat(path, context.temp_allocator); err == nil {
		return strings.clone(fi.fullpath)
	}
	return strings.clone(path)
}

file_watcher_stop :: proc(w: ^File_Watcher) {
	if w.thread == nil {
		return
	}
	sync.atomic_store(&w.quit, true)
	thread.join(w.thread)
	thread.destroy(w.thread)
	delete(w.script_dir)
	delete(w.media_dir)
	w^ = {}
}

// The changes since the last call, cleared.
file_watcher_take :: proc(w: ^File_Watcher) -> Watch_Changes {
	return transmute(Watch_Changes)sync.atomic_exchange(&w.changes, 0)
}

@(private = "file")
watch_loop :: proc(w: ^File_Watcher) {
	script := watch_stamp(w.script_dir, w.media_dir)
	media := watch_stamp(w.media_dir, "")
	for !sync.atomic_load(&w.quit) {
		time.sleep(WATCH_INTERVAL)
		s := watch_stamp(w.script_dir, w.media_dir)
		m := watch_stamp(w.media_dir, "")
		changed: Watch_Changes
		if s != script {
			changed += {.Script}
		}
		if m != media {
			changed += {.Media}
		}
		script, media = s, m
		if changed != {} {
			sync.atomic_or(&w.changes, transmute(u32)changed)
		}
		free_all(context.temp_allocator)
	}
}

// A fingerprint of every file under `dir` (names, sizes and modification
// times), skipping `skip` and hidden entries. Any edit, add, remove or
// rename changes it.
@(private = "file")
watch_stamp :: proc(dir, skip: string) -> u64 {
	h := u64(14695981039346656037)
	files := 0
	walk :: proc(dir, skip: string, depth: int, h: ^u64, files: ^int) {
		if depth > WATCH_MAX_DEPTH || files^ >= WATCH_MAX_FILES {
			return
		}
		infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil {
			return
		}
		for fi in infos {
			if strings.has_prefix(fi.name, ".") || fi.fullpath == skip {
				continue
			}
			if fi.type == .Directory {
				walk(fi.fullpath, skip, depth + 1, h, files)
				continue
			}
			files^ += 1
			h^ = hash.fnv64a(transmute([]u8)fi.fullpath, h^)
			stamp := [2]i64{fi.size, time.to_unix_nanoseconds(fi.modification_time)}
			h^ = hash.fnv64a(([^]u8)(&stamp)[:size_of(stamp)], h^)
		}
	}
	walk(dir, skip, 0, &h, &files)
	return h
}
