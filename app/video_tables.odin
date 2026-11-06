package onimite_app

import "core:hash"
import "core:slice"
import "core:strings"
import om "../onimite"
import script "../script"

// The video's tables, one per kind of row the evaluator reads (eval_*.odin):
// its scenes, cues, problems, media files and marks, as flat rows of typed
// fields (a name a Text_Span into the tables' text, a reference an index),
// with what is derived from them made here once, never per frame where they
// are read: each scene's problems and each problem's scenes (spans into
// `scene_problems` and `problem_scenes`), the names in order for lookups by
// name (`*_names`), the worst status of each table and the problems'
// counts. The preview's worker fills them when what they come from changes
// (a load, the findings of the frames shown, the marks, the sounds landing)
// and publishes them through the mailbox; `onimite show` can fill them with
// the same producers in its own process. The tracks, as the timeline shows
// them (groups, tracks and parts), are the timeline's table's (Wave_Table).

// A row's status, as the Watch shows it in colour.
Status :: enum u8 {
	Ok,
	Info,
	Warning,
	Error,
}

// A name that names a row of another kind: what a field so typed may hold
// is that kind's collection (Value.domain). A scene's cue, a cue's sound.
Cue_Name :: distinct Text_Span
Track_Name :: distinct Text_Span

Scene_Row :: struct {
	name:     Text_Span,
	// its frames, [start, end)
	start:    int,
	end:      int,
	cue:      Cue_Name,
	// the script line that adds it
	source:   Text_Span,
	hold:     om.Hold,
	// the worst of the problems seen in it
	status:   Status,
	id:       u64 `m:"-"`, // its name and how many before it share it
	problems: [2]i32 `m:"-"`, // first, count into scene_problems
}

Cue_Row :: struct {
	name:    Text_Span,
	seconds: f64,
	frame:   int,
	hit:     Track_Name,
	source:  Text_Span,
	// its sync finding's message ("" none)
	sync:    Text_Span,
	status:  Status,
	id:      u64 `m:"-"`,
}

// A finding of the frames shown since the load (grouped as `inspect`
// groups them), or a line of a failed reload's error.
Problem_Row :: struct {
	severity: om.Severity,
	code:     om.Diagnostic_Code,
	message:  Text_Span,
	source:   Text_Span,
	// the first and last frames it was seen in (-1: at load), and in how many
	first:    int,
	last:     int,
	frames:   int,
	// a line of the failed reload's error (the last good version plays)
	reload:   bool,
	status:   Status,
	id:       u64 `m:"-"`, // the finding's key
	scenes:   [2]i32 `m:"-"`, // first, count into problem_scenes
}

Media_File_Row :: struct {
	kind:   om.Media_Kind,
	name:   Text_Span,
	// what it is after its kind ("128x64", "unreadable")
	detail: Text_Span,
	failed: bool,
	// the first frame a track plays it at (-1: none)
	first:  int,
	status: Status,
	thumb:  i32 `m:"-"`, // its row of the media table (thumbnails), -1 none
	id:     u64 `m:"-"`, // its kind and name
}

Video_Tables :: struct {
	scenes:         [dynamic]Scene_Row,
	cues:           [dynamic]Cue_Row,
	problems:       [dynamic]Problem_Row,
	media:          [dynamic]Media_File_Row,
	marks:          [dynamic]Mark,
	scene_problems: [dynamic]i32,
	problem_scenes: [dynamic]i32,
	// rows by name (then place), for `scenes.Race` and `media["logo.png"]`
	scene_names:    [dynamic]i32,
	cue_names:      [dynamic]i32,
	media_names:    [dynamic]i32,
	// each collection's worst status, and the problems' errors and warnings
	worst:          [Kind]Status,
	errors:         int,
	warnings:       int,
	fps:            int,
	text:           [dynamic]u8,
}

video_tables_destroy :: proc(t: ^Video_Tables) {
	delete(t.scenes)
	delete(t.cues)
	delete(t.problems)
	delete(t.media)
	delete(t.marks)
	delete(t.scene_problems)
	delete(t.problem_scenes)
	delete(t.scene_names)
	delete(t.cue_names)
	delete(t.media_names)
	delete(t.text)
	t^ = {}
}

video_tables_copy :: proc(dst, src: ^Video_Tables) {
	table_copy(&dst.scenes, src.scenes[:])
	table_copy(&dst.cues, src.cues[:])
	table_copy(&dst.problems, src.problems[:])
	table_copy(&dst.media, src.media[:])
	table_copy(&dst.marks, src.marks[:])
	table_copy(&dst.scene_problems, src.scene_problems[:])
	table_copy(&dst.problem_scenes, src.problem_scenes[:])
	table_copy(&dst.scene_names, src.scene_names[:])
	table_copy(&dst.cue_names, src.cue_names[:])
	table_copy(&dst.media_names, src.media_names[:])
	table_copy(&dst.text, src.text[:])
	dst.worst, dst.errors, dst.warnings, dst.fps = src.worst, src.errors, src.warnings, src.fps
}

