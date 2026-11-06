package onimite_app

import "core:reflect"
import "core:strings"
import "core:unicode/utf8"
import platform "../platform"
import ui "../ui"

// The preview's keys, as RAD Debugger routes them: each key pressed (or
// repeated) runs its first matching row here; a row's command is the
// preview's (pushed, applied after the frame) or the UI's (COMMAND_KINDS'
// .Ui domain: run at once, before the build, into a UI event or the UI's
// state). The keys that move and edit (the arrows, Home and End, Page Up and
// Down, Delete, Backspace, Enter, Space, Escape, Tab and their chords) are RAD's UI
// commands: their events go to the focused panel's view, and what no view
// takes the video and the timeline turn into the preview's commands
// (VIEW_EVENTS). The rest are fframes' Dock keys (lowercase letters plain,
// capitals with Shift) and the preview's own. A row matches, as RAD's
// bindings, each press of its key, repeats included, with exactly its
// modifiers held. While the lister is up, only the UI's rows match.

// A row: its key with exactly `mods` held (RAD's binding), its command.
Key_Binding :: struct {
	key:  platform.Key,
	mods: ui.Modifiers,
	kind: Command_Kind,
	regs: Command_Regs,
}

@(rodata)
PREVIEW_KEYS := [?]Key_Binding {
	{key = .O, mods = {.Control}, kind = .File_Dialog},
	{key = .J, mods = {.Shift}, kind = .Frame_Start},
	{key = .J, kind = .Frame_Step, regs = {count = -1}},
	{key = .K, kind = .Frame_Step, regs = {count = 1}},
	{key = .S, mods = {.Shift}, kind = .Scene_Step, regs = {count = -1}},
	{key = .S, kind = .Scene_Step, regs = {count = 1}},
	{key = .W, kind = .Scene_Step, regs = {count = 1}},
	{key = .B, kind = .Scene_Step, regs = {count = -1}},
	{key = .Zero, mods = {.Control}, kind = .Timeline_Fit},
	{key = .Zero, kind = .Frame_Start},
	{key = .G, mods = {.Shift}, kind = .Frame_Set, regs = {count = max(int)}},
	{key = .L, mods = {.Shift}, kind = .Loop_Toggle},
	{key = .L, kind = .Volume_Step, regs = {scalar = VOLUME_STEP}},
	{key = .H, mods = {.Control}, kind = .Mute_Toggle},
	{key = .H, kind = .Volume_Step, regs = {scalar = -VOLUME_STEP}},
	// The window's font size a point up or down (RAD's Alt+= and Alt+-).
	{key = .Equal, mods = {.Alt}, kind = .Font_Size_Increase},
	{key = .Minus, mods = {.Alt}, kind = .Font_Size_Decrease},
	// Zoom around the playhead (count -1).
	{key = .Equal, kind = .Timeline_Zoom, regs = {scalar = 1.5, count = -1}},
	{key = .Minus, kind = .Timeline_Zoom, regs = {scalar = 1 / 1.5, count = -1}},
	{key = .R, kind = .Script_Reload, regs = {flag = true}},
	{key = .D, kind = .Watch_Show, regs = {spec = "video:problems"}},
	{key = .N, mods = {.Shift}, kind = .Problem_Step, regs = {count = -1}},
	{key = .N, kind = .Problem_Step, regs = {count = 1}},
	{key = .M, kind = .Bookmark_Toggle},
	{key = .Left_Bracket, kind = .Mark_In},
	{key = .Right_Bracket, kind = .Mark_Out},
	{key = .P, kind = .Mark_Point},
	{key = .F, kind = .Fullscreen_Toggle},
	{key = .Enter, mods = {.Control}, kind = .Fullscreen_Toggle}, // RAD's toggle_fullscreen
	{key = .T, kind = .Timeline_Toggle},
	{key = .Z, kind = .Picture_Fit},
	{key = .I, kind = .Watch_Show, regs = {spec = "video:media"}},
	{key = .P, mods = {.Control}, kind = .Go_To}, // its query asks where (command_run)
	{key = .W, mods = {.Control}, kind = .View_Close}, // RAD's close_tab: the focused panel's shown tab
	{key = .F, mods = {.Control}, kind = .Search},
	{key = .Slash, kind = .Search}, // RAD's binding; it types itself while a field has the keys
	{key = .Q, kind = .Quit},
	// RAD's UI commands (RD_DefaultBindingTable).
	{key = .Enter, kind = .Accept},
	{key = .Space, kind = .Accept},
	{key = .Escape, kind = .Cancel},
	{key = .Left, kind = .Move_Left},
	{key = .Right, kind = .Move_Right},
	{key = .Up, kind = .Move_Up},
	{key = .Down, kind = .Move_Down},
	{key = .Left, mods = {.Shift}, kind = .Move_Left_Select},
	{key = .Right, mods = {.Shift}, kind = .Move_Right_Select},
	{key = .Up, mods = {.Shift}, kind = .Move_Up_Select},
	{key = .Down, mods = {.Shift}, kind = .Move_Down_Select},
	{key = .Left, mods = {.Control}, kind = .Move_Left_Chunk},
	{key = .Right, mods = {.Control}, kind = .Move_Right_Chunk},
	{key = .Up, mods = {.Control}, kind = .Move_Up_Chunk},
	{key = .Down, mods = {.Control}, kind = .Move_Down_Chunk},
	{key = .Page_Up, kind = .Move_Up_Page},
	{key = .Page_Down, kind = .Move_Down_Page},
	{key = .Home, mods = {.Control}, kind = .Move_Up_Whole},
	{key = .End, mods = {.Control}, kind = .Move_Down_Whole},
	{key = .Left, mods = {.Control, .Shift}, kind = .Move_Left_Chunk_Select},
	{key = .Right, mods = {.Control, .Shift}, kind = .Move_Right_Chunk_Select},
	{key = .Up, mods = {.Control, .Shift}, kind = .Move_Up_Chunk_Select},
	{key = .Down, mods = {.Control, .Shift}, kind = .Move_Down_Chunk_Select},
	{key = .Page_Up, mods = {.Shift}, kind = .Move_Up_Page_Select},
	{key = .Page_Down, mods = {.Shift}, kind = .Move_Down_Page_Select},
	{key = .Home, mods = {.Control, .Shift}, kind = .Move_Up_Whole_Select},
	{key = .End, mods = {.Control, .Shift}, kind = .Move_Down_Whole_Select},
	{key = .Up, mods = {.Alt}, kind = .Move_Up_Reorder},
	{key = .Down, mods = {.Alt}, kind = .Move_Down_Reorder},
	{key = .Home, kind = .Move_Home},
	{key = .End, kind = .Move_End},
	{key = .Home, mods = {.Shift}, kind = .Move_Home_Select},
	{key = .End, mods = {.Shift}, kind = .Move_End_Select},
	{key = .A, mods = {.Control}, kind = .Select_All},
	{key = .Delete, kind = .Delete_Single},
	{key = .Delete, mods = {.Control}, kind = .Delete_Chunk},
	{key = .Backspace, kind = .Backspace_Single},
	{key = .Backspace, mods = {.Control}, kind = .Backspace_Chunk},
	{key = .C, mods = {.Control}, kind = .Copy},
	{key = .Insert, mods = {.Control}, kind = .Copy},
	{key = .X, mods = {.Control}, kind = .Cut},
	{key = .V, mods = {.Control}, kind = .Paste},
	{key = .Insert, mods = {.Shift}, kind = .Paste},
	{key = .Tab, kind = .Move_Next},
	{key = .Tab, mods = {.Shift}, kind = .Move_Prev},
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
	{key = .Escape, kind = .Quit},
}

