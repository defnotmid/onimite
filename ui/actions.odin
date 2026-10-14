// Ported from ../paf/ui (itself from odincade's sketch_and_extrude).
package ui

import platform "../platform"

Action_Kind :: enum u8 {
	Null,
	Key,
	Text,
	Scroll,
	Drop,
}

// The window's input this frame as rows, gathered once at build_begin:
// every consumer claims a row explicitly, so nested focus scopes cannot
// double-fire. Widgets take scrolls through `signal_from_box`, a focused
// text field its text and editing keys; the application takes the other
// keys and drops.
Action_Row :: struct {
	kind:         Action_Kind,
	// Key: the key that went down, or (`repeat`) is repeating while held.
	key:          platform.Key,
	repeat:       bool,
	// Text: one character typed (the window's text events are on while a
	// text field has focus).
	text:         rune,
	// Control and Shift as held (Scroll: Control only).
	control:      bool,
	shift:        bool,
	// Scroll: where, and by how much; `horizontal` (wheel x, touchpad),
	// right positive, is consumed apart from vertical scrolls.
	position:     [2]f32,
	scroll_delta: f32,
	horizontal:   bool,
	// Drop: a file dropped on the window or picked in the open-file dialog
	// (the platform's until the next tick).
	path:         string,
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

// Gather maps the platform's input this frame to action rows.
actions_gather_from_platform :: proc(storage: ^Action_Storage, p: ^platform.Platform) {
	action_storage_clear(storage)
	control, shift := platform.ctrl_down(p), platform.shift_down(p)
	for k in platform.Key {
		if platform.key_typed(p, k) {
			append(&storage.rows, Action_Row{kind = .Key, key = k, repeat = !platform.key_pressed(p, k), control = control, shift = shift})
		}
	}
	// A Control chord is a command, never text, though some platforms
	// still send its character.
	if !control {
		for character in string(p.input.text[:]) {
			append(&storage.rows, Action_Row{kind = .Text, text = character})
		}
	}
	at := platform.mouse_pos(p)
	if wheel := platform.mouse_wheel(p); wheel != 0 {
		append(&storage.rows, Action_Row{kind = .Scroll, position = at, scroll_delta = wheel, control = control, shift = shift})
	}
	if wheel_x := platform.mouse_wheel_x(p); wheel_x != 0 {
		append(&storage.rows, Action_Row{kind = .Scroll, position = at, scroll_delta = wheel_x, control = control, shift = shift, horizontal = true})
	}
	for path in platform.dropped_files(p) {
		append(&storage.rows, Action_Row{kind = .Drop, path = path})
	}
}

// Claims the scroll rows inside [min, max) with Control as given, summed.
@(private)
action_scroll_consume :: proc(s: ^State, control: bool, min, max: [2]f32, horizontal := false) -> f32 {
	result: f32
	for &action in s.actions.rows {
		inside := action.position.x >= min.x && action.position.x < max.x && action.position.y >= min.y && action.position.y < max.y
		if !action.consumed && action.kind == .Scroll && action.control == control && action.horizontal == horizontal && inside {
			action.consumed = true
			result += action.scroll_delta
		}
	}
	return result
}

// Claims a press (or repeat) of `key` without Control.
action_key_take :: proc(s: ^State, key: platform.Key) -> bool {
	for &action in s.actions.rows {
		if !action.consumed && action.kind == .Key && action.key == key && !action.control {
			action.consumed = true
			return true
		}
	}
	return false
}

// Claims the list keys pressed this frame and sums the rows they move a
// selection by: Up / Down one, Page Up / Page Down `page`.
action_list_step :: proc(s: ^State, page: int) -> int {
	step := 0
	for &action in s.actions.rows {
		if action.consumed || action.kind != .Key || action.control {
			continue
		}
		#partial switch action.key {
		case .Up:
			step -= 1
		case .Down:
			step += 1
		case .Page_Up:
			step -= page
		case .Page_Down:
			step += page
		case:
			continue
		}
		action.consumed = true
	}
	return step
}
