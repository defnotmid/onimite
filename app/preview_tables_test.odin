package onimite_app

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
import om "../onimite"
import script "../script"

@(test)
test_wave_pyramid :: proc(t: ^testing.T) {
	// A clip silent but for one loud sample pair at 3000 and a quiet run.
	frames := 10_000
	samples := make([]f32, frames * 2)
	defer delete(samples)
	samples[3000 * 2] = 0.9
	samples[3000 * 2 + 1] = -0.5
	for i in 6000 ..< 6100 {
		samples[i * 2] = 0.1
	}
	clip := om.Audio_Clip{samples = samples, frames = frames}
	b: Wave_Builder
	defer wave_builder_destroy(&b)
	placed := []om.Placed_Track{{track = {src = "a.wav"}, clip = &clip, start = 480, end = 480 + frames}}
	video: om.Video
	wave_builder_lanes(&b, placed, {0}, &video, 0, nil)
	testing.expect(t, wave_builder_pending(&b))
	for wave_builder_pending(&b) {
		wave_builder_step(&b)
	}
	c := &b.table.clips[0]
	testing.expect_value(t, int(c.count[0]), (frames + WAVE_BUCKET - 1) / WAVE_BUCKET)
	testing.expect(t, c.levels > 3)
	// Any span over the loud pair finds it, whichever level answers.
	for span in ([]int{1, 300, 2000, 9000}) {
		lo, hi, ok := wave_peak(&b.table, c, 3000 - span / 2, 3000 + span / 2 + 1)
		testing.expect(t, ok)
		testing.expectf(t, hi > 0.85 && lo < -0.45, "span %d: %v..%v", span, lo, hi)
	}
	lo, hi, _ := wave_peak(&b.table, c, 6000, 6100)
	testing.expect(t, hi > 0.09 && hi < 0.2 && lo == 0)
	testing.expect_value(t, text_of(b.table.text[:], b.table.lanes[0].name), "a.wav")
}

// A bus's tracks are one group item (with a lane of their sound together)
// followed by a track item each, in time order; a lone track on no bus is
// an item of its own. Paths are what `onimite show` takes.
@(test)
test_timeline_items :: proc(t: ^testing.T) {
	frames := 4800
	samples := make([]f32, frames * 2)
	defer delete(samples)
	samples[100 * 2] = 0.8
	clip := om.Audio_Clip{samples = samples, frames = frames}
	placed := []om.Placed_Track {
		{track = {src = "late", bus = "sfx"}, clip = &clip, start = 20_000, end = 20_000 + frames},
		{track = {src = "music"}, clip = &clip, start = 0, end = frames},
		{track = {src = "early", bus = "sfx"}, clip = &clip, start = 1000, end = 1000 + frames},
	}
	buses := []om.Bus{{name = "sfx", gain_db = -6}}
	video := om.Video{buses = buses}
	b: Wave_Builder
	defer wave_builder_destroy(&b)
	wave_builder_lanes(&b, placed, {1, 2, 0}, &video, 3, nil)
	items := b.table.items[:]
	path :: proc(b: ^Wave_Builder, i: int) -> string {return text_of(b.table.text[:], b.table.items[i].path)}
	testing.expect_value(t, len(items), 5)
	testing.expect_value(t, items[0].kind, Timeline_Kind.Scenes)
	testing.expect_value(t, items[1].kind, Timeline_Kind.Group)
	testing.expect_value(t, path(&b, 1), "bus/sfx")
	testing.expect_value(t, items[1].children, 2)
	// Its tracks in time order, named by their place in time.
	testing.expect_value(t, path(&b, 2), "track/1")
	testing.expect_value(t, path(&b, 3), "track/2")
	testing.expect_value(t, items[2].parent, 1)
	testing.expect_value(t, path(&b, 4), "track/0")
	testing.expect_value(t, items[4].parent, -1)
	for wave_builder_pending(&b) {
		wave_builder_step(&b)
	}
	// The group's sound has both tracks' loud sample at their places, in a
	// region each (nothing between them).
	g := b.table.lanes[items[1].lane]
	testing.expect_value(t, g.start, 1000)
	regions := lane_regions(&b.table, items[1].lane)
	testing.expect_value(t, len(regions), 2)
	for at in ([]int{1000 + 100, 20_000 + 100}) {
		hi: f32
		ok: bool
		for r in regions {
			if at >= r.start && at < r.end {
				_, hi, ok = wave_peak(&b.table, &b.table.clips[r.clip], at - r.start + r.at, at - r.start + r.at + 1)
			}
		}
		testing.expectf(t, ok && hi > 0.7, "the group's peak at %d: %v", at, hi)
	}
}

