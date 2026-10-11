// Ported from ../paf/ui (itself from odincade's sketch_and_extrude).
package ui

import platform "../platform"

Action_Kind :: enum u8 {
	Null,
	Press,
	Scroll,
}

// The semantic vocabulary this application gathers from the platform. Every
// consumer claims a row explicitly through the procedures below, so nested
// focus scopes cannot double-fire. (paf's vocabulary, replaced by the
// preview's.)
Action_Slot :: enum u8 {
	Null,
	Cancel,
}

Action_Row :: struct {
	kind:         Action_Kind,
	slot:         Action_Slot,
	position:     [2]f32,
	scroll_delta: f32,
	control:      bool,
	// A horizontal scroll (wheel x, touchpad), right positive; consumed
	// apart from vertical ones.
	horizontal:   bool,
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

// Gather maps platform-specific keys to semantic, contiguous action rows.
// Consumers claim rows explicitly, so nested focus scopes cannot double-fire.
actions_gather_from_platform :: proc(storage: ^Action_Storage, p: ^platform.Platform) {
	action_storage_clear(storage)
	control := platform.ctrl_down(p)
	if platform.key_pressed(p, .Escape) {
		append(&storage.rows, Action_Row{kind = .Press, slot = .Cancel})
	}
	wheel := platform.mouse_wheel(p)
	if wheel != 0 {
		append(
			&storage.rows,
			Action_Row {
				kind = .Scroll,
				position = platform.mouse_pos(p),
				scroll_delta = wheel,
				control = control,
			},
		)
	}
	if wheel_x := platform.mouse_wheel_x(p); wheel_x != 0 {
		append(&storage.rows, Action_Row{kind = .Scroll, position = platform.mouse_pos(p), scroll_delta = wheel_x, control = control, horizontal = true})
	}
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

action_scroll_consume :: proc(
	s: ^State,
	control: bool,
	min: [2]f32 = {},
	max: [2]f32 = {},
	bounded := false,
	horizontal := false,
) -> f32 {
	result: f32
	for index in 0 ..< len(s.actions.rows) {
		action := &s.actions.rows[index]
		inside :=
			!bounded ||
			(action.position.x >= min.x &&
					action.position.x < max.x &&
					action.position.y >= min.y &&
					action.position.y < max.y)
		if !action.consumed && action.kind == .Scroll && action.control == control && action.horizontal == horizontal && inside {
			action.consumed = true
			result += action.scroll_delta
		}
	}
	return result
}
