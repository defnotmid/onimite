package onimite_app

import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"
import platform "../platform"
import render "../render"
import ui "../ui"

// A mode lists its catalogs in order: the view descriptors (a Watch tab
// per table of WATCH_TABS, then an expression Watch) and the panel's
// actions, or a command's query's rows (Go_To's: scenes, cues, problems,
// marks). A filter keeps the options whose group and label the one matcher
// finds it in (RAD's fuzzy_match_find), in the catalogs' order; a query's
// rows, those whose labels it finds it in (their collections filter them).
@(test)
test_lister_options :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ws: Workspace
	defer workspace_destroy(&ws)
	workspace_init(&ws)
	tables: Video_Tables
	defer video_tables_destroy(&tables)
	test_tables(&tables, {{"Intro", 0}, {"Scene Two", 90}}, {{"drop", 48}}, "media/logo.png failed to load")
	waves: Wave_Table
	video := workspace_view(&ws, workspace_find(&ws, .Video)).panel
	list :: proc(tables: ^Video_Tables, waves: ^Wave_Table, panel: Panel_Id, mode: Lister_Mode, query: string) -> (matches: [dynamic]Lister_Option, total: int) {
		rows := lister_rows({reader = {tables = tables, waves = waves}, fps = 30, panel = panel, command = .Go_To}, mode, query)
		matches = make([dynamic]Lister_Option, context.temp_allocator)
		for i in 0 ..< rows.count do append(&matches, lister_option(&rows, i))
		return matches, rows.total
	}

	add, total := list(&tables, &waves, video, .Panel, "")
	testing.expect_value(t, total, 2 + len(WATCH_TABS) + 1 + len(PANEL_ACTIONS))
	testing.expect_value(t, add[0].label, "Video")
	testing.expect_value(t, add[0].row.kind, Command_Kind.View_Open)
	testing.expect_value(t, add[0].row.regs.panel, video)
	testing.expect_value(t, add[3].label, "Watch: Cues")
	testing.expect_value(t, add[3].summary, "1 cue")
	testing.expect_value(t, add[3].row.regs.spec, "video:cues")
	testing.expect_value(t, add[6].label, "Watch: Marks")
	testing.expect_value(t, add[7].label, "Watch")
	testing.expect_value(t, add[7].row.regs.spec, "")
	testing.expect_value(t, add[8].label, "Split right")
	testing.expect_value(t, add[8].row.regs.panel, video)

	// Go_To's query: its rows in their collections' order, each filling
	// the command's frame.
	go_to, _ := list(&tables, &waves, video, .Query, "")
	testing.expect_value(t, go_to[0].group, "Scene")
	testing.expect_value(t, go_to[0].label, "Intro")
	testing.expect_value(t, go_to[1].row.kind, Command_Kind.Go_To)
	testing.expect_value(t, go_to[1].row.regs.count, 90)
	testing.expect_value(t, go_to[1].summary, "00:03.00 · f 90")
	testing.expect_value(t, go_to[2].group, "Cue")
	// A problem at no frame fills nothing.
	testing.expect_value(t, go_to[3].group, "Problem")
	testing.expect_value(t, go_to[3].row.kind, Command_Kind.None)
	testing.expect_value(t, go_to[3].summary, "at no frame")
	testing.expect_value(t, len(go_to), 4)

	// Matched, case ignored, in the catalogs' order.
	sc, _ := list(&tables, &waves, video, .Query, "SC")
	testing.expect_value(t, len(sc), 1)
	testing.expect_value(t, sc[0].label, "Scene Two")
	views, _ := list(&tables, &waves, video, .Panel, "SC")
	testing.expect_value(t, views[0].label, "Watch: Scenes")
	cues, _ := list(&tables, &waves, video, .Panel, "cues")
	testing.expect_value(t, cues[0].label, "Watch: Cues")
	drop, _ := list(&tables, &waves, video, .Query, "drop")
	testing.expect_value(t, len(drop), 1)
	testing.expect_value(t, drop[0].row.regs.count, 48)
	none, _ := list(&tables, &waves, video, .Query, "zzz")
	testing.expect_value(t, len(none), 0)

	// RAD's matcher: substrings, parts in any order, each outside the ones
	// before; what they lit.
	lit := make([dynamic]Fuzzy_Range, context.temp_allocator)
	testing.expect(t, fuzzy_find("Split right", "right spl", &lit))
	testing.expect(t, len(lit) == 2 && lit[0] == {6, 11} && lit[1] == {0, 3})
	testing.expect(t, !fuzzy_find("Split right", "sr"), "letters in order are no substring")
	testing.expect(t, !fuzzy_find("Timeline", "x"))
	testing.expect(t, !fuzzy_find("aa", "a a a"), "a part takes no place another took")
}

