package ui

import "../animation"

import platform "../platform"
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

@(test)
test_ctrl_wheel_gathers_one_consumable_scroll_action :: proc(t: ^testing.T) {
	p: platform.Platform
	p.input.key_down[.LCtrl] = true
	p.input.wheel = 1
	s: State
	s.actions = action_storage_make()
	defer action_storage_destroy(&s.actions)
	actions_gather_from_platform(&s.actions, &p)

	testing.expect_value(t, action_scroll_consume(&s, true), f32(1))
	testing.expect_value(t, action_scroll_consume(&s, true), f32(0))
}

@(test)
test_scroll_action_is_consumed_only_by_the_hovered_bounds :: proc(t: ^testing.T) {
	s: State
	s.actions = action_storage_make()
	defer action_storage_destroy(&s.actions)
	append(&s.actions.rows, Action_Row{kind = .Scroll, position = {50, 50}, scroll_delta = -2})

	testing.expect_value(t, action_scroll_consume(&s, false, {0, 0}, {25, 25}, true), f32(0))
	testing.expect_value(t, action_scroll_consume(&s, false, {25, 25}, {75, 75}, true), f32(-2))
	testing.expect_value(t, action_scroll_consume(&s, false, {25, 25}, {75, 75}, true), f32(0))
}

@(test)
test_manual_list_scroll_cancels_cursor_containment_until_selection_moves :: proc(t: ^testing.T) {
	scroll_index: animation.Scroll
	contain_selection := true
	list_scroll_apply(&scroll_index, &contain_selection, -2, 20)
	testing.expect_value(t, scroll_index.track.target, f32(4))
	testing.expect(t, !contain_selection, "manual wheel movement must own the scroll position")

	list_scroll_contain_selection(&scroll_index, &contain_selection, 0, 5, 20)
	testing.expect_value(t, scroll_index.track.target, f32(4))

	contain_selection = true
	list_scroll_contain_selection(&scroll_index, &contain_selection, 0, 5, 20)
	testing.expect_value(t, scroll_index.track.target, f32(0))
	testing.expect(t, !contain_selection, "selection containment is a one-shot request")
}

@(test)
test_typed_text_gathers_as_claimable_text_actions :: proc(t: ^testing.T) {
	p: platform.Platform
	append(&p.input.text, "vn1")
	defer delete(p.input.text)
	s: State
	s.actions = action_storage_make()
	defer action_storage_destroy(&s.actions)
	actions_gather_from_platform(&s.actions, &p)

	// Each rune is a separate claimable row, in order.
	testing.expect(t, action_text_rune_consume(&s, 'v'), "expected text row for 'v'")
	testing.expect(t, action_text_rune_consume(&s, 'n'), "expected text row for 'n'")
	testing.expect(t, action_text_rune_consume(&s, '1'), "expected text row for '1'")
	testing.expect(t, !action_text_rune_consume(&s, 'v'), "a claimed rune must not fire twice")
}

@(test)
test_control_chord_does_not_leak_a_printable_character :: proc(t: ^testing.T) {
	p: platform.Platform
	p.input.key_down[.LCtrl] = true
	append(&p.input.text, u8('a'))
	defer delete(p.input.text)
	s: State
	s.actions = action_storage_make()
	defer action_storage_destroy(&s.actions)
	actions_gather_from_platform(&s.actions, &p)

	testing.expect(
		t,
		!action_text_rune_consume(&s, 'a'),
		"a control chord is a command, and must not also reach a focused edit",
	)
}

@(test)
test_ctrl_n_and_ctrl_p_gather_vertical_navigation_without_text :: proc(t: ^testing.T) {
	p: platform.Platform
	s: State
	s.actions = action_storage_make()
	defer action_storage_destroy(&s.actions)
	p.input.key_down[.LCtrl] = true

	p.input.key_down[.N] = true
	p.input.key_hit[.N] = true
	append(&p.input.text, u8('n'))
	actions_gather_from_platform(&s.actions, &p)
	testing.expect_value(t, action_navigation_delta(&s), [2]i32{0, 1})
	testing.expect(t, !action_text_rune_consume(&s, 'n'), "Ctrl-N must not leak text")

	p.input.key_down[.N] = false
	p.input.key_hit[.N] = false
	p.input.key_down[.P] = true
	p.input.key_hit[.P] = true
	p.input.key_hit[.P] = true
	clear(&p.input.text)
	append(&p.input.text, u8('p'))
	actions_gather_from_platform(&s.actions, &p)
	testing.expect_value(t, action_navigation_delta(&s), [2]i32{0, -1})
	testing.expect(t, !action_text_rune_consume(&s, 'p'), "Ctrl-P must not leak text")

	delete(p.input.text)
}

