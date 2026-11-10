package onimite_app

import "core:fmt"
import "core:strings"
import "core:testing"
import om "../onimite"
import platform "../platform"
import render "../render"
import script "../script"
import ui "../ui"
import "../expr"

// ---- fixtures ---------------------------------------------------------------------------

// The Watch tabs by their tables (WATCH_TABS' order), for tests.
Test_Tab :: enum u8 {
	Scenes,
	Cues,
	Problems,
	Media,
	Marks,
}

tab_of :: proc(tab: Test_Tab) -> string {
	tabs := WATCH_TABS
	return tabs[tab]
}

Test_Row :: struct {
	name:  string,
	frame: int,
}

// Tables made by the producers from scenes (each to the next's start, the
// last 30 frames long), cues (at 30 fps) and a failed reload's error.
test_tables :: proc(t: ^Video_Tables, scenes: []Test_Row = nil, cues: []Test_Row = nil, load_error := "", marks: []Mark = nil) {
	sc := make([]om.Scene, len(scenes), context.temp_allocator)
	infos := make([]om.Scene_Info, len(scenes), context.temp_allocator)
	for s, i in scenes {
		sc[i] = {name = s.name, source = fmt.tprintf("video.lua:%d", i + 1)}
		end := scenes[i + 1].frame if i + 1 < len(scenes) else s.frame + 30
		infos[i] = {i, &sc[i], s.frame, end, end - s.frame, i + 1 == len(scenes)}
	}
	tl := om.Timeline{infos, len(scenes) > 0 ? infos[len(infos) - 1].end_frame : 0}
	cs := make([]script.Cue, len(cues), context.temp_allocator)
	for c, i in cues do cs[i] = {c.name, f64(c.frame) / 30, "", fmt.tprintf("video.lua:%d", 20 + i)}
	findings: Finding_Table
	defer finding_table_destroy(&findings)
	video_tables_build(t, {timeline = &tl, fps = 30, findings = &findings, cues = cs, load_error = load_error, marks = marks})
}

// The fixture the Watch's rows were recorded on before the evaluator
// (C8a): four scenes (one name twice, one with a space), two cues (one
// with a sync finding), a failed reload and three findings, four media
// files, two marks.
test_fixture :: proc(t: ^Video_Tables) {
	intro, outro, finish, again := om.Scene{name = "Intro", source = "video.lua:4"}, om.Scene{name = "Outro", source = "video.lua:9", cue = "drop"}, om.Scene{name = "Big Finish", source = "video.lua:14"}, om.Scene{name = "Intro", source = "video.lua:19"}
	scenes := []om.Scene_Info{{0, &intro, 0, 30, 30, false}, {1, &outro, 30, 60, 30, false}, {2, &finish, 60, 90, 30, false}, {3, &again, 90, 120, 30, true}}
	tl := om.Timeline{scenes, 120}
	findings: Finding_Table
	defer finding_table_destroy(&findings)
	finding_add(&findings, &tl, 12, om.Diagnostic{severity = .Warning, code = .Text_Clipped, name = "title", x = 10})
	finding_add(&findings, &tl, 40, om.Diagnostic{severity = .Warning, code = .Text_Clipped, name = "title", x = 14})
	finding_add(&findings, nil, LOAD_FRAME, om.Diagnostic{severity = .Error, code = .Missing_Track, name = "video.lua:3", a = "music.mp3"})
	cues := []script.Cue{{"drop", 1.5, "", "video.lua:9"}, {"beat[2]", 0.5, "kick", "video.lua:10"}}
	sync := []om.Diagnostic{{severity = .Warning, code = .Cue_Drift, name = "beat[*]", a = "3 of 3 animate keys", b = "their cues", w = -0.5}}
	logo, bad := om.Media_Image{width = 128, height = 64}, om.Media_Image{failed = true}
	m: om.Media
	m.images["logo.png"] = &logo
	m.images["bad.png"] = &bad
	m.audio["music.wav"] = om.Audio_Clip{frames = 96000, source_rate = 48000, source_channels = 2}
	m.audio["unused.wav"] = om.Audio_Clip{frames = 48000, source_rate = 44100, source_channels = 1}
	defer delete(m.images)
	defer delete(m.audio)
	placed := []om.Placed_Track{{track = {src = "music.wav"}, start = 48000, end = 144000}}
	marks := []Mark{{1, 30, 90}, {2, 120, -1}}
	video_tables_build(t, {timeline = &tl, fps = 30, findings = &findings, cues = cues, sync = sync, media = &m, placed = placed, load_error = "boom\nat line 3", marks = marks})
}

