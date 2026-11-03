package onimite_app

import "core:testing"
import platform "../platform"
import ui "../ui"

// A key's press with exactly its modifiers runs its row (RAD's binding),
// repeats included: the preview's command is pushed, a UI command's event
// made at once (RAD's UI commands: the arrows, Home and End, Delete,
// Backspace, Enter, Escape).
@(test)
test_preview_keys :: proc(t: ^testing.T) {
	app: App_State
	app.commands = command_storage_make()
	defer command_storage_destroy(&app.commands)
	s: ui.State
	s.actions = ui.action_storage_make()
	defer ui.action_storage_destroy(&s.actions)
	defer free_all(context.temp_allocator)
	press :: proc(app: ^App_State, s: ^ui.State, key: platform.Key, mods: ui.Modifiers = {}, repeat := false, modal := false) -> Command_Row {
		clear(&app.commands.pending.rows)
		ui.action_storage_clear(&s.actions)
		app.preview.workspace.lister.panel = 1 if modal else 0
		key_route(app, s, {key_press(key, mods, repeat)})
		app.preview.workspace.lister.panel = 0
		batch := &app.commands.pending
		return command_row_of(batch, batch.rows[0]) if len(batch.rows) == 1 else {}
	}
	event :: proc(s: ^ui.State) -> ui.Action_Row {return s.actions.rows[0] if len(s.actions.rows) == 1 else {}}
	testing.expect_value(t, press(&app, &s, .J).kind, Command_Kind.Frame_Step)
	testing.expect_value(t, press(&app, &s, .J).regs.count, -1)
	testing.expect_value(t, press(&app, &s, .J, {.Shift}).kind, Command_Kind.Frame_Start)
	testing.expect_value(t, press(&app, &s, .Zero, {.Control}).kind, Command_Kind.Timeline_Fit)
	testing.expect_value(t, press(&app, &s, .S, {.Shift}).regs.count, -1)
	testing.expect_value(t, press(&app, &s, .O, {.Control}).kind, Command_Kind.File_Dialog)
	testing.expect_value(t, press(&app, &s, .Q, {.Control}).kind, Command_Kind.None)
	testing.expect_value(t, press(&app, &s, .D).regs.spec, "video:problems")
	testing.expect_value(t, press(&app, &s, .I).regs.spec, "video:media")
	// Ctrl+P runs Go_To as RAD's RunCommand: without its frame, its query
	// asks for it (the lister on the command's query).
	go_to := press(&app, &s, .P, {.Control})
	testing.expect(t, go_to.kind == .Lister_Open && go_to.regs.lister == .Query && go_to.regs.command == .Go_To)
	testing.expect_value(t, press(&app, &s, .N).kind, Command_Kind.Problem_Step)
	testing.expect_value(t, press(&app, &s, .N, {.Shift}).regs.count, -1)
	// Exactly its modifiers: Control+Shift+O is no row's.
	testing.expect_value(t, press(&app, &s, .O, {.Control, .Shift}).kind, Command_Kind.None)
	// The window's font size: Alt+= and Alt+- (= alone zooms the timeline);
	// held, Alt+= repeats the font size alone.
	testing.expect_value(t, press(&app, &s, .Equal, {.Alt}).kind, Command_Kind.Font_Size_Increase)
	testing.expect_value(t, press(&app, &s, .Minus, {.Alt}).kind, Command_Kind.Font_Size_Decrease)
	testing.expect_value(t, press(&app, &s, .Equal).kind, Command_Kind.Timeline_Zoom)
	for _ in 0 ..< 3 do testing.expect_value(t, press(&app, &s, .Equal, {.Alt}, repeat = true).kind, Command_Kind.Font_Size_Increase)
	// RAD's toggle_fullscreen.
	testing.expect_value(t, press(&app, &s, .Enter, {.Control}).kind, Command_Kind.Fullscreen_Toggle)
	// RAD's UI commands push their events, no command.
	testing.expect_value(t, press(&app, &s, .Left).kind, Command_Kind.None)
	testing.expect(t, event(&s).kind == .Navigate && event(&s).delta == {-1, 0} && event(&s).delta_unit == .Char)
	press(&app, &s, .Left, {.Shift})
	testing.expect(t, event(&s).delta == {-1, 0} && .Keep_Mark in event(&s).flags)
	press(&app, &s, .Right, {.Control})
	testing.expect(t, event(&s).delta == {1, 0} && event(&s).delta_unit == .Word)
	press(&app, &s, .Page_Down)
	testing.expect(t, event(&s).delta == {0, 1} && event(&s).delta_unit == .Page)
	press(&app, &s, .Home)
	testing.expect(t, event(&s).delta == {-1, 0} && event(&s).delta_unit == .Line)
	press(&app, &s, .Delete)
	testing.expect(t, event(&s).kind == .Edit && event(&s).delta == {1, 0} && .Delete in event(&s).flags)
	press(&app, &s, .Backspace, repeat = true) // held: it repeats
	testing.expect(t, event(&s).kind == .Edit && event(&s).delta == {-1, 0})
	press(&app, &s, .Enter)
	testing.expect(t, ui.action_pressed(&s, .Accept))
	testing.expect_value(t, press(&app, &s, .Space).kind, Command_Kind.None) // RAD's: Space accepts
	testing.expect(t, ui.action_pressed(&s, .Accept))
	press(&app, &s, .Escape)
	testing.expect(t, ui.action_pressed(&s, .Cancel))
	press(&app, &s, .Up, {.Alt})
	testing.expect(t, event(&s).delta == {0, -1} && .Reorder in event(&s).flags)
	// Ctrl+P opens the lister on Go_To's query; while it is up, only the
	// UI's keys (and `modal` rows) run, Search dropped (the lister has the keys).
	testing.expect_value(t, press(&app, &s, .P, {.Control}).kind, Command_Kind.Lister_Open)
	testing.expect_value(t, press(&app, &s, .P, {.Control}).regs.lister, Lister_Mode.Query)
	testing.expect_value(t, press(&app, &s, .O, {.Control}, modal = true).kind, Command_Kind.None)
	press(&app, &s, .Down, modal = true)
	testing.expect_value(t, event(&s).delta, [2]i32{0, 1})
	// The video alone (--bare): Escape quits, its own row (BARE_KEYS).
	app.preview.bare = true
	testing.expect_value(t, press(&app, &s, .Escape).kind, Command_Kind.Quit)
	app.preview.bare = false
	testing.expect_value(t, press(&app, &s, .Escape).kind, Command_Kind.None)
}