@(test)
test_file_open_shortcuts_gather_distinct_semantic_actions :: proc(t: ^testing.T) {
	p: platform.Platform
	s: State
	s.actions = action_storage_make()
	defer action_storage_destroy(&s.actions)
	p.input.key_down[.LCtrl] = true
	p.input.key_down[.O] = true
	p.input.key_hit[.O] = true
	actions_gather_from_platform(&s.actions, &p)
	testing.expect(
		t,
		action_pressed(&s, .File_Browser_Open_Back),
		"Ctrl+O should open a GDS or go back in the open browser",
	)

	p.input.key_down[.LShift] = true
	actions_gather_from_platform(&s.actions, &p)
	testing.expect(
		t,
		action_pressed(&s, .File_Browser_Open_Timing),
		"Ctrl+Shift+O should open the timing-file browser",
	)
	testing.expect(
		t,
		!action_pressed(&s, .File_Browser_Open_Back),
		"the timing chord must not also publish the GDS action",
	)
}

@(test)
test_backspace_gathers_edit_action_on_press_and_repeat :: proc(t: ^testing.T) {
	p: platform.Platform
	s: State
	s.actions = action_storage_make()
	defer action_storage_destroy(&s.actions)

	p.input.key_down[.Backspace] = true
	p.input.key_hit[.Backspace] = true
	actions_gather_from_platform(&s.actions, &p)
	testing.expect_value(t, action_edit_delta(&s), [2]i32{-1, 0})

	// Held: no fresh press edge, but auto-repeat must still delete, so a held
	// backspace clears a filter box rather than stalling after one character.
	p.input.key_hit[.Backspace] = false
	p.input.key_repeat[.Backspace] = true
	actions_gather_from_platform(&s.actions, &p)
	testing.expect_value(t, action_edit_delta(&s), [2]i32{-1, 0})

	p.input.key_repeat[.Backspace] = false
	actions_gather_from_platform(&s.actions, &p)
	testing.expect_value(t, action_edit_delta(&s), [2]i32{0, 0})
}

@(test)
test_accept_and_cancel_gather_from_enter_and_escape :: proc(t: ^testing.T) {
	p: platform.Platform
	s: State
	s.actions = action_storage_make()
	defer action_storage_destroy(&s.actions)

	p.input.key_down[.Enter] = true
	p.input.key_hit[.Enter] = true
	p.input.key_down[.Escape] = true
	p.input.key_hit[.Escape] = true
	actions_gather_from_platform(&s.actions, &p)
	testing.expect(t, action_pressed(&s, .Accept), "Enter should gather accept")
	testing.expect(t, action_pressed(&s, .Cancel), "Escape should gather cancel")
}

@(test)
test_any_key_or_mouse_press_gathers_dismiss_action :: proc(t: ^testing.T) {
	p: platform.Platform
	s: State
	s.actions = action_storage_make()
	defer action_storage_destroy(&s.actions)

	p.input.key_hit[.A] = true
	actions_gather_from_platform(&s.actions, &p)
	testing.expect(t, action_pressed(&s, .Dismiss), "any key should gather dismiss")

	p.input.key_hit[.A] = false
	p.input.mb_down[.Left] = true
	actions_gather_from_platform(&s.actions, &p)
	testing.expect(t, action_pressed(&s, .Dismiss), "any mouse button should gather dismiss")
}

@(test)
test_font_scale_adjustment_is_central_and_clamped :: proc(t: ^testing.T) {
	p := platform.Platform {
		frame_time = 0.2,
	}
	s := State {
		font_scale = 1,
		p          = &p,
		actions    = action_storage_make(),
	}
	defer action_storage_destroy(&s.actions)
	append(&s.actions.rows, Action_Row{kind = .Scroll, scroll_delta = 1, control = true})
	font_scale_process_actions(&s)
	testing.expect_value(t, s.font_scale, f32(1.1))

	clear(&s.actions.rows)
	append(&s.actions.rows, Action_Row{kind = .Scroll, scroll_delta = 100, control = true})
	font_scale_process_actions(&s)
	testing.expect_value(t, s.font_scale, f32(FONT_SCALE_MAX))
}