// The Watch's rows: a scene with the problems seen in it, a cue its sync
// finding names (by family too), the problems grouped like `inspect`'s and
// most severe first, the load's at no frame.
@(test)
test_watch_rows :: proc(t: ^testing.T) {
	intro, outro := om.Scene{name = "Intro"}, om.Scene{name = "Outro"}
	scenes := []om.Scene_Info{{0, &intro, 0, 30, 30, false}, {1, &outro, 30, 60, 30, true}}
	tl := om.Timeline{scenes, 60}
	findings: Finding_Table
	defer finding_table_destroy(&findings)
	d := om.Diagnostic{severity = .Warning, code = .Text_Clipped, name = "title", x = 10}
	testing.expect(t, finding_add(&findings, &tl, 12, d))
	// The same finding at another place in a later frame extends the range;
	// one inside it changes nothing.
	d2 := om.Diagnostic{severity = .Warning, code = .Text_Clipped, name = "title", x = 14}
	testing.expect(t, finding_add(&findings, &tl, 20, d2))
	testing.expect(t, !finding_add(&findings, &tl, 15, d2))
	// What the load found is its own finding, seen in no frame.
	load := om.Diagnostic{severity = .Error, code = .Missing_Track, name = "video.lua:3", a = "music.mp3"}
	testing.expect(t, finding_add(&findings, nil, LOAD_FRAME, load))
	cues := []script.Cue{{"drop", 1.5, "", "video.lua:9"}, {"beat[2]", 0.5, "", "video.lua:10"}}
	sync := []om.Diagnostic{{severity = .Warning, code = .Cue_Drift, name = "beat[*]", a = "3 of 3 animate keys", b = "their cues", w = -0.5}}
	table: Watch_Table
	defer watch_table_destroy(&table)
	watch_table_build(&table, {timeline = &tl, fps = 30, findings = &findings, cues = cues, sync = sync})
	row :: proc(t: ^Watch_Table, section: Watch_Section, i: int) -> Watch_Row {return t.rows[t.sections[section].first + i]}
	label :: proc(t: ^Watch_Table, section: Watch_Section, i: int) -> string {return text_of(t.text[:], row(t, section, i).label)}

	testing.expect_value(t, table.sections[.Scenes].count, 2)
	testing.expect_value(t, row(&table, .Scenes, 0).status, Watch_Status.Warning)
	testing.expect_value(t, row(&table, .Scenes, 1).status, Watch_Status.Ok)
	testing.expect_value(t, row(&table, .Scenes, 1).frame, 30)
	testing.expect_value(t, row(&table, .Cues, 0).status, Watch_Status.Ok)
	testing.expect_value(t, row(&table, .Cues, 0).frame, 45)
	testing.expect_value(t, row(&table, .Cues, 1).status, Watch_Status.Warning)
	testing.expect_value(t, table.sections[.Cues].worst, Watch_Status.Warning)
	testing.expect_value(t, table.sections[.Problems].count, 2)
	testing.expect_value(t, row(&table, .Problems, 0).status, Watch_Status.Error)
	testing.expect_value(t, row(&table, .Problems, 0).frame, -1)
	testing.expect_value(t, label(&table, .Problems, 0), `video.lua:3: the track plays "music.mp3", which is not in the media`)
	testing.expect_value(t, row(&table, .Problems, 1).frame, 12)
	testing.expect_value(t, label(&table, .Problems, 1), `text "title" is cut off by the canvas edge (x=10 y=0 w=0 h=0)`)
	testing.expect_value(t, text_of(table.text[:], row(&table, .Problems, 1).detail), "Warning 0.40s..0.67s (frames 12..20, seen in 3) [Intro]")
	testing.expect_value(t, table.sections[.Media].count, 0)
}