// A preview with a window's UI, its tables the fixture's, for frames
// through the whole pipeline (the events' route, the build, the commands
// applied).
Test_Preview :: struct {
	app:  App_State,
	p:    platform.Platform,
	font: render.Font,
	s:    ui.State,
}

test_preview_make :: proc(tp: ^Test_Preview) -> bool {
	tp.app.commands = command_storage_make()
	pv := &tp.app.preview
	pv.active = true
	workspace_init(&pv.workspace)
	pv.font_size = FONT_SIZE_DEFAULT
	pv.timeline.fps, pv.timeline.frames = 30, 120
	test_fixture(&pv.tables)
	tp.p.width, tp.p.height, tp.p.dpi_scale = 1280, 800, 1
	tp.p.input.focused = true
	ok: bool
	tp.font, ok = render.font_load(UI_FONT)
	ui.init(&tp.s, nil, &tp.p, &tp.font)
	icons := PREVIEW_ICONS
	for icon in icons do ui.icons_set(&tp.s, {icon})
	return ok
}

test_preview_destroy :: proc(tp: ^Test_Preview) {
	ui.destroy(&tp.s)
	render.font_unload(&tp.font)
	preview_state_destroy(&tp.app.preview)
	command_storage_destroy(&tp.app.commands)
	delete(tp.p.input.events)
}

// One window frame with these events (at the pointer), then the rows it
// pushed, run through the command table (`dispatch`); their kinds.
test_frame :: proc(tp: ^Test_Preview, events: ..platform.Event) -> []Command_Row {
	p := &tp.p
	clear(&p.input.events)
	for e in events {
		ev := e
		if ev.kind == .Mouse_Press || ev.kind == .Mouse_Release do ev.position = p.input.mouse
		append(&p.input.events, ev)
	}
	preview_layout(&tp.app, p)
	preview_input(&tp.app, &tp.s, p)
	ui.build_begin(&tp.s)
	preview_views(&tp.app, &tp.s, p)
	ui.build_end(&tp.s)
	if tp.app.preview.drag == .Dropping do preview_drag_end(&tp.app)
	batch := &tp.app.commands.pending
	rows := make([dynamic]Command_Row, context.temp_allocator)
	for q in batch.rows {
		r := command_row_of(batch, q)
		r.regs.spec = strings.clone(r.regs.spec, context.temp_allocator)
		append(&rows, r)
	}
	dispatch(&tp.app)
	clear(&p.input.events)
	return rows[:]
}

// Whether a row of `kind` is among `rows`.
test_has :: proc(rows: []Command_Row, kind: Command_Kind) -> bool {
	for r in rows do if r.kind == kind do return true
	return false
}

// The box whose key's text is `key` (built this frame, keyed under its
// parents as build_box keys it).
test_box :: proc(s: ^ui.State, key: string) -> ^ui.Box {
	for k, b in s.box_table {
		if b.last_build_index != s.build_index do continue
		seed: ui.Key
		for p := b.parent; p != nil; p = p.parent {
			if p.key != 0 {seed = p.key; break}
		}
		if ui.key_from_string(seed, key) == k do return b
	}
	return nil
}

// ---- the tests --------------------------------------------------------------------------