@(test)
test_default_navigation_follows_box_hierarchy :: proc(t: ^testing.T) {
	root := Box {
		key   = Key(1),
		flags = {.Default_Focus_Nav_Y},
	}
	first := Box {
		key   = Key(2),
		flags = {.Clickable},
	}
	second := Box {
		key   = Key(3),
		flags = {.Clickable},
	}
	third := Box {
		key   = Key(4),
		flags = {.Clickable},
	}
	root.first = &first
	root.last = &third
	first.parent = &root
	first.next = &second
	second.parent = &root
	second.prev = &first
	second.next = &third
	third.parent = &root
	third.prev = &second
	root.default_nav_focus_hot_key = second.key

	testing.expect(t, default_nav_apply_delta(&root, {0, 1}), "expected down navigation")
	testing.expect_value(t, root.default_nav_focus_hot_key, third.key)
	testing.expect(t, default_nav_apply_delta(&root, {0, -1}), "expected up navigation")
	testing.expect_value(t, root.default_nav_focus_hot_key, second.key)
	_ = default_nav_apply_delta(&root, {0, -1})
	_ = default_nav_apply_delta(&root, {0, -1})
	testing.expect_value(t, root.default_nav_focus_hot_key, first.key)
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
test_keyboard_focus_does_not_block_mouse_hover :: proc(t: ^testing.T) {
	p := platform.Platform{}
	p.input.mouse = {200, 10}
	s := State {
		p              = &p,
		keyboard_focus = Key(99),
	}
	box := Box {
		key = Key(1),
		flags = {.Clickable},
		rect = {min = {0, 0}, max = {240, 22}},
	}

	sig := signal_from_box(&s, &box)
	testing.expect(t, .Mouse_Over in sig.flags, "full row should own its mouse bounds")
	testing.expect(t, .Hovering in sig.flags, "keyboard focus must not suppress row hover")
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

	initial := anim_f32(&s, key, 1, {initial = 0, duration = 0.2, easing = .Cubic_Out})
	testing.expect_value(t, initial, f32(0))
	animations_advance(&s)
	testing.expect(t, s.animations.rows[0].current > 0, "animation should advance after the build")

	s.build_index = 2
	continued := anim_f32(&s, key, 1, {initial = 0, duration = 0.2, easing = .Cubic_Out})
	testing.expect(t, continued > 0, "continuously touched animation should preserve state")

	s.build_index = 4
	reappeared := anim_f32(&s, key, 1, {initial = 0, duration = 0.2, easing = .Cubic_Out})
	testing.expect_value(t, reappeared, f32(0))
}

@(test)
test_modal_surface_uses_shared_open_animation :: proc(t: ^testing.T) {
	p := platform.Platform {
		width      = 800,
		height     = 600,
		frame_time = 1.0 / 60.0,
	}
	s: State
	init(&s, nil, &p, nil)
	defer destroy(&s)
	build_begin(&s)
	surface := modal_surface_begin(
		&s,
		"###test_modal",
		{
			open = true,
			width = 400,
			height = 200,
			background = {20, 20, 20, 255},
			border = {80, 80, 80, 255},
			backdrop = {0, 0, 0, 160},
			vertical_squish = 0.1,
		},
	)
	defer modal_surface_end(&s)

	testing.expect_value(t, surface.open_t, f32(0))
	testing.expect_value(t, surface.panel.fixed_size.x, f32(400))
	testing.expect_value(t, surface.panel.fixed_size.y, f32(180))
	testing.expect_value(t, surface.panel.opacity, f32(0))
}

@(test)
test_line_edit_semantic_text_action_draws_animated_cursor_trail :: proc(t: ^testing.T) {
	p := platform.Platform {
		width      = 800,
		height     = 600,
		frame_time = 1.0 / 60.0,
	}
	s: State
	init(&s, nil, &p, nil)
	defer destroy(&s)
	buf := make([dynamic]u8)
	defer delete(buf)
	cursor := 0

	build_begin(&s)
	first := line_edit(&s, &buf, &cursor)
	s.keyboard_focus = first.box.key
	animations_advance(&s)

	append(&p.input.text, u8('a'))
	defer delete(p.input.text)
	build_begin(&s)
	second := line_edit(&s, &buf, &cursor)

	testing.expect_value(t, string(buf[:]), "a")
	testing.expect_value(t, second.box.child_count, 2)
	testing.expect(
		t,
		.Draw_Horizontal_Gradient in second.box.first.flags,
		"first typed character should draw a cursor trail",
	)
	testing.expect_value(t, second.box.first.gradient_right.a, u8(63))

	clear(&p.input.text)
	p.input.key_down[.Backspace] = true
	p.input.key_hit[.Backspace] = true
	build_begin(&s)
	_ = line_edit(&s, &buf, &cursor)
	testing.expect_value(t, string(buf[:]), "")
	for action in s.actions.rows {
		if action.kind == .Edit {
			testing.expect(t, action.consumed, "focused line edit should consume edit action")
		}
	}
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
test_scroll_list_separates_the_in_flow_border_from_clipped_row_content :: proc(t: ^testing.T) {
	p := platform.Platform {
		width  = 800,
		height = 600,
	}
	s: State
	init(&s, nil, &p, nil)
	defer destroy(&s)
	build_begin(&s)
	set_next_pref_width(&s, px(300))
	set_next_pref_height(&s, px(160))
	_ = row(&s, "###list_wrap")
	spacer(&s, px(12))
	signal := scroll_list_begin(&s, "###list")
	set_next_pref_width(&s, fill())
	set_next_pref_height(&s, px(22))
	row_box := build_box(&s, {.Draw_Background}, "###row")
	scroll_list_end(&s)
	spacer(&s, px(12))
	pop_parent(&s)
	pop_parent(&s)
	for axis in Axis2 {
		layout_standalone(&s, s.root, axis)
		layout_upwards_dependent(&s, s.root, axis)
		layout_downwards_dependent(s.root, axis)
		layout_enforce_constraints(s.root, axis)
		layout_position(s.root, axis)
	}

	content := signal.box
	middle := content.parent
	outer := middle.parent
	testing.expect(t, outer != nil && .Draw_Border in outer.flags)
	testing.expect(t, .Floating_X not_in outer.flags && .Floating_Y not_in outer.flags)
	testing.expect(t, .Clip in content.flags)
	testing.expect(t, .Draw_Border not_in content.flags)
	testing.expect_value(t, content.child_count, 1)
	testing.expect(t, content.rect.max.x > content.rect.min.x)
	testing.expect(t, content.rect.max.y > content.rect.min.y)
	testing.expect(t, row_box.rect.max.x > row_box.rect.min.x)
	testing.expect(t, row_box.rect.max.y > row_box.rect.min.y)
	testing.expect(t, row_box.rect.min.x >= content.rect.min.x)
	testing.expect(t, row_box.rect.min.y >= content.rect.min.y)
	testing.expect(t, row_box.rect.max.x <= content.rect.max.x)
	testing.expect(t, row_box.rect.max.y <= content.rect.max.y)
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

@(test)
test_modal_input_scope_blocks_underlying_widgets :: proc(t: ^testing.T) {
	p: platform.Platform
	p.input.mb_down[.Left] = true
	p.input.mouse = {20, 20}
	s := State {
		p                  = &p,
		modal_input_active = true,
	}
	underlying := Box {
		key = Key(1),
		flags = {.Clickable},
		rect = {min = {0, 0}, max = {100, 100}},
	}
	modal_root := Box {
		key   = Key(2),
		flags = {.Modal_Input_Root},
	}
	modal_child := Box {
		parent = &modal_root,
		key = Key(3),
		flags = {.Clickable},
		rect = {min = {0, 0}, max = {100, 100}},
	}

	underlying_signal := signal_from_box(&s, &underlying)
	testing.expect(t, .Left_Pressed not_in underlying_signal.flags)
	modal_signal := signal_from_box(&s, &modal_child)
	testing.expect(t, .Left_Pressed in modal_signal.flags)
}

@(test)
test_modal_transition_preserves_focus_assigned_during_open_frame :: proc(t: ^testing.T) {
	s: State
	s.box_table = make(map[Key]^Box)
	defer delete(s.box_table)
	modal_root := Box {
		key   = Key(1),
		flags = {.Modal_Input_Root},
	}
	modal_edit := Box {
		parent = &modal_root,
		key    = Key(2),
	}
	underlying := Box {
		key = Key(3),
	}
	s.box_table[modal_root.key] = &modal_root
	s.box_table[modal_edit.key] = &modal_edit
	s.box_table[underlying.key] = &underlying

	s.keyboard_focus = modal_edit.key
	s.hot = modal_edit.key
	modal_input_set(&s, true)
	testing.expect_value(t, s.keyboard_focus, modal_edit.key)
	testing.expect_value(t, s.hot, modal_edit.key)

	s.modal_input_active = false
	s.keyboard_focus = underlying.key
	s.hot = underlying.key
	modal_input_set(&s, true)
	testing.expect_value(t, s.keyboard_focus, Key(0))
	testing.expect_value(t, s.hot, Key(0))
}
