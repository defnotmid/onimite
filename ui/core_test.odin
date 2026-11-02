package ui

import "../animation"

import platform "../platform"
import "../render"
import "core:fmt"
import "core:testing"

@(test)
test_action_rows_are_consumed_once :: proc(t: ^testing.T) {
	s: State
	s.actions = action_storage_make()
	defer action_storage_destroy(&s.actions)
	append(&s.actions.rows, Action_Row{kind = .Press, slot = .Accept})

	testing.expect(t, action_pressed(&s, .Accept), "expected accept action")
	testing.expect(t, !action_pressed(&s, .Accept), "consumed action must not fire twice")
}

// A test frame's pointer event: a button pressed or released at the
// pointer, as the platform's pump makes one.
test_button :: proc(p: ^platform.Platform, b: platform.Mouse_Button, down: bool) {
	p.input.mb_down[b] = down
	append(&p.input.events, platform.Event{kind = .Mouse_Press if down else .Mouse_Release, button = b, position = p.input.mouse})
}
// A test frame's wheel event at the pointer, in RAD's units (120 a notch,
// down positive).
test_wheel :: proc(p: ^platform.Platform, delta: [2]f32) {
	append(&p.input.events, platform.Event{kind = .Scroll, position = p.input.mouse, delta = delta})
}
// A test frame's events read as its rows (the pointer's, through
// action_push_event as the app's key_route makes them), then gone, as the
// next pump's.
test_gather :: proc(s: ^State) {
	action_storage_clear(&s.actions)
	for e in platform.events(s.p) do action_push_event(&s.actions, e)
	clear(&s.p.input.events)
}

// The wheel with Control held is one row, taken once: by a hovered view
// (Control among its modifiers) or what the window leaves (exactly Control),
// in RAD's steps (three a notch).
@(test)
test_ctrl_wheel_is_one_row_taken_once :: proc(t: ^testing.T) {
	s: State
	s.actions = action_storage_make()
	defer action_storage_destroy(&s.actions)
	append(&s.actions.rows, Action_Row{kind = .Scroll, scroll_delta = {0, -120}, modifiers = {.Control, .Shift}}, Action_Row{kind = .Scroll, scroll_delta = {0, 120}, modifiers = {.Control}})
	testing.expect_value(t, action_scroll_take(&s, {.Control}), f32(3))
	testing.expect_value(t, action_scroll_take(&s, {.Control}), f32(0))
	testing.expect_value(t, action_scroll_take(&s, {.Control}, any = true), f32(-3))
}

// RAD's wheel step (ui_signal_from_box): an event's delta over 40, toward
// zero, at least one either way: three a notch, one for a touchpad's
// fraction of one.
@(test)
test_wheel_steps_three_a_notch :: proc(t: ^testing.T) {
	testing.expect_value(t, scroll_steps({0, 120}), [2]f32{0, 3})
	testing.expect_value(t, scroll_steps({0, -120}), [2]f32{0, -3})
	testing.expect_value(t, scroll_steps({0, 100}), [2]f32{0, 2})
	testing.expect_value(t, scroll_steps({12, -12}), [2]f32{1, -1})
	testing.expect_value(t, NOTCH_STEPS, 3)
}

// As RAD's ui_signal_from_box: a Scroll box takes the wheel with no modifier
// or Shift alone, Shift swapping its axes; with Control it is left for the
// views and the window.
@(test)
test_scroll_box_takes_the_wheel_shift_swaps_axes :: proc(t: ^testing.T) {
	p := platform.Platform{width = 200, height = 200}
	s: State
	s.p = &p
	s.actions = action_storage_make()
	defer action_storage_destroy(&s.actions)
	box := Box{key = Key(1), flags = {.Scroll}, rect = {min = {0, 0}, max = {100, 100}}}
	// Two notches down: six steps; with Shift, six right (RAD's swap).
	append(&s.actions.rows, Action_Row{kind = .Scroll, position = {50, 50}, scroll_delta = {0, 240}})
	testing.expect_value(t, signal_from_box(&s, &box).scroll, [2]f32{0, 6})
	append(&s.actions.rows, Action_Row{kind = .Scroll, position = {50, 50}, scroll_delta = {0, 240}, modifiers = {.Shift}})
	testing.expect_value(t, signal_from_box(&s, &box).scroll, [2]f32{6, 0})
	append(&s.actions.rows, Action_Row{kind = .Scroll, position = {50, 50}, scroll_delta = {0, 240}, modifiers = {.Control}})
	testing.expect_value(t, signal_from_box(&s, &box).scroll, [2]f32{0, 0})
	testing.expect_value(t, action_scroll_take(&s, {.Control}), f32(6))
	// Outside it, the wheel is left.
	append(&s.actions.rows, Action_Row{kind = .Scroll, position = {150, 50}, scroll_delta = {0, 120}})
	testing.expect_value(t, signal_from_box(&s, &box).scroll, [2]f32{0, 0})
}