// What the tables are made from: a load and what the frames shown found.
Table_Sources :: struct {
	// The scenes (nil when the timeline does not resolve).
	timeline:   ^om.Timeline,
	fps:        int,
	findings:   ^Finding_Table,
	cues:       []script.Cue,
	// The sync findings (`sync_check`); nil while sounds are being built.
	sync:       []om.Diagnostic,
	media:      ^om.Media,
	placed:     []om.Placed_Track,
	// Why the last load failed ("" after a good one).
	load_error: string,
	// The marks a person made in the window, in time order.
	marks:      []Mark,
}

// Fills `t`, each table by its producer: the problems first (the scenes
// read theirs), then the scenes, the cues, the media and the marks, then
// the names in order.
video_tables_build :: proc(t: ^Video_Tables, src: Table_Sources) {
	clear(&t.text)
	t.fps = max(src.fps, 1)
	t.worst = {}
	empty: om.Timeline
	tl := src.timeline if src.timeline != nil else &empty
	problem_rows_build(t, src, tl)
	scene_rows_build(t, tl)
	cue_rows_build(t, src)
	media_rows_build(t, src)
	table_copy(&t.marks, src.marks)
	if len(t.marks) > 0 do t.worst[.Marks] = .Info
	names_build(&t.scene_names, t.text[:], t.scenes[:])
	names_build(&t.cue_names, t.text[:], t.cues[:])
	names_build(&t.media_names, t.text[:], t.media[:])
}

status_of :: proc(s: om.Severity) -> Status {
	switch s {
	case .Info:
		return .Info
	case .Warning:
		return .Warning
	case .Error:
		return .Error
	}
	return .Ok
}

// The problems: a failed reload's lines first, then the findings as
// `inspect` orders them, each with the scenes it was seen in (sized, then
// filled: a counting sort of the findings' scene pairs).
@(private = "file")
problem_rows_build :: proc(t: ^Video_Tables, src: Table_Sources, tl: ^om.Timeline) {
	lines: []string
	if src.load_error != "" do lines = strings.split_lines(src.load_error, context.temp_allocator)
	order := findings_order(src.findings)
	report := findings_report(src.findings, tl, t.fps)
	resize(&t.problems, len(lines) + len(order))
	for line, i in lines {
		t.problems[i] = {severity = .Error, code = .Script_Error, message = text_push(&t.text, line), first = -1, last = -1, reload = true, status = .Error, id = hash.fnv64a(transmute([]u8)line, u64(i))}
	}
	// each finding's place among the problems
	place := make([]i32, len(src.findings.rows), context.temp_allocator)
	for k, i in order do place[k] = i32(len(lines) + i)
	counts := make([]i32, len(t.problems) + 1, context.temp_allocator)
	for pair in src.findings.scenes do counts[place[pair[0]] + 1] += 1
	for i in 1 ..< len(counts) do counts[i] += counts[i - 1]
	resize(&t.problem_scenes, len(src.findings.scenes))
	fill := make([]i32, len(t.problems), context.temp_allocator)
	copy(fill, counts[:len(t.problems)])
	for pair in src.findings.scenes {
		p := place[pair[0]]
		t.problem_scenes[fill[p]] = pair[1]
		fill[p] += 1
	}
	for f, i in report {
		row := src.findings.rows[order[i]]
		at := len(lines) + i
		seen := f.frames > 0
		t.problems[at] = {
			severity = row.diagnostic.severity,
			code     = row.diagnostic.code,
			message  = text_push(&t.text, f.message),
			source   = text_push(&t.text, f.source),
			first    = f.first_frame if seen else -1,
			last     = f.last_frame if seen else -1,
			frames   = f.frames,
			status   = status_of(row.diagnostic.severity),
			id       = row.key,
		}
	}
	t.errors, t.warnings = 0, 0
	for &p, i in t.problems {
		p.scenes = {counts[i], counts[i + 1] - counts[i]}
		t.errors += int(p.severity == .Error)
		t.warnings += int(p.severity == .Warning)
		t.worst[.Problems] = max(t.worst[.Problems], p.status)
	}
}

