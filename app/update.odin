package onimite_app

import "core:bytes"
import "core:compress/gzip"
import "core:compress/zlib"
import "core:crypto/sha2"
import "core:encoding/endian"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "deps:ottis/assets"

// `onimite update`: replaces this onimite with the latest release. The
// latest release's SHA256SUMS names this platform's archive (the version is
// in its name) and its hash; the archive is downloaded, checked, unpacked
// beside this onimite, its binary run once, and then swapped in. A release
// the installers put in <root>/vX.Y.Z behind a <root>/current link gets a
// directory of its own and the link moves; anywhere else (a Claude Desktop
// bundle, an unpacked archive) the files are replaced where they are, the
// old ones moved aside first (Windows can't overwrite a running program)
// and removed after, or at the next update when they are still in use.

UPDATE_RELEASES :: "https://github.com/defnotmid/onimite/releases"

// This platform's name in the release archives ("": no release is built).
UPDATE_PLATFORM :: "linux-x86_64" when ODIN_OS == .Linux && ODIN_ARCH == .amd64 else "macos-arm64" when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 else "windows-x86_64" when ODIN_OS == .Windows && ODIN_ARCH == .amd64 else ""
UPDATE_ARCHIVE :: ".zip" when ODIN_OS == .Windows else ".tar.gz"
UPDATE_EXE :: "onimite.exe" when ODIN_OS == .Windows else "onimite"

// A release of this platform: its tag, archive and the archive's SHA-256.
Update_Release :: struct {
	tag, archive, sha256: string,
}

// What `update` found and did (its --json document).
Update_Report :: struct {
	version: string, // this onimite
	latest:  string, // the latest release
	newer:   bool, // the latest is newer than this onimite
	updated: bool,
	path:    string, // the directory the release went into ("" when none did)
}

update_run :: proc(app: ^App_State, regs: Command_Regs) -> Error {
	check := regs.flag
	if UPDATE_PLATFORM == "" {
		return fail(app, {code = .Update_Platform, name = fmt.tprintf("%v %v", ODIN_OS, ODIN_ARCH)})
	}
	_, released := update_version(ONIMITE_VERSION)
	if !released && !check {
		return fail(app, {code = .Update_Dev, name = ONIMITE_VERSION})
	}
	exe, eerr := os.get_executable_path(context.temp_allocator)
	if eerr != nil {
		return fail(app, {code = .Update_Install, path = "this onimite", os = eerr})
	}
	dir, root := update_layout(exe)
	if root == "" {
		update_leftovers_remove(dir)
	}

	latest, problem := update_latest()
	if problem != "" {
		return fail(app, {code = .Update_Fetch, name = "SHA256SUMS", spec = problem})
	}
	report := Update_Report{version = ONIMITE_VERSION, latest = latest.tag, newer = update_newer(latest.tag, ONIMITE_VERSION)}
	if check || !report.newer {
		text: string
		switch {
		case !released:
			text = fmt.tprintf("this is a development build (%s); the latest release is %s", ONIMITE_VERSION, latest.tag)
		case report.newer:
			text = fmt.tprintf("onimite %s is out (this is %s): `onimite update` installs it", latest.tag, ONIMITE_VERSION)
		case:
			text = fmt.tprintf("onimite %s is the latest release", ONIMITE_VERSION)
		}
		emit(app, report, text)
		return nil
	}

	// Staged beside where it goes, so moving it in is a rename.
	stage := filepath.join({root, fmt.tprintf(".%s.partial", latest.tag)} if root != "" else {dir, ".update"}, context.temp_allocator) or_else ""
	archive := strings.concatenate({stage, UPDATE_ARCHIVE}, context.temp_allocator)
	os.remove_all(stage)
	defer os.remove_all(stage)
	defer os.remove(archive)
	if err := os.make_directory_all(stage); err != nil {
		return fail(app, {code = .Update_Install, path = stage, os = err})
	}
	sha, ferr := update_fetch(latest.archive, latest.tag, archive)
	if ferr != "" {
		return fail(app, {code = .Update_Fetch, name = latest.archive, spec = ferr})
	}
	if sha != latest.sha256 {
		return fail(app, {code = .Update_Checksum, name = latest.archive})
	}
	data, rerr := os.read_entire_file(archive, context.temp_allocator)
	if rerr != nil {
		return fail(app, {code = .Update_Unpack, name = latest.archive, spec = fmt.tprint(rerr)})
	}
	if problem := update_unpack(latest.archive, data, stage); problem != "" {
		return fail(app, {code = .Update_Unpack, name = latest.archive, spec = problem})
	}
	// The new onimite must run here before it replaces this one.
	staged_exe := filepath.join({stage, UPDATE_EXE}, context.temp_allocator) or_else ""
	state, out, _, xerr := os.process_exec({command = {staged_exe, "--version"}}, context.temp_allocator)
	if xerr != nil || !state.exited || state.exit_code != 0 || !strings.has_prefix(string(out), "onimite ") {
		return fail(app, {code = .Update_Broken, path = staged_exe})
	}

	if root != "" {
		report.path = filepath.join({root, latest.tag}, context.temp_allocator) or_else ""
		if f := update_link(root, stage, latest.tag); f.code != .None {
			return fail(app, f)
		}
	} else {
		report.path = dir
		if f := update_replace(dir, stage); f.code != .None {
			return fail(app, f)
		}
	}
	report.updated = true
	emit(app, report, fmt.tprintf("onimite %s → %s, in %s", ONIMITE_VERSION, latest.tag, report.path))
	return nil
}

