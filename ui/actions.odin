package ui

import platform "../platform"

// A frame's input as RAD Debugger's UI events (UI_Event), one row per OS
// event in the order they came: the mouse's buttons and the wheel straight
// from the platform's events (action_push_event), the keys' and the typed
// text's through the app's bindings first (onimite's app/preview_keys.odin),
// as RAD's frame turns window events into UI events. Boxes and views take
// the rows they are for, so nothing fires twice.
Action_Kind :: enum u8 {
	Null,
	Press,
	Text,
	Navigate,
	Edit,
	Scroll,
	// A mouse button going down or up at `position`, taken by the one box
	// it is for (signal_from_box), as RAD Debugger's press and release events.
	Mouse_Press,
	Mouse_Release,
}
// What a press is for (RAD's UI_EventActionSlot).
Action_Slot :: enum u8 {
	Null,
	Accept,
	Cancel,
}
// How a Navigate, Edit or Text row edits text (RAD's UI_EventFlags; see
// text_op_from_action).
Action_Flag :: enum u8 {
	Keep_Mark, // the mark stays: the move extends the selection
	Delete, // what the move spans (or the selection) is removed
	Copy, // the selection goes to the clipboard
	Paste, // the text is the clipboard's
	Zero_Delta_On_Select, // with a selection, the move only collapses it
	Pick_Select_Side, // with a selection, the move collapses it to the side it goes
	Cap_At_Line,
	Explicit_Directional,
	Reorder,
	Secondary, // a step through a list rather than a move in text (Tab)
}
Action_Flags :: bit_set[Action_Flag;u16]
// The modifiers held with an input row (RAD's event modifiers): the
// platform's event's.
Modifier :: platform.Modifier
Modifiers :: platform.Modifiers
// What a delta counts (RAD's UI_EventDeltaUnit).
Action_Delta_Unit :: enum u8 {
	Null,
	Char,
	Word,
	Line,
	Page,
	Whole,
}

Action_Row :: struct {
	kind:         Action_Kind,
	slot:         Action_Slot,
	flags:        Action_Flags,
	delta_unit:   Action_Delta_Unit,
	delta:        [2]i32,
	text:         string, // Text: what it inserts, frame-lived
	position:     [2]f32,
	scroll_delta: [2]f32, // Scroll: RAD's units (120 a notch), right and down positive
	button:       platform.Mouse_Button, // Mouse_Press, Mouse_Release
	modifiers:    Modifiers, // held with it
	consumed:     bool,
}

Action_Storage :: struct {
	rows: [dynamic]Action_Row,
}

action_storage_make :: proc() -> Action_Storage {
	return {rows = make([dynamic]Action_Row)}
}

action_storage_destroy :: proc(storage: ^Action_Storage) {
	delete(storage.rows)
	storage^ = {}
}

action_storage_clear :: proc(storage: ^Action_Storage) {
	clear(&storage.rows)
}

// A pointer event's row, at its own position with its modifiers, as RAD
// turns a window event into a UI event: a mouse button's press or release,
// or the wheel. False for a key's or a character's (the app's bindings
// route those).
action_push_event :: proc(storage: ^Action_Storage, e: platform.Event) -> bool {
	#partial switch e.kind {
	case .Mouse_Press:
		append(&storage.rows, Action_Row{kind = .Mouse_Press, button = e.button, position = e.position, modifiers = e.modifiers})
	case .Mouse_Release:
		append(&storage.rows, Action_Row{kind = .Mouse_Release, button = e.button, position = e.position, modifiers = e.modifiers})
	case .Scroll:
		append(&storage.rows, Action_Row{kind = .Scroll, position = e.position, scroll_delta = e.delta, modifiers = e.modifiers})
	case:
		return false
	}
	return true
}

// RAD's steps of a wheel event (ui_signal_from_box): its delta over 40,
// toward zero, at least one either way; a notch is NOTCH_STEPS.
NOTCH_STEPS :: platform.WHEEL_NOTCH / 40
scroll_steps :: proc(delta: [2]f32) -> (steps: [2]f32) {
	for v, i in delta {
		steps[i] = f32(i16(v / 40))
		if v > 0 && steps[i] == 0 do steps[i] = 1
		if v < 0 && steps[i] == 0 do steps[i] = -1
	}
	return
}

action_pressed :: proc(s: ^State, slot: Action_Slot) -> bool {
	for index in 0 ..< len(s.actions.rows) {
		action := &s.actions.rows[index]
		if !action.consumed && action.kind == .Press && action.slot == slot {
			action.consumed = true
			return true
		}
	}
	return false
}

// The wheel's vertical steps (scroll_steps, down positive) with exactly
// `modifiers` held, taken (as RAD's window takes what scroll events with
// Control are left, and a hovered view takes those with Control in them:
// `any`).
action_scroll_take :: proc(s: ^State, modifiers: Modifiers, any := false) -> f32 {
	result: f32
	for &action in s.actions.rows {
		if action.consumed || action.kind != .Scroll do continue
		if any ? action.modifiers & modifiers != modifiers : action.modifiers != modifiers do continue
		action.consumed = true
		result += scroll_steps(action.scroll_delta).y
	}
	return result
}

action_navigation_delta :: proc(s: ^State) -> [2]i32 {
	result: [2]i32
	for index in 0 ..< len(s.actions.rows) {
		action := &s.actions.rows[index]
		if !action.consumed && action.kind == .Navigate {
			action.consumed = true
			result += action.delta
		}
	}
	return result
}

box_is_default_nav_root :: proc(box: ^Box) -> bool {
	return box != nil && (.Default_Focus_Nav_X in box.flags || .Default_Focus_Nav_Y in box.flags)
}

default_nav_root_from_box :: proc(box: ^Box) -> ^Box {
	for ancestor := box.parent; ancestor != nil; ancestor = ancestor.parent {
		if box_is_default_nav_root(ancestor) {
			return ancestor
		}
	}
	return nil
}