// As RAD's: each button pressed on a box drags it while held (LeftDragging,
// MiddleDragging, RightDragging), across frames, and the drag's start state
// is what its press stored (ui_store_drag_struct), read back with the
// pointer's motion since (ui_drag_delta).
@(test)
test_middle_and_right_drags_hold_their_box :: proc(t: ^testing.T) {
	p := platform.Platform{width = 200, height = 200}
	s: State; init(&s, nil, &p, nil); defer destroy(&s)
	defer delete(p.input.events)
	frame :: proc(s: ^State) -> Signal {
		test_gather(s)
		build_begin(s)
		set_next_rect(s, {0, 0, 100, 100})
		sig := signal_from_box(s, build_box(s, {.Clickable}, "###pan"))
		build_end(s)
		return sig
	}
	p.input.mouse = {50, 50}
	frame(&s)
	test_button(&p, .Middle, true)
	sig := frame(&s)
	testing.expect(t, .Middle_Pressed in sig.flags && middle_dragging(sig) && !dragging(sig))
	start := [2]f32{7, 9}
	store_drag_struct(&s, &start)
	p.input.mouse = {150, 70} // past the box: the drag holds it
	sig = frame(&s)
	testing.expect(t, middle_dragging(sig))
	testing.expect_value(t, drag_delta(&s), [2]f32{100, 20})
	testing.expect_value(t, drag_struct(&s, [2]f32)^, start)
	test_button(&p, .Middle, false)
	sig = frame(&s)
	testing.expect(t, !middle_dragging(sig))
	p.input.mouse = {50, 50}
	frame(&s)
	test_button(&p, .Right, true)
	sig = frame(&s)
	testing.expect(t, right_dragging(sig) && .Right_Pressed in sig.flags)
}

// As RAD's hover cursor: the hot box's shape, kept by the box the left
// button holds past its edge, the arrow off every box; with the window
// unfocused only a held box sets it.
@(test)
test_hover_cursor_follows_hot_then_held_box :: proc(t: ^testing.T) {
	p := platform.Platform{width = 200, height = 200}
	p.input.focused = true
	s: State; init(&s, nil, &p, nil); defer destroy(&s)
	defer delete(p.input.events)
	frame :: proc(s: ^State) {
		test_gather(s)
		build_begin(s)
		set_next_rect(s, {0, 0, 100, 10})
		set_next_hover_cursor(s, .Up_Down)
		signal_from_box(s, build_box(s, {.Clickable}, "###split"))
		build_end(s)
	}
	p.input.mouse = {50, 5}
	frame(&s); frame(&s) // its rect is last frame's: hot on the second
	testing.expect_value(t, p.cursor, platform.Cursor.Up_Down)
	p.input.mouse = {50, 150}
	frame(&s)
	testing.expect_value(t, p.cursor, platform.Cursor.Pointer)
	p.input.mouse = {50, 5}
	test_button(&p, .Left, true)
	frame(&s)
	p.input.mouse = {50, 150} // dragged past its edge: it holds the shape
	frame(&s)
	testing.expect_value(t, p.cursor, platform.Cursor.Up_Down)
	test_button(&p, .Left, false)
	frame(&s)
	testing.expect_value(t, p.cursor, platform.Cursor.Pointer)
	p.input.focused = false
	p.input.mouse = {50, 5}
	frame(&s)
	testing.expect_value(t, p.cursor, platform.Cursor.Pointer)
}

