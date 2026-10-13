package ui

import "core:fmt"
import "core:unicode/utf8"

import platform "../platform"
import render "../render"

////////////////////////////////
// Containers
//
// Containers build a box, push it as parent, and return true so they compose
// with `if ... { defer ui.pop_parent(s) ... }`. The caller pops the parent.

// row lays children left-to-right.
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
	if s.next.pref_width == nil && s.next.fixed_width == nil {
		set_next_pref_width(s, fill())
	}
	if s.next.pref_height == nil && s.next.fixed_height == nil {
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

////////////////////////////////
// Button

// button is a clickable box with background, border, centered text, and
// hot/active effects. Returns its Signal; use ui.clicked(sig).
button :: proc(s: ^State, text: string) -> Signal {
	// Widget defaults must not replace the caller's one-shot layout, as in
	// RAD's UI macros.
	if s.next.pref_width == nil && s.next.fixed_width == nil {
		set_next_pref_width(s, text_content(20))
	}
	if s.next.pref_height == nil && s.next.fixed_height == nil {
		set_next_pref_height(s, text_content(8))
	}
	if s.next.text_align == nil {
		set_next_text_align(s, .Center)
	}
	b := build_box(
		s,
		{
			.Clickable,
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
// Slider

// slider_value is a track whose fill shows `value`; it never writes: it
// returns the value under the pointer while pressed or dragged (`changed`),
// so the caller can push it as a command. The track takes the caller's size (default fill x 20 px).
slider_value :: proc(s: ^State, key: string, value, min_v, max_v: f32) -> (next: f32, changed: bool, sig: Signal) {
	if s.next.pref_width == nil && s.next.fixed_width == nil {
		set_next_pref_width(s, fill())
	}
	if s.next.pref_height == nil && s.next.fixed_height == nil {
		set_next_pref_height(s, px(20))
	}
	track := build_box(s, {.Clickable, .Draw_Background, .Draw_Hot_Effects}, key)
	sig = signal_from_box(s, track)
	next = clamp(value, min_v, max_v)
	tw := track.rect.max.x - track.rect.min.x
	th := track.rect.max.y - track.rect.min.y
	if (dragging(sig) || pressed(sig)) && tw > 0 {
		t := clamp((platform.mouse_pos(s.p).x - track.rect.min.x) / tw, 0, 1)
		next = min_v + t * (max_v - min_v)
		changed = next != value
	}
	frac := (next - min_v) / (max_v - min_v) if max_v > min_v else 0
	push_parent(s, track)
	set_next_fixed_x(s, 0)
	set_next_fixed_y(s, 0)
	set_next_fixed_width(s, max(frac * tw, 0))
	set_next_fixed_height(s, th)
	set_next_bg_color(s, s.theme.accent)
	build_box(s, {.Draw_Background}, "###fill")
	pop_parent(s)
	return
}

////////////////////////////////
// Spacer

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

////////////////////////////////
// List scrolling
//
// A list's scroll is the first row it shows, a row index the caller
// keeps; these keep it inside the list and the selection in view, and
// ease the rows between scroll positions.

// Moves `first` by the wheel (`wheel`, up positive) and keeps it within the
// `count` rows of which `visible` show. Returns whether the wheel moved it,
// which cancels following the selection until it moves again.
list_scroll_apply :: proc(first: ^int, wheel: f32, visible, count: int, rows_per_tick: f32 = 2) -> (scrolled: bool) {
	if wheel != 0 {
		first^ -= int(wheel * rows_per_tick)
		scrolled = true
	}
	first^ = clamp(first^, 0, max(count - visible, 0))
	return
}

// Scrolls `first` just enough that row `selected` is among the `visible`
// rows shown.
list_scroll_contain_selection :: proc(first: ^int, selected, visible, count: int) {
	if selected < first^ {
		first^ = selected
	} else if selected >= first^ + visible {
		first^ = selected - visible + 1
	}
	first^ = clamp(first^, 0, max(count - visible, 0))
}

// The row to build first and the fraction of a row the list is scrolled
// past it, easing toward `first` (keyed by the list).
scroll_page :: proc(s: ^State, key: Key, first: int) -> (row: int, fraction: f32) {
	at := anim_f32(s, key_from_string(key, "###scroll"), f32(first), {initial = f64(first), duration = 0.12, easing = .Cubic_Out})
	row = int(max(at, 0))
	return row, max(at, 0) - f32(row)
}

////////////////////////////////
// Line edit

// line_edit is a one-line text field on `buf` with a cursor at byte
// `cursor`. While it has keyboard focus (a click gives it; the caller may
// set State.keyboard_focus to its box's key) it takes the frame's text and
// editing keys: Backspace, Delete, Left, Right, Home, End; and keeps the
// window's text events on. `placeholder` shows, dimmed, while it is empty.
// The caller sizes it (default fill x 28 px).
line_edit :: proc(s: ^State, key: string, buf: ^[dynamic]u8, cursor: ^int, placeholder := "") -> Signal {
	if s.next.pref_width == nil && s.next.fixed_width == nil {
		set_next_pref_width(s, fill())
	}
	if s.next.pref_height == nil && s.next.fixed_height == nil {
		set_next_pref_height(s, px(28))
	}
	if s.next.bg_color == nil {
		set_next_bg_color(s, s.theme.background)
	}
	set_next_text_align(s, .Left)
	box := build_box(s, {.Clickable, .Draw_Background, .Draw_Border, .Draw_Text, .Clip}, key)
	sig := signal_from_box(s, box)
	if clicked(sig) {
		s.keyboard_focus = box.key
	}
	focused := box.key != Key(0) && s.keyboard_focus == box.key
	cursor^ = clamp(cursor^, 0, len(buf))
	if focused {
		s.text_wanted = true
		line_edit_apply(s, buf, cursor)
	}
	box.str = string(buf[:])
	if len(buf) == 0 && placeholder != "" {
		box.str = placeholder
		box.text_color = lerp_u8(box.text_color, box.bg_color, 0.5)
	}
	if focused {
		// The caret, easing to where the cursor is.
		before := string(buf[:cursor^])
		target := box.text_padding + (render.measure_text(s.font, before, box.font_size) if s.font != nil else 0)
		x := anim_f32(s, key_from_string(box.key, "###caret"), target, {initial = f64(target), duration = 0.08, easing = .Cubic_Out})
		push_parent(s, box)
		set_next_fixed_x(s, x)
		set_next_fixed_y(s, 4)
		set_next_fixed_width(s, max(1, box.font_size / 10))
		set_next_fixed_height(s, max(box.rect.max.y - box.rect.min.y - 8, 2))
		set_next_bg_color(s, s.theme.accent)
		set_next_corner_radius(s, 0)
		build_box(s, {.Draw_Background}, "###caret")
		pop_parent(s)
	}
	return sig
}

// Applies the frame's text and editing keys to `buf` at `cursor`, claiming
// them; whole UTF-8 characters at a time.
line_edit_apply :: proc(s: ^State, buf: ^[dynamic]u8, cursor: ^int) {
	continuation :: proc(b: u8) -> bool {return b & 0xC0 == 0x80}
	for &action in s.actions.rows {
		if action.consumed {
			continue
		}
		switch {
		case action.kind == .Text:
			bytes, n := utf8.encode_rune(action.text)
			inject_at(buf, cursor^, ..bytes[:n])
			cursor^ += n
		case action.kind == .Key && !action.control:
			#partial switch action.key {
			case .Backspace:
				if cursor^ > 0 {
					first := cursor^ - 1
					for first > 0 && continuation(buf[first]) {
						first -= 1
					}
					remove_range(buf, first, cursor^)
					cursor^ = first
				}
			case .Delete:
				if cursor^ < len(buf) {
					last := cursor^ + 1
					for last < len(buf) && continuation(buf[last]) {
						last += 1
					}
					remove_range(buf, cursor^, last)
				}
			case .Left:
				for cursor^ > 0 {
					cursor^ -= 1
					if !continuation(buf[cursor^]) {
						break
					}
				}
			case .Right:
				for cursor^ < len(buf) {
					cursor^ += 1
					if cursor^ == len(buf) || !continuation(buf[cursor^]) {
						break
					}
				}
			case .Home:
				cursor^ = 0
			case .End:
				cursor^ = len(buf)
			case:
				continue
			}
		case:
			continue
		}
		action.consumed = true
	}
}