// Where this onimite is: its directory, and `root` when the installers put
// it there (<root>/vX.Y.Z with <root>/current linking to it; on Windows
// `current` is a junction the files are replaced through).
update_layout :: proc(exe: string) -> (dir, root: string) {
	dir = filepath.dir(exe)
	when ODIN_OS != .Windows {
		parent := filepath.dir(dir)
		current := filepath.join({parent, "current"}, context.temp_allocator) or_else ""
		if target, err := os.read_link(current, context.temp_allocator); err == nil && (target == filepath.base(dir) || target == dir) {
			root = parent
		}
	}
	return
}

// The latest release of this platform, from its SHA256SUMS; what went
// wrong otherwise.
update_latest :: proc() -> (r: Update_Release, problem: string) {
	dir, derr := os.make_directory_temp("", "onimite-update-*", context.temp_allocator)
	if derr != nil {
		return {}, fmt.tprintf("can not make a temporary directory (%v)", derr)
	}
	defer os.remove_all(dir)
	path := filepath.join({dir, "SHA256SUMS"}, context.temp_allocator) or_else ""
	if _, problem = update_fetch("SHA256SUMS", "", path); problem != "" {
		return
	}
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return {}, fmt.tprintf("can not read %s (%v)", path, rerr)
	}
	ok: bool
	if r, ok = update_sums_find(string(data)); !ok {
		return {}, "the latest release lists no onimite-vX.Y.Z-" + UPDATE_PLATFORM + UPDATE_ARCHIVE
	}
	return
}

// This platform's archive in a SHA256SUMS (`<sha256>  <file>` lines).
update_sums_find :: proc(sums: string) -> (r: Update_Release, ok: bool) {
	suffix :: "-" + UPDATE_PLATFORM + UPDATE_ARCHIVE
	for line in strings.split_lines(sums, context.temp_allocator) {
		sha, _, name := strings.partition(strings.trim_space(line), " ")
		name = strings.trim_left(strings.trim_space(name), "*")
		if strings.has_prefix(name, "onimite-v") && strings.has_suffix(name, suffix) {
			return {tag = name[len("onimite-"):len(name) - len(suffix)], archive = name, sha256 = strings.to_lower(sha, context.temp_allocator)}, true
		}
	}
	return {}, false
}

