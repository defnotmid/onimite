package ui

import "core:fmt"
import "core:math"
import "core:strings"
import vg "deps:ovg"

import platform "../platform"
import render "../render"

Progress_Bar_Params :: struct {
	height:        f32,
	background:    [4]u8,
	fill:          [4]u8,
	border:        [4]u8,
	corner_radius: f32,
}

////////////////////////////////
// Containers
//
// Containers build a box, push it as parent, and return true so they compose
// with `if ... { defer ui.pop_parent(s) ... }`. The caller pops the parent.

// row lays children left-to-right. Sized children_sum unless overridden.
row :: proc(s: ^State, key := "row") -> bool {
	set_next_child_layout_axis(s, .X)
	b := build_box(s, {}, fmt.tprintf("%s##row", key))
	push_parent(s, b)
	return true
}

// column lays children top-to-bottom.
column :: proc(s: ^State, key := "col") -> bool {
	set_next_child_layout_axis(s, .Y)
	b := build_box(s, {}, fmt.tprintf("%s##col", key))
	push_parent(s, b)
	return true
}

// panel is a floating, bordered, background-filled container anchored at
// (x, y) with an explicit size, laying children vertically. Good for windows.
panel :: proc(s: ^State, key: string, x, y, w, h: f32) -> bool {
	set_next_fixed_x(s, x)
	set_next_fixed_y(s, y)
	set_next_fixed_width(s, w)
	set_next_fixed_height(s, h)
	set_next_child_layout_axis(s, .Y)
	b := build_box(s, {.Draw_Background, .Draw_Border, .Clip}, key)
	push_parent(s, b)
	return true
}

////////////////////////////////
// Labels

// label draws non-interactive text sized to its content.
label :: proc(s: ^State, text: string) -> Signal {
	set_next_pref_width(s, text_content())
	set_next_pref_height(s, text_content())
	b := build_box(s, {.Draw_Text}, text)
	return signal_from_box(s, b)
}

// labelf is label with formatting. The formatted string is used for both the
// display and the identity, so unique text yields a unique key.
labelf :: proc(s: ^State, format: string, args: ..any) -> Signal {
	str := fmt.tprintf(format, ..args)
	return label(s, str)
}

////////////////////////////////
// Button

// button is a clickable box with background, border, centered text, and
// hot/active effects. Returns its Signal; use ui.clicked(sig).
button :: proc(s: ^State, text: string) -> Signal {
	// Widget defaults must not replace caller one-shot/scoped layout. This is
	// the same stack precedence used by RAD's UI macros.
	if !stack_has_override(&s.pref_width) && !stack_has_override(&s.fixed_width) {
		set_next_pref_width(s, text_content(20))
	}
	if !stack_has_override(&s.pref_height) && !stack_has_override(&s.fixed_height) {
		set_next_pref_height(s, text_content(8))
	}
	if !stack_has_override(&s.text_align) {
		set_next_text_align(s, .Center)
	}
	b := build_box(
		s,
		{
			.Clickable,
			.Click_To_Focus,
			.Draw_Background,
			.Draw_Border,
			.Draw_Text,
			.Draw_Hot_Effects,
			.Draw_Active_Effects,
		},
		text,
	)
	return signal_from_box(s, b)
}

////////////////////////////////
// Selection row

// selection_row_begin makes one keyed row the visual and interaction owner.
// Cells built beneath it remain presentation unless they publish an independent
// action of their own, as a toggle switch does.
selection_row_begin :: proc(
	s: ^State,
	key: string,
	selected: bool,
	background: [4]u8,
	corner_radius: f32 = 0,
) -> Signal {
	set_next_child_layout_axis(s, .X)
	set_next_bg_color(s, selected ? lerp_u8(background, s.theme.accent, 0.46) : background)
	set_next_corner_radius(s, corner_radius)
	box := build_box(
		s,
		{.Clickable, .Click_To_Focus, .Draw_Background, .Draw_Hot_Effects, .Draw_Active_Effects},
		key,
	)
	signal := signal_from_box(s, box)
	push_parent(s, box)
	return signal
}