// As RAD's ui_scroll_list with Nav and Snap: focus active, Down and Up move
// the cursor a row, round past either end, Page three rows short of what is
// in view; the cursor scrolls into view with a row below it.
@(test)
test_scroll_list_cursor_moves_round_and_snaps :: proc(t: ^testing.T) {
	p := platform.Platform{width = 200, height = 200}
	s: State; init(&s, nil, &p, nil); defer destroy(&s)
	scroll: animation.Scroll
	cursor := 0
	frame :: proc(s: ^State, scroll: ^animation.Scroll, cursor: ^int, rows: ..Action_Row) {
		action_storage_clear(&s.actions)
		append(&s.actions.rows, ..rows)
		build_begin(s)
		push_focus(s, .On)
		scroll_list_begin(s, "###list", {100, 100}, scroll, 20, 20, cursor)
		scroll_list_end(s)
		pop_focus(s)
		build_end(s)
	}
	up :: Action_Row{kind = .Navigate, delta_unit = .Char, delta = {0, -1}}
	down :: Action_Row{kind = .Navigate, delta_unit = .Char, delta = {0, 1}}
	page_down :: Action_Row{kind = .Navigate, delta_unit = .Page, delta = {0, 1}}
	frame(&s, &scroll, &cursor, up)
	testing.expect_value(t, cursor, 19) // round to the last
	testing.expect_value(t, scroll.track.target, f32(16)) // a row below it in view
	frame(&s, &scroll, &cursor, down)
	testing.expect_value(t, cursor, 0)
	testing.expect_value(t, scroll.track.target, f32(0))
	frame(&s, &scroll, &cursor, page_down, down, down)
	testing.expect_value(t, cursor, 4)
	testing.expect_value(t, scroll.track.target, f32(1)) // a row below it in view
	// Focus not active: the rows are left.
	action_storage_clear(&s.actions)
	append(&s.actions.rows, down)
	build_begin(&s)
	scroll_list_begin(&s, "###list", {100, 100}, &scroll, 20, 20, &cursor)
	scroll_list_end(&s)
	build_end(&s)
	testing.expect_value(t, cursor, 4)
	testing.expect(t, !s.actions.rows[0].consumed)
}

// As RAD's default navigation: in a navigation root built while focus is
// active, a vertical step moves its focus to the next or previous clickable
// box, from the next frame; a box focused by key is focus hot.
@(test)
test_default_navigation_follows_box_hierarchy :: proc(t: ^testing.T) {
	p := platform.Platform{width = 200, height = 200}
	s: State; init(&s, nil, &p, nil); defer destroy(&s)
	keys: [3]Key
	hot: [3]bool
	frame :: proc(s: ^State, keys: ^[3]Key, hot: ^[3]bool, step: i32) {
		action_storage_clear(&s.actions)
		if step != 0 do append(&s.actions.rows, Action_Row{kind = .Navigate, delta_unit = .Char, delta = {0, step}})
		build_begin(s)
		push_focus(s, .On)
		set_next_rect(s, {0, 0, 100, 90})
		root := build_box(s, {.Default_Focus_Nav_Y}, "###root")
		push_parent(s, root)
		push_focus(s, .Null)
		for i in 0 ..< 3 {
			set_next_rect(s, {0, f32(i) * 30, 100, 30})
			b := build_box(s, {.Clickable}, fmt.tprintf("###item_%d", i))
			keys[i], hot[i] = b.key, .Focus_Hot in b.flags
		}
		pop_focus(s)
		pop_parent(s)
		pop_focus(s)
		build_end(s)
	}
	frame(&s, &keys, &hot, 0)
	frame(&s, &keys, &hot, 1) // down: the first item
	frame(&s, &keys, &hot, 0)
	testing.expect(t, hot == {true, false, false}, "the first item is focused")
	frame(&s, &keys, &hot, 1)
	frame(&s, &keys, &hot, 1)
	frame(&s, &keys, &hot, 0)
	testing.expect(t, hot == {false, false, true}, "two down: the third")
	frame(&s, &keys, &hot, -1)
	frame(&s, &keys, &hot, 0)
	testing.expect(t, hot == {false, true, false}, "up: the second")
}

@(test)
test_button_preserves_caller_layout_overrides :: proc(t: ^testing.T) {
	p := platform.Platform {
		width  = 320,
		height = 200,
	}
	s: State
	init(&s, nil, &p, nil)
	defer destroy(&s)
	build_begin(&s)

	set_next_pref_width(&s, px(240))
	set_next_pref_height(&s, px(22))
	set_next_text_align(&s, .Left)
	sig := button(&s, "row###test_row")
	testing.expect_value(t, sig.box.pref_size[.X].kind, Size_Kind.Pixels)
	testing.expect_value(t, sig.box.pref_size[.X].value, f32(240))
	testing.expect_value(t, sig.box.pref_size[.Y].kind, Size_Kind.Pixels)
	testing.expect_value(t, sig.box.pref_size[.Y].value, f32(22))
	testing.expect_value(t, sig.box.text_align, Text_Align.Left)
}