// The parser (onib's, smaller): names with a qualifier, members, indices,
// calls kept for lenses, comma lists; numbers say whether they're
// integers; what isn't an expression says why.
@(test)
test_expr_parse :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	nodes := make([dynamic]expr.Node, context.temp_allocator)
	root, error := expr.parse("video:scenes.Race.start", &nodes)
	testing.expect_value(t, error, "")
	testing.expect(t, nodes[root].op == .Member && nodes[root].text == "start")
	race := nodes[nodes[root].a]
	testing.expect(t, race.op == .Member && race.text == "Race")
	name := nodes[race.a]
	testing.expect(t, name.op == .Name && name.text == "scenes" && name.qualifier == "video")
	root, error = expr.parse(`scenes["two words"][3]`, &nodes)
	testing.expect(t, error == "" && nodes[root].op == .Index && nodes[nodes[root].b].integer && nodes[nodes[root].b].number == 3)
	inner := nodes[nodes[root].a]
	testing.expect(t, inner.op == .Index && nodes[inner.b].op == .Text && nodes[inner.b].text == "two words")
	root, _ = expr.parse("1.5", &nodes)
	testing.expect(t, nodes[root].op == .Number && !nodes[root].integer)
	root, _ = expr.parse(`"a \"b\""`, &nodes)
	testing.expect_value(t, nodes[root].text, `a "b"`)
	root, error = expr.parse("scenes, cues.drop , marks", &nodes)
	testing.expect(t, error == "" && nodes[root].op == .List)
	items: [dynamic]string
	defer delete(items)
	for link := root; link >= 0; link = nodes[link].b do append(&items, nodes[link].text)
	testing.expect(t, len(items) == 3 && items[1] == "cues.drop" && items[2] == "marks")
	root, error = expr.parse("hex(scenes[0].start, 2)", &nodes)
	testing.expect(t, error == "" && nodes[root].op == .Call && nodes[nodes[root].a].text == "hex")
	args := 0
	for link := nodes[root].b; link >= 0; link = nodes[link].b do args += 1
	testing.expect_value(t, args, 2)
	for bad in ([]struct {
			source, error: string,
		}{{"scenes.", "expected a member name"}, {`scenes["two`, "unterminated text"}, {"3px", "a number takes no unit"}, {"scenes)", "unexpected text"}, {"scenes[0", "expected ]"}, {"video:", "expected a name after the qualifier"}}) {
		_, error = expr.parse(bad.source, &nodes)
		testing.expectf(t, error == bad.error, "%q: %q, want %q", bad.source, error, bad.error)
	}
	testing.expect(t, expr.is_identifier("Race") && expr.is_identifier("beat_2") && !expr.is_identifier("Big Finish") && !expr.is_identifier("3d") && !expr.is_identifier("logo.png"))
}

// A row's members are its struct's fields read by RTTI (onib's walk): in
// declaration order, `m:"-"` hidden, `m:"+"` flattened in place (a union
// its variant's `kind` first), `m:"name"` renamed, an enum its lowercase
// name with its names as its domain; then what its
// table computes.
@(test)
test_members_by_rtti :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Spot :: struct {
		cone: f64,
	}
	Point :: struct {
		at: int,
	}
	Shape :: union {
		Spot,
		Point,
	}
	Row :: struct {
		name:   int `m:"title"`,
		hidden: int `m:"-"`,
		inner:  struct {
			a, b: int,
		} `m:"+"`,
		shape:  Shape `m:"+"`,
		hold:   om.Hold,
	}
	row := Row{name = 7, inner = {1, 2}, shape = Spot{0.25}, hold = .Freeze}
	fields: [dynamic]Field
	defer delete(fields)
	field_members({ptr = &row, id = Row}, &fields)
	names: [dynamic]string
	defer delete(names)
	for f in fields do append(&names, f.name)
	want := []string{"title", "a", "b", "kind", "cone", "hold"}
	testing.expectf(t, len(names) == len(want), "members %v", names[:])
	for n, i in want do if i < len(names) do testing.expect_value(t, names[i], n)
	testing.expect_value(t, variant_name(Shape, Spot), "spot")
	testing.expect_value(t, enum_names(om.Hold)[2], "freeze")

	// The tables' rows through the evaluator: a scene's fields, then its
	// problems (computed); an enum's name and its domain; a name typed as
	// another kind's (a scene's cue) its kind's names.
	tables: Video_Tables
	defer video_tables_destroy(&tables)
	test_fixture(&tables)
	waves: Wave_Table
	r := Reader{tables = &tables, waves = &waves}
	v, error := evaluate(&r, "scenes.Outro")
	testing.expect_value(t, error, "")
	kids := make([dynamic]Child, context.temp_allocator)
	field_children(&r, v, &kids)
	got := make([dynamic]string, context.temp_allocator)
	for k in kids do append(&got, k.label)
	members := []string{"name", "start", "end", "cue", "source", "hold", "status", "problems"}
	testing.expectf(t, len(got) == len(members), "scene members %v", got[:])
	for n, i in members do if i < len(got) do testing.expect_value(t, got[i], n)
	start, _ := evaluate(&r, "scenes.Outro.start")
	testing.expect(t, start.kind == .Number && start.number == 30 && start.type == int)
	testing.expect_value(t, value_text(&r, start), "30")
	hold, _ := evaluate(&r, "scenes.Outro.hold")
	testing.expect(t, hold.kind == .Text && hold.text == "alive" && hold.domain)
	holds, _ := evaluate(&r, "scenes.Outro.hold.domain")
	testing.expect_value(t, value_text(&r, holds), "4 choices")
	cue, _ := evaluate(&r, "scenes.Outro.cue")
	testing.expect(t, cue.text == "drop" && cue.domain)
	cues, _ := evaluate(&r, "scenes.Outro.cue.domain")
	testing.expect_value(t, collection(cues).info(&r, cues, "").count, 2)
	problems, _ := evaluate(&r, "scenes.Outro.problems")
	testing.expect_value(t, value_text(&r, problems), "1 problem")
	seen, _ := evaluate(&r, "problems[3].scenes")
	testing.expect_value(t, value_text(&r, seen), "2 scenes")
	worst, _ := evaluate(&r, "video:problems.status")
	testing.expect_value(t, worst.text, "error")
	_, error = evaluate(&r, "scenes.Outro.nope")
	testing.expect_value(t, error, `a scene has no member "nope"`)
}

