package onimite_app

import "core:testing"
import platform "../platform"
import ui "../ui"

// A key with Control and Shift as held picks its first matching row.
@(test)
test_preview_keys :: proc(t: ^testing.T) {
	app: App_State
	app.commands = command_storage_make()
	defer command_storage_destroy(&app.commands)
	press :: proc(app: ^App_State, key: platform.Key, shift := false, ctrl := false, repeat := false, modal := false) -> Command_Row {
		actions := []ui.Action_Row{{kind = .Key, key = key, shift = shift, control = ctrl, repeat = repeat}}
		clear(&app.commands.pending.rows)
		preview_keys(app, actions, modal)
		return app.commands.pending.rows[0].row if len(app.commands.pending.rows) == 1 else {}
	}
	testing.expect_value(t, press(&app, .Left).kind, Command_Kind.Frame_Step)
	testing.expect_value(t, press(&app, .Left).regs.count, -1)
	testing.expect_value(t, press(&app, .Left, shift = true).kind, Command_Kind.Frame_Start)
	testing.expect_value(t, press(&app, .Left, ctrl = true).kind, Command_Kind.Seconds_Step)
	testing.expect_value(t, press(&app, .Zero, ctrl = true).kind, Command_Kind.Timeline_Fit)
	testing.expect_value(t, press(&app, .S, shift = true).regs.count, -1)
	testing.expect_value(t, press(&app, .O, ctrl = true).kind, Command_Kind.File_Dialog)
	testing.expect_value(t, press(&app, .Q, ctrl = true).kind, Command_Kind.None)
	testing.expect_value(t, press(&app, .D).regs.section, Watch_Section.Problems)
	testing.expect_value(t, press(&app, .I).regs.section, Watch_Section.Media)
	testing.expect_value(t, press(&app, .N).kind, Command_Kind.Problem_Step)
	testing.expect_value(t, press(&app, .N, shift = true).regs.count, -1)
	testing.expect_value(t, press(&app, .Escape).kind, Command_Kind.Dismiss)
	// Held keys repeat only the rows that say so.
	testing.expect_value(t, press(&app, .Left, repeat = true).kind, Command_Kind.Frame_Step)
	testing.expect_value(t, press(&app, .Home, repeat = true).kind, Command_Kind.None)
	// Ctrl+P opens the lister on the places to go; while it is up, keys
	// are its own but Escape still dismisses it.
	testing.expect_value(t, press(&app, .P, ctrl = true).kind, Command_Kind.Lister_Open)
	testing.expect_value(t, press(&app, .P, ctrl = true).regs.lister, Lister_Mode.Go_To)
	testing.expect_value(t, press(&app, .Q, modal = true).kind, Command_Kind.None)
	testing.expect_value(t, press(&app, .Down, modal = true).kind, Command_Kind.None)
	testing.expect_value(t, press(&app, .Escape, modal = true).kind, Command_Kind.Dismiss)
}