// RAD's text hotkeys: while a field edits (the UI's text_edit_mode, from
// last frame), a key that types a character types it instead of running
// its row; otherwise its row runs and eats the character it typed (RAD's
// wm_text). What is left of the typing is insert_text, a character a row.
@(test)
test_key_route_types_while_editing :: proc(t: ^testing.T) {
	app: App_State
	app.commands = command_storage_make()
	defer command_storage_destroy(&app.commands)
	s: ui.State
	s.actions = ui.action_storage_make()
	defer ui.action_storage_destroy(&s.actions)
	defer free_all(context.temp_allocator)
	typed :: proc(key: platform.Key, text: string) -> []platform.Event {
		out := make([dynamic]platform.Event, context.temp_allocator)
		append(&out, key_press(key))
		append(&out, ..text_events(text))
		return out[:]
	}
	key_route(&app, &s, typed(.R, "rλ"))
	testing.expect_value(t, len(app.commands.pending.rows), 1) // R reloads
	testing.expect(t, len(s.actions.rows) == 1 && s.actions.rows[0].kind == .Text && s.actions.rows[0].text == "λ")
	clear(&app.commands.pending.rows)
	ui.action_storage_clear(&s.actions)
	s.text_edit_mode = true
	key_route(&app, &s, typed(.R, "r"))
	testing.expect_value(t, len(app.commands.pending.rows), 0)
	testing.expect(t, len(s.actions.rows) == 1 && s.actions.rows[0].text == "r")
	testing.expect(t, !s.text_edit_mode) // read and cleared
	// Space while editing types a space and accepts nothing.
	ui.action_storage_clear(&s.actions)
	s.text_edit_mode = true
	key_route(&app, &s, typed(.Space, " "))
	testing.expect(t, len(s.actions.rows) == 1 && s.actions.rows[0].kind == .Text && s.actions.rows[0].text == " ")
	testing.expect(t, !ui.action_pressed(&s, .Accept))
	// Enter in a single-line field still accepts, its newline eaten; in a
	// multi-line one it types the newline.
	ui.action_storage_clear(&s.actions)
	s.text_edit_mode = true
	key_route(&app, &s, typed(.Enter, "\n"))
	testing.expect(t, len(s.actions.rows) == 1 && ui.action_pressed(&s, .Accept))
	ui.action_storage_clear(&s.actions)
	s.text_edit_mode, s.text_edit_mode_multiline = true, true
	key_route(&app, &s, typed(.Enter, "\n"))
	testing.expect(t, len(s.actions.rows) == 1 && s.actions.rows[0].text == "\n")
}

// Search (Ctrl+F) is a UI kind: it runs at once, giving the focused panel's
// Watch's filter row the keys; with the video's panel focused it does
// nothing.
@(test)
test_search_focuses_the_focused_watch_filter :: proc(t: ^testing.T) {
	app: App_State
	app.commands = command_storage_make()
	defer command_storage_destroy(&app.commands)
	pv := &app.preview
	defer preview_state_destroy(pv)
	workspace_init(&pv.workspace)
	s: ui.State
	ctrl_f := []platform.Event{key_press(.F, {.Control})}
	key_route(&app, &s, ctrl_f)
	testing.expect_value(t, len(app.commands.pending.rows), 0)
	testing.expect_value(t, len(pv.view_filters), 0)
	watch_show(&app, tab_of(.Cues))
	watch := workspace_find_watch(&pv.workspace, tab_of(.Cues))
	key_route(&app, &s, ctrl_f)
	testing.expect(t, view_filter_field(pv, watch).focused)
	testing.expect_value(t, len(app.commands.pending.rows), 0)
	// With the lister up, Search is dropped.
	view_filter_field(pv, watch).focused = false
	pv.workspace.lister.panel = 1
	key_route(&app, &s, ctrl_f)
	testing.expect(t, !view_filter_field(pv, watch).focused)
	pv.workspace.lister.panel = 0
}