@(test)
test_focus_does_not_block_mouse_hover :: proc(t: ^testing.T) {
	p := platform.Platform{}
	p.input.mouse = {200, 10}
	s := State {
		p = &p,
	}
	push_focus(&s, .On); defer delete(s.focus_hot.items); defer delete(s.focus_active.items)
	box := Box {
		key = Key(1),
		flags = {.Clickable},
		rect = {min = {0, 0}, max = {240, 22}},
	}

	sig := signal_from_box(&s, &box)
	testing.expect(t, .Mouse_Over in sig.flags, "full row should own its mouse bounds")
	testing.expect(t, .Hovering in sig.flags, "focus must not suppress row hover")
}

@(test)
test_keyed_animation_advances_and_resets_after_reappearing :: proc(t: ^testing.T) {
	p := platform.Platform {
		frame_time = 1.0 / 60.0,
	}
	s := State {
		p           = &p,
		animations  = animation_storage_make(),
		build_index = 1,
	}
	defer animation_storage_destroy(&s.animations)
	key := key_from_string(Key(0), "###test_animation")

	initial := anim_f32(&s, key, 1, {initial = 0})
	testing.expect_value(t, initial, f32(0))
	animations_advance(&s)
	testing.expect(t, s.animations.rows[0].current > 0, "animation should advance after the build")

	s.build_index = 2
	continued := anim_f32(&s, key, 1, {initial = 0})
	testing.expect(t, continued > 0, "continuously touched animation should preserve state")

	s.build_index = 4
	reappeared := anim_f32(&s, key, 1, {initial = 0})
	testing.expect_value(t, reappeared, f32(0))
}