// Marks written beside a clip read back as they were (moments and ranges,
// their numbers, in time order), in seconds a person and an agent read;
// none written removes the file.
@(test)
test_marks_file :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_marks_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	clip, _ := filepath.join({dir, "take.mp4"}, context.temp_allocator)
	marks := []Mark{{2, 30, 90}, {1, 120, -1}, {3, 150, 151}}
	marks_write(clip, marks, 60)
	text, err := os.read_entire_file(marks_file(clip), context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expectf(t, strings.contains(string(text), `{ "n": 2, "from": 0.500, "to": 1.500 }`), "the file says %s", string(text))
	testing.expect(t, strings.contains(string(text), `{ "n": 1, "at": 2.000 }`))
	back := marks_read(clip, 60, context.temp_allocator)
	testing.expect_value(t, len(back), 3)
	for m, i in marks {
		testing.expectf(t, back[i] == m, "mark %d read back as %v, not %v", i, back[i], m)
	}
	marks_write(clip, nil, 60)
	testing.expect(t, !os.exists(marks_file(clip)))
}


// The rows below the scenes from blocks and spans are the rows a walk of
// every item gives (an item shown when every item above it is open), in
// order, for any rows open: the whole list, any window of it, its points,
// and the last first row that still fills an area.
@(test)
test_timeline_rows_blocks :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	app: App_State
	pv := &app.preview
	defer preview_state_destroy(pv)
	workspace_init(&pv.workspace)
	w := &pv.waves
	add :: proc(w: ^Wave_Table, kind: Timeline_Kind, parent: i32, path: string) {
		append(&w.items, Timeline_Item{kind = kind, parent = parent, path = text_push(&w.text, path)})
		if parent >= 0 do w.items[parent].children += 1
	}
	add(w, .Scenes, -1, "scenes")
	add(w, .Cues, -1, "cues")
	add(w, .Group, -1, "bus/a")       // 2
	add(w, .Track, 2, "track/0")      // 3
	add(w, .Part, 3, "track/0/part/0")
	add(w, .Part, 3, "track/0/part/1")
	add(w, .Track, 2, "track/1")      // 6
	add(w, .Group, -1, "bus/b")       // 7
	add(w, .Track, 7, "track/2")      // 8
	add(w, .Notes, 8, "track/2/notes")
	add(w, .Track, -1, "track/3")
	timeline_tree(w)
	walk :: proc(app: ^App_State) -> [dynamic]int {
		items := app.preview.waves.items[:]
		out := make([dynamic]int, context.temp_allocator)
		for it, i in items {
			if it.kind == .Scenes do continue
			shown := true
			for p := it.parent; p >= 0 && shown; p = items[p].parent do shown = timeline_row_open(app, items[p])
			if shown do append(&out, i)
		}
		return out
	}
	opens := [][]int{{}, {2}, {2, 3}, {3}, {2, 3, 7, 8}, {7}, {8, 7, 3, 2}}
	for open in opens {
		clear(&pv.rows_open)
		for i in open do append(&pv.rows_open, w.items[i].key)
		want := walk(&app)
		r := timeline_rows(&app)
		testing.expect_value(t, r.total, len(want))
		got := rows_window(&r, 0, max(int))
		testing.expectf(t, slice.equal(got, want[:]), "open %v: %v, want %v", open, got, want[:])
		points: f32
		for i in want do points += row_height(w.items[i].kind)
		testing.expect_value(t, r.points, points)
		for first in 0 ..< len(want) {
			testing.expect(t, slice.equal(rows_window(&r, first, 3), want[first:min(first + 3, len(want))]))
		}
		for room in ([]f32{10, 40, 60, 100, points, points + 1}) {
			last := len(want)
			for acc: f32 = 0; last > 0 && acc + row_height(w.items[want[last - 1]].kind) <= room; last -= 1 do acc += row_height(w.items[want[last - 1]].kind)
			testing.expect_value(t, rows_last_first(w, &r, room), last if points > room else 0)
		}
	}
}