// The scenes, each with the problems seen in it (the problems' scenes,
// grouped by scene: a counting sort) and their worst status.
@(private = "file")
scene_rows_build :: proc(t: ^Video_Tables, tl: ^om.Timeline) {
	resize(&t.scenes, len(tl.scenes))
	counts := make([]i32, len(tl.scenes) + 1, context.temp_allocator)
	for s in t.problem_scenes do if int(s) < len(tl.scenes) do counts[s + 1] += 1
	for i in 1 ..< len(counts) do counts[i] += counts[i - 1]
	resize(&t.scene_problems, int(counts[len(tl.scenes)]))
	fill := make([]i32, len(tl.scenes), context.temp_allocator)
	copy(fill, counts[:len(tl.scenes)])
	for p, i in t.problems {
		for s in t.problem_scenes[p.scenes[0]:][:p.scenes[1]] {
			if int(s) >= len(tl.scenes) do continue
			t.scene_problems[fill[s]] = i32(i)
			fill[s] += 1
		}
	}
	for sc, k in tl.scenes {
		same := 0
		for earlier in tl.scenes[:k] do same += int(earlier.scene.name == sc.scene.name)
		row := Scene_Row {
			name     = text_push(&t.text, sc.scene.name),
			start    = sc.start_frame,
			end      = sc.end_frame,
			cue      = Cue_Name(text_push(&t.text, sc.scene.cue)),
			source   = text_push(&t.text, sc.scene.source),
			hold     = sc.scene.hold,
			id       = hash.fnv64a(transmute([]u8)sc.scene.name, u64(same)),
			problems = {counts[k], counts[k + 1] - counts[k]},
		}
		for p in t.scene_problems[row.problems[0]:][:row.problems[1]] do row.status = max(row.status, t.problems[p].status)
		t.scenes[k] = row
		t.worst[.Scenes] = max(t.worst[.Scenes], row.status)
	}
}

// The cues, each with its sync finding: one that names it, or its family
// (`beat[*]`).
@(private = "file")
cue_rows_build :: proc(t: ^Video_Tables, src: Table_Sources) {
	resize(&t.cues, len(src.cues))
	for c, i in src.cues {
		row := Cue_Row {
			name    = text_push(&t.text, c.name),
			seconds = c.seconds,
			frame   = om.frame_at(c.seconds, t.fps),
			hit     = Track_Name(text_push(&t.text, c.hit)),
			source  = text_push(&t.text, c.at),
			id      = hash.fnv64a(transmute([]u8)c.name),
		}
		for d in src.sync {
			family := strings.trim_suffix(d.name, "[*]")
			if d.name == c.name || (family != d.name && family_of(c.name) == family) {
				row.sync = text_push(&t.text, om.diagnostic_message(d, context.temp_allocator))
				row.status = status_of(d.severity)
				break
			}
		}
		t.cues[i] = row
		t.worst[.Cues] = max(t.worst[.Cues], row.status)
	}
}

// A media file's durable id: its kind and name, the same across loads.
media_file_id :: proc(kind: om.Media_Kind, name: string) -> u64 {
	return hash.fnv64a(transmute([]u8)name, u64(kind) + 1)
}

// The media files in `media_items`' order (the media table's: its row k
// has file k's thumbnail), each with its first use.
@(private = "file")
media_rows_build :: proc(t: ^Video_Tables, src: Table_Sources) {
	clear(&t.media)
	if src.media == nil do return
	items := media_items(src.media)
	resize(&t.media, len(items))
	for it, k in items {
		first := media_first_frame(src.placed, it.name, t.fps)
		row := Media_File_Row {
			kind   = it.kind,
			name   = text_push(&t.text, it.name),
			detail = text_push(&t.text, it.detail),
			failed = it.failed,
			first  = first,
			thumb  = i32(k),
			id     = media_file_id(it.kind, it.name),
		}
		switch {
		case it.failed:
			row.status = .Error
		case it.kind == .Audio && first < 0:
			row.status = .Info
		}
		t.media[k] = row
		t.worst[.Media] = max(t.worst[.Media], row.status)
	}
}

// A table's rows by name, then place: equal names lie together, so a
// lookup finds every row a name names.
names_build :: proc(out: ^[dynamic]i32, text: []u8, rows: []$T) {
	resize(out, len(rows))
	for &n, i in out do n = i32(i)
	Ctx :: struct {
		text: []u8,
		rows: []T,
	}
	ctx := Ctx{text, rows}
	context.user_ptr = &ctx
	slice.stable_sort_by(out[:], proc(a, b: i32) -> bool {
		c := (^Ctx)(context.user_ptr)
		return text_of(c.text, Text_Span(c.rows[a].name)) < text_of(c.text, Text_Span(c.rows[b].name))
	})
}

// The rows of `rows` named `name` (a span of `names`, in place order).
names_find :: proc(names: []i32, text: []u8, rows: []$T, name: string) -> []i32 {
	lo, hi := 0, len(names)
	for lo < hi {
		mid := (lo + hi) / 2
		if text_of(text, Text_Span(rows[names[mid]].name)) < name {lo = mid + 1} else {hi = mid}
	}
	end := lo
	for end < len(names) && text_of(text, Text_Span(rows[names[end]].name)) == name do end += 1
	return names[lo:end]
}