// The video alone's (--bare), before the preview's: Escape closes it.
@(rodata)
BARE_KEYS := [?]Key_Binding {
	{key = .Escape, kind = .Quit},
}

// A live board's (--live): nothing a passer-by can press by accident.
@(rodata)
LIVE_KEYS := [?]Key_Binding {
	{key = .Q, mods = {.Control}, kind = .Quit},
}

// A key press event (the platform's), for the drives and the tests: `key`
// with exactly `mods` held.
key_press :: proc(key: platform.Key, mods: ui.Modifiers = {}, repeat := false) -> platform.Event {
	return {kind = .Key_Press, key = key, modifiers = mods, repeat = repeat}
}

// The characters of `typed` as Text events, for the drives and the tests.
text_events :: proc(typed: string) -> []platform.Event {
	out := make([dynamic]platform.Event, context.temp_allocator)
	for r in typed do append(&out, platform.Event{kind = .Text, character = r})
	return out[:]
}

// The frame's events, before the build (as RAD's frame takes the window's
// events before ui_begin_build): key_route over all of them, in order.
preview_key_input :: proc(app: ^App_State, s: ^ui.State, p: ^platform.Platform) {
	ui.action_storage_clear(&s.actions)
	key_route(app, s, platform.events(p))
}

// The events' one route, as RAD Debugger's frame, in the order they came: a
// pointer event becomes the UI's row as it is (ui.action_push_event); a
// key's press, repeats included, runs the first row of its key with exactly
// its modifiers (key_binding_run), unless it types a character while text
// is edited (RAD's allow_text_hotkeys; Enter while no multi-line text is:
// the UI's text_edit_mode from last frame, read and cleared here), and a
// row run eats the character its key typed (RAD's wm_text); a character
// left is insert_text ('\n' only while multi-line text is edited).
key_route :: proc(app: ^App_State, s: ^ui.State, events: []platform.Event) {
	editing, multi_line := s.text_edit_mode, s.text_edit_mode_multiline
	s.text_edit_mode, s.text_edit_mode_multiline = false, false
	eaten := make([]bool, len(events), context.temp_allocator)
	for e, i in events {
		if eaten[i] || ui.action_push_event(&s.actions, e) do continue
		#partial switch e.kind {
		case .Key_Press:
			character := key_character(e.key, e.modifiers)
			if character != 0 && editing && (character != '\n' || multi_line) do continue
			if !key_binding_run(app, s, e) || character == 0 do continue
			for j in i + 1 ..< len(events) {
				if !eaten[j] && events[j].kind == .Text && events[j].character == character {eaten[j] = true; break}
			}
		case .Text:
			if e.character == '\n' && !multi_line do continue
			buf, n := utf8.encode_rune(e.character)
			key_event(s, .Insert_Text, strings.clone(string(buf[:n]), context.temp_allocator)) // the row outlives this loop
		}
	}
}