// Writes release file `name` (of release `tag`, "": the latest) to `path`
// and returns its SHA-256. The releases are GitHub's, or the files in the
// directory ONIMITE_UPDATE_FROM names (tests).
update_fetch :: proc(name, tag, path: string) -> (sha256: string, problem: string) {
	f, err := os.create(path)
	if err != nil {
		return "", fmt.tprintf("can not write %s (%v)", path, err)
	}
	defer os.close(f)
	sink := assets.Sink{file = f}
	sha2.init_256(&sink.hash)
	if from := os.get_env("ONIMITE_UPDATE_FROM", context.temp_allocator); from != "" {
		src := filepath.join({from, name}, context.temp_allocator) or_else ""
		data, rerr := os.read_entire_file(src, context.temp_allocator)
		if rerr != nil {
			return "", fmt.tprintf("can not read %s (%v)", src, rerr)
		}
		if werr := assets.sink_write(&sink, data); werr != nil {
			return "", fmt.tprintf("can not write %s (%v)", path, werr)
		}
	} else {
		url := fmt.tprintf("%s/latest/download/%s", UPDATE_RELEASES, name) if tag == "" else fmt.tprintf("%s/download/%s/%s", UPDATE_RELEASES, tag, name)
		if e, failed := assets.http_get(url, &sink, fmt.tprintf("onimite/%s", ONIMITE_VERSION)).?; failed {
			return "", e
		}
	}
	digest: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&sink.hash, digest[:])
	return string(hex.encode(digest[:], context.temp_allocator)), ""
}

// A release tag `vX.Y.Z` (a `-suffix` ignored) as numbers; false for
// anything else, like "dev".
update_version :: proc(tag: string) -> (v: [3]int, ok: bool) {
	s, _, _ := strings.partition(tag, "-")
	if !strings.has_prefix(s, "v") {
		return
	}
	parts := strings.split(s[1:], ".", context.temp_allocator)
	if len(parts) != 3 {
		return
	}
	for p, i in parts {
		n, nok := strconv.parse_int(p, 10)
		if !nok || n < 0 {
			return {}, false
		}
		v[i] = n
	}
	return v, true
}

// Whether release `latest` is newer than `current` (false when either is
// not a release).
update_newer :: proc(latest, current: string) -> bool {
	l, lok := update_version(latest)
	c, cok := update_version(current)
	if !lok || !cok {
		return false
	}
	for i in 0 ..< 3 {
		if l[i] != c[i] {
			return l[i] > c[i]
		}
	}
	return false
}

// Moves the installers' `current` link to the release unpacked in `stage`,
// which becomes <root>/<tag>.
@(private = "file")
update_link :: proc(root, stage, tag: string) -> Failure {
	dest := filepath.join({root, tag}, context.temp_allocator) or_else ""
	os.remove_all(dest) // an earlier, unfinished install of this release
	if err := os.rename(stage, dest); err != nil {
		return {code = .Update_Install, path = dest, os = err}
	}
	link := filepath.join({root, ".current-new"}, context.temp_allocator) or_else ""
	current := filepath.join({root, "current"}, context.temp_allocator) or_else ""
	os.remove(link)
	if err := os.symlink(tag, link); err != nil {
		return {code = .Update_Install, path = link, os = err}
	}
	if err := os.rename(link, current); err != nil {
		return {code = .Update_Install, path = current, os = err}
	}
	return {}
}

// Replaces the files in `dir` with those in `stage`: each old one moved
// aside (name.old), the new one moved in, the old ones removed; on a
// failure the old ones go back.
@(private = "file")
update_replace :: proc(dir, stage: string) -> Failure {
	entries, err := os.read_all_directory_by_path(stage, context.temp_allocator)
	if err != nil {
		return {code = .Update_Install, path = stage, os = err}
	}
	aside := make([dynamic]string, context.temp_allocator)
	failure: Failure
	for e in entries {
		target := filepath.join({dir, e.name}, context.temp_allocator) or_else ""
		old := strings.concatenate({target, ".old"}, context.temp_allocator)
		remove_path(old)
		if os.exists(target) {
			if err := os.rename(target, old); err != nil {
				failure = {code = .Update_Install, path = target, os = err}
				break
			}
			append(&aside, target)
		}
		if err := os.rename(e.fullpath, target); err != nil {
			failure = {code = .Update_Install, path = target, os = err}
			break
		}
	}
	for target in aside {
		old := strings.concatenate({target, ".old"}, context.temp_allocator)
		if failure.code != .None {
			remove_path(target)
			os.rename(old, target)
		} else {
			remove_path(old) // Windows: the running onimite stays until the next update
		}
	}
	return failure
}