// Rows by name in the member form (`scenes.Outro`), names that aren't
// identifiers in quotes (`scenes["Big Finish"]`, `media["logo.png"]`),
// rows by place (`scenes[3]`); a name two rows have is an error naming each
// place, and so is an unknown qualifier. Each row's own source is written
// so (its suffix).
@(test)
test_names_and_qualifiers :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	tables: Video_Tables
	defer video_tables_destroy(&tables)
	test_fixture(&tables)
	waves: Wave_Table
	r := Reader{tables = &tables, waves = &waves}
	v, error := evaluate(&r, "scenes.Outro")
	testing.expect(t, error == "" && v.kind == .Scene && v.ref.row == 1)
	v, error = evaluate(&r, `video:scenes["Big Finish"].start`)
	testing.expect(t, error == "" && v.number == 60)
	v, error = evaluate(&r, "scenes[3]")
	testing.expect(t, error == "" && row_label(&r, v) == "Intro" && v.ref.row == 3)
	v, error = evaluate(&r, `media["logo.png"].detail`)
	testing.expect(t, error == "" && v.text == "128x64")
	_, error = evaluate(&r, "scenes.Intro")
	testing.expect_value(t, error, "2 scenes named Intro: scenes[0], scenes[3]")
	_, error = evaluate(&r, `scenes["Nope"]`)
	testing.expect_value(t, error, `no scene named "Nope"`)
	_, error = evaluate(&r, "vidoe:scenes")
	testing.expect_value(t, error, "unknown space vidoe (video, query)")
	_, error = evaluate(&r, "query:scenes")
	testing.expect_value(t, error, `no query name "scenes"`)
	_, error = evaluate(&r, "scene")
	testing.expect_value(t, error, `unknown name "scene"; the roots are scenes, cues, problems, media, marks, tracks`)
	_, error = evaluate(&r, "scenes[9]")
	testing.expect_value(t, error, "scenes[9] is out of range: 4 scenes")
	scenes, _ := evaluate(&r, "scenes")
	info := collection(scenes).info(&r, scenes, "")
	kids := make([]Child, info.count, context.temp_allocator)
	collection_rows(&r, scenes, &info, 0, info.count, kids)
	suffixes := []string{"[0]", ".Outro", `["Big Finish"]`, "[3]"}
	for k, i in kids do testing.expect_value(t, k.suffix, suffixes[i])
	// Every row's source evaluates back to it.
	for k in kids {
		back, back_error := evaluate(&r, strings.concatenate({"scenes", k.suffix}, context.temp_allocator))
		testing.expect(t, back_error == "" && back.ref == k.value.ref)
	}
}

