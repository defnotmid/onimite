package ui

import "../animation"
import platform "../platform"

Action_Kind :: enum u8 {
	Null,
	Press,
	Text,
	Edit,
	Navigate,
	Scroll,
	// onimite: every key that went down (or repeats) with Control and Shift
	// as held, for the application's key map; files dropped on the window.
	Key,
	Drop,
}

Action_Slot :: enum u8 {
	Null,
	Accept,
	Complete,
	Cancel,
	Dismiss,
	Font_Size,
	File_Browser_Open_Back,
	File_Browser_Open_Timing,
	File_Browser_Forward,
	File_Browser_Home,
}

Action_Row :: struct {
	kind:                 Action_Kind,
	slot:                 Action_Slot,
	delta:                [2]i32,
	position:             [2]f32,
	scroll_delta:         f32,
	text:                 rune,
	control:              bool,
	explicit_directional: bool,
	consumed:             bool,
	// onimite: a horizontal scroll (wheel x, touchpad), kept apart from the
	// vertical rows.
	horizontal:           bool,
	// onimite: Key: the key, whether it is repeating while held, Shift as
	// held (`control` too); Drop: the file's path (the platform's until the
	// next tick).
	key:                  platform.Key,
	repeat:               bool,
	shift:                bool,
	path:                 string,
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
//
// Input that widgets compete for lives here — text, editing, navigation,
// scrolling, accept/cancel. File-browser chords are actions too: Ctrl+O means
// "open" while the browser is hidden and "back" while it is visible, so the
// focused modal must get first claim on that semantic input.
actions_gather_from_platform :: proc(storage: ^Action_Storage, p: ^platform.Platform) {
	action_storage_clear(storage)
	control := platform.ctrl_down(p)
	if platform.key_pressed(p, .Enter) {
		append(&storage.rows, Action_Row{kind = .Press, slot = .Accept})
	}
	if platform.key_pressed(p, .Tab) {
		append(&storage.rows, Action_Row{kind = .Press, slot = .Complete})
	}
	if platform.key_pressed(p, .Escape) {
		append(&storage.rows, Action_Row{kind = .Press, slot = .Cancel})
	}
	if control && platform.key_pressed(p, .O) {
		if platform.shift_down(p) {
			append(&storage.rows, Action_Row{kind = .Press, slot = .File_Browser_Open_Timing})
		} else {
			append(&storage.rows, Action_Row{kind = .Press, slot = .File_Browser_Open_Back})
		}
	}
	if control && platform.key_pressed(p, .I) {
		append(&storage.rows, Action_Row{kind = .Press, slot = .File_Browser_Forward})
	}
	if control && platform.key_pressed(p, .N) {
		append(
			&storage.rows,
			Action_Row{kind = .Navigate, delta = {0, 1}, explicit_directional = true},
		)
	}
	if control && platform.key_pressed(p, .P) {
		append(
			&storage.rows,
			Action_Row{kind = .Navigate, delta = {0, -1}, explicit_directional = true},
		)
	}
	if platform.key_pressed(p, .Backspace) || platform.key_repeat(p, .Backspace) {
		append(&storage.rows, Action_Row{kind = .Edit, delta = {-1, 0}})
	}
	// A control chord is a command or navigation action, never text. SDL may
	// still publish its printable character on some platforms, so exclude it at
	// the action-admission boundary instead of making every text widget guess.
	if !control {
		for character in string(p.input.text[:]) {
			append(&storage.rows, Action_Row{kind = .Text, text = character})
			if character == '~' {
				append(&storage.rows, Action_Row{kind = .Press, slot = .File_Browser_Home})
			}
		}
	}
	if platform.key_pressed(p, .Left) {
		append(
			&storage.rows,
			Action_Row{kind = .Navigate, delta = {-1, 0}, explicit_directional = true},
		)
	}
	if platform.key_pressed(p, .Right) {
		append(
			&storage.rows,
			Action_Row{kind = .Navigate, delta = {1, 0}, explicit_directional = true},
		)
	}
	if platform.key_pressed(p, .Up) {
		append(
			&storage.rows,
			Action_Row{kind = .Navigate, delta = {0, -1}, explicit_directional = true},
		)
	}
	if platform.key_pressed(p, .Down) {
		append(
			&storage.rows,
			Action_Row{kind = .Navigate, delta = {0, 1}, explicit_directional = true},
		)
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
	// onimite: the keys for the application's key map, and dropped files.
	for k in platform.Key {
		if platform.key_typed(p, k) {
			append(&storage.rows, Action_Row{kind = .Key, key = k, repeat = !platform.key_pressed(p, k), control = control, shift = platform.shift_down(p)})
		}
	}
	for path in platform.dropped_files(p) {
		append(&storage.rows, Action_Row{kind = .Drop, path = path})
	}
	// onimite: the horizontal wheel as its own rows (the timeline pans by it).
	if wheel_x := platform.mouse_wheel_x(p); wheel_x != 0 {
		append(
			&storage.rows,
			Action_Row {
				kind = .Scroll,
				position = platform.mouse_pos(p),
				scroll_delta = wheel_x,
				control = control,
				horizontal = true,
			},
		)
	}
	if platform.any_input_pressed(p) {
		append(&storage.rows, Action_Row{kind = .Press, slot = .Dismiss})
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
	horizontal := false, // onimite: the horizontal rows instead
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

// list_scroll_apply owns direct wheel movement. A manual scroll cancels any
// pending cursor-containment request, matching RAD Debugger's separation of
// scroll position from its explicit center/contain-cursor flags.
list_scroll_apply :: proc(
	scroll: ^animation.Scroll,
	contain_selection: ^bool,
	scroll_delta: f32,
	max_scroll: i32,
	rows_per_tick: f32 = 2,
) {
	animation.scroll_limit(scroll, f32(max_scroll))
	if scroll_delta != 0 {
		animation.scroll_by(scroll, -scroll_delta * rows_per_tick)
		contain_selection^ = false
	}
}

list_scroll_contain_selection :: proc(
	scroll: ^animation.Scroll,
	contain_selection: ^bool,
	selected_ordinal, visible_rows: int,
	max_scroll: i32,
) {
	animation.scroll_limit(scroll, f32(max_scroll))
	if !contain_selection^ do return
	if selected_ordinal >= 0 {
		if f32(selected_ordinal) < scroll.track.target do animation.scroll_to(scroll, f32(selected_ordinal))
		else if f32(selected_ordinal) >= scroll.track.target + f32(visible_rows) do animation.scroll_to(scroll, f32(selected_ordinal - visible_rows + 1))
	}
	contain_selection^ = false
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

action_edit_delta :: proc(s: ^State) -> [2]i32 {
	result: [2]i32
	for index in 0 ..< len(s.actions.rows) {
		action := &s.actions.rows[index]
		if !action.consumed && action.kind == .Edit {
			action.consumed = true
			result += action.delta
		}
	}
	return result
}

action_text_rune_consume :: proc(s: ^State, character: rune) -> bool {
	for index in 0 ..< len(s.actions.rows) {
		action := &s.actions.rows[index]
		if !action.consumed && action.kind == .Text && action.text == character {
			action.consumed = true
			return true
		}
	}
	return false
}

FONT_SCALE_MIN :: 0.75
FONT_SCALE_MAX :: 1.50
FONT_SCALE_STEP :: 0.10

font_scale_process_actions :: proc(s: ^State) {
	delta := action_scroll_consume(s, true)
	if delta != 0 {
		value := s.font_motion.active ? s.font_motion.target : s.font_scale
		animation.target(
			&s.font_motion,
			s.font_scale,
			clamp(value + delta * FONT_SCALE_STEP, FONT_SCALE_MIN, FONT_SCALE_MAX),
		)
	}
	if animation.advance(&s.font_scale, &s.font_motion, s.p.frame_time) do s.is_animating = true
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

default_nav_set_root :: proc(s: ^State, root: ^Box) {
	if root != nil && box_is_default_nav_root(root) {
		s.default_nav_root = root.key
	}
}

default_nav_clear_root :: proc(s: ^State) {
	s.default_nav_root = Key(0)
}

default_nav_clear_focus :: proc(root: ^Box) {
	if root != nil {
		root.default_nav_focus_hot_key = Key(0)
		root.default_nav_focus_active_key = Key(0)
	}
}

default_nav_is_focus_hot :: proc(box: ^Box) -> bool {
	root := default_nav_root_from_box(box)
	return(
		root != nil &&
		(root.default_nav_focus_hot_key == box.key ||
				root.default_nav_focus_active_key == box.key) \
	)
}

default_nav_candidates_gather :: proc(root, parent: ^Box, out: ^[dynamic]^Box) {
	for child := parent.first; child != nil; child = child.next {
		if .Clickable in child.flags && .Focus_Nav_Skip not_in child.flags {
			append(out, child)
		}
		is_nested_root := child != root && box_is_default_nav_root(child)
		if !is_nested_root || root.default_nav_focus_active_key == child.key {
			default_nav_candidates_gather(root, child, out)
		}
	}
}

default_nav_apply_delta :: proc(root: ^Box, delta: [2]i32) -> bool {
	if root == nil || (delta.x == 0 && delta.y == 0) {
		return false
	}
	axis := delta.x != 0 ? Axis2.X : Axis2.Y
	if (axis == .X && .Default_Focus_Nav_X not_in root.flags) ||
	   (axis == .Y && .Default_Focus_Nav_Y not_in root.flags) {
		return false
	}

	candidates := make([dynamic]^Box, context.temp_allocator)
	default_nav_candidates_gather(root, root, &candidates)
	if len(candidates) == 0 {
		return false
	}

	current := -1
	for candidate, index in candidates {
		if candidate.key == root.default_nav_focus_hot_key {
			current = index
			break
		}
	}
	direction := delta[axis] < 0 ? -1 : 1
	next := current + direction
	if current < 0 {
		next = direction > 0 ? 0 : len(candidates) - 1
	}
	next = clamp(next, 0, len(candidates) - 1)
	root.default_nav_focus_hot_key = candidates[next].key
	return true
}

default_nav_process_actions :: proc(s: ^State) {
	if s.modal_input_active {
		return
	}
	if s.default_nav_root == Key(0) {
		return
	}
	root, root_ok := s.box_table[s.default_nav_root]
	if !root_ok || root == nil {
		return
	}

	for index in 0 ..< len(s.actions.rows) {
		action := &s.actions.rows[index]
		if action.consumed {
			continue
		}
		if action.kind == .Navigate && root.default_nav_focus_active_key == Key(0) {
			if default_nav_apply_delta(root, action.delta) {
				action.consumed = true
			}
		} else if action.kind == .Press &&
		   action.slot == .Cancel &&
		   root.default_nav_focus_active_key != Key(0) {
			root.default_nav_focus_active_key = Key(0)
			action.consumed = true
		}
	}
}