// Removes what an earlier update left in `dir`: its stage, and the files
// it moved aside that were still in use then.
update_leftovers_remove :: proc(dir: string) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return
	}
	for e in entries {
		if e.name == ".update" || e.name == ".update" + UPDATE_ARCHIVE {
			remove_path(e.fullpath)
		} else if strings.has_suffix(e.name, ".old") {
			if os.exists(filepath.join({dir, e.name[:len(e.name) - len(".old")]}, context.temp_allocator) or_else "") {
				remove_path(e.fullpath)
			}
		}
	}
}

// Removes a file, or a directory and everything in it (os.remove_all
// leaves a plain file on macOS).
@(private = "file")
remove_path :: proc(path: string) {
	if os.is_dir(path) {
		os.remove_all(path)
	} else {
		os.remove(path)
	}
}

// ---- release archives -------------------------------------------------------------

// Unpacks release archive `name` (a .tar.gz or a .zip) from `data` into
// `dir`, without its top directory (onimite-vX.Y.Z-<platform>/); "" or
// what went wrong.
update_unpack :: proc(name: string, data: []u8, dir: string) -> string {
	if strings.has_suffix(name, ".zip") {
		return zip_unpack(data, dir)
	}
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	if err := gzip.load_from_bytes(data, &buf); err != nil {
		return fmt.tprintf("not a gzip file (%v)", err)
	}
	return tar_unpack(bytes.buffer_to_bytes(&buf), dir)
}

// The path inside the release of archive entry `name`: without the top
// directory ("" for the top directory itself); false for one that would
// land outside it.
@(private = "file")
archive_entry :: proc(name: string) -> (rel: string, ok: bool) {
	name := strings.trim_prefix(name, "./")
	if strings.has_prefix(name, "/") || strings.contains_rune(name, '\\') || strings.contains_rune(name, ':') {
		return "", false
	}
	_, _, rel = strings.partition(name, "/")
	rel = strings.trim_suffix(rel, "/")
	for part in strings.split(rel, "/", context.temp_allocator) {
		if part == ".." {
			return "", false
		}
	}
	return rel, true
}

@(private = "file")
archive_write :: proc(dir, rel: string, data: []u8, perm: os.Permissions) -> string {
	path := filepath.join({dir, rel}, context.temp_allocator) or_else ""
	if err := os.make_directory_all(filepath.dir(path)); err != nil && err != .Exist {
		return fmt.tprintf("can not create %s (%v)", filepath.dir(path), err)
	}
	if err := os.write_entire_file(path, data, perm); err != nil {
		return fmt.tprintf("can not write %s (%v)", path, err)
	}
	return ""
}

// A ustar / GNU / pax tar: files and directories (a release has nothing
// else); a GNU long name or a pax `path` names the entry after it.
@(private = "file")
tar_unpack :: proc(data: []u8, dir: string) -> string {
	next_name := ""
	for off := 0; off + 512 <= len(data); {
		h := data[off:off + 512]
		if h[0] == 0 {
			break // the zero blocks at the end
		}
		name := tar_string(h[0:100])
		if prefix := tar_string(h[345:500]); prefix != "" {
			name = fmt.tprintf("%s/%s", prefix, name)
		}
		if next_name != "" {
			name, next_name = next_name, ""
		}
		mode, mode_ok := tar_octal(h[100:108])
		size, size_ok := tar_octal(h[124:136])
		if !mode_ok || !size_ok || off + 512 + size > len(data) {
			return fmt.tprintf("a damaged entry at byte %d", off)
		}
		body := data[off + 512:][:size]
		off += 512 + (size + 511) / 512 * 512
		type := h[156]
		switch type {
		case 'L':
			next_name = tar_string(body)
			continue
		case 'x':
			next_name = pax_path(body)
			continue
		case 'g':
			continue
		}
		rel, ok := archive_entry(name)
		if !ok {
			return fmt.tprintf("%q is outside the release", name)
		}
		switch type {
		case '5':
			if rel != "" {
				path := filepath.join({dir, rel}, context.temp_allocator) or_else ""
				if err := os.make_directory_all(path); err != nil && err != .Exist {
					return fmt.tprintf("can not create %s (%v)", path, err)
				}
			}
		case '0', 0:
			if problem := archive_write(dir, rel, body, transmute(os.Permissions)u32(mode & 0o777)); problem != "" {
				return problem
			}
		case:
			return fmt.tprintf("%s is not a file or a directory", name)
		}
	}
	return ""
}