// A collection's rows by number, lo up to hi (only those built), and each
// row's id: id_from_num and num_from_id turn one into the other, under a
// filter too (positions before it), and an id keeps to its row when the
// tables are made again with a row before it.
@(test)
test_collection_range_and_ids :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	tables: Video_Tables
	defer video_tables_destroy(&tables)
	test_tables(&tables, {{"Intro", 0}, {"Race", 30}, {"Outro", 60}}, {{"drop", 45}})
	waves: Wave_Table
	r := Reader{tables = &tables, waves = &waves}
	scenes, _ := evaluate(&r, "scenes")
	c := collection(scenes)
	info := c.info(&r, scenes, "")
	testing.expect_value(t, info.count, 3)
	two := make([]Child, 2, context.temp_allocator)
	collection_rows(&r, scenes, &info, 1, 3, two)
	testing.expect(t, two[0].label == "Race" && two[1].label == "Outro")
	race := c.id_from_num(&r, scenes, &info, 1)
	testing.expect_value(t, c.num_from_id(&r, scenes, &info, race), 1)
	testing.expect_value(t, row_id_parse(row_id_text(race)), race)
	filtered := c.info(&r, scenes, "o")
	testing.expect_value(t, filtered.count, 2) // Intro, Outro
	testing.expect_value(t, c.num_from_id(&r, scenes, &filtered, race), -1)
	outro := c.id_from_num(&r, scenes, &info, 2)
	testing.expect_value(t, c.num_from_id(&r, scenes, &filtered, outro), 1)
	// A reload with a scene before them: the ids find their rows' new places.
	test_tables(&tables, {{"Title", 0}, {"Intro", 10}, {"Race", 30}, {"Outro", 60}}, {{"drop", 45}})
	info = c.info(&r, scenes, "")
	testing.expect_value(t, c.num_from_id(&r, scenes, &info, race), 2)
	testing.expect_value(t, c.num_from_id(&r, scenes, &info, outro), 3)
	cues, _ := evaluate(&r, "cues")
	cue_info := collection(cues).info(&r, cues, "")
	testing.expect_value(t, collection(cues).num_from_id(&r, cues, &cue_info, race), -1) // another kind's
	testing.expect_value(t, size_of(Value) <= 248, true)
}

// The Watch tabs list the rows the Watch listed before the evaluator, on
// the same fixture: each row's label, its value's text (the Watch's detail
// then), its status and its frame, and each tab's title and colour. The
// lines are the pre-change build's (watch_table_build), recorded as they
// printed.
@(test)
test_watch_tabs_match_the_old_watch :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	tables: Video_Tables
	defer video_tables_destroy(&tables)
	test_fixture(&tables)
	waves: Wave_Table
	want := []string {
		"DUMP Scenes|Warning|0|Intro|1 problem  1.00s long  frames 0..30 (0.00s..1.00s)  video.lua:4",
		"DUMP Scenes|Warning|30|Outro|1 problem  1.00s long  frames 30..60 (1.00s..2.00s)  cue drop  video.lua:9",
		"DUMP Scenes|Ok|60|Big Finish|1.00s long  frames 60..90 (2.00s..3.00s)  video.lua:14",
		"DUMP Scenes|Ok|90|Intro|1.00s long  frames 90..120 (3.00s..4.00s)  video.lua:19",
		"TITLE Scenes|Scenes 4|[230, 180, 80, 255]",
		"DUMP Cues|Ok|45|drop|1.500s (frame 45)  video.lua:9",
		`DUMP Cues|Warning|15|beat[2]|cue "beat[*]": 3 of 3 animate keys: -0.500s off their cues  0.500s (frame 15)  video.lua:10  hit kick`,
		"TITLE Cues|Cues 2|[230, 180, 80, 255]",
		"DUMP Problems|Error|-1|boom|the script failed to load; the last good version plays",
		"DUMP Problems|Error|-1|at line 3|",
		`DUMP Problems|Error|-1|video.lua:3: the track plays "music.mp3", which is not in the media|Error at load`,
		`DUMP Problems|Warning|12|text "title" is cut off by the canvas edge (x=10 y=0 w=0 h=0)|Warning 0.40s..1.33s (frames 12..40, seen in 2) [Intro + Outro]`,
		"TITLE Problems|Problems 4|[232, 92, 92, 255]",
		"DUMP Media|Error|-1|bad.png|image unreadable",
		"DUMP Media|Ok|-1|logo.png|image 128x64",
		"DUMP Media|Ok|30|music.wav|sound 2.000s, 48000 Hz, stereo  first at 1.000s (frame 30)",
		"DUMP Media|Info|-1|unused.wav|sound 1.000s, 44100 Hz, mono  unused: no track plays it",
		"TITLE Media|Media 4|[232, 92, 92, 255]",
		"DUMP Marks|Info|30|Mark 1|1.00s to 3.00s  2.00s long",
		"DUMP Marks|Info|120|Mark 2|at 4.00s",
		"TITLE Marks|Marks 2|[0, 0, 0, 0]",
	}
	got := make([dynamic]string, context.temp_allocator)
	app: App_State
	app.preview.tables = tables
	app.preview.waves = waves
	for tab in Test_Tab {
		v := View_Record{scoped = true}
		append(&v.inputs, Watch_Input{tab_of(tab), 0})
		defer delete(v.inputs)
		blocks := watch_blocks(&app, &v)
		rows := make([dynamic]View_Row, context.temp_allocator)
		blocks_window(&blocks, 0, max(int), &rows)
		for row in rows {
			r := blocks.r
			append(&got, fmt.tprintf("DUMP %v|%v|%d|%s|%s", tab, row_status(&r, row.value), row_frame(&r, row.value), row.label, value_text(&r, row.value)))
		}
		title, color := watch_title(&app, &v)
		append(&got, fmt.tprintf("TITLE %v|%s|%v", tab, title, color))
	}
	testing.expect_value(t, len(got), len(want))
	for line, i in want do if i < len(got) do testing.expect_value(t, got[i], line)
}