// Runs the first row of the mode's tables for a key press: its key with
// exactly its modifiers (RAD's binding); while the lister is up only the
// UI's rows. A preview command runs as RAD's RunCommand (command_run: one
// with a query asks for its operand). False when none ran.
key_binding_run :: proc(app: ^App_State, s: ^ui.State, e: platform.Event) -> bool {
	modal := app.preview.workspace.lister.panel != 0
	tables := [2][]Key_Binding{{}, PREVIEW_KEYS[:]}
	switch {
	case app.preview.live:
		tables = {{}, LIVE_KEYS[:]}
	case app.preview.present:
		tables = {{}, PRESENT_KEYS[:]}
	case app.preview.bare:
		tables = {BARE_KEYS[:], PREVIEW_KEYS[:]}
	}
	for keys in tables {
		for b in keys {
			ui_kind := COMMAND_KINDS[b.kind].domain == .Ui
			if b.key != e.key || b.mods != e.modifiers || !(ui_kind || !modal) do continue
			if ui_kind {
				ui_command(app, s, b.kind, b.regs)
			} else {
				command_run(app, b.kind, b.regs)
			}
			return true
		}
	}
	return false
}

// The character a key types with its modifiers, 0 for none: RAD's
// wm_codepoint_from_modifiers_and_key, over the keys the platform has.
key_character :: proc(key: platform.Key, mods: ui.Modifiers) -> rune {
	if mods & {.Control, .Alt} != {} do return 0
	shift := .Shift in mods
	#partial switch key {
	case .A ..= .Z:
		name := reflect.enum_string(key)
		return rune(shift ? name[0] : name[0] + ('a' - 'A'))
	case .Zero ..= .Nine:
		shifted := [10]rune{')', '!', '@', '#', '$', '%', '^', '&', '*', '('}
		i := int(key) - int(platform.Key.Zero)
		return shift ? shifted[i] : rune('0' + i)
	case .Space:
		return ' '
	case .Enter:
		return shift ? 0 : '\n'
	case .Comma:
		return shift ? '<' : ','
	case .Period:
		return shift ? '>' : '.'
	case .Minus:
		return shift ? '_' : '-'
	case .Equal:
		return shift ? '+' : '='
	case .Left_Bracket:
		return shift ? '{' : '['
	case .Right_Bracket:
		return shift ? '}' : ']'
	case .Semicolon:
		return shift ? ':' : ';'
	case .Apostrophe:
		return shift ? '"' : '\''
	case .Slash:
		return shift ? '?' : '/'
	}
	return 0
}