// As RAD's rd_cell: focused, the field clips, its scroll box lets the text
// overflow, the text is kept whole and drawn with the cursor, and the view
// follows the cursor; unfocused, the text is cut and the view rests at 0.
@(test)
test_line_edit_focused_scrolls_to_its_cursor :: proc(t: ^testing.T) {
	p := platform.Platform{width = 800, height = 600, frame_time = 1}
	font, ok := render.font_load(#load("../assets/fonts/JetBrainsMono-Regular.ttf")); assert(ok); defer render.font_unload(&font)
	s: State; init(&s, nil, &p, &font); defer destroy(&s)
	buf := make([dynamic]u8); defer delete(buf)
	append(&buf, "a long line of text that runs well past the field")
	cursor, mark := len(buf), len(buf)
	frame :: proc(s: ^State, buf: ^[dynamic]u8, cursor, mark: ^int, focused := false) -> Signal {
		build_begin(s)
		push_focus(s, focused ? .On : .Off)
		set_next_rect(s, {10, 10, 120, 30})
		sig := line_edit(s, buf, cursor, mark)
		pop_focus(s)
		build_end(s)
		return sig
	}
	sig := frame(&s, &buf, &cursor, &mark)
	text := sig.box.first.first.last
	testing.expect(t, .Clip not_in sig.box.flags && .Disable_Text_Trunc not_in text.flags, "unfocused: cut, not clipped")
	for _ in 0 ..< 3 do sig = frame(&s, &buf, &cursor, &mark, focused = true)
	scroll := sig.box.first.first
	text = scroll.last
	testing.expect(t, .Clip in sig.box.flags && scroll.flags >= {.Allow_Overflow_X, .Clip}, "focused: clipped, overflowing")
	testing.expect(t, .Disable_Text_Trunc in text.flags && text.custom_draw == line_edit_draw, "focused: whole, with its cursor")
	testing.expect(t, scroll.view_off.x > 0 && text.rect.max.x <= sig.box.rect.max.x + s.theme.default_font_px, "scrolled to the cursor at the end")
	sig = frame(&s, &buf, &cursor, &mark)
	testing.expect_value(t, sig.box.first.first.view_off.x, f32(0))
	// Not edited, its text box no longer draws a cursor: a box's custom draw
	// is the frame's that equips it.
	testing.expect(t, sig.box.first.first.last.custom_draw == nil, "no stale cursor draw")
}

@(test)
test_selection_row_owns_visual_state_for_its_cells :: proc(t: ^testing.T) {
	p := platform.Platform {
		width  = 800,
		height = 600,
	}
	s: State
	init(&s, nil, &p, nil)
	defer destroy(&s)
	build_begin(&s)
	set_next_pref_width(&s, px(300))
	set_next_pref_height(&s, px(24))
	signal := selection_row_begin(&s, "selected row", true, {20, 22, 28, 255}, 3)
	label(&s, "cell")
	pop_parent(&s)

	testing.expect(t, signal.box != nil, "selection row should publish one keyed control")
	testing.expect(t, .Clickable in signal.box.flags)
	testing.expect(t, .Draw_Hot_Effects in signal.box.flags)
	testing.expect_value(t, signal.box.child_count, 1)
	testing.expect(t, .Draw_Border not_in signal.box.flags)
}

@(test)
test_toggle_switch_owns_track_and_thumb_presentation :: proc(t: ^testing.T) {
	p := platform.Platform {
		width  = 800,
		height = 600,
	}
	s: State
	init(&s, nil, &p, nil)
	defer destroy(&s)
	toggled := true
	build_begin(&s)
	signal := toggle_switch(&s, &toggled, "feature")

	testing.expect(t, signal.box != nil, "toggle should publish one keyed control")
	testing.expect_value(t, signal.box.child_count, 3)
	track := signal.box.first
	testing.expect(t, track != nil && .Draw_Background in track.flags)
	testing.expect(t, track.first != nil && .Draw_Background in track.first.flags)
}

// As RAD Debugger's ui_signal_from_box: each event is taken by the first box
// it is for, as signals are computed. Built front to back, the box in front
// takes the press, the hover and the wheel; the one beneath gets none, and
// the release goes to the box the press made active.
@(test)
test_the_box_built_first_takes_the_pointer :: proc(t: ^testing.T) {
	p := platform.Platform{width = 200, height = 200}
	defer delete(p.input.events)
	p.input.mouse = {50, 50}
	test_button(&p, .Left, true)
	test_wheel(&p, {0, 120})
	s: State
	s.p = &p
	s.actions = action_storage_make()
	defer action_storage_destroy(&s.actions)
	test_gather(&s)
	front := Box{key = Key(1), flags = {.Clickable, .Scroll}, rect = {min = {25, 25}, max = {75, 75}}}
	back := Box{key = Key(2), flags = {.Clickable, .Scroll}, rect = {min = {0, 0}, max = {100, 100}}}
	a, b := signal_from_box(&s, &front), signal_from_box(&s, &back)
	testing.expect(t, .Left_Pressed in a.flags && .Hovering in a.flags && a.scroll.y == 3)
	testing.expect(t, .Left_Pressed not_in b.flags && .Hovering not_in b.flags && b.scroll.y == 0)
	testing.expect(t, .Mouse_Over in b.flags) // over it, though occluded
	testing.expect_value(t, s.active[.Left], front.key)
	// The release, wherever it falls, is the active box's alone.
	test_button(&p, .Left, false)
	test_gather(&s)
	b, a = signal_from_box(&s, &back), signal_from_box(&s, &front)
	testing.expect(t, .Left_Clicked not_in b.flags && .Left_Clicked in a.flags)
	testing.expect_value(t, s.active[.Left], Key(0))
	// A box that does not scroll lets the wheel pass to the one beneath.
	test_wheel(&p, {0, -120})
	test_gather(&s)
	label := Box{key = Key(3), flags = {.Clickable}, rect = {min = {25, 25}, max = {75, 75}}}
	testing.expect_value(t, signal_from_box(&s, &label).scroll.y, f32(0))
	testing.expect_value(t, signal_from_box(&s, &back).scroll.y, f32(-3))
	// A press and its release in one frame (a tap): a click where they
	// happened, wherever the pointer is when the frame reads them.
	p.input.mouse = {50, 50}
	test_button(&p, .Left, true)
	test_button(&p, .Left, false)
	p.input.mouse = {150, 150}
	test_gather(&s)
	a = signal_from_box(&s, &front)
	testing.expect(t, .Left_Pressed in a.flags && .Left_Clicked in a.flags)
	testing.expect_value(t, s.active[.Left], Key(0))
	// Two presses in one frame are two.
	test_button(&p, .Left, true); test_button(&p, .Left, false)
	test_button(&p, .Left, true); test_button(&p, .Left, false)
	test_gather(&s)
	presses := 0
	for r in s.actions.rows do if r.kind == .Mouse_Press do presses += 1
	testing.expect_value(t, presses, 2)
}
