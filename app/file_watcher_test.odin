package onimite_app

import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

@(test)
test_file_watcher :: proc(t: ^testing.T) {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	dir := join({tmp if tmp != "" else "/tmp", "onimite_watch_test"})
	_ = os.remove_all(dir)
	media := join({dir, "media"})
	scenes := join({dir, "scenes"})
	testing.expect(t, os.make_directory_all(media) == nil)
	testing.expect(t, os.make_directory_all(scenes) == nil)
	defer os.remove_all(dir)
	script := join({dir, "video.lua"})
	module := join({scenes, "title.lua"})
	image := join({media, "logo.svg"})
	_ = os.write_entire_file(script, transmute([]u8)string("return 1"))
	_ = os.write_entire_file(module, transmute([]u8)string("return 1"))
	_ = os.write_entire_file(image, transmute([]u8)string("<svg/>"))

	w: File_Watcher
	file_watcher_start(&w, script, media)
	defer file_watcher_stop(&w)
	settle := 3 * WATCH_INTERVAL

	time.sleep(settle)
	testing.expect_value(t, file_watcher_take(&w), File_Changes{})

	// A required module (not the script itself) changed.
	_ = os.write_entire_file(module, transmute([]u8)string("return 22"))
	time.sleep(settle)
	testing.expect_value(t, file_watcher_take(&w), File_Changes{.Script})

	// A media file edited in place: only media.
	_ = os.write_entire_file(image, transmute([]u8)string("<svg width='2'/>"))
	time.sleep(settle)
	testing.expect_value(t, file_watcher_take(&w), File_Changes{.Media})
}

// A script named without a folder (`preview video.lua` from its folder)
// watches the working directory, not nothing.
@(test)
test_file_watcher_bare_script :: proc(t: ^testing.T) {
	cwd, _ := os.get_working_directory(context.temp_allocator)
	want, _ := os.stat(cwd, context.temp_allocator)
	got := watch_dir("video.lua")
	defer delete(got)
	testing.expect_value(t, got, want.fullpath)
}

@(private = "file")
join :: proc(parts: []string) -> string {
	p, _ := filepath.join(parts, context.temp_allocator)
	return p
}