// A row unfolds into its members (RAD's watch rows), through whole frames:
// the expander is the row's first part to take the pointer, a pointing
// hand while hovered (RAD's ui_expander); a press on it opens the row
// (Watch_Expand), whose members follow it, and a member that is a
// collection (its problems) has its own; a second press closes it. The
// open row keeps to its scene by id when the tables are made again with a
// scene before it.
@(test)
test_rows_unfold_through_the_expander :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	tp: Test_Preview
	testing.expect(t, test_preview_make(&tp))
	defer test_preview_destroy(&tp)
	app := &tp.app
	pv := &app.preview
	watch_show(app, "video:scenes")
	id := workspace_find_watch(&pv.workspace, "video:scenes")
	v := workspace_view(&pv.workspace, id)
	for _ in 0 ..< 3 do test_frame(&tp)
	blocks := watch_blocks(app, v)
	testing.expect_value(t, blocks.total, 4)
	rows := make([dynamic]View_Row, context.temp_allocator)
	blocks_window(&blocks, 1, 1, &rows)
	outro := rows[0]
	testing.expect(t, outro.label == "Outro" && outro.unfolds && !outro.expanded)
	expander := test_box(&tp.s, fmt.tprintf("###watch_expander_%d_%s", id, outro.key))
	testing.expect(t, expander != nil && .Clickable in expander.flags)
	if expander == nil do return
	tp.p.input.mouse = (expander.rect.min + expander.rect.max) / 2
	test_frame(&tp)
	test_frame(&tp)
	testing.expect_value(t, tp.p.cursor, platform.Cursor.Hand_Point)
	pressed := test_frame(&tp, {kind = .Mouse_Press, button = .Left})
	testing.expect(t, test_has(pressed, .Watch_Expand))
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	testing.expect_value(t, len(v.expanded), 1)
	blocks = watch_blocks(app, v)
	testing.expect_value(t, blocks.total, 4 + 8) // its eight members
	clear(&rows)
	blocks_window(&blocks, 1, 10, &rows)
	testing.expect(t, rows[0].expanded && rows[1].label == "name" && rows[1].depth == 1 && rows[1].source == "video:scenes.Outro.name")
	testing.expect_value(t, value_text(&blocks.r, rows[1].value), "Outro")
	testing.expect(t, rows[8].label == "problems" && rows[8].unfolds && rows[9].label == "Big Finish")
	// Its members draw as rows of their own, indented a level.
	for _ in 0 ..< 2 do test_frame(&tp)
	testing.expect(t, test_box(&tp.s, fmt.tprintf("###watch_row_%d_%s", id, rows[1].key)) != nil)
	// The tables again, a scene first: the open row is still Outro's.
	test_tables(&pv.tables, {{"Title", 0}, {"Intro", 10}, {"Outro", 30}, {"Big Finish", 60}})
	blocks = watch_blocks(app, v)
	testing.expect_value(t, blocks.total, 4 + 8)
	clear(&rows)
	blocks_window(&blocks, 2, 2, &rows)
	testing.expect(t, rows[0].label == "Outro" && rows[0].expanded && rows[1].label == "name")
	// A second press closes it.
	for _ in 0 ..< 2 do test_frame(&tp)
	expander = test_box(&tp.s, fmt.tprintf("###watch_expander_%d_%s", id, rows[0].key))
	testing.expect(t, expander != nil)
	if expander == nil do return
	tp.p.input.mouse = (expander.rect.min + expander.rect.max) / 2
	test_frame(&tp)
	test_frame(&tp, {kind = .Mouse_Press, button = .Left})
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	testing.expect_value(t, len(v.expanded), 0)
}