// The lister keeps its catalogs' order under a query (nothing ranked, as
// RAD's), and a query of several parts, one with a slash either way and
// in any case, matches each part as a substring.
@(test)
test_lister_query_keeps_order :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ws: Workspace
	defer workspace_destroy(&ws)
	workspace_init(&ws)
	tables: Video_Tables
	defer video_tables_destroy(&tables)
	test_tables(&tables, {{"Outro media", 0}, {"Media", 60}}, {{"media drop", 48}}, "media/logo.png failed to load")
	waves: Wave_Table
	panel := workspace_view(&ws, workspace_find(&ws, .Video)).panel
	labels :: proc(tables: ^Video_Tables, waves: ^Wave_Table, panel: Panel_Id, query: string) -> []string {
		rows := lister_rows({reader = {tables = tables, waves = waves}, fps = 30, panel = panel, command = .Go_To}, .Query, query)
		out := make([dynamic]string, context.temp_allocator)
		for i in 0 ..< rows.count do append(&out, lister_option(&rows, i).label)
		return out[:]
	}
	// "media" is a whole word in the second scene and a better match there,
	// yet the rows keep their order.
	got := labels(&tables, &waves, panel, "media")
	testing.expect(t, len(got) == 4 && got[0] == "Outro media" && got[1] == "Media" && got[2] == "media drop" && got[3] == "media/logo.png failed to load")
	got = labels(&tables, &waves, panel, `LOGO MEDIA\`) // a backslash for the slash
	testing.expect(t, len(got) == 1 && got[0] == "media/logo.png failed to load")
	got = labels(&tables, &waves, panel, "png fail")
	testing.expect(t, len(got) == 1)
	testing.expect_value(t, len(labels(&tables, &waves, panel, "png zzz")), 0)
}

// The lister through its action rows: Down moves the selection, Enter
// (Accept) pushes the selected option's row and closes; typing pushes the
// filter, and the list follows it.
@(test)
test_lister_keys :: proc(t: ^testing.T) {
	app: App_State
	app.commands = command_storage_make()
	defer command_storage_destroy(&app.commands)
	pv := &app.preview
	defer preview_state_destroy(pv)
	workspace_init(&pv.workspace)
	workspace_measure(&pv.workspace, {0, 0, 1280, 700}, 1, tabs_height(FONT_SIZE_DEFAULT), {.Video = -1, .Timeline = 100, .Watch = -1, .Image = -1, .Audio = -1})
	pv.timeline.fps = 30
	test_tables(&pv.tables, {{"Intro", 0}, {"Two", 90}}, {{"drop", 48}})
	p: platform.Platform
	p.width, p.height = 1280, 800
	font, font_ok := render.font_load(UI_FONT)
	testing.expect(t, font_ok)
	defer render.font_unload(&font)
	s: ui.State
	ui.init(&s, nil, &p, &font)
	defer ui.destroy(&s)
	defer free_all(context.temp_allocator)

	// One window frame with these input rows (made before the build, as
	// the keys' are); the rows it pushed, applied to the workspace (no
	// canvas: nothing is drawn).
	frame :: proc(app: ^App_State, s: ^ui.State, input: ..ui.Action_Row) -> []Command_Row {
		ui.action_storage_clear(&s.actions)
		append(&s.actions.rows, ..input)
		ui.build_begin(s)
		lister_view(app, s, 1, {0, 0, 1280, 700})
		ui.build_end(s)
		batch := &app.commands.pending
		rows := make([]Command_Row, len(batch.rows), context.temp_allocator)
		for q, i in batch.rows {
			rows[i] = command_row_of(batch, q)
			rows[i].regs.spec = strings.clone(rows[i].regs.spec, context.temp_allocator)
			workspace_apply(&app.preview.workspace, rows[i].kind, rows[i].regs)
		}
		clear(&batch.rows)
		clear(&batch.text)
		return rows
	}

	workspace_apply(&pv.workspace, .Lister_Open, {lister = .Query, command = .Go_To})
	testing.expect(t, pv.workspace.lister.panel != 0)
	testing.expect_value(t, len(frame(&app, &s)), 0)
	// A floating view's container lights no focus overlay; its search row
	// neither overlay nor border (RAD's).
	container, search := false, false
	for _, b in s.box_table {
		if b.flags & {.Disable_Focus_Overlay, .Draw_Drop_Shadow, .Draw_Background_Blur} == {.Disable_Focus_Overlay, .Draw_Drop_Shadow, .Draw_Background_Blur} do container = true
		if b.flags & {.Disable_Focus_Overlay, .Disable_Focus_Border, .Focus_Active} == {.Disable_Focus_Overlay, .Disable_Focus_Border, .Focus_Active} do search = true
	}
	testing.expect(t, container && search)
	testing.expect_value(t, len(frame(&app, &s, {kind = .Navigate, delta_unit = .Char, delta = {0, 1}})), 0)
	accepted := frame(&app, &s, {kind = .Press, slot = .Accept})
	testing.expect_value(t, len(accepted), 2)
	testing.expect_value(t, accepted[0].kind, Command_Kind.Go_To)
	testing.expect_value(t, accepted[0].regs.count, 90)
	testing.expect_value(t, accepted[1].kind, Command_Kind.Lister_Close)
	testing.expect_value(t, pv.workspace.lister.panel, Panel_Id(0))

	// Typing filters; Enter accepts the first match.
	workspace_apply(&pv.workspace, .Lister_Open, {lister = .Query, command = .Go_To})
	frame(&app, &s)
	typed := frame(&app, &s, {kind = .Text, text = "d"}, {kind = .Text, text = "r"})
	testing.expect_value(t, len(typed), 1)
	testing.expect_value(t, typed[0].kind, Command_Kind.Lister_Filter)
	testing.expect_value(t, typed[0].regs.spec, "dr")
	testing.expect_value(t, string(pv.workspace.lister.query[:]), "dr")
	accepted = frame(&app, &s, {kind = .Press, slot = .Accept})
	testing.expect_value(t, accepted[0].regs.count, 48)

	// The + opens it for its own panel; a branch has no +.
	video := workspace_view(&pv.workspace, workspace_find(&pv.workspace, .Video)).panel
	workspace_apply(&pv.workspace, .Lister_Open, {panel = pv.workspace.root, lister = .Panel})
	testing.expect_value(t, pv.workspace.lister.panel, Panel_Id(0))
	workspace_apply(&pv.workspace, .Lister_Open, {panel = video, lister = .Panel})
	testing.expect_value(t, pv.workspace.lister.panel, video)
	testing.expect_value(t, pv.workspace.lister.mode, Lister_Mode.Panel)
}

// A tab dragged through the UI's pipeline, frame by frame (RAD's drag and
// drop): a press on the timeline's tab, a drag past 10 points begins it, and
// the left button released over the video panel's left dock site drops it
// there (that frame only): the timeline moves to a new panel left of the
// video, and the frame after, no button held, nothing is dragged or active.
// Escape during another drag, from its own press, ends it.
@(test)
test_tab_drag_drops_through_the_pipeline :: proc(t: ^testing.T) {
	app: App_State
	app.commands = command_storage_make()
	defer command_storage_destroy(&app.commands)
	pv := &app.preview
	defer preview_state_destroy(pv)
	workspace_init(&pv.workspace)
	workspace_measure(&pv.workspace, {0, 0, 1280, 700}, 1, tabs_height(FONT_SIZE_DEFAULT), {.Video = -1, .Timeline = 100, .Watch = -1, .Image = -1, .Audio = -1})
	p: platform.Platform
	p.width, p.height = 1280, 800
	font, font_ok := render.font_load(UI_FONT)
	testing.expect(t, font_ok)
	defer render.font_unload(&font)
	s: ui.State
	ui.init(&s, nil, &p, &font)
	defer ui.destroy(&s)
	defer free_all(context.temp_allocator)
	defer delete(p.input.events)
	// One frame: the rows it pushed, the workspace's applied and the
	// panels measured again, as the preview's frame does.
	frame :: proc(app: ^App_State, s: ^ui.State, mouse: [2]f32, down: bool) -> []Command_Row {
		test_input(s.p, mouse, down)
		preview_input(app, s, s.p)
		ui.build_begin(s)
		panels_view(app, s, 1)
		ui.build_end(s)
		if app.preview.drag == .Dropping do app.preview.drag, app.preview.drag_view = .Null, 0
		batch := &app.commands.pending
		rows := make([]Command_Row, len(batch.rows), context.temp_allocator)
		for q, i in batch.rows {
			rows[i] = command_row_of(batch, q)
			if COMMAND_KINDS[rows[i].kind].domain == .Workspace do workspace_apply(&app.preview.workspace, rows[i].kind, rows[i].regs)
		}
		clear(&batch.rows)
		clear(&batch.text)
		workspace_measure(&app.preview.workspace, {0, 0, 1280, 700}, 1, tabs_height(FONT_SIZE_DEFAULT), {.Video = -1, .Timeline = 100, .Watch = -1, .Image = -1, .Audio = -1})
		return rows
	}
	ws := &pv.workspace
	timeline := workspace_find(ws, .Timeline)
	video := workspace_view(ws, workspace_find(ws, .Video)).panel
	tab := ws.areas[workspace_view(ws, timeline).panel - 1].rect
	at := [2]f32{tab.x + 20, tab.y + 5}
	frame(&app, &s, at, false) // the boxes' rects
	frame(&app, &s, at, false)
	frame(&app, &s, at, true) // pressed: the tab shows
	frame(&app, &s, at + {4, 0}, true)
	testing.expect_value(t, pv.drag, Drag_State.Null) // not past 10 points yet
	r := ws.areas[video - 1].content
	size := min(48, min(r.width, r.height) / 4)
	left := [2]f32{r.x + r.width / 2 - size - 4, r.y + r.height / 2}
	frame(&app, &s, left, true)
	testing.expect_value(t, pv.drag, Drag_State.Dragging)
	testing.expect_value(t, pv.drag_view, timeline)
	frame(&app, &s, left, true) // the sites are hot under the pointer
	dropped := frame(&app, &s, left, false)
	testing.expect_value(t, len(dropped), 1)
	testing.expect_value(t, dropped[0].kind, Command_Kind.View_Move)
	testing.expect_value(t, dropped[0].regs.direction, Direction.Left)
	testing.expect_value(t, dropped[0].regs.panel, video)
	testing.expect_value(t, pv.drag, Drag_State.Null)
	left_panel := workspace_view(ws, timeline).panel
	testing.expect(t, left_panel != video && workspace_panel(ws, workspace_panel(ws, video).parent).children[0] == left_panel)
	testing.expect_value(t, len(frame(&app, &s, left, false)), 0)
	testing.expect(t, pv.drag == .Null && s.active[.Left] == 0)

	// Escape during a tab's drag ends it (RAD's: a cancel no view takes
	// cancels a drag), through the whole frame: the timeline's tab, where
	// it now is (the panels slid there), pressed and dragged.
	p.frame_dt = 1
	for _ in 0 ..< 3 do frame(&app, &s, {}, false)
	tab = ws.areas[left_panel - 1].rect
	at = {tab.x + 20, tab.y + 5}
	frame(&app, &s, at, false)
	testing.expect_value(t, s.active[.Left], ui.Key(0))
	frame(&app, &s, at, true)
	frame(&app, &s, at + {40, 0}, true)
	testing.expect_value(t, pv.drag, Drag_State.Dragging)
	testing.expect_value(t, pv.drag_view, timeline)
	test_input(&p, at + {40, 0}, true, 0, .Escape)
	preview_input(&app, &s, &p)
	ui.build_begin(&s)
	preview_views(&app, &s, &p)
	ui.build_end(&s)
	testing.expect_value(t, pv.drag, Drag_State.Null)
	clear(&app.commands.pending.rows); clear(&app.commands.pending.text)
}

// A Watch's filter row is RAD's search row (raddbg_core.c:1658-1756,
// 5207-5225, 16603-16624), through the whole frame: shut until Search opens
// it, easing open at the menu rate, its old text selected and the keys its;
// Search again shuts it, Enter shuts it and keeps the filter, Escape shuts and
// empties it, even with the keys on the rows below; a press elsewhere takes
// the keys and leaves it open. Slash searches too, and types itself while a
// field has the keys.
@(test)
test_search_row_opens_as_rads :: proc(t: ^testing.T) {
	app: App_State
	app.commands = command_storage_make()
	defer command_storage_destroy(&app.commands)
	pv := &app.preview
	defer preview_state_destroy(pv)
	workspace_init(&pv.workspace)
	pv.font_size = FONT_SIZE_DEFAULT
	pv.timeline.fps = 30
	test_tables(&pv.tables, cues = {{"one", 10}, {"two", 48}, {"three", 90}})
	p: platform.Platform
	p.width, p.height, p.dpi_scale, p.frame_dt = 1280, 800, 1, 1.0 / 60
	font, font_ok := render.font_load(UI_FONT)
	testing.expect(t, font_ok)
	defer render.font_unload(&font)
	s: ui.State
	ui.init(&s, nil, &p, &font)
	defer ui.destroy(&s)
	defer free_all(context.temp_allocator)
	defer delete(p.input.events)
	frame :: proc(app: ^App_State, s: ^ui.State, events: ..platform.Event) {
		clear(&s.p.input.events)
		append(&s.p.input.events, ..events)
		preview_layout(app, s.p); preview_input(app, s, s.p)
		ui.build_begin(s); preview_views(app, s, s.p); ui.build_end(s)
		batch := &app.commands.pending
		for q in batch.rows {
			r := command_row_of(batch, q)
			r.regs.spec = strings.clone(r.regs.spec, context.temp_allocator)
			if COMMAND_KINDS[r.kind].domain == .Workspace do workspace_apply(&app.preview.workspace, r.kind, r.regs)
			else do preview_apply(app, r.kind, r.regs)
		}
		clear(&batch.rows); clear(&batch.text)
		clear(&s.p.input.events)
	}
	settle :: proc(app: ^App_State, s: ^ui.State) {for _ in 0 ..< 30 do frame(app, s)}
	ws := &pv.workspace
	watch := workspace_open(ws, ws.focused, .Watch, expression = "video:cues", direction = .Right)
	frame(&app, &s)
	field := view_filter_field(pv, watch)
	row_box :: proc(s: ^ui.State, watch: View_Id) -> ^ui.Box {
		for _, b in s.box_table do if b.last_build_index == s.build_index && b.parent != nil && b.key == ui.key_from_string(b.parent.key, fmt.tprintf("###filter_row_%d", watch)) do return b
		return nil
	}
	h := list_row_height(&s)
	// Shut, with a filter, the row isn't built.
	preview_apply(&app, .View_Filter, {view = watch, spec = "t"})
	settle(&app, &s)
	testing.expect(t, row_box(&s, watch) == nil)
	// Search opens it, its text selected, the keys its; it eases open at
	// RAD's menu rate, 1 - 2^(-70 dt) of the way a frame.
	frame(&app, &s, key_press(.F, {.Control}))
	testing.expect(t, field.open && field.focused)
	testing.expect_value(t, field.cursor, 1)
	testing.expect_value(t, field.mark, 0)
	frame(&app, &s)
	testing.expect_value(t, ui.box_size(row_box(&s, watch)).y, math.floor(h * (1 - math.pow(f32(2), -70.0 / 60))))
	settle(&app, &s)
	testing.expect_value(t, ui.box_size(row_box(&s, watch)).y, h)
	// Search again shuts it, the filter kept.
	frame(&app, &s, key_press(.F, {.Control}))
	settle(&app, &s)
	testing.expect(t, !field.open && !field.focused && row_box(&s, watch) == nil)
	testing.expect_value(t, string(ws.views[watch - 1].filter[:]), "t")
	// Enter shuts it and keeps the filter; the cursor row didn't take it.
	frame(&app, &s, key_press(.Slash))
	testing.expect(t, field.open && field.focused)
	settle(&app, &s)
	frame(&app, &s, key_press(.Enter))
	testing.expect(t, !field.open && !field.focused)
	testing.expect_value(t, string(ws.views[watch - 1].filter[:]), "t")
	// Slash types itself while the field has the keys (a key's event, then
	// its character's), its selected text replaced.
	settle(&app, &s)
	frame(&app, &s, key_press(.Slash))
	settle(&app, &s)
	frame(&app, &s, key_press(.Slash), platform.Event{kind = .Text, character = '/'})
	frame(&app, &s)
	testing.expect(t, field.open)
	testing.expect_value(t, string(ws.views[watch - 1].filter[:]), "/")
	// A press elsewhere takes the keys and leaves it open.
	settle(&app, &s)
	p.input.mouse = {640, 700}
	frame(&app, &s, platform.Event{kind = .Mouse_Press, button = .Left, position = p.input.mouse})
	frame(&app, &s, platform.Event{kind = .Mouse_Release, button = .Left, position = p.input.mouse})
	testing.expect(t, field.open && !field.focused)
	// Escape shuts and empties it, the keys elsewhere, its panel focused.
	ws.focused = workspace_view(ws, watch).panel
	frame(&app, &s)
	frame(&app, &s, key_press(.Escape))
	frame(&app, &s)
	testing.expect(t, !field.open && !field.focused)
	testing.expect_value(t, len(ws.views[watch - 1].filter), 0)
}

// The keys reach the focused panel's view, through the whole frame (the
// key table, the UI's events, the build): with the Watch focused, Down moves
// its cursor row and the volume stays, Left moves nothing, Enter and Space
// go to the cursor row's frame and don't toggle playback; with the video
// focused, Left steps a frame back, Down turns the volume down and Space
// (its leftover accept) plays or pauses; Escape that no view takes does
// nothing (RAD's: a leftover cancel only cancels a drag). A press on an
// unfocused Watch's row, or on its filter, focuses its panel.
@(test)
test_keys_reach_the_focused_panel :: proc(t: ^testing.T) {
	app: App_State
	app.commands = command_storage_make()
	defer command_storage_destroy(&app.commands)
	pv := &app.preview
	defer preview_state_destroy(pv)
	workspace_init(&pv.workspace)
	pv.font_size = FONT_SIZE_DEFAULT // the window's font, as the preview opens with
	pv.timeline.fps = 30
	test_tables(&pv.tables, cues = {{"one", 10}, {"two", 48}, {"three", 90}})
	p: platform.Platform
	p.width, p.height, p.dpi_scale = 1280, 800, 1
	font, font_ok := render.font_load(UI_FONT)
	testing.expect(t, font_ok)
	defer render.font_unload(&font)
	s: ui.State
	ui.init(&s, nil, &p, &font)
	defer ui.destroy(&s)
	defer free_all(context.temp_allocator)
	// One window frame with `keys` pressed (`click`: the left button
	// pressed, then released the next frame, where the pointer is): the rows
	// it pushed (the workspace's applied).
	defer delete(p.input.events)
	frame :: proc(app: ^App_State, s: ^ui.State, keys: ..platform.Key, down := false, mods: ui.Modifiers = {}) -> []Command_Row {
		p := s.p
		test_input(p, p.input.mouse, down, 0, ..keys, mods = mods)
		preview_layout(app, p)
		preview_input(app, s, p)
		ui.build_begin(s)
		preview_views(app, s, p)
		ui.build_end(s)
		batch := &app.commands.pending
		rows := make([dynamic]Command_Row, context.temp_allocator)
		for q in batch.rows {
			row := command_row_of(batch, q)
			if COMMAND_KINDS[row.kind].domain == .Workspace do workspace_apply(&app.preview.workspace, row.kind, row.regs)
			else do append(&rows, row)
		}
		clear(&batch.rows)
		clear(&batch.text)
		return rows[:]
	}
	watch_show(&app, "video:cues")
	watch := workspace_find_watch(&pv.workspace, "video:cues")
	testing.expect_value(t, pv.workspace.focused, workspace_view(&pv.workspace, watch).panel)
	frame(&app, &s)
	frame(&app, &s)
	rows := frame(&app, &s, .Down)
	testing.expect_value(t, view_list(pv, watch).cursor, 1)
	testing.expect(t, !test_has(rows, .Volume_Step))
	rows = frame(&app, &s, .Left)
	testing.expect_value(t, len(rows), 0)
	rows = frame(&app, &s, .Enter)
	testing.expect(t, len(rows) == 1 && rows[0].kind == .Go_To && rows[0].regs.count == 48)
	rows = frame(&app, &s, .Down)
	rows = frame(&app, &s, .Space)
	testing.expect(t, len(rows) == 1 && rows[0].kind == .Go_To && rows[0].regs.count == 90)
	testing.expect(t, !test_has(rows, .Playback_Toggle))
	// The video's panel focused: the same keys are its.
	workspace_select(&pv.workspace, workspace_find(&pv.workspace, .Video))
	frame(&app, &s)
	rows = frame(&app, &s, .Left)
	testing.expect(t, len(rows) == 1 && rows[0].kind == .Frame_Step && rows[0].regs.count == -1)
	rows = frame(&app, &s, .Down)
	testing.expect(t, len(rows) == 1 && rows[0].kind == .Volume_Step && rows[0].regs.scalar < 0)
	testing.expect_value(t, view_list(pv, watch).cursor, 2)
	rows = frame(&app, &s, .Space)
	testing.expect(t, len(rows) == 1 && rows[0].kind == .Playback_Toggle)
	// The rest of the video's keys, through the whole frame: Page Down / Up
	// a scene, Home the start, End the last frame, Delete the mark under the
	// playhead, Ctrl+Left a second back.
	expect_row :: proc(t: ^testing.T, rows: []Command_Row, kind: Command_Kind) -> Command_Row {
		testing.expect(t, len(rows) == 1 && rows[0].kind == kind)
		return rows[0] if len(rows) == 1 else {}
	}
	testing.expect_value(t, expect_row(t, frame(&app, &s, .Page_Down), .Scene_Step).regs.count, 1)
	testing.expect_value(t, expect_row(t, frame(&app, &s, .Page_Up), .Scene_Step).regs.count, -1)
	expect_row(t, frame(&app, &s, .Home), .Frame_Start)
	testing.expect_value(t, expect_row(t, frame(&app, &s, .End), .Frame_Set).regs.count, max(int))
	expect_row(t, frame(&app, &s, .Delete), .Mark_Delete)
	testing.expect_value(t, expect_row(t, frame(&app, &s, .Left, mods = {.Control}), .Seconds_Step).regs.scalar, -1)
	rows = frame(&app, &s, .Escape)
	testing.expect_value(t, len(rows), 0)
	// A press on the unfocused Watch's row focuses its panel (RAD's
	// table-wide press), and on its filter row too (RAD's search row press).
	ws := &pv.workspace
	content := ws.areas[workspace_view(ws, watch).panel - 1].content
	press_at :: proc(app: ^App_State, s: ^ui.State, at: [2]f32) {
		s.p.input.mouse = at
		frame(app, s)
		frame(app, s, down = true)
		frame(app, s)
	}
	testing.expect(t, ws.focused != workspace_view(ws, watch).panel)
	press_at(&app, &s, {content.x + 50, content.y + 10})
	testing.expect_value(t, ws.focused, workspace_view(ws, watch).panel)
	// Its filter row open (a filter typed, the row eased open), the video's
	// panel focused.
	preview_apply(&app, .View_Filter, {view = watch, spec = "t"})
	view_filter_field(pv, watch).open = true
	p.frame_dt = 1.0 / 60
	for _ in 0 ..< 60 do frame(&app, &s)
	workspace_select(ws, workspace_find(ws, .Video))
	frame(&app, &s)
	press_at(&app, &s, {content.x + 50, content.y + list_row_height(&s) / 2})
	testing.expect_value(t, ws.focused, workspace_view(ws, watch).panel)
	testing.expect(t, view_filter_field(pv, watch).focused)
	// RAD's search row lights neither its overlay nor its border.
	search_flags := 0
	for _, b in s.box_table do if b.flags & {.Disable_Focus_Overlay, .Disable_Focus_Border} == {.Disable_Focus_Overlay, .Disable_Focus_Border} do search_flags += 1
	testing.expect(t, search_flags > 0)
	// An AltGr character (Control and Alt held, as Windows gives it; Linux's
	// AltGr is neither) types into it.
	frame_events :: proc(app: ^App_State, s: ^ui.State, events: ..platform.Event) -> []Command_Row {
		clear(&s.p.input.events)
		append(&s.p.input.events, ..events)
		preview_layout(app, s.p); preview_input(app, s, s.p)
		ui.build_begin(s); preview_views(app, s, s.p); ui.build_end(s)
		rows := make([dynamic]Command_Row, context.temp_allocator)
		batch := &app.commands.pending
		for q in batch.rows {
			r := command_row_of(batch, q)
			r.regs.spec = strings.clone(r.regs.spec, context.temp_allocator)
			if COMMAND_KINDS[r.kind].domain == .Workspace do workspace_apply(&app.preview.workspace, r.kind, r.regs)
			else do preview_apply(app, r.kind, r.regs)
			append(&rows, r)
		}
		clear(&batch.rows); clear(&batch.text)
		clear(&s.p.input.events)
		return rows[:]
	}
	frame_events(&app, &s, platform.Event{kind = .Text, character = '@', modifiers = {.Control, .Alt}})
	frame(&app, &s)
	testing.expect_value(t, string(pv.workspace.views[watch - 1].filter[:]), "t@")
	// A click on a row (the field lets go of the keys), then Escape: the
	// filter cleared and its row closed (RAD's query cancel, its panel
	// focused).
	press_at(&app, &s, {content.x + 50, content.y + list_row_height(&s) * 1.5})
	testing.expect(t, !view_filter_field(pv, watch).focused)
	frame_events(&app, &s, key_press(.Escape))
	frame(&app, &s)
	testing.expect_value(t, len(pv.workspace.views[watch - 1].filter), 0)
	testing.expect(t, !view_filter_field(pv, watch).focused && !view_filter_field(pv, watch).open)

	// Focus leaves the window while the left button holds a row down: no
	// release comes (RAD's window layer sends none) and the UI keeps the
	// row the press made active (RAD's clears it only for a disabled or
	// pruned box), so nothing clicks until a release does.
	at := [2]f32{content.x + 50, content.y + 10}
	s.p.input.mouse = at
	frame(&app, &s)
	frame_events(&app, &s, platform.Event{kind = .Mouse_Press, button = .Left, position = at})
	held := s.active[.Left]
	testing.expect(t, held != 0)
	platform.input_focus_lost(&s.p.input)
	testing.expect_value(t, len(s.p.input.events), 0)
	rows = frame_events(&app, &s)
	for r in rows do testing.expect(t, r.kind != .Frame_Set)
	testing.expect_value(t, s.active[.Left], held)
	s.p.input.focused = true
	frame_events(&app, &s, platform.Event{kind = .Mouse_Release, button = .Left, position = at})
	testing.expect_value(t, s.active[.Left], ui.Key(0))
}

// A test frame's pointer at `mouse` with the left button `down`: a change is
// its press or release there, as the platform's pump makes one; `wheel`
// notches (up positive) and `keys` pressed, in that order.
test_input :: proc(p: ^platform.Platform, mouse: [2]f32, down: bool, wheel: f32 = 0, keys: ..platform.Key, mods: ui.Modifiers = {}) {
	clear(&p.input.events)
	p.input.mouse_prev, p.input.mouse = p.input.mouse, mouse
	if down != p.input.mb_down[.Left] {
		p.input.mb_down[.Left] = down
		append(&p.input.events, platform.Event{kind = .Mouse_Press if down else .Mouse_Release, button = .Left, position = mouse})
	}
	if wheel != 0 do append(&p.input.events, platform.Event{kind = .Scroll, position = mouse, delta = {0, -wheel * platform.WHEEL_NOTCH}})
	for k in keys do append(&p.input.events, key_press(k, mods))
}

// The timeline's rows are box rows in the one scroll list (RAD's, its row
// blocks giving each its height), through whole frames: the wheel over them
// scrolls them a row a tick and the bar's arrow a row a frame, both into the
// view's scroll (View_Scroll); a press on a row scrubs (Frame_Set) and a click
// on a group's name opens it (Timeline_Row_Toggle), the next frame showing its
// children; and with the timeline focused, Left still steps a frame back.
@(test)
test_timeline_rows_are_the_scroll_list :: proc(t: ^testing.T) {
	app: App_State
	app.commands = command_storage_make()
	defer command_storage_destroy(&app.commands)
	pv := &app.preview
	defer preview_state_destroy(pv)
	workspace_init(&pv.workspace)
	pv.font_size = FONT_SIZE_DEFAULT // the window's font, as the preview opens with
	pv.timeline.fps, pv.timeline.frames = 30, 300
	preview_cameras_reset(pv)
	w := &pv.waves
	add :: proc(w: ^Wave_Table, kind: Timeline_Kind, parent: i32, path: string) {
		append(&w.items, Timeline_Item{kind = kind, parent = parent, row = -1, path = text_push(&w.text, path)})
		if parent >= 0 do w.items[parent].children += 1
	}
	add(w, .Cues, -1, "cues")
	add(w, .Group, -1, "bus/a") // 1, open: a track
	add(w, .Track, 1, "track/0")
	for i in 0 ..< 30 do add(w, .Track, -1, fmt.tprintf("track/%d", i + 1))
	timeline_tree(w)
	p: platform.Platform
	p.width, p.height, p.dpi_scale = 1280, 800, 1
	font, font_ok := render.font_load(UI_FONT)
	testing.expect(t, font_ok)
	defer render.font_unload(&font)
	s: ui.State
	ui.init(&s, nil, &p, &font)
	defer ui.destroy(&s)
	defer free_all(context.temp_allocator)
	defer delete(p.input.events)
	// One window frame: the pointer at `mouse` (`down`: the left button),
	// the wheel, the keys; the rows it pushed, the ones the timeline's state
	// takes applied.
	frame :: proc(app: ^App_State, s: ^ui.State, mouse: [2]f32, down := false, wheel: f32 = 0, keys: ..platform.Key) -> []Command_Row {
		p := s.p
		test_input(p, mouse, down, wheel, ..keys)
		preview_layout(app, p)
		preview_input(app, s, p)
		ui.build_begin(s)
		preview_views(app, s, p)
		ui.build_end(s)
		batch := &app.commands.pending
		rows := make([dynamic]Command_Row, context.temp_allocator)
		for q in batch.rows {
			row := command_row_of(batch, q)
			#partial switch row.kind {
			case .View_Scroll, .Timeline_Row_Toggle:
				preview_apply(app, row.kind, row.regs)
			case:
				if COMMAND_KINDS[row.kind].domain == .Workspace do workspace_apply(&app.preview.workspace, row.kind, row.regs)
			}
			append(&rows, row)
		}
		clear(&batch.rows)
		clear(&batch.text)
		return rows[:]
	}
	find :: proc(rows: []Command_Row, kind: Command_Kind) -> (Command_Row, bool) {
		for r in rows do if r.kind == kind do return r, true
		return {}, false
	}
	ws := &pv.workspace
	tl := workspace_find(ws, .Timeline)
	away := [2]f32{5, 5}
	frame(&app, &s, away)
	frame(&app, &s, away)
	area := ws.areas[workspace_view(ws, tl).panel - 1].content
	list := s.scroll_list
	testing.expect(t, list.content != nil)
	rows_y := list.content.rect.min.y
	// The rows start under the head (the ruler, the scenes and the cues,
	// which don't scroll): the group 24 points, a track 18 (the group is
	// closed: its track isn't there).
	testing.expect_value(t, rows_y, area.y + TIMELINE_GAP + RULER_HEIGHT + SCENE_HEIGHT + CUE_HEIGHT)
	first := list.content.first
	testing.expect_value(t, first.rect.max.y - first.rect.min.y, f32(LANE_HEIGHT))
	testing.expect_value(t, first.next.rect.max.y - first.next.rect.min.y, f32(TRACK_HEIGHT))
	// The wheel over the rows: a notch down, three rows (2 point units), as
	// RAD's.
	over := [2]f32{area.x + TRACK_PAD + 400, rows_y + 30}
	rows := frame(&app, &s, over, wheel = -1)
	scroll, scrolled := find(rows, .View_Scroll)
	testing.expect(t, scrolled && scroll.regs.count == 3 && workspace_view(ws, tl).scroll == 3)
	_, panned := find(rows, .Timeline_Pan)
	testing.expect(t, !panned)
	for _ in 0 ..< 3 do frame(&app, &s, away)
	// The bar's down arrow, pressed and held: a unit a frame.
	down := s.scroll_list.content.next.last
	at := (down.rect.min + down.rect.max) / 2
	frame(&app, &s, at)
	rows = frame(&app, &s, at, true)
	scroll, scrolled = find(rows, .View_Scroll)
	testing.expect(t, scrolled && scroll.regs.count == 4)
	frame(&app, &s, at)
	// Back to the top, then a press on a row's body scrubs, on the group's
	// name toggles it.
	preview_apply(&app, .View_Scroll, {view = tl, count = 0})
	for _ in 0 ..< 3 do frame(&app, &s, away)
	group := s.scroll_list.content.first
	body := [2]f32{group.rect.min.x + 400, (group.rect.min.y + group.rect.max.y) / 2}
	frame(&app, &s, body)
	rows = frame(&app, &s, body, true)
	set, scrubbed := find(rows, .Frame_Set)
	testing.expect(t, scrubbed && set.regs.count == int(math.floor(f64(400) / ((f64(group.rect.max.x - group.rect.min.x)) / 300))))
	frame(&app, &s, body)
	name := [2]f32{group.rect.min.x + 20, body.y}
	frame(&app, &s, name)
	rows = frame(&app, &s, name, true)
	_, scrubbed = find(rows, .Frame_Set)
	_, toggled := find(rows, .Timeline_Row_Toggle)
	testing.expect(t, !toggled && !scrubbed)
	rows = frame(&app, &s, name)
	toggle: Command_Row
	toggle, toggled = find(rows, .Timeline_Row_Toggle)
	testing.expect(t, toggled && toggle.regs.spec == "bus/a")
	frame(&app, &s, away)
	opened := s.scroll_list.content.first.next
	testing.expect_value(t, opened.rect.max.y - opened.rect.min.y, f32(TRACK_HEIGHT))
	testing.expect_value(t, len(timeline_rows(&app).spans), 3)
	// The timeline's panel focused: Left steps a frame back.
	workspace_select(ws, tl)
	frame(&app, &s, away)
	rows = frame(&app, &s, away, keys = {.Left})
	step, stepped := find(rows, .Frame_Step)
	testing.expect(t, stepped && step.regs.count == -1)
	// The cues' band in the head is the cues row's: the pointer comes over
	// it, and the frame after shows the row's tooltip (the tooltip root's),
	// as a row's.
	tip :: proc(s: ^ui.State) -> string {
		for b := s.tooltip_root.first; b != nil; b = b.next do if strings.contains(b.str, "onimite show") do return b.str
		return ""
	}
	testing.expect_value(t, tip(&s), "")
	band := [2]f32{area.x + TRACK_PAD + 400, area.y + TIMELINE_GAP + RULER_HEIGHT + SCENE_HEIGHT + CUE_HEIGHT / 2}
	frame(&app, &s, band)
	frame(&app, &s, band)
	testing.expect(t, strings.contains(tip(&s), "(onimite show cues)"))
	frame(&app, &s, away)
	testing.expect_value(t, tip(&s), "")
	// The band has no name to press on: anywhere along it a press scrubs.
	band_start := [2]f32{area.x + TRACK_PAD + 20, band.y}
	frame(&app, &s, band_start)
	rows = frame(&app, &s, band_start, true)
	_, scrubbed = find(rows, .Frame_Set)
	testing.expect(t, scrubbed)
	frame(&app, &s, away)
	// Collapsed (T), its panel focused, it still steps frames.
	preview_apply(&app, .Timeline_Toggle, {})
	frame(&app, &s, away)
	rows = frame(&app, &s, away, keys = {.Left})
	step, stepped = find(rows, .Frame_Step)
	testing.expect(t, stepped && step.regs.count == -1)
}

// A tab is as wide as RAD's: its title's width, its close button's and an
// em, at most twenty ems; laid out through the frame, the tab's box is that
// wide, so tabs with longer titles are wider. Every tab has its X (its last
// box): a click on one tab's X closes that tab, not the shown one, and a
// middle click on a tab closes it, frame by frame through the pipeline.
@(test)
test_tab_width_follows_its_title :: proc(t: ^testing.T) {
	app: App_State
	app.commands = command_storage_make()
	defer command_storage_destroy(&app.commands)
	pv := &app.preview
	defer preview_state_destroy(pv)
	workspace_init(&pv.workspace)
	pv.font_size = FONT_SIZE_DEFAULT // the window's font, as the preview opens with
	pv.timeline.fps = 30
	test_tables(&pv.tables, cues = {{"one", 10}})
	p: platform.Platform
	p.width, p.height, p.dpi_scale = 1280, 800, 1
	font, font_ok := render.font_load(UI_FONT)
	testing.expect(t, font_ok)
	defer render.font_unload(&font)
	s: ui.State
	ui.init(&s, nil, &p, &font)
	defer ui.destroy(&s)
	defer free_all(context.temp_allocator)
	watch_open_all(&app, .Problems)
	ws := &pv.workspace
	defer delete(p.input.events)
	// One window frame with the pointer at `at` and these events, through
	// the whole frame (the events' route, the build): the rows it pushed,
	// the workspace's applied.
	frame :: proc(app: ^App_State, s: ^ui.State, at: [2]f32, events: ..platform.Event) -> []Command_Row {
		p := s.p
		clear(&p.input.events)
		p.input.mouse_prev, p.input.mouse = p.input.mouse, at
		for e in events {
			ev := e; ev.position = at
			append(&p.input.events, ev)
		}
		preview_layout(app, p)
		preview_input(app, s, p)
		ui.build_begin(s)
		preview_views(app, s, p)
		ui.build_end(s)
		batch := &app.commands.pending
		rows := make([dynamic]Command_Row, context.temp_allocator)
		for q in batch.rows {
			r := command_row_of(batch, q)
			if COMMAND_KINDS[r.kind].domain == .Workspace do workspace_apply(&app.preview.workspace, r.kind, r.regs)
			append(&rows, r)
		}
		clear(&batch.rows); clear(&batch.text)
		return rows[:]
	}
	count :: proc(rows: []Command_Row, kind: Command_Kind) -> (n: int) {
		for r in rows do if r.kind == kind do n += 1
		return
	}
	for _ in 0 ..< 3 do frame(&app, &s, {})
	fs := ui.top_font_size(&s)
	// The tab whose title box shows `title`: its box (the title's parent).
	tab_box :: proc(s: ^ui.State, title: string) -> ^ui.Box {
		for _, b in s.box_table do if b.str == title && b.parent != nil do return b.parent
		return nil
	}
	widths: [Test_Tab]f32
	for section in Test_Tab {
		tab := workspace_find_watch(ws, tab_of(section))
		title, _ := view_title(&app, tab)
		want := render.measure_text(&font, title, fs) + TAB_CLOSE * fs + fs
		widths[section] = tab_width(&app, &s, tab)
		testing.expect_value(t, widths[section], math.floor(min(want, TAB_MAX * fs)))
		if b := tab_box(&s, title); b != nil {
			testing.expect_value(t, b.rect.max.x - b.rect.min.x, widths[section])
		} else {
			testing.expectf(t, false, "no tab titled %q", title)
		}
	}
	// "Marks 0" is narrower than "Scenes 0".
	testing.expect(t, widths[.Marks] < widths[.Scenes])

	// Every tab's last box is its X, clickable, an icon.
	for section in Test_Tab {
		title, _ := view_title(&app, workspace_find_watch(ws, tab_of(section)))
		b := tab_box(&s, title)
		testing.expect(t, b != nil && b.last != nil && .Clickable in b.last.flags && .Draw_Icon in b.last.flags)
	}
	// A click on the cues' X (the problems' tab shown) closes the cues.
	shown := workspace_find_watch(ws, tab_of(.Problems))
	cues_title, _ := view_title(&app, workspace_find_watch(ws, tab_of(.Cues)))
	x := tab_box(&s, cues_title).last
	at := (x.rect.min + x.rect.max) / 2
	press :: proc(b: platform.Mouse_Button) -> platform.Event {return {kind = .Mouse_Press, button = b}}
	release :: proc(b: platform.Mouse_Button) -> platform.Event {return {kind = .Mouse_Release, button = b}}
	frame(&app, &s, at)
	frame(&app, &s, at, press(.Left))
	frame(&app, &s, at, release(.Left))
	testing.expect_value(t, workspace_find_watch(ws, tab_of(.Cues)), View_Id(0))
	testing.expect_value(t, workspace_panel(ws, workspace_view(ws, shown).panel).shown, shown)
	// A middle click on the marks' tab (its title) closes it.
	for _ in 0 ..< 30 do frame(&app, &s, {}) // the tabs ease into their new places
	marks_title, _ := view_title(&app, workspace_find_watch(ws, tab_of(.Marks)))
	title_box: ^ui.Box
	for _, b in s.box_table do if b.str == marks_title do title_box = b
	testing.expect(t, title_box != nil)
	if title_box != nil {
		at = (title_box.rect.min + title_box.rect.max) / 2
		frame(&app, &s, at)
		frame(&app, &s, at, press(.Middle))
		frame(&app, &s, at, release(.Middle))
		testing.expect_value(t, workspace_find_watch(ws, tab_of(.Marks)), View_Id(0))
		testing.expect(t, workspace_find_watch(ws, tab_of(.Problems)) == shown)
	}
	// A middle click on the scenes' X is the X's alone: one close, the tab
	// neither shown nor closed twice.
	scenes := workspace_find_watch(ws, tab_of(.Scenes))
	scenes_title, _ := view_title(&app, scenes)
	x = tab_box(&s, scenes_title).last
	at = (x.rect.min + x.rect.max) / 2
	frame(&app, &s, at)
	pressed := frame(&app, &s, at, press(.Middle))
	released := frame(&app, &s, at, release(.Middle))
	testing.expect_value(t, count(pressed, .View_Select) + count(released, .View_Select), 0)
	testing.expect_value(t, count(pressed, .View_Close) + count(released, .View_Close), 1)
	testing.expect_value(t, workspace_find_watch(ws, tab_of(.Scenes)), View_Id(0))

	// The + toggles its lister on press: open, held and let go open; pressed
	// again, closed, and let go closed.
	panel := workspace_view(ws, shown).panel
	frame(&app, &s, {}) // laid out without the scenes' tab
	plus: ^ui.Box
	shown_title, _ := view_title(&app, shown)
	if b := tab_box(&s, shown_title); b != nil {
		for k := b.parent.first; k != nil; k = k.next do if k.str == "+" do plus = k // its bar's
	}
	testing.expect(t, plus != nil)
	if plus != nil {
		at = (plus.rect.min + plus.rect.max) / 2
		frame(&app, &s, at)
		frame(&app, &s, at, press(.Left))
		testing.expect_value(t, ws.lister.panel, panel)
		frame(&app, &s, at, release(.Left))
		testing.expect_value(t, ws.lister.panel, panel)
		frame(&app, &s, at, press(.Left))
		testing.expect_value(t, ws.lister.panel, Panel_Id(0))
		frame(&app, &s, at, release(.Left))
		testing.expect_value(t, ws.lister.panel, Panel_Id(0))
	}
}

// A panel's tab bar whose tabs overflow it scrolls sideways under the wheel
// (RAD's ViewScrollX), clamped at both ends (ViewClampX).
@(test)
test_tab_bar_scrolls_sideways :: proc(t: ^testing.T) {
	app: App_State
	app.commands = command_storage_make()
	defer command_storage_destroy(&app.commands)
	pv := &app.preview
	defer preview_state_destroy(pv)
	workspace_init(&pv.workspace)
	pv.font_size = FONT_SIZE_DEFAULT
	p: platform.Platform
	p.width, p.height, p.dpi_scale, p.frame_dt = 900, 700, 1, 1
	font, font_ok := render.font_load(UI_FONT)
	testing.expect(t, font_ok)
	defer render.font_unload(&font)
	s: ui.State
	ui.init(&s, nil, &p, &font)
	defer ui.destroy(&s)
	defer free_all(context.temp_allocator)
	defer delete(p.input.events)
	watch_open_all(&app, .Problems)
	ws := &pv.workspace
	panel := workspace_view(ws, workspace_find_watch(ws, tab_of(.Problems))).panel
	frame :: proc(app: ^App_State, s: ^ui.State, at: [2]f32, wheel: f32 = 0) {
		p := s.p
		clear(&p.input.events)
		p.input.mouse = at
		if wheel != 0 do append(&p.input.events, platform.Event{kind = .Scroll, position = at, delta = {0, wheel}})
		preview_layout(app, p)
		preview_input(app, s, p)
		ui.build_begin(s)
		preview_views(app, s, p)
		ui.build_end(s)
		clear(&app.commands.pending.rows); clear(&app.commands.pending.text)
	}
	for _ in 0 ..< 3 do frame(&app, &s, {})
	// The bar: the Watch's first tab's parent.
	title, _ := view_title(&app, workspace_find_watch(ws, tab_of(.Scenes)))
	bar: ^ui.Box
	for _, b in s.box_table do if b.str == title && b.parent != nil do bar = b.parent.parent
	testing.expect(t, bar != nil)
	if bar == nil do return
	limit := bar.view_bounds.x - bar.fixed_size.x
	testing.expect(t, limit > 0) // its tabs overflow it
	at := [2]f32{ws.areas[panel - 1].rect.x + 40, ws.areas[panel - 1].rect.y + ws.tab_height / 2}
	frame(&app, &s, at, 120) // a notch: 120 pixels along
	testing.expect_value(t, bar.view_off_target.x, min(f32(120), limit))
	for _ in 0 ..< 40 do frame(&app, &s, at, 120)
	testing.expect_value(t, bar.view_off_target.x, limit)
	for _ in 0 ..< 40 do frame(&app, &s, at, -120)
	testing.expect_value(t, bar.view_off_target.x, f32(0))
}

// However a tab's drag ends, the frame after it, with no button held, the
// tab isn't hollow, no slot is open, no drag is on and no box is active
// (RAD's: the hollow tab is still the clickable tab, the drag's release
// ends on it), through whole frames: a drop on its own place, a drop
// elsewhere in its bar, a drop into another panel, a release over no site
// (the controls), Escape, a release outside the window.
@(test)
test_tab_drag_ends_leave_no_hollow_tab :: proc(t: ^testing.T) {
	app: App_State
	app.commands = command_storage_make()
	defer command_storage_destroy(&app.commands)
	pv := &app.preview
	defer preview_state_destroy(pv)
	workspace_init(&pv.workspace)
	pv.font_size = FONT_SIZE_DEFAULT
	p: platform.Platform
	p.width, p.height, p.dpi_scale = 1600, 900, 1
	p.input.focused = true
	font, font_ok := render.font_load(UI_FONT)
	testing.expect(t, font_ok)
	defer render.font_unload(&font)
	s: ui.State
	ui.init(&s, nil, &p, &font)
	defer ui.destroy(&s)
	defer free_all(context.temp_allocator)
	defer delete(p.input.events)
	watch_open_all(&app, .Cues)
	ws := &pv.workspace
	// One window frame as the preview's: the pointer at `at`, the left
	// button `down` (a change its event), `keys`; the rows applied; a drop
	// lasting its frame.
	frame :: proc(app: ^App_State, s: ^ui.State, at: [2]f32, down: bool, keys: ..platform.Key) {
		p := s.p
		test_input(p, at, down, 0, ..keys)
		preview_layout(app, p)
		preview_input(app, s, p)
		ui.build_begin(s)
		preview_views(app, s, p)
		ui.build_end(s)
		if app.preview.drag == .Dropping do app.preview.drag, app.preview.drag_view = .Null, 0
		batch := &app.commands.pending
		for q in batch.rows {
			r := command_row_of(batch, q)
			if COMMAND_KINDS[r.kind].domain == .Workspace do workspace_apply(&app.preview.workspace, r.kind, r.regs)
			else do preview_apply(app, r.kind, r.regs)
		}
		clear(&batch.rows); clear(&batch.text)
	}
	// Where a tab's title is (its title box), and whether the tab is built
	// whole (not hollow: its title there).
	title_at :: proc(app: ^App_State, s: ^ui.State, section: Test_Tab) -> (at: [2]f32, whole: bool) {
		title, _ := view_title(app, workspace_find_watch(&app.preview.workspace, tab_of(section)))
		for _, b in s.box_table do if b.str == title && b.parent != nil && b.last_build_index == s.build_index {
			return (b.rect.min + b.rect.max) / 2, true
		}
		return
	}
	// Presses Scenes' tab and drags it 40 pixels right: a drag.
	start :: proc(t: ^testing.T, app: ^App_State, s: ^ui.State) -> [2]f32 {
		for _ in 0 ..< 2 do frame(app, s, {}, false)
		at, _ := title_at(app, s, .Scenes)
		frame(app, s, at, false)
		frame(app, s, at, true)
		frame(app, s, at + {40, 0}, true)
		testing.expect_value(t, app.preview.drag, Drag_State.Dragging)
		frame(app, s, at + {40, 0}, true)
		_, whole := title_at(app, s, .Scenes)
		testing.expect(t, !whole) // hollow while dragged, from the frame after
		return at
	}
	after :: proc(t: ^testing.T, app: ^App_State, s: ^ui.State, at: [2]f32, case_: string) {
		frame(app, s, at, false)
		_, whole := title_at(app, s, .Scenes)
		testing.expectf(t, whole && app.preview.drag == .Null && app.preview.drop_slot.panel == 0 && s.active[.Left] == 0, "%s: the tab whole, no drag, no slot, nothing active", case_)
	}
	// A drop on its own place, away from where it was pressed (a drop that
	// moves nothing).
	at := start(t, &app, &s)
	frame(&app, &s, at + {20, 0}, true)
	frame(&app, &s, at + {20, 0}, false)
	after(t, &app, &s, at + {20, 0}, "own place")
	// A drop after Media in its bar.
	at = start(t, &app, &s)
	media, _ := title_at(&app, &s, .Media)
	frame(&app, &s, media + {30, 0}, true)
	frame(&app, &s, media + {30, 0}, false)
	after(t, &app, &s, media, "same bar")
	// A drop into the video's panel, its tab bar.
	at = start(t, &app, &s)
	video := ws.areas[workspace_view(ws, workspace_find(ws, .Video)).panel - 1].rect
	there := [2]f32{video.x + video.width - 20, video.y + ws.tab_height / 2}
	frame(&app, &s, there, true)
	frame(&app, &s, there, false)
	testing.expect_value(t, workspace_view(ws, workspace_find_watch(ws, tab_of(.Scenes))).panel, workspace_view(ws, workspace_find(ws, .Video)).panel)
	after(t, &app, &s, there, "another panel")
	// Escape.
	at = start(t, &app, &s)
	frame(&app, &s, at + {40, 0}, true, .Escape)
	frame(&app, &s, at + {40, 0}, false)
	after(t, &app, &s, at, "Escape")
	// A release outside the window.
	at = start(t, &app, &s)
	frame(&app, &s, {-50, -50}, false)
	after(t, &app, &s, at, "outside")
	// A release over no site: the controls.
	at = start(t, &app, &s)
	controls := [2]f32{f32(p.width) / 2, f32(p.height) - pv.bar_height * 1.5}
	frame(&app, &s, controls, true)
	frame(&app, &s, controls, false)
	after(t, &app, &s, controls, "no site")
}

// The controls bar, through whole frames: its play/pause icon shows play
// while paused and pause while playing, a click on it toggles playback, and
// it leads the bar at the left, the time after it. Hovered, the icon shows
// its command and key.
@(test)
test_controls_bar_play_and_time :: proc(t: ^testing.T) {
	app: App_State
	app.commands = command_storage_make()
	defer command_storage_destroy(&app.commands)
	pv := &app.preview
	defer preview_state_destroy(pv)
	workspace_init(&pv.workspace)
	pv.font_size = FONT_SIZE_DEFAULT
	pv.timeline.fps, pv.timeline.frames = 30, 300
	pv.bookmark, pv.mark_in = -1, -1 // none, as the preview opens with
	p: platform.Platform
	p.width, p.height, p.dpi_scale = 1280, 800, 1
	p.input.focused = true
	font, font_ok := render.font_load(UI_FONT)
	testing.expect(t, font_ok)
	defer render.font_unload(&font)
	s: ui.State
	ui.init(&s, nil, &p, &font)
	defer ui.destroy(&s)
	defer free_all(context.temp_allocator)
	defer delete(p.input.events)
	frame :: proc(app: ^App_State, s: ^ui.State, at: [2]f32, down: bool) -> []Command_Row {
		p := s.p
		test_input(p, at, down)
		s.theme.default_font_px = FONT_SIZE_DEFAULT * p.dpi_scale
		preview_layout(app, p)
		preview_input(app, s, p)
		ui.build_begin(s)
		preview_views(app, s, p)
		ui.build_end(s)
		batch := &app.commands.pending
		rows := make([dynamic]Command_Row, context.temp_allocator)
		for q in batch.rows {
			r := command_row_of(batch, q)
			if r.kind == .Playback_Toggle do app.preview.playing = !app.preview.playing
			append(&rows, r)
		}
		clear(&batch.rows); clear(&batch.text)
		return rows[:]
	}
	icons := PREVIEW_ICONS
	icon_box :: proc(s: ^ui.State, icon: string) -> ^ui.Box {
		for _, b in s.box_table do if b.icon == icon && b.last_build_index == s.build_index do return b
		return nil
	}
	frame(&app, &s, {}, false)
	frame(&app, &s, {}, false)
	play := icon_box(&s, icons[.Play])
	testing.expect(t, play != nil && icon_box(&s, icons[.Pause]) == nil)
	if play == nil do return
	// At the bar's left, half an em in; the time the box after it.
	bar := play.parent.parent
	testing.expect_value(t, play.rect.min.x - bar.rect.min.x, math.floor(ui.top_font_size(&s) * 0.5))
	testing.expect(t, play.next != nil && play.next.rect.min.x == play.rect.max.x)
	// Square at the bar's height.
	testing.expect_value(t, play.rect.max.x - play.rect.min.x, bar.rect.max.y - bar.rect.min.y)
	// Hovered: its tooltip, "Play" and Space.
	at := (play.rect.min + play.rect.max) / 2
	frame(&app, &s, at, false)
	tip := false
	for _, b in s.box_table do if b.str == "Play" && b.last_build_index == s.build_index do tip = true
	testing.expect(t, tip)
	// A click: playback toggles, and the icon shows pause.
	frame(&app, &s, at, true)
	rows := frame(&app, &s, at, false)
	toggled := false
	for r in rows do if r.kind == .Playback_Toggle do toggled = true
	testing.expect(t, toggled && pv.playing)
	frame(&app, &s, at, false)
	testing.expect(t, icon_box(&s, icons[.Pause]) != nil && icon_box(&s, icons[.Play]) == nil)

	// The bookmark's icon: off, then a click sets the bookmark (the row
	// applied), on, its tooltip carrying the bookmark's time.
	click :: proc(app: ^App_State, s: ^ui.State, b: ^ui.Box) -> []Command_Row {
		at := (b.rect.min + b.rect.max) / 2
		frame(app, s, at, false)
		frame(app, s, at, true)
		rows := frame(app, s, at, false)
		for r in rows do if r.kind != .Playback_Toggle do preview_apply(app, r.kind, r.regs)
		frame(app, s, at, false)
		return rows
	}
	active :: proc(s: ^ui.State, b: ^ui.Box) -> bool {return b.bg_color == s.theme.active}
	pv.frame = 60
	mark := icon_box(&s, icons[.Bookmark])
	testing.expect(t, mark != nil && !active(&s, mark))
	if mark != nil {
		click(&app, &s, mark)
		mark = icon_box(&s, icons[.Bookmark])
		testing.expect(t, pv.bookmark == 60 && active(&s, mark))
		tip := false
		for _, b in s.box_table do if b.str == "Mark · 00:02.00" && b.last_build_index == s.build_index do tip = true
		testing.expect(t, tip)
	}
	// The speaker: its waves, a click mutes, an X.
	sound := icon_box(&s, icons[.Sound])
	testing.expect(t, sound != nil && icon_box(&s, icons[.Muted]) == nil)
	if sound != nil {
		click(&app, &s, sound)
		testing.expect(t, pv.muted && icon_box(&s, icons[.Muted]) != nil && icon_box(&s, icons[.Sound]) == nil)
	}
}

// Every Watch tab on a table, in order in one panel, `shown`'s shown: a
// tab bar full enough to size, scroll and drag tabs in.
@(private = "file")
watch_open_all :: proc(app: ^App_State, shown: Test_Tab) {
	for section in Test_Tab do watch_show(app, tab_of(section))
	watch_show(app, tab_of(shown))
}
