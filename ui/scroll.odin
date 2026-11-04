package ui

import "../animation"
import "core:fmt"
import "core:math"

// The shared scroll presentation primitive. Call once per visible scroll area;
// views receive a page plus a fractional offset and never implement easing.
scroll_page :: proc(s: ^State, scroll: ^animation.Scroll) -> (first: int, fraction: f32) {
	if animation.scroll_advance(scroll, s.p.frame_dt) do s.is_animating = true
	return animation.scroll_page(scroll)
}

// The scroll list, after RAD Debugger's ui_scroll_list_begin/end, laid out
// as RAD's: a container `dim` big in its parent's layout, holding the rows'
// clipping box and, beside it, the scroll bar. The rows are built into the
// rows' box, `row_height` tall each (the pref height it pushes), from the
// first shown, its view offset the scroll's fraction of a row. The rows' box
// fades its top or bottom edge while rows lie past it, and takes the wheel at
// the list's end, after its rows. `scroll` eases toward the index of the
// first row shown, as RAD's: from the first row to the last (the last row at
// the top), and a scroll outside that range goes back to its start (RAD's
// scroll_row_idx_range and ui_scroll_pt_clamp_idx).
Scroll_List :: struct {
	content: ^Box, // the rows' clipping box
	scroll:  ^animation.Scroll,
	target:  f32, // where the bar or the cursor's snap asked to go this frame
	moved:   bool,
	jump:    bool, // the bar's thumb dragged: there at once (RAD's off = 0)
}
// RAD's UI_ScrollListRowBlock: `row_count` rows of the list holding
// `item_count` items (an item taller than a row is one item in a block of
// its rows).
Scroll_List_Row_Block :: struct {
	row_count, item_count: int,
}
// The first row of `item` (RAD's ui_scroll_list_row_from_item).
scroll_list_row_from_item :: proc(blocks: []Scroll_List_Row_Block, item: int) -> int {
	row, at := 0, 0
	for b in blocks {
		if at <= item && item < at + b.item_count do return row + (item - at) * (b.row_count / b.item_count)
		row += b.row_count
		at += b.item_count
	}
	return 0
}
// The item at `row`: its block's first (RAD's ui_scroll_list_item_from_row).
scroll_list_item_from_row :: proc(blocks: []Scroll_List_Row_Block, row: int) -> int {
	r, at := 0, 0
	for b in blocks {
		if r <= row && row < r + b.row_count do return at
		r += b.row_count
		at += b.item_count
	}
	return 0
}
// The scroll bar's width: one and a half of the font, as RAD's.
scroll_bar_width :: proc(s: ^State) -> f32 {return math.round(stack_top(&s.font_size, s.theme.default_font_px) * s.font_scale * 1.5)}
// Begin a list of `rows` in a box `dim` big (in its parent's layout), each
// `row_height` tall; returns the first row shown and the last (one past).
// `row_blocks` (RAD's) map items to rows for a cursor over items taller
// than a row. With a `cursor` (a row), the list has RAD's keyboard navigation and snap
// (UI_ScrollListFlag_Nav, _Snap): while its focus is active it takes every
// row with a delta that deletes nothing, a Char step moving the cursor a row
// (past either end, round to the other), a Word, Line or Page step three rows
// short of what is in view, a Whole step to an end; a cursor that moved
// scrolls into view with a row around it.
scroll_list_begin :: proc(s: ^State, key: string, dim: [2]f32, scroll: ^animation.Scroll, rows: int, row_height: f32, cursor: ^int = nil, row_blocks: []Scroll_List_Row_Block = nil) -> (first, last: int) {
	bar := scroll_bar_width(s)
	visible := max(1, int(dim.y / max(row_height, 1)))
	maximum := f32(max(0, rows - 1))
	snapped := false
	if scroll.track.target > maximum {
		scroll.maximum = maximum
		animation.scroll_to(scroll, 0)
		snapped = true
	}
	animation.scroll_limit(scroll, maximum)
	if cursor != nil && is_focus_active(s) {
		c, moved := cursor^, false
		for &a in s.actions.rows {
			if a.consumed || a.delta == {} || .Delete in a.flags do continue
			a.consumed = true
			moved = true
			switch a.delta_unit {
			case .Null:
				moved = false
			case .Char:
				c += int(a.delta.y)
				if c < 0 do c = rows - 1
				if c > rows - 1 do c = 0
			case .Word, .Line, .Page:
				c += a.delta.y > 0 ? visible - 3 : a.delta.y < 0 ? -(visible - 3) : 0
				c = clamp(c, 0, max(rows - 1, 0))
			case .Whole:
				if a.delta.y != 0 do c = a.delta.y > 0 ? rows - 1 : 0
			}
		}
		if moved {
			cursor^ = clamp(c, 0, max(rows - 1, 0))
			// The cursor's rows: its item's, or a row around it (RAD's).
			idx := int(scroll.track.target)
			lo, hi := idx, idx + visible + 1
			c_lo, c_hi := cursor^ - 1, cursor^ + 3
			if len(row_blocks) > 0 {
				c_lo = scroll_list_row_from_item(row_blocks, cursor^)
				c_hi = c_lo + 4
			}
			idx += min(0, c_lo - lo) + max(0, c_hi - hi)
			before := scroll.track.target
			animation.scroll_to(scroll, f32(clamp(idx, 0, max(rows - 1, 0))))
			snapped ||= scroll.track.target != before
		}
	}
	fraction: f32
	first, fraction = scroll_page(s, scroll)
	last = min(rows, first + visible + 1)
	set_next_fixed_width(s, dim.x); set_next_fixed_height(s, dim.y); set_next_child_layout_axis(s, .X)
	container := build_box(s, {}, key)
	push_parent(s, container)
	fades: Box_Flags
	if first > 0 do fades += {.Draw_Fade_Top}
	if first + visible < rows do fades += {.Draw_Fade_Bottom}
	set_next_fixed_width(s, max(0, dim.x - bar)); set_next_fixed_height(s, dim.y); set_next_child_layout_axis(s, .Y)
	content := build_box(s, {.Clip, .Allow_Overflow_Y, .Scroll} | fades, fmt.tprintf("%s###rows", key))
	content.view_off.y, content.view_off_target.y = row_height * fraction, row_height * fraction
	// The bar outside any focus (RAD's UI_Focus(Null)): a list's focus
	// lights its rows, never the bar's parts.
	push_focus(s, .Null)
	set_next_fixed_width(s, bar); set_next_fixed_height(s, dim.y)
	target, moved, jump := scroll_bar(s, scroll, rows, visible, fmt.tprintf("%s###bar", key))
	pop_focus(s)
	if snapped && !moved do target, moved = scroll.track.target, true
	s.scroll_list = {content, scroll, target, moved, jump}
	push_parent(s, content)
	push_pref_height(s, px(row_height))
	return
}
// End the list begun last: the rows' box takes the wheel over it (what no
// box in front of it took), a row a step (three a notch), as RAD's (new_idx
// = idx + sig.scroll.y). Returns where the bar, the wheel or the cursor asks
// the list to go, if any moved it, and whether it goes there at once (`jump`:
// the bar's thumb dragged, RAD's off = 0); the caller decides where that
// goes (a view's scroll register, an overlay's own).
scroll_list_end :: proc(s: ^State) -> (target: f32, moved, jump: bool) {
	l := s.scroll_list
	pop_pref_height(s)
	pop_parent(s) // the rows' box
	pop_parent(s) // the container
	target, moved, jump = l.target, l.moved, l.jump
	if wheel := signal_from_box(s, l.content).scroll.y; wheel != 0 {
		target = (moved ? target : l.scroll.track.target) + wheel
		moved, jump = true, false
	}
	target = clamp(target, 0, l.scroll.maximum)
	return
}
// The vertical scroll bar, after RAD Debugger's ui_scroll_bar and laid out
// as it: in the box its caller sized, a button at each end stepping a row a
// frame while held, the area between (its parts before and after the thumb
// stepping a row a frame toward their side while held) and the thumb, sized
// to the rows in view (at least a twentieth) and placed at the index the
// list goes to (RAD's pt.idx), which drags from where the list was when it
// was pressed (the stored drag state) to a whole index, at once (`jump`:
// RAD's off = 0). Disabled (dimmed, inert) when nothing scrolls.
SCROLL_UP_ICON :: "M7 14.5 L12 9.5 L17 14.5"
SCROLL_DOWN_ICON :: "M7 9.5 L12 14.5 L17 9.5"
ICONS := [?]string{SCROLL_UP_ICON, SCROLL_DOWN_ICON}
scroll_bar :: proc(s: ^State, scroll: ^animation.Scroll, rows, visible: int, key: string) -> (target: f32, moved, jump: bool) {
	target = scroll.track.target
	idx := math.floor(target)
	maximum := scroll.maximum
	enabled := maximum > 0
	if !enabled do push_opacity(s, 0.4)
	defer if !enabled do pop_opacity(s)
	set_next_child_layout_axis(s, .Y)
	container := build_box(s, {.Draw_Border}, key)
	push_parent(s, container)
	defer pop_parent(s)
	width := container.fixed_size.x
	clickable: Box_Flags = enabled ? {.Clickable} : {}
	arrow :: proc(s: ^State, width: f32, icon, key: string, clickable: Box_Flags) -> Signal {
		set_next_pref_width(s, pct(1)); set_next_pref_height(s, px(width)); set_next_icon(s, icon)
		return signal_from_box(s, build_box(s, clickable + {.Draw_Background, .Draw_Border, .Draw_Icon, .Draw_Hot_Effects, .Draw_Active_Effects}, key))
	}
	up := arrow(s, width, SCROLL_UP_ICON, "###up", clickable)
	set_next_pref_width(s, pct(1)); set_next_pref_height(s, pct(1, 0)); set_next_child_layout_axis(s, .Y)
	area := build_box(s, {}, "###area")
	push_parent(s, area)
	// As RAD's: the parts before and after the thumb are the rows above the
	// first shown and below it, the thumb the rows in view, out of the
	// scroll's range (rows - 1); what doesn't fit is squished away.
	all := f32(max(rows - 1, 1))
	before_signal, after_signal: Signal
	if enabled {
		set_next_pref_width(s, pct(1)); set_next_pref_height(s, pct(idx / all, 0))
		before_signal = signal_from_box(s, build_box(s, clickable, "###before"))
	}
	set_next_pref_width(s, pct(1)); set_next_pref_height(s, pct(clamp(f32(visible) / all, 0.05, 1), 0))
	thumb := build_box(s, clickable + {.Draw_Background, .Draw_Border, .Draw_Hot_Effects, .Draw_Active_Effects}, "###thumb")
	scroller := signal_from_box(s, thumb)
	if enabled {
		set_next_pref_width(s, pct(1)); set_next_pref_height(s, pct(1 - idx / all, 0))
		after_signal = signal_from_box(s, build_box(s, clickable, "###after"))
	}
	pop_parent(s)
	down := arrow(s, width, SCROLL_DOWN_ICON, "###down", clickable)
	if !enabled do return
	// The thumb follows the pointer from where the list was when it was
	// pressed, over the area's free length.
	Scroll_Bar_Drag :: struct {
		start, space: f32,
	}
	if dragging(scroller) {
		if pressed(scroller) {
			d := Scroll_Bar_Drag{idx, math.floor(box_size(area).y) - math.floor(box_size(thumb).y)}
			store_drag_struct(s, &d)
		}
		d := drag_struct(s, Scroll_Bar_Drag)^
		target = f32(int(d.start + (d.space > 0 ? drag_delta(s).y / d.space * all : 0)))
		moved, jump = true, true
	}
	if dragging(up) || dragging(before_signal) {target -= 1; moved = true}
	if dragging(down) || dragging(after_signal) {target += 1; moved = true}
	target = clamp(target, 0, maximum)
	return
}
