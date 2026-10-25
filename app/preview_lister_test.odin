package onimite_app

import "core:strings"
import "core:testing"
import platform "../platform"
import ui "../ui"

@(private = "file")
watch_add :: proc(w: ^Watch_Table, section: Watch_Section, frame: int, label: string) {
	g := &w.sections[section]
	if g.count == 0 {
		g.first = len(w.rows)
	}
	g.count += 1
	append(&w.rows, Watch_Row{section = section, frame = frame, label = text_push(&w.text, label)})
}

// A mode lists its catalogs in order: the view descriptors (a Watch once
// per section) and the panel's actions, or the rows of the sections
// that are places to go. A filter keeps the options whose group and label
// have its letters in order, ranked by the one matcher (fuzzy_score):
// runs and word starts first, equal scores in the catalogs' order.
@(test)
test_lister_options :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ws: Workspace
	defer workspace_destroy(&ws)
	workspace_init(&ws)
	w: Watch_Table
	defer watch_table_destroy(&w)
	watch_add(&w, .Scenes, 0, "Intro")
	watch_add(&w, .Scenes, 90, "Scene Two")
	watch_add(&w, .Cues, 48, "drop")
	watch_add(&w, .Problems, -1, "media/logo.png failed to load")
	watch_add(&w, .Media, 12, "logo.png")
	video := workspace_view(&ws, workspace_find(&ws, .Video)).panel
	list :: proc(ws: ^Workspace, w: ^Watch_Table, panel: Panel_Id, mode: Lister_Mode, query: string) -> (matches: [dynamic]Lister_Option, total: int) {
		rows := lister_rows({w, 30, panel}, mode, query)
		matches = make([dynamic]Lister_Option, context.temp_allocator)
		for i in 0 ..< rows.count do append(&matches, lister_option(&rows, i))
		return matches, rows.total
	}

	add, total := list(&ws, &w, video, .Panel, "")
	testing.expect_value(t, total, 2 + len(Watch_Section) + len(PANEL_ACTIONS))
	testing.expect_value(t, add[0].label, "Video")
	testing.expect_value(t, add[0].row.kind, Command_Kind.View_Open)
	testing.expect_value(t, add[0].row.regs.panel, video)
	testing.expect_value(t, add[3].label, "Watch: Cues")
	testing.expect_value(t, add[3].row.regs.section, Watch_Section.Cues)
	testing.expect_value(t, add[6].label, "Watch: Marks")
	testing.expect_value(t, add[7].label, "Split right")
	testing.expect_value(t, add[7].row.regs.panel, video)

	// Places first; Media rows are not places.
	go_to, _ := list(&ws, &w, video, .Go_To, "")
	testing.expect_value(t, go_to[0].group, "Scene")
	testing.expect_value(t, go_to[0].label, "Intro")
	testing.expect_value(t, go_to[1].row.kind, Command_Kind.Frame_Set)
	testing.expect_value(t, go_to[1].row.regs.count, 90)
	testing.expect_value(t, go_to[1].summary, "00:03.00 · f 90")
	testing.expect_value(t, go_to[2].group, "Cue")
	// A problem at no frame opens the Watch on its section.
	testing.expect_value(t, go_to[3].row.kind, Command_Kind.Watch_Show)
	testing.expect_value(t, go_to[3].row.regs.section, Watch_Section.Problems)
	testing.expect_value(t, go_to[4].group, "View")

	// Ranked by the matcher; case ignored.
	sc, _ := list(&ws, &w, video, .Go_To, "SC")
	testing.expect_value(t, len(sc), 3)
	testing.expect_value(t, sc[0].label, "Intro")
	testing.expect_value(t, sc[1].label, "Scene Two")
	testing.expect_value(t, sc[2].label, "Watch: Scenes")
	cues, _ := list(&ws, &w, video, .Panel, "cues")
	testing.expect_value(t, cues[0].label, "Watch: Cues")
	drop, _ := list(&ws, &w, video, .Go_To, "drop")
	testing.expect_value(t, len(drop), 1)
	testing.expect_value(t, drop[0].row.regs.count, 48)
	none, _ := list(&ws, &w, video, .Go_To, "zzz")
	testing.expect_value(t, len(none), 0)

	// The letters the filter lit, and parts in any order.
	marks := fuzzy_positions("Split right", "sr")
	testing.expect(t, len(marks) == 2 && marks[0] == 0 && marks[1] == 6, "Split right: s and r")
	_, both := fuzzy_score("Split right", "right spl")
	testing.expect(t, both, "parts match in any order")
	_, none_ok := fuzzy_score("Timeline", "x")
	testing.expect(t, !none_ok, "no x in Timeline")
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
	workspace_measure(&pv.workspace, {0, 0, 1280, 700}, 1, {.Video = -1, .Timeline = 100, .Watch = -1})
	pv.timeline.fps = 30
	watch_add(&pv.watch, .Scenes, 0, "Intro")
	watch_add(&pv.watch, .Scenes, 90, "Two")
	watch_add(&pv.watch, .Cues, 48, "drop")
	p: platform.Platform
	p.width, p.height = 1280, 800
	s: ui.State
	ui.init(&s, nil, &p, nil)
	defer ui.destroy(&s)
	defer free_all(context.temp_allocator)

	// One window frame with these input rows; the rows it pushed, applied
	// to the workspace (no renderer: nothing is drawn).
	frame :: proc(app: ^App_State, s: ^ui.State, input: ..ui.Action_Row) -> []Command_Row {
		ui.build_begin(s)
		ui.modal_input_set(s, app.preview.workspace.lister.panel != 0)
		append(&s.actions.rows, ..input)
		lister_view(app, s, 1)
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

	workspace_apply(&pv.workspace, .Lister_Open, {lister = .Go_To})
	testing.expect(t, pv.workspace.lister.panel != 0)
	testing.expect_value(t, len(frame(&app, &s)), 0)
	testing.expect_value(t, len(frame(&app, &s, {kind = .Navigate, delta = {0, 1}})), 0)
	accepted := frame(&app, &s, {kind = .Press, slot = .Accept})
	testing.expect_value(t, len(accepted), 2)
	testing.expect_value(t, accepted[0].kind, Command_Kind.Frame_Set)
	testing.expect_value(t, accepted[0].regs.count, 90)
	testing.expect_value(t, accepted[1].kind, Command_Kind.Lister_Close)
	testing.expect_value(t, pv.workspace.lister.panel, Panel_Id(0))

	// Typing filters; Enter accepts the first match.
	workspace_apply(&pv.workspace, .Lister_Open, {lister = .Go_To})
	frame(&app, &s)
	typed := frame(&app, &s, {kind = .Text, text = 'd'}, {kind = .Text, text = 'r'})
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