////////////////////////////////
// Toggle switch

// RAD-style toggle: the keyed container owns interaction and animation; the
// track and thumb are presentation children of that one semantic control.
toggle_switch :: proc(s: ^State, toggled: ^bool, text: string, height: f32 = 18) -> Signal {
	set_next_child_layout_axis(s, .X)
	if !stack_has_override(&s.pref_width) && !stack_has_override(&s.fixed_width) {
		set_next_pref_width(s, children_sum())
	}
	if !stack_has_override(&s.pref_height) && !stack_has_override(&s.fixed_height) {
		set_next_pref_height(s, px(height))
	}
	set_next_bg_color(s, {0, 0, 0, 0})
	container := build_box(
		s,
		{.Clickable, .Click_To_Focus, .Draw_Background, .Draw_Hot_Effects, .Draw_Active_Effects},
		fmt.tprintf("###toggle_%s", text),
	)
	sig := signal_from_box(s, container)
	if clicked(sig) {
		toggled^ = !toggled^
	}
	toggle_t := anim_f32(
		s,
		key_from_string(container.key, "###toggle_t"),
		toggled^ ? 1 : 0,
		{initial = toggled^ ? 1 : 0},
	)

	push_parent(s, container)
	{
		track_width := height * 1.85
		thumb_size := max(4, height - 6)
		travel := max(0, track_width - thumb_size - 6)
		base := toggled^ ? s.theme.accent : s.theme.panel
		set_next_pref_width(s, px(track_width))
		set_next_pref_height(s, px(height))
		set_next_bg_color(s, base)
		set_next_corner_radius(s, height * 0.5)
		track := build_box(s, {.Draw_Background, .Draw_Border}, fmt.tprintf("###track_%s", text))
		push_parent(s, track)
		set_next_fixed_x(s, 3 + travel * toggle_t)
		set_next_fixed_y(s, 3)
		set_next_fixed_width(s, thumb_size)
		set_next_fixed_height(s, thumb_size)
		set_next_bg_color(s, s.theme.text)
		set_next_corner_radius(s, thumb_size * 0.5)
		build_box(s, {.Draw_Background}, fmt.tprintf("###thumb_%s", text))
		pop_parent(s)
		if display := display_part_from_string(text); display != "" {
			spacer(s, px(6))
			set_next_pref_width(s, text_content())
			set_next_pref_height(s, text_content())
			build_box(s, {.Draw_Text}, display)
		}
	}
	pop_parent(s)
	return sig
}

////////////////////////////////
// Slider

// slider drags a thumb between min and max, writing to `value`. Returns the
// track's Signal (dragging = actively adjusting). As toggle_switch, it
// sets its own size only where the caller set none, and the caller passes
// sizes in pixels (`height`: the track's and the thumb's).
slider :: proc(s: ^State, value: ^f32, min_v, max_v: f32, key: string = "", height: f32 = 20) -> Signal {
	if !stack_has_override(&s.pref_width) && !stack_has_override(&s.fixed_width) {
		set_next_pref_width(s, fill())
	}
	if !stack_has_override(&s.pref_height) && !stack_has_override(&s.fixed_height) {
		set_next_pref_height(s, px(height))
	}
	set_next_bg_color(s, s.theme.panel)
	set_next_hover_cursor(s, .Left_Right)
	track := build_box(
		s,
		{.Clickable, .Draw_Background, .Draw_Border},
		key != "" ? key : fmt.tprintf("###slider_%p", value),
	)
	sig := signal_from_box(s, track)

	// map interaction against last-frame track rect
	tw := track.rect.max.x - track.rect.min.x
	if (dragging(sig) || pressed(sig)) && tw > 0 {
		mp := platform.mouse_pos(s.p)
		t := (mp.x - track.rect.min.x) / tw
		t = clamp(t, 0, 1)
		value^ = min_v + t * (max_v - min_v)
	}
	value^ = clamp(value^, min_v, max_v)

	// thumb: floating within the track
	push_parent(s, track)
	{
		frac := max_v > min_v ? (value^ - min_v) / (max_v - min_v) : 0
		thumb_w := height * 0.6
		usable := tw - thumb_w
		if usable < 0 {usable = 0}
		set_next_fixed_x(s, frac * usable)
		set_next_fixed_y(s, 0)
		set_next_fixed_width(s, thumb_w)
		set_next_fixed_height(s, height)
		set_next_bg_color(s, s.theme.accent)
		set_next_corner_radius(s, height * 0.15)
		build_box(s, {.Draw_Background}, "###thumb")
	}
	pop_parent(s)
	return sig
}

