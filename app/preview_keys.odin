package onimite_app

import platform "../platform"
import ui "../ui"

// The preview's keys: fframes' Dock keys (lowercase letters plain, capitals
// with Shift) plus its own, each the command row it pushes. A row matches
// when its key went down (`repeat`: or repeats while held) with Control and
// Shift as it says; the first matching row of a key wins. While the lister
// is up, only the rows marked `modal` match: the other keys are the
// lister's (typing, selecting, picking).

Key_Mod :: enum u8 {
	Any,
	Up,
	Down,
}

Key_Binding :: struct {
	key:    platform.Key,
	ctrl:   Key_Mod,
	shift:  Key_Mod,
	repeat: bool,
	modal:  bool,
	kind:   Command_Kind,
	regs:   Command_Regs,
}

@(rodata)
PREVIEW_KEYS := [?]Key_Binding {
	{key = .O, ctrl = .Down, kind = .File_Dialog},
	{key = .Space, ctrl = .Up, kind = .Playback_Toggle},
	{key = .Left, ctrl = .Down, repeat = true, kind = .Seconds_Step, regs = {scalar = -1}},
	{key = .Left, shift = .Down, repeat = true, kind = .Frame_Start},
	{key = .Left, repeat = true, kind = .Frame_Step, regs = {count = -1}},
	{key = .Right, ctrl = .Down, repeat = true, kind = .Seconds_Step, regs = {scalar = 1}},
	{key = .Right, shift = .Down, repeat = true, kind = .Frame_Set, regs = {count = max(int)}},
	{key = .Right, repeat = true, kind = .Frame_Step, regs = {count = 1}},
	{key = .J, ctrl = .Up, shift = .Down, repeat = true, kind = .Frame_Start},
	{key = .J, ctrl = .Up, repeat = true, kind = .Frame_Step, regs = {count = -1}},
	{key = .K, ctrl = .Up, repeat = true, kind = .Frame_Step, regs = {count = 1}},
	{key = .Page_Up, repeat = true, kind = .Scene_Step, regs = {count = -1}},
	{key = .Page_Down, repeat = true, kind = .Scene_Step, regs = {count = 1}},
	{key = .S, ctrl = .Up, shift = .Down, repeat = true, kind = .Scene_Step, regs = {count = -1}},
	{key = .S, ctrl = .Up, repeat = true, kind = .Scene_Step, regs = {count = 1}},
	{key = .W, ctrl = .Up, repeat = true, kind = .Scene_Step, regs = {count = 1}},
	{key = .B, ctrl = .Up, repeat = true, kind = .Scene_Step, regs = {count = -1}},
	{key = .Home, kind = .Frame_Start},
	{key = .Zero, ctrl = .Down, kind = .Timeline_Fit},
	{key = .Zero, kind = .Frame_Start},
	{key = .End, kind = .Frame_Set, regs = {count = max(int)}},
	{key = .G, ctrl = .Up, shift = .Down, kind = .Frame_Set, regs = {count = max(int)}},
	{key = .Up, repeat = true, kind = .Volume_Step, regs = {scalar = VOLUME_STEP}},
	{key = .Down, ctrl = .Down, repeat = true, kind = .Mute_Toggle},
	{key = .Down, repeat = true, kind = .Volume_Step, regs = {scalar = -VOLUME_STEP}},
	{key = .L, ctrl = .Up, shift = .Down, repeat = true, kind = .Loop_Toggle},
	{key = .L, ctrl = .Up, repeat = true, kind = .Volume_Step, regs = {scalar = VOLUME_STEP}},
	{key = .H, ctrl = .Down, repeat = true, kind = .Mute_Toggle},
	{key = .H, repeat = true, kind = .Volume_Step, regs = {scalar = -VOLUME_STEP}},
	// Zoom around the playhead (count -1).
	{key = .Equals, ctrl = .Up, repeat = true, kind = .Timeline_Zoom, regs = {scalar = 1.5, count = -1}},
	{key = .Minus, ctrl = .Up, repeat = true, kind = .Timeline_Zoom, regs = {scalar = 1 / 1.5, count = -1}},
	{key = .R, kind = .Script_Reload, regs = {flag = true}},
	{key = .D, ctrl = .Up, kind = .Watch_Show, regs = {section = .Problems}},
	{key = .N, ctrl = .Up, shift = .Down, repeat = true, kind = .Problem_Step, regs = {count = -1}},
	{key = .N, ctrl = .Up, repeat = true, kind = .Problem_Step, regs = {count = 1}},
	{key = .M, ctrl = .Up, kind = .Bookmark_Toggle},
	{key = .Left_Bracket, ctrl = .Up, kind = .Mark_In},
	{key = .Right_Bracket, ctrl = .Up, kind = .Mark_Out},
	{key = .P, ctrl = .Up, kind = .Mark_Point},
	{key = .Delete, kind = .Mark_Delete},
	{key = .Backspace, kind = .Mark_Delete},
	{key = .F, ctrl = .Up, kind = .Fullscreen_Toggle},
	{key = .T, ctrl = .Up, kind = .Timeline_Toggle},
	{key = .Z, ctrl = .Up, kind = .Video_Fit},
	{key = .I, ctrl = .Up, kind = .Watch_Show, regs = {section = .Media}},
	{key = .P, ctrl = .Down, kind = .Lister_Open, regs = {lister = .Go_To}},
	{key = .Q, ctrl = .Up, kind = .Quit},
	{key = .Escape, modal = true, kind = .Dismiss},
}

// A presentation's keys (--present), in place of the preview's: on and
// back as presentation clickers send them, black, pause.
@(rodata)
PRESENT_KEYS := [?]Key_Binding {
	{key = .Right, kind = .Present_Next},
	{key = .Space, kind = .Present_Next},
	{key = .Page_Down, kind = .Present_Next},
	{key = .Down, kind = .Present_Next},
	{key = .Enter, kind = .Present_Next},
	{key = .Left, kind = .Present_Previous},
	{key = .Page_Up, kind = .Present_Previous},
	{key = .Up, kind = .Present_Previous},
	{key = .Backspace, kind = .Present_Previous},
	{key = .B, kind = .Blackout_Toggle},
	{key = .P, kind = .Playback_Toggle},
	{key = .F, kind = .Fullscreen_Toggle},
	{key = .Q, kind = .Quit},
	{key = .Escape, modal = true, kind = .Dismiss},
}

// Pushes the rows of the keys that went down this window frame (the
// window's key actions); `modal`: the lister is up.
preview_keys :: proc(app: ^App_State, actions: []ui.Action_Row, modal: bool) {
	held :: proc(m: Key_Mod, down: bool) -> bool {
		return m == .Any || (m == .Down) == down
	}
	for &a in actions {
		if a.kind != .Key || a.consumed {
			continue
		}
		for b in (PRESENT_KEYS[:] if app.preview.present else PREVIEW_KEYS[:]) {
			if b.key == a.key && (b.modal || !modal) && (b.repeat || !a.repeat) && held(b.ctrl, a.control) && held(b.shift, a.shift) {
				command_push(&app.commands, b.kind, b.regs)
				a.consumed = true
				break
			}
		}
	}
}
