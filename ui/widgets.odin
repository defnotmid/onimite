package ui

import "core:fmt"

import platform "../platform"

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