// The expression Watch (RAD's watch window), through whole frames and the
// keys' route: typing on its last row adds an expression (Enter commits),
// Enter on an expression's row edits it (what's typed replaces it), Alt+Up
// moves it up (the cursor with it), Delete removes it, Escape drops an
// edit, a paste begins one; each change a command.
@(test)
test_expression_watch_rows :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	tp: Test_Preview
	testing.expect(t, test_preview_make(&tp))
	defer test_preview_destroy(&tp)
	app := &tp.app
	pv := &app.preview
	video := workspace_view(&pv.workspace, workspace_find(&pv.workspace, .Video)).panel
	command_push(&app.commands, .View_Open, {panel = video, view_kind = .Watch})
	dispatch(app)
	id := workspace_shown(&pv.workspace, .Watch)
	v := workspace_view(&pv.workspace, id)
	testing.expect(t, v != nil && !v.scoped && len(v.inputs) == 0)
	if v == nil do return
	title, _ := view_title(app, id)
	testing.expect_value(t, title, "Watch")
	for _ in 0 ..< 3 do test_frame(&tp)
	type :: proc(tp: ^Test_Preview, text: string) -> []Command_Row {return test_frame(tp, ..text_events(text))}
	key :: proc(tp: ^Test_Preview, k: platform.Key, mods: ui.Modifiers = {}) -> []Command_Row {return test_frame(tp, key_press(k, mods))}
	// Real key presses alongside text events on the empty row must not fire single-key commands (s -> Scene_Step, q -> Quit).
	first_s := test_frame(&tp, key_press(.S), text_events("s", from_press = true)[0])
	testing.expect_value(t, len(first_s), 0)
	type(&tp, "cenes")
	testing.expect_value(t, pv.watch_edit.view, id)
	testing.expect_value(t, string(pv.watch_edit.text[:]), "scenes")
	added := key(&tp, .Enter)
	testing.expect(t, len(added) == 1 && added[0].kind == .Watch_Input_Add && added[0].regs.spec == "scenes")
	testing.expect(t, len(v.inputs) == 1 && v.inputs[0].source == "scenes")
	key(&tp, .Down)
	type(&tp, "cues.drop")
	key(&tp, .Enter)
	testing.expect(t, len(v.inputs) == 2 && v.inputs[1].source == "cues.drop")
	// The rows: the expressions' values (a cue worded as the Watch words it).
	blocks := watch_blocks(app, v)
	rows := make([dynamic]View_Row, context.temp_allocator)
	blocks_window(&blocks, 0, 2, &rows)
	testing.expect_value(t, value_text(&blocks.r, rows[0].value), "4 scenes")
	testing.expect_value(t, value_text(&blocks.r, rows[1].value), "1.500s (frame 45)  video.lua:9")
	// Edit: Enter on its row, then typing replaces the whole text.
	testing.expect_value(t, view_list(pv, id).cursor, 1)
	key(&tp, .Enter)
	testing.expect_value(t, pv.watch_edit.view, id)
	type(&tp, "marks")
	set := key(&tp, .Enter)
	testing.expect(t, len(set) == 1 && set[0].kind == .Watch_Input_Set && set[0].regs.count == 1)
	testing.expect_value(t, v.inputs[1].source, "marks")
	// Alt+Up moves it above the scenes, the cursor with it.
	moved := key(&tp, .Up, {.Alt})
	testing.expect(t, len(moved) == 1 && moved[0].kind == .Watch_Input_Move && moved[0].regs.option == 0)
	testing.expect(t, v.inputs[0].source == "marks" && v.inputs[1].source == "scenes")
	testing.expect_value(t, view_list(pv, id).cursor, 0)
	// Escape drops an edit; the expression stays (even when a filter is open on the view).
	field := view_filter_field(pv, id)
	field.open = true
	append(&field.text, "ma")
	append(&v.filter, "ma")
	key(&tp, .Enter)
	testing.expect_value(t, len(test_frame(&tp, key_press(.Q), text_events("q", from_press = true)[0])), 0)
	type(&tp, "nonsense")
	testing.expect_value(t, len(key(&tp, .Escape)), 0)
	testing.expect(t, pv.watch_edit.view == 0 && v.inputs[0].source == "marks")
	testing.expect(t, field.open && string(v.filter[:]) == "ma")
	field.open = false
	clear(&field.text)
	clear(&v.filter)
	// A paste begins an edit with what's pasted over all of it.
	test_frame(&tp)
	ui.action_storage_clear(&tp.s.actions)
	pv.workspace.focused = v.panel
	paste_rows := test_frame_actions(&tp, {kind = .Text, flags = {.Paste}, text = "problems"})
	testing.expect_value(t, len(paste_rows), 0)
	testing.expect_value(t, string(pv.watch_edit.text[:]), "problems")
	key(&tp, .Enter)
	testing.expect_value(t, v.inputs[0].source, "problems")
	// Delete removes the cursor's expression.
	removed := key(&tp, .Delete)
	testing.expect(t, len(removed) == 1 && removed[0].kind == .Watch_Input_Remove && removed[0].regs.count == 0)
	testing.expect(t, len(v.inputs) == 1 && v.inputs[0].source == "scenes")
	// An expression that doesn't evaluate shows why, in its row.
	key(&tp, .Down)
	type(&tp, "scene")
	key(&tp, .Enter)
	blocks = watch_blocks(app, v)
	clear(&rows)
	blocks_window(&blocks, 1, 1, &rows)
	testing.expect_value(t, rows[0].error, `unknown name "scene"; the roots are scenes, cues, problems, media, marks, tracks`)
}