////////////////////////////////
// Spacer & divider

// spacer inserts an empty, non-interactive gap of `size` along the parent's
// layout axis.
spacer :: proc(s: ^State, size: Size) {
	parent := top_parent(s)
	axis := parent != nil ? parent.child_layout_axis : Axis2.Y
	if axis == .X {
		set_next_pref_width(s, size)
		set_next_pref_height(s, fill())
	} else {
		set_next_pref_height(s, size)
		set_next_pref_width(s, fill())
	}
	build_box(s, {}, "")
}

// divider draws a 1px line filling the cross axis of the parent.
divider :: proc(s: ^State) {
	parent := top_parent(s)
	axis := parent != nil ? parent.child_layout_axis : Axis2.Y
	set_next_bg_color(s, s.theme.border)
	if axis == .Y {
		set_next_pref_width(s, fill())
		set_next_pref_height(s, px(1))
	} else {
		set_next_pref_height(s, fill())
		set_next_pref_width(s, px(1))
	}
	build_box(s, {.Draw_Background}, "")
}

// progress_bar builds a non-interactive keyed track and fill. Callers may push
// the returned track as a parent to add an activity pulse or other overlays.
progress_bar :: proc(s: ^State, key: string, value: f32, params: Progress_Bar_Params) -> ^Box {
	if !stack_has_override(&s.pref_width) && !stack_has_override(&s.fixed_width) {
		set_next_pref_width(s, fill())
	}
	if !stack_has_override(&s.pref_height) && !stack_has_override(&s.fixed_height) {
		set_next_pref_height(s, px(params.height))
	}
	set_next_child_layout_axis(s, .X)
	set_next_bg_color(s, params.background)
	set_next_border_color(s, params.border)
	set_next_corner_radius(s, params.corner_radius)
	track := build_box(s, {.Draw_Background, .Draw_Border, .Clip}, key)

	push_parent(s, track)
	fill_fraction := clamp(value, 0, 1)
	if fill_fraction > 0 {
		set_next_pref_width(s, pct(fill_fraction))
		set_next_pref_height(s, fill())
		set_next_bg_color(s, params.fill)
		set_next_corner_radius(s, 0)
		build_box(s, {.Draw_Background}, fmt.tprintf("%s_fill", key))
	}
	pop_parent(s)
	return track
}

////////////////////////////////
// Line edit