@(private = "file")
tar_string :: proc(field: []u8) -> string {
	n := bytes.index_byte(field, 0)
	return string(field[:n if n >= 0 else len(field)])
}

@(private = "file")
tar_octal :: proc(field: []u8) -> (int, bool) {
	n, ok := strconv.parse_int(strings.trim(tar_string(field), " "), 8)
	return n, ok && n >= 0
}

// The `path` record of a pax header ("" when it has none): records are
// `<length> <key>=<value>\n`.
@(private = "file")
pax_path :: proc(body: []u8) -> string {
	rest := string(body)
	for len(rest) > 0 {
		length_text, _, _ := strings.partition(rest, " ")
		length, ok := strconv.parse_int(length_text, 10)
		if !ok || length <= len(length_text) + 1 || length > len(rest) {
			return ""
		}
		record := rest[len(length_text) + 1:length]
		rest = rest[length:]
		if key, _, value := strings.partition(strings.trim_suffix(record, "\n"), "="); key == "path" {
			return value
		}
	}
	return ""
}

// A zip of stored and deflated entries, read through its central directory.
@(private = "file")
zip_unpack :: proc(data: []u8, dir: string) -> string {
	le16 :: proc(data: []u8, at: int) -> int {
		v, _ := endian.get_u16(data[at:], .Little)
		return int(v)
	}
	le32 :: proc(data: []u8, at: int) -> int {
		v, _ := endian.get_u32(data[at:], .Little)
		return int(v)
	}
	// The end record: the last 22 bytes, before a comment of up to 64 KiB.
	end := -1
	for i := len(data) - 22; i >= max(0, len(data) - 22 - 0xffff); i -= 1 {
		if le32(data, i) == 0x06054b50 {
			end = i
			break
		}
	}
	if end < 0 {
		return "not a zip file"
	}
	count, off := le16(data, end + 10), le32(data, end + 16)
	for _ in 0 ..< count {
		if off + 46 > len(data) || le32(data, off) != 0x02014b50 {
			return "a damaged zip directory"
		}
		method, packed, size := le16(data, off + 10), le32(data, off + 20), le32(data, off + 24)
		name_len := le16(data, off + 28)
		local := le32(data, off + 42)
		next := off + 46 + name_len + le16(data, off + 30) + le16(data, off + 32)
		if next > len(data) || local + 30 > len(data) || le32(data, local) != 0x04034b50 {
			return "a damaged zip directory"
		}
		name := string(data[off + 46:][:name_len])
		off = next
		start := local + 30 + le16(data, local + 26) + le16(data, local + 28)
		if start + packed > len(data) {
			return fmt.tprintf("%s ends early", name)
		}
		rel, ok := archive_entry(name)
		if !ok {
			return fmt.tprintf("%q is outside the release", name)
		}
		if rel == "" || strings.has_suffix(name, "/") {
			continue // directories come with their files
		}
		body := data[start:][:packed]
		switch method {
		case 0:
			if problem := archive_write(dir, rel, body, os.Permissions_Read_All + {.Write_User}); problem != "" {
				return problem
			}
		case 8:
			buf: bytes.Buffer
			defer bytes.buffer_destroy(&buf)
			if err := zlib.inflate_from_byte_array_raw(body, &buf, expected_output_size = size); err != nil {
				return fmt.tprintf("can not inflate %s (%v)", name, err)
			}
			if problem := archive_write(dir, rel, bytes.buffer_to_bytes(&buf), os.Permissions_Read_All + {.Write_User}); problem != "" {
				return problem
			}
		case:
			return fmt.tprintf("%s is packed with method %d (only stored and deflated are read)", name, method)
		}
	}
	return ""
}