// A UI kind run, as RAD Debugger's frame runs one: Search toggles the focused
// panel's view's filter row, opening it with its old text selected and the
// keys (RAD's PushQuery for search, raddbg_core.c:16603-16624); the rest push
// their UI event (key_event).
ui_command :: proc(app: ^App_State, s: ^ui.State, kind: Command_Kind, regs: Command_Regs) {
	if kind == .Search {
		// With the lister up its focus has the keys: Search is dropped.
		ws := &app.preview.workspace
		if ws.lister.panel != 0 do return
		if p := workspace_panel(ws, ws.focused); p != nil && p.shown != 0 && view_filters(app, p.shown) {
			f := view_filter_field(&app.preview, p.shown)
			if !f.open {
				clear(&f.text); append(&f.text, string(workspace_view(ws, p.shown).filter[:]))
				f.cursor, f.mark = len(f.text), 0
			}
			f.open = !f.open
			f.focused = f.open
		}
		return
	}
	key_event(s, kind, regs.spec)
}

// A UI kind's event, as RAD Debugger's frame turns its commands into UI
// events: the kind, flags, unit and delta a field, a list or a view takes.
// Paste carries the clipboard; insert_text its text.
key_event :: proc(s: ^ui.State, kind: Command_Kind, text: string) {
	row :: proc(kind: ui.Action_Kind, flags: ui.Action_Flags, unit: ui.Action_Delta_Unit, delta: [2]i32) -> ui.Action_Row {
		return {kind = kind, flags = flags, delta_unit = unit, delta = delta}
	}
	e: ui.Action_Row
	#partial switch kind {
	case .Accept:
		e = {kind = .Press, slot = .Accept}
	case .Cancel:
		e = {kind = .Press, slot = .Cancel}
	case .Move_Left:
		e = row(.Navigate, {.Pick_Select_Side, .Zero_Delta_On_Select, .Explicit_Directional}, .Char, {-1, 0})
	case .Move_Right:
		e = row(.Navigate, {.Pick_Select_Side, .Zero_Delta_On_Select, .Explicit_Directional}, .Char, {1, 0})
	case .Move_Up:
		e = row(.Navigate, {.Explicit_Directional, .Secondary}, .Char, {0, -1})
	case .Move_Down:
		e = row(.Navigate, {.Explicit_Directional, .Secondary}, .Char, {0, 1})
	case .Move_Left_Select:
		e = row(.Navigate, {.Keep_Mark, .Explicit_Directional}, .Char, {-1, 0})
	case .Move_Right_Select:
		e = row(.Navigate, {.Keep_Mark, .Explicit_Directional}, .Char, {1, 0})
	case .Move_Up_Select:
		e = row(.Navigate, {.Keep_Mark, .Explicit_Directional, .Secondary}, .Char, {0, -1})
	case .Move_Down_Select:
		e = row(.Navigate, {.Keep_Mark, .Explicit_Directional, .Secondary}, .Char, {0, 1})
	case .Move_Left_Chunk:
		e = row(.Navigate, {.Explicit_Directional}, .Word, {-1, 0})
	case .Move_Right_Chunk:
		e = row(.Navigate, {.Explicit_Directional}, .Word, {1, 0})
	case .Move_Up_Chunk:
		e = row(.Navigate, {.Explicit_Directional, .Secondary}, .Word, {0, -1})
	case .Move_Down_Chunk:
		e = row(.Navigate, {.Explicit_Directional, .Secondary}, .Word, {0, 1})
	case .Move_Up_Page:
		e = row(.Navigate, {.Secondary}, .Page, {0, -1})
	case .Move_Down_Page:
		e = row(.Navigate, {.Secondary}, .Page, {0, 1})
	case .Move_Up_Whole:
		e = row(.Navigate, {.Secondary}, .Whole, {0, -1})
	case .Move_Down_Whole:
		e = row(.Navigate, {.Secondary}, .Whole, {0, 1})
	case .Move_Left_Chunk_Select:
		e = row(.Navigate, {.Keep_Mark, .Explicit_Directional}, .Word, {-1, 0})
	case .Move_Right_Chunk_Select:
		e = row(.Navigate, {.Keep_Mark, .Explicit_Directional}, .Word, {1, 0})
	case .Move_Up_Chunk_Select:
		e = row(.Navigate, {.Keep_Mark, .Explicit_Directional}, .Word, {0, -1})
	case .Move_Down_Chunk_Select:
		e = row(.Navigate, {.Keep_Mark, .Explicit_Directional}, .Word, {0, 1})
	case .Move_Up_Page_Select:
		e = row(.Navigate, {.Keep_Mark}, .Page, {0, -1})
	case .Move_Down_Page_Select:
		e = row(.Navigate, {.Keep_Mark}, .Page, {0, 1})
	case .Move_Up_Whole_Select:
		e = row(.Navigate, {.Keep_Mark}, .Whole, {0, -1})
	case .Move_Down_Whole_Select:
		e = row(.Navigate, {.Keep_Mark}, .Whole, {0, 1})
	case .Move_Up_Reorder:
		e = row(.Navigate, {.Reorder}, .Char, {0, -1})
	case .Move_Down_Reorder:
		e = row(.Navigate, {.Reorder}, .Char, {0, 1})
	case .Move_Home:
		e = row(.Navigate, {}, .Line, {-1, 0})
	case .Move_End:
		e = row(.Navigate, {}, .Line, {1, 0})
	case .Move_Home_Select:
		e = row(.Navigate, {.Keep_Mark}, .Line, {-1, 0})
	case .Move_End_Select:
		e = row(.Navigate, {.Keep_Mark}, .Line, {1, 0})
	case .Select_All:
		append(&s.actions.rows, row(.Navigate, {}, .Whole, {-1, 0}))
		e = row(.Navigate, {.Keep_Mark}, .Whole, {1, 0})
	case .Delete_Single:
		e = row(.Edit, {.Delete, .Zero_Delta_On_Select}, .Char, {1, 0})
	case .Delete_Chunk:
		e = row(.Edit, {.Delete, .Zero_Delta_On_Select}, .Word, {1, 0})
	case .Backspace_Single:
		e = row(.Edit, {.Delete, .Zero_Delta_On_Select}, .Char, {-1, 0})
	case .Backspace_Chunk:
		e = row(.Edit, {.Delete, .Zero_Delta_On_Select}, .Word, {-1, 0})
	case .Copy:
		e = {kind = .Edit, flags = {.Copy, .Keep_Mark}}
	case .Cut:
		e = {kind = .Edit, flags = {.Copy, .Delete}}
	case .Paste:
		e = {kind = .Text, flags = {.Paste}, text = platform.clipboard()}
	case .Insert_Text:
		e = {kind = .Text, text = text}
	case .Move_Next:
		e = row(.Navigate, {.Secondary}, .Char, {0, 1})
	case .Move_Prev:
		e = row(.Navigate, {.Secondary}, .Char, {0, -1})
	case:
		return
	}
	append(&s.actions.rows, e)
}