// A frame whose UI events are these rows as they are (a paste's text, which
// the platform's clipboard gives a real one).
test_frame_actions :: proc(tp: ^Test_Preview, actions: ..ui.Action_Row) -> []Command_Row {
	p := &tp.p
	clear(&p.input.events)
	preview_layout(&tp.app, p)
	preview_input(&tp.app, &tp.s, p)
	append(&tp.s.actions.rows, ..actions)
	ui.build_begin(&tp.s)
	preview_views(&tp.app, &tp.s, p)
	ui.build_end(&tp.s)
	batch := &tp.app.commands.pending
	rows := make([dynamic]Command_Row, context.temp_allocator)
	for q in batch.rows do append(&rows, command_row_of(batch, q))
	dispatch(&tp.app)
	return rows[:]
}

// Go-to is a command with a query operand (onib's node.goto, RAD's
// goto_name): Ctrl+P runs Go_To, which, without its frame, asks for it with
// the lister over `scenes, cues, problems, marks`; typing filters their
// labels; Enter fills its register from the picked row's kind (a scene's
// start) and Go_To runs through the command table, the playhead there; a
// row with no frame (a problem at load) fills nothing and leaves the lister
// open.
@(test)
test_go_to_is_a_command :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	tp: Test_Preview
	testing.expect(t, test_preview_make(&tp))
	defer test_preview_destroy(&tp)
	app := &tp.app
	pv := &app.preview
	for _ in 0 ..< 2 do test_frame(&tp)
	asked := test_frame(&tp, key_press(.P, {.Control}))
	testing.expect(t, len(asked) == 1 && asked[0].kind == .Lister_Open && asked[0].regs.lister == .Query && asked[0].regs.command == .Go_To)
	testing.expect(t, pv.workspace.lister.panel != 0 && pv.workspace.lister.command == .Go_To)
	rows := lister_rows({reader = preview_reader(app), fps = 30, panel = pv.workspace.lister.panel, command = .Go_To}, .Query, "")
	testing.expect_value(t, rows.total, 4 + 2 + 4 + 2) // scenes, cues, problems, marks
	first := lister_option(&rows, 0)
	testing.expect(t, first.group == "Scene" && first.label == "Intro" && first.row.kind == .Go_To && first.row.regs.count == 0)
	testing.expect_value(t, lister_option(&rows, 6).row.kind, Command_Kind.None) // a reload's line: no frame
	test_frame(&tp, ..text_events("big"))
	testing.expect_value(t, string(pv.workspace.lister.query[:]), "big")
	went := test_frame(&tp, key_press(.Enter))
	testing.expect(t, len(went) == 2 && went[0].kind == .Go_To && went[0].regs.count == 60 && went[1].kind == .Lister_Close)
	testing.expect_value(t, pv.frame, 60)
	testing.expect_value(t, pv.workspace.lister.panel, Panel_Id(0))
	// A problem at load: Enter leaves the lister open.
	test_frame(&tp, key_press(.P, {.Control}))
	test_frame(&tp, ..text_events("boom"))
	testing.expect_value(t, len(test_frame(&tp, key_press(.Enter))), 0)
	testing.expect(t, pv.workspace.lister.panel != 0)
}
