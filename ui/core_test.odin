package ui

import "core:testing"
import platform "../platform"

// A keyed box starts each frame from last frame's rect; a key built twice
// in a frame is transient the second time; keys not built are forgotten.
@(test)
test_box_memory :: proc(t: ^testing.T) {
	p: platform.Platform
	p.width, p.height = 200, 100
	s: State
	init(&s, nil, &p, nil)
	defer destroy(&s)
	frame :: proc(s: ^State, twice: bool, with_b: bool) -> (a: ^Box, dup: ^Box) {
		build_begin(s)
		set_next_pref_width(s, px(40))
		set_next_pref_height(s, px(20))
		a = build_box(s, {}, "###a")
		if twice {
			set_next_pref_width(s, px(10))
			set_next_pref_height(s, px(10))
			dup = build_box(s, {}, "###a")
		}
		if with_b {
			set_next_pref_width(s, px(30))
			set_next_pref_height(s, px(20))
			build_box(s, {}, "###b")
		}
		build_end(s)
		return
	}
	defer free_all(context.temp_allocator)
	a, _ := frame(&s, false, true)
	testing.expect_value(t, a.rect.max, [2]f32{40, 20})
	// The root, a and b.
	testing.expect_value(t, len(s.memories), 3)
	a2, dup := frame(&s, true, false)
	// The same row; the second box of the key has none.
	testing.expect_value(t, a2.memory, a.memory)
	testing.expect_value(t, dup.memory, -1)
	testing.expect_value(t, len(s.memories), 2)
	testing.expect_value(t, len(s.memory_of_key), 2)
	// Built with last frame's rect (layout sets this frame's at build_end).
	build_begin(&s)
	set_next_pref_width(&s, px(5))
	set_next_pref_height(&s, px(5))
	again := build_box(&s, {}, "###a")
	testing.expect_value(t, again.rect.max, [2]f32{40, 20})
	build_end(&s)
}

// While a modal is up, a box outside its root gets no press; one inside does.
@(test)
test_modal_input_scope_blocks_underlying_widgets :: proc(t: ^testing.T) {
	p: platform.Platform
	p.input.mb_down[.Left] = true
	p.input.mouse = {20, 20}
	s := State {
		p           = &p,
		modal_input = true,
	}
	underlying := Box {
		key   = Key(1),
		flags = {.Clickable},
		rect  = {min = {0, 0}, max = {100, 100}},
	}
	modal_root := Box {
		key   = Key(2),
		flags = {.Modal_Input_Root},
	}
	modal_child := Box {
		parent = &modal_root,
		key    = Key(3),
		flags  = {.Clickable},
		rect   = {min = {0, 0}, max = {100, 100}},
	}
	testing.expect(t, .Left_Pressed not_in signal_from_box(&s, &underlying).flags)
	testing.expect(t, .Left_Pressed in signal_from_box(&s, &modal_child).flags)
}

// Putting a modal up drops the focus and the hot and pressed boxes; while
// it stays up, what the modal took is kept.
@(test)
test_modal_input_set_drops_underlying_focus :: proc(t: ^testing.T) {
	s: State
	s.keyboard_focus, s.hot, s.active = Key(5), Key(6), Key(7)
	modal_input_set(&s, true)
	testing.expect_value(t, s.keyboard_focus, Key(0))
	testing.expect_value(t, s.hot, Key(0))
	testing.expect_value(t, s.active, Key(0))
	s.keyboard_focus = Key(9)
	modal_input_set(&s, true)
	testing.expect_value(t, s.keyboard_focus, Key(9))
	modal_input_set(&s, false)
	testing.expect(t, !s.modal_input)
}

// A focused line edit takes text and editing keys a whole UTF-8 character
// at a time, and leaves other keys to the application.
@(test)
test_line_edit_editing :: proc(t: ^testing.T) {
	p: platform.Platform
	p.width, p.height = 800, 600
	s: State
	init(&s, nil, &p, nil)
	defer destroy(&s)
	defer free_all(context.temp_allocator)
	buf := make([dynamic]u8)
	defer delete(buf)
	append(&buf, "aλc")
	cursor := len(buf)
	edit :: proc(s: ^State, buf: ^[dynamic]u8, cursor: ^int, rows: ..Action_Row) -> Signal {
		build_begin(s)
		append(&s.actions.rows, ..rows)
		// No build_end: there is no renderer to draw with.
		return line_edit(s, "###edit", buf, cursor)
	}
	first := edit(&s, &buf, &cursor)
	// Not focused: typing goes elsewhere.
	edit(&s, &buf, &cursor, {kind = .Text, text = 'x'})
	testing.expect_value(t, string(buf[:]), "aλc")
	s.keyboard_focus = first.box.key
	edit(&s, &buf, &cursor, {kind = .Key, key = .Left}, {kind = .Text, text = 'b'})
	testing.expect_value(t, string(buf[:]), "aλbc")
	testing.expect(t, s.text_wanted)
	edit(&s, &buf, &cursor, {kind = .Key, key = .Backspace}, {kind = .Key, key = .Backspace})
	testing.expect_value(t, string(buf[:]), "ac")
	testing.expect_value(t, cursor, 1)
	edit(&s, &buf, &cursor, {kind = .Key, key = .Home}, {kind = .Key, key = .Delete}, {kind = .Key, key = .End}, {kind = .Text, text = 'é'})
	testing.expect_value(t, string(buf[:]), "cé")
	testing.expect_value(t, cursor, len(buf))
	build_begin(&s)
	append(&s.actions.rows, Action_Row{kind = .Key, key = .Q}, Action_Row{kind = .Key, key = .Left, control = true})
	line_edit(&s, "###edit", &buf, &cursor)
	testing.expect(t, !s.actions.rows[0].consumed && !s.actions.rows[1].consumed)
}

// The list keys move a selection; the scroll keeps it in view.
@(test)
test_list_navigation :: proc(t: ^testing.T) {
	s: State
	s.actions = action_storage_make()
	defer action_storage_destroy(&s.actions)
	append(&s.actions.rows, Action_Row{kind = .Key, key = .Down}, Action_Row{kind = .Key, key = .Page_Down}, Action_Row{kind = .Key, key = .Up}, Action_Row{kind = .Key, key = .Enter})
	testing.expect_value(t, action_list_step(&s, 10), 10)
	testing.expect(t, action_key_take(&s, .Enter))
	testing.expect(t, !action_key_take(&s, .Enter))
	first := 0
	list_scroll_contain_selection(&first, 12, 5, 30)
	testing.expect_value(t, first, 8)
	list_scroll_contain_selection(&first, 3, 5, 30)
	testing.expect_value(t, first, 3)
	testing.expect(t, list_scroll_apply(&first, -10, 5, 30))
	testing.expect_value(t, first, 23)
}
