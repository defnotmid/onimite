package ui

import "core:fmt"
import "core:unicode/utf8"

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

// scroll_list_begin builds one in-flow list boundary. The outer box owns the
// background and border; the inset child owns clipping and wheel input. Rows
// therefore cannot cover the border or escape its content rectangle.
scroll_list_begin :: proc(s: ^State, key: string, inset: f32 = 3) -> Signal {
	// RAD's scroll list always gives its top-level container explicit dimensions.
	// In this port the surrounding layout owns those dimensions, so consume any
	// caller override or fill the remaining parent extent by default.
	if !stack_has_override(&s.pref_width) && !stack_has_override(&s.fixed_width) {
		set_next_pref_width(s, fill())
	}
	if !stack_has_override(&s.pref_height) && !stack_has_override(&s.fixed_height) {
		set_next_pref_height(s, fill())
	}
	set_next_child_layout_axis(s, .Y)
	outer := build_box(s, {.Draw_Background, .Draw_Border}, key)
	push_parent(s, outer)

	spacer(s, px(inset))
	set_next_pref_width(s, fill())
	set_next_pref_height(s, fill())
	set_next_child_layout_axis(s, .X)
	middle := build_box(s, {}, fmt.tprintf("%s###middle", key))
	push_parent(s, middle)

	spacer(s, px(inset))
	set_next_pref_width(s, fill())
	set_next_pref_height(s, fill())
	set_next_child_layout_axis(s, .Y)
	content := build_box(s, {.Clip}, fmt.tprintf("%s###content", key))
	signal := signal_from_box(s, content)
	push_parent(s, content)
	return signal
}

scroll_list_end :: proc(s: ^State, inset: f32 = 3) {
	pop_parent(s) // content
	spacer(s, px(inset))
	pop_parent(s) // middle
	spacer(s, px(inset))
	pop_parent(s) // outer
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
	box.hot_color =
		selected ? lerp_u8(s.theme.accent, s.theme.hot, 0.22) : lerp_u8(background, s.theme.accent, 0.28)
	box.active_color = lerp_u8(box.hot_color, s.theme.active, 0.35)
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
	container := build_box(
		s,
		{.Clickable, .Click_To_Focus, .Draw_Hot_Effects, .Draw_Active_Effects},
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
		{initial = toggled^ ? 1 : 0, duration = 0.14, easing = .Cubic_Out},
	)

	push_parent(s, container)
	{
		track_width := height * 1.85
		thumb_size := max(4, height - 6)
		travel := max(0, track_width - thumb_size - 6)
		base := toggled^ ? s.theme.accent : s.theme.panel
		set_next_pref_width(s, px(track_width))
		set_next_pref_height(s, px(height))
		set_next_bg_color(s, lerp_u8(base, s.theme.hot, container.hot_t * 0.35))
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

// line_edit is a single-line text field. It consumes semantic text actions and
// handles Backspace. `buf` is the editable byte buffer
// and `cursor` the byte offset (kept at len(buf) here — end-insert). Focus is
// explicit: whichever line_edit was last left-clicked receives input while it
// owns State.keyboard_focus. Mouse-active state remains separate so focused
// edits do not suppress hover interaction elsewhere.
line_edit_text_width :: proc(s: ^State, text: string, font_size: f32) -> f32 {
	if s != nil && s.font != nil && s.font.text != nil {
		return render.measure_text(s.font, text, font_size)
	}
	return f32(len(text)) * font_size * 0.6
}

line_edit :: proc(s: ^State, buf: ^[dynamic]u8, cursor: ^int) -> Signal {
	set_next_pref_width(s, fill())
	set_next_pref_height(s, text_content(8))
	set_next_bg_color(s, s.theme.panel)
	set_next_text_align(s, .Left)
	key_str := fmt.tprintf("###edit_%p", buf)
	box := build_box(s, {.Clickable, .Draw_Background, .Draw_Border, .Draw_Text, .Clip}, key_str)
	sig := signal_from_box(s, box)

	// Focus is sticky on click, independent from the mouse-active key.
	if clicked(sig) {
		s.keyboard_focus = box.key
	}
	is_focused := s.keyboard_focus == box.key

	cursor^=clamp(cursor^,0,len(buf))
	if is_focused {
		for &action in s.actions.rows {
			if action.consumed do continue
			#partial switch action.kind {
			case .Text:
				bytes,count:=utf8.encode_rune(action.text)
				old:=len(buf); resize(buf,old+count)
				for i:=old-1; i>=cursor^; i-=1 do buf[i+count]=buf[i]
				copy(buf[cursor^:cursor^+count],bytes[:count])
				cursor^+=count; action.consumed=true
			case .Edit:
				if action.delta.x<0 && cursor^>0 {
					first:=cursor^-1
					for first>0 && buf[first]&0xC0==0x80 do first-=1
					count:=cursor^-first
					for i in cursor^..<len(buf) do buf[i-count]=buf[i]
					resize(buf,len(buf)-count); cursor^=first
				}
				action.consumed=true
			case .Navigate:
				if action.delta.x<0 && cursor^>0 {
					cursor^-=1; for cursor^>0 && buf[cursor^]&0xC0==0x80 do cursor^-=1
				} else if action.delta.x>0 && cursor^<len(buf) {
					cursor^+=1; for cursor^<len(buf) && buf[cursor^]&0xC0==0x80 do cursor^+=1
				}
				if action.delta.x!=0 do action.consumed=true
			}
		}
	}

	display := string(buf[:])
	box.str = display
	cursor^ = clamp(cursor^, 0, len(buf))
	cursor_target := line_edit_text_width(s, string(buf[:cursor^]), box.font_size)
	cursor_animated := anim_f32(
		s,
		key_from_string(box.key, "###cursor_off_px"),
		cursor_target,
		{initial = cursor_target, duration = 0.16, easing = .Cubic_Out},
	)
	if is_focused {
		cursor_x := box.text_padding + cursor_target
		animated_x := box.text_padding + cursor_animated
		caret_h := max(box.font_size, 2)
		caret_y := max(box.font_size * 0.2, 2)
		caret_w := max(1, box.font_size / 10)

		push_parent(s, box)
		trail_min := min(cursor_x, animated_x)
		trail_w := max(cursor_x, animated_x) - trail_min
		if trail_w > 0.5 {
			set_next_fixed_x(s, trail_min)
			set_next_fixed_y(s, caret_y)
			set_next_fixed_width(s, trail_w)
			set_next_fixed_height(s, caret_h)
			trail := build_box(s, {.Draw_Horizontal_Gradient}, "###cursor_trail")
			strong := s.theme.accent
			// RAD's current line-edit trail is one quarter of the cursor alpha,
			// with the trailing edge reduced to one tenth of that value.
			strong.a = u8(f32(strong.a) * 0.25)
			weak := strong
			weak.a = u8(f32(weak.a) * 0.1)
			if cursor_x > animated_x {
				trail.gradient_left = weak
				trail.gradient_right = strong
			} else {
				trail.gradient_left = strong
				trail.gradient_right = weak
			}
			trail.corner_radius = box.font_size * 0.2
		}
		set_next_fixed_x(s, cursor_x)
		set_next_fixed_y(s, caret_y)
		set_next_fixed_width(s, caret_w)
		set_next_fixed_height(s, caret_h)
		set_next_bg_color(s, s.theme.accent)
		build_box(s, {.Draw_Background}, "###cursor")
		pop_parent(s)
	}
	return sig
}
