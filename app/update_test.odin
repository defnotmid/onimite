package onimite_app

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_update_versions :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	v, ok := update_version("v0.12.3")
	testing.expect(t, ok && v == {0, 12, 3})
	v, ok = update_version("v1.0.0-rc1")
	testing.expect(t, ok && v == {1, 0, 0})
	for tag in ([]string{"dev", "1.2.3", "v1.2", "v1.2.x", "v1.-2.3"}) {
		_, ok = update_version(tag)
		testing.expectf(t, !ok, "%q read as a release", tag)
	}
	testing.expect(t, update_newer("v0.0.10", "v0.0.9"))
	testing.expect(t, update_newer("v1.0.0", "v0.9.9"))
	testing.expect(t, !update_newer("v0.0.5", "v0.0.5"))
	testing.expect(t, !update_newer("v0.0.4", "v0.0.5"))
	testing.expect(t, !update_newer("v9.9.9", "dev"))
}

// SHA256SUMS of a release: this platform's archive among the others.
@(test)
test_update_sums :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	when UPDATE_PLATFORM != "" {
		archive := "onimite-v0.0.6-" + UPDATE_PLATFORM + UPDATE_ARCHIVE
		sums := strings.concatenate({"0aa  onimite-v0.0.6-other-arch.tar.gz\n", "1BB  onimite-video-skill-v0.0.6.tar.gz\n", "2cc  onimite-v0.0.6-" + UPDATE_PLATFORM + ".mcpb\n", "3DD *", archive, "\n"}, context.temp_allocator)
		r, ok := update_sums_find(sums)
		testing.expect(t, ok)
		testing.expect_value(t, r.tag, "v0.0.6")
		testing.expect_value(t, r.archive, archive)
		testing.expect_value(t, r.sha256, "3dd")
	}
	_, found := update_sums_find("0aa  onimite-video-skill-v0.0.6.tar.gz\n")
	testing.expect(t, !found)
}

// The archives a release ships, unpacked without their top directory: tar
// with GNU and pax long names (and the executable bit), zip stored and
// deflated; an entry that would land outside is refused.
@(test)
test_update_unpack :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	long := strings.concatenate({"LICENSES/", strings.repeat("a", 120, context.temp_allocator), ".txt"}, context.temp_allocator)
	Case :: struct {
		name:  string,
		data:  []u8,
		files: []string,
		texts: []string,
	}
	cases := []Case {
		{"release_gnu.tar.gz", #load("../testdata/update/release_gnu.tar.gz"), {"onimite", long}, {"#!binary\n", "long\n"}},
		{"release_pax.tar.gz", #load("../testdata/update/release_pax.tar.gz"), {"onimite", long}, {"#!binary\n", "long\n"}},
		{"release.zip", #load("../testdata/update/release.zip"), {"onimite.exe", "LICENSES/a.txt"}, {"stored binary\n", strings.repeat("deflated ", 50, context.temp_allocator)}},
	}
	for c in cases {
		dir, err := os.make_directory_temp("", "onimite-unpack-*", context.temp_allocator)
		testing.expect(t, err == nil)
		defer os.remove_all(dir)
		problem := update_unpack(c.name, c.data, dir)
		testing.expectf(t, problem == "", "%s: %s", c.name, problem)
		for rel, i in c.files {
			path := filepath.join({dir, rel}, context.temp_allocator) or_else ""
			data, rerr := os.read_entire_file(path, context.temp_allocator)
			testing.expectf(t, rerr == nil && string(data) == c.texts[i], "%s: %s", c.name, rel)
			when ODIN_OS != .Windows {
				if rel == "onimite" {
					info, _ := os.stat(path, context.temp_allocator)
					testing.expectf(t, .Execute_User in info.mode, "%s: onimite is not executable", c.name)
				}
			}
		}
	}
	dir, _ := os.make_directory_temp("", "onimite-unpack-*", context.temp_allocator)
	defer os.remove_all(dir)
	testing.expect(t, update_unpack("outside.tar.gz", #load("../testdata/update/outside.tar.gz"), dir) != "")
	testing.expect(t, !os.exists(filepath.join({filepath.dir(dir), "escaped"}, context.temp_allocator) or_else ""))
}
