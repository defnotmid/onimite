package onimite_app

import "core:testing"
import platform "../platform"

// A key with Control and Shift as held picks its first matching row.
@(test)
test_preview_keys :: proc(t: ^testing.T) {
	app: App_State
	app.commands = command_storage_make()
	defer command_storage_destroy(&app.commands)
	press :: proc(app: ^App_State, key: platform.Key, shift := false, ctrl := false) -> Command_Row {
		p: platform.Platform
		p.input.key_hit[key] = true
		p.input.key_down[.LShift] = shift
		p.input.key_down[.LCtrl] = ctrl
		clear(&app.commands.rows)
		preview_keys(app, &p)
		return app.commands.rows[0] if len(app.commands.rows) == 1 else {}
	}
	testing.expect_value(t, press(&app, .Left).kind, Command_Kind.Frame_Step)
	testing.expect_value(t, press(&app, .Left).regs.count, -1)
	testing.expect_value(t, press(&app, .Left, shift = true).kind, Command_Kind.Frame_Start)
	testing.expect_value(t, press(&app, .Left, ctrl = true).kind, Command_Kind.Seconds_Step)
	testing.expect_value(t, press(&app, .Zero, ctrl = true).kind, Command_Kind.Timeline_Fit)
	testing.expect_value(t, press(&app, .S, shift = true).regs.count, -1)
	testing.expect_value(t, press(&app, .O, ctrl = true).kind, Command_Kind.File_Dialog)
	testing.expect_value(t, press(&app, .Q, ctrl = true).kind, Command_Kind.None)
}