// A single-line text field, as RAD Debugger's rd_cell builds one: the field,
// an edit box filling it, a scroll box (Clip and Allow_Overflow_X while
// editing) and the text box after a half-em spacer. Its focus is rd_cell's:
// the focus stacks' (focus.odin), or its navigation root's key. Focus active,
// it is being edited: the text is kept whole, the scroll box's view offset
// keeps the cursor between two ems from its left and one from its right, and
// it takes Text, Edit and Navigate rows with no vertical step (the rest go on
// to lists) through text_op_from_action, the frame in text-edit mode. Not
// active, the text is cut to "..." and the view rests at 0; a double click,
// its keyboard press, or typing while it is focus hot starts editing (its
// root makes it active from the next frame) with all its text selected, and
// editing, its keyboard press ends it. Editing, a press puts the cursor and
// mark under the pointer and a drag moves the cursor.
// As RAD's rd_cell flags: a cell draws its background unless No_Background,
// and a border only with Border.
Line_Edit_Flag :: enum u8 {
	No_Background,
	Border,
}
Line_Edit_Flags :: bit_set[Line_Edit_Flag;u8]
line_edit :: proc(s: ^State, buf: ^[dynamic]u8, cursor, mark: ^int, cell: Line_Edit_Flags = {}) -> Signal {
	key_str := fmt.tprintf("###edit_%p", buf)
	key := key_from_string(active_seed_key(s), key_str)
	auto_hot, auto_active := is_key_auto_focus_hot(s, key), is_key_auto_focus_active(s, key)
	if auto_hot do push_focus_hot(s, .On)
	if auto_active do push_focus_active(s, .On)
	defer {if auto_hot do pop_focus_hot(s); if auto_active do pop_focus_active(s)}
	focus_hot, focused := is_focus_hot(s), is_focus_active(s)
	focused_disabled := !focused && top_focus_active(s) == .On
	set_next_pref_width(s, fill())
	set_next_pref_height(s, text_content(8))
	set_next_bg_color(s, s.theme.panel)
	set_next_child_layout_axis(s, .X)
	flags := Box_Flags{.Clickable, .Click_To_Focus}
	if .No_Background not_in cell do flags += {.Draw_Background}
	if .Border in cell do flags += {.Draw_Border}
	if auto_hot || auto_active do flags += {.Keyboard_Clickable}
	if focused || focused_disabled do flags += {.Clip}
	set_next_hover_cursor(s, .IBar if focused else .Pointer)
	box := build_box(s, flags, key_str)
	sig := signal_from_box(s, box)
	started := false
	if !focused {
		typing := false
		if focus_hot do for a in s.actions.rows do if !a.consumed && (a.text != "" || .Paste in a.flags) {typing = true; break}
		if double_clicked(sig) || keyboard_pressed(sig) || typing {
			set_auto_focus_active_key(s, key)
			cursor^, mark^ = len(buf), 0
			started = true
		}
	} else if keyboard_pressed(sig) {
		set_auto_focus_active_key(s, 0)
	}
	cursor^, mark^ = clamp(cursor^, 0, len(buf)), clamp(mark^, 0, len(buf))
	if focused || started {
		s.text_edit_mode = true
		for &a in s.actions.rows {
			if a.consumed || a.kind != .Edit && a.kind != .Navigate && a.kind != .Text || a.delta.y != 0 do continue
			op := text_op_from_action(a, string(buf[:]), {0, len(buf)}, cursor^, mark^)
			if op.range[0] != op.range[1] || op.replace != "" do text_replace_range(buf, op.range, op.replace)
			if .Copy in a.flags do platform.set_clipboard(op.copy)
			cursor^, mark^ = op.cursor, op.mark
			a.consumed = true
		}
	}
	text := strings.clone(string(buf[:]), context.temp_allocator)
	fs := box.font_size
	push_parent(s, box)
	set_next_pref_width(s, pct(1, 0)); set_next_pref_height(s, pct(1)); set_next_child_layout_axis(s, .X)
	edit_box := build_box(s, {}, "edit_box")
	push_parent(s, edit_box)
	set_next_pref_width(s, children_sum(0)); set_next_pref_height(s, pct(1)); set_next_child_layout_axis(s, .X)
	scroll := build_box(s, focused ? {.Allow_Overflow_X, .Clip} : {}, "scroll_box")
	push_parent(s, scroll)
	set_next_pref_width(s, px(fs * 0.5)); set_next_pref_height(s, pct(1))
	build_box(s, {}, "")
	set_next_pref_width(s, text_content(fs * 0.5, 0)); set_next_pref_height(s, pct(1))
	text_box := build_box(s, {.Draw_Text} + (focused ? {.Disable_Text_Trunc} : {}), "###text_box")
	text_box.str = text
	mouse_off, cursor_off := 0, f32(0)
	if focused || focused_disabled {
		draw := new(Line_Edit_Draw, context.temp_allocator)
		draw^ = {text = text, cursor = cursor^, mark = mark^, trail = !dragging(sig)}
		box_equip_custom_draw(text_box, line_edit_draw, draw)
		box_text_metrics_ensure(s, text_box)
		mouse_off = render.slot_offset_at(s.font, text_box.text_slot, text, platform.mouse_pos(s.p).x - box_text_position(s, text_box).x)
		cursor_off = line_edit_text_width(s, text[:cursor^], fs)
	}
	pop_parent(s); pop_parent(s); pop_parent(s)
	if focused && dragging(sig) {
		if pressed(sig) do mark^ = mouse_off
		cursor^ = mouse_off
	}
	if !focused && focused_disabled && pressed(sig) do cursor^, mark^ = mouse_off, mouse_off
	// The cursor kept in view: from two ems before it to one after.
	if focused || focused_disabled {
		visible := (box.rect.max.x - box.rect.min.x) - math.floor(fs * 2)
		if visible > 0 {
			lo, hi := max(0, cursor_off - fs * 2), max(0, cursor_off + fs)
			view := scroll.view_off_target.x
			scroll.view_off_target.x += min(lo - view, 0) + max(hi - (view + visible), 0)
		}
	} else {
		scroll.view_off_target.x = 0; scroll.view_off.x = 0
	}
	return sig
}
line_edit_text_width :: proc(s: ^State, text: string, font_size: f32) -> f32 {
	if s != nil && s.font != nil && s.font.text != nil {
		return render.measure_text(s.font, text, font_size)
	}
	return f32(len(text)) * font_size * 0.6
}
// What a focused field's text box draws over its text (RAD's
// UI_LineEditDrawData).
Line_Edit_Draw :: struct {
	text:         string,
	cursor, mark: int,
	trail:        bool,
}
// As RAD's ui_line_edit_draw: the selection from the mark to the cursor, the
// cursor, and a faint trail sweeping from where the cursor was, fading toward
// that end.
line_edit_draw :: proc(s: ^State, box: ^Box, c: ^vg.Canvas) {
	d := (^Line_Edit_Draw)(box.custom_data)
	fs := box.font_size
	at := box_text_position(s, box)
	off := line_edit_text_width(s, d.text[:d.cursor], fs)
	animated := anim_f32(s, key_from_string(box.key, "###cursor_off_px"), off, {initial = off})
	mark_off := line_edit_text_width(s, d.text[:d.mark], fs)
	thick := max(1, math.floor(fs / 10))
	field := box.parent.parent.rect
	y0, y1 := field.min.y + fs * 0.5, field.max.y - fs * 0.5
	rect :: proc(s: ^State, c: ^vg.Canvas, x0, y0, x1, y1, radius: f32, paint: vg.Paint) {
		r := min(radius, (x1 - x0) / 2, (y1 - y0) / 2)
		box_path(&s.path, x0, y0, x1 - x0, y1 - y0, {r, r, r, r})
		vg.fill_path(c, &s.path, paint)
	}
	cx := at.x + off
	mx := at.x + mark_off
	focus := box.parent.parent.focus_active_t
	rect(s, c, min(cx, mx - thick), y0, max(cx + thick, mx + thick), y1, fs / 2, vg.paint_color(color(s.theme.selection, box.opacity * (focus * 0.2 + 0.8))))
	rect(s, c, cx, y0, cx + thick, y1, 0, vg.paint_color(color(s.theme.accent, box.opacity * focus)))
	if d.trail && off != animated {
		lo, hi := at.x + min(off, animated), at.x + max(off, animated)
		strong := color(s.theme.accent, box.opacity * focus * 0.25)
		weak := strong; weak.a *= 0.1
		left, right := strong, weak
		if off > animated do left, right = weak, strong
		rect(s, c, lo, y0, hi, y1, fs * 0.2, vg.paint_linear_gradient(lo, y0, hi, y0, left, right))
	}
}