// What the video and the timeline do with the keys' UI events no box in
// them took, while their panel is focused (RAD's views consume the events
// their focus gets): an event of `kind` (a press: for `slot`) stepping `unit`
// along `axis` (0 across, 1 down) toward `sign`, with the flags `with` and
// none of `without`, pushes `row`. The fframes keys' meanings: play / pause,
// a frame, a second, the ends, the volume, mute, a scene, a mark's removal.
View_Event :: struct {
	kind:          ui.Action_Kind,
	slot:          ui.Action_Slot,
	unit:          ui.Action_Delta_Unit,
	axis:          int,
	sign:          i32,
	with, without: ui.Action_Flags,
	row:           Command_Row,
}

@(rodata)
VIEW_EVENTS := [?]View_Event {
	{.Press, .Accept, .Null, 0, 0, {}, {}, {.Playback_Toggle, {}}},
	{.Navigate, .Null, .Char, 0, -1, {}, {.Keep_Mark, .Reorder}, {.Frame_Step, {count = -1}}},
	{.Navigate, .Null, .Char, 0, 1, {}, {.Keep_Mark, .Reorder}, {.Frame_Step, {count = 1}}},
	{.Navigate, .Null, .Char, 0, -1, {.Keep_Mark}, {}, {.Frame_Start, {}}},
	{.Navigate, .Null, .Char, 0, 1, {.Keep_Mark}, {}, {.Frame_Set, {count = max(int)}}},
	{.Navigate, .Null, .Word, 0, -1, {}, {}, {.Seconds_Step, {scalar = -1}}},
	{.Navigate, .Null, .Word, 0, 1, {}, {}, {.Seconds_Step, {scalar = 1}}},
	{.Navigate, .Null, .Line, 0, -1, {}, {}, {.Frame_Start, {}}},
	{.Navigate, .Null, .Line, 0, 1, {}, {}, {.Frame_Set, {count = max(int)}}},
	{.Navigate, .Null, .Whole, 1, -1, {}, {}, {.Frame_Start, {}}},
	{.Navigate, .Null, .Whole, 1, 1, {}, {}, {.Frame_Set, {count = max(int)}}},
	{.Navigate, .Null, .Char, 1, -1, {.Explicit_Directional}, {.Reorder}, {.Volume_Step, {scalar = VOLUME_STEP}}},
	{.Navigate, .Null, .Char, 1, 1, {.Explicit_Directional}, {.Reorder}, {.Volume_Step, {scalar = -VOLUME_STEP}}},
	{.Navigate, .Null, .Word, 1, -1, {}, {}, {.Volume_Step, {scalar = VOLUME_STEP}}},
	{.Navigate, .Null, .Word, 1, 1, {}, {}, {.Mute_Toggle, {}}},
	{.Navigate, .Null, .Page, 1, -1, {}, {}, {.Scene_Step, {count = -1}}},
	{.Navigate, .Null, .Page, 1, 1, {}, {}, {.Scene_Step, {count = 1}}},
	{.Edit, .Null, .Char, 0, -1, {.Delete}, {}, {.Mark_Delete, {}}},
	{.Edit, .Null, .Char, 0, 1, {.Delete}, {}, {.Mark_Delete, {}}},
	{.Edit, .Null, .Word, 0, -1, {.Delete}, {}, {.Mark_Delete, {}}},
	{.Edit, .Null, .Word, 0, 1, {.Delete}, {}, {.Mark_Delete, {}}},
}

// The UI events a view whose focus is active takes as the preview's
// commands (VIEW_EVENTS), the first row each matches.
view_events_take :: proc(app: ^App_State, s: ^ui.State) {
	if !ui.is_focus_active(s) do return
	for &a in s.actions.rows {
		if a.consumed do continue
		for e in VIEW_EVENTS {
			step := a.delta[e.axis]
			if a.kind != e.kind || a.slot != e.slot || a.delta_unit != e.unit || a.delta[1 - e.axis] != 0 || (step > 0 ? 1 : step < 0 ? -1 : 0) != e.sign || a.flags & e.with != e.with || a.flags & e.without != {} do continue
			a.consumed = true
			command_push(&app.commands, e.row.kind, e.row.regs)
			break
		}
	}
}
