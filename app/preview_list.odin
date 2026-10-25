package onimite_app

import "core:fmt"
import "core:strings"
import "../animation"
import platform "../platform"
import ui "../ui"

// What every list in the preview is built from, after onib's
// (view/workspace_ui.odin, view/watch.odin): boxes placed at window rects,
// one scrolled-list primitive, and a filter's matched letters lit.

// The next box at `r` (window pixels), whatever its parents' places.
place :: proc(s: ^ui.State, r: Workspace_Rect) {
	origin: [2]f32
	for b := ui.top_parent(s); b != nil; b = b.parent do origin += b.fixed_pos
	ui.set_next_fixed_x(s, r.x - origin.x); ui.set_next_fixed_y(s, r.y - origin.y)
	ui.set_next_fixed_width(s, max(r.width, 0)); ui.set_next_fixed_height(s, max(r.height, 0))
}

// A box at `r` with `flags`, its text left-aligned in `color`; its signal.
cell :: proc(s: ^ui.State, r: Workspace_Rect, key: string, flags: ui.Box_Flags, color := COLOR_TEXT) -> ui.Signal {
	place(s, r); ui.set_next_text_align(s, .Left); ui.set_next_text_color(s, color)
	return ui.signal_from_box(s, ui.build_box(s, flags, key))
}

inside :: proc(r: Workspace_Rect, p: [2]f32) -> bool {return p.x >= r.x && p.y >= r.y && p.x < r.x + r.width && p.y < r.y + r.height}

// Every scrolled list in the preview is this one primitive, over the UI's
// (after RAD Debugger's, as onib's): a clipping box whose wheel is its own
// while the pointer is over it, its scroll eased. A view's list follows the
// view's scroll register, which commands set; an overlay's (the lister's)
// keeps its own, and a row asked to show (list_show, a keyboard cursor)
// stays in view.
List :: struct {
	scroll:  animation.Scroll,
	contain: bool, // a show is pending
	cursor:  int, // the row asked to show
}

list_show :: proc(l: ^List, row: int) {l.cursor = row; l.contain = true}

// The list's clipping box over `r`, the parent until the caller pops it. Not
// clickable: the first clickable box under the pointer takes the hover, and
// that must be a row, not the box around them. Returns the first row shown,
// how far past it the list has scrolled, and the rows the wheel over it asks
// to move (the caller decides where that goes).
list_begin :: proc(s: ^ui.State, l: ^List, r: Workspace_Rect, key: string, rows_per_tick: f32 = 1) -> (first: int, fraction, wheel: f32) {
	place(s, r)
	ui.push_parent(s, ui.build_box(s, {.Clip}, key))
	if inside(r, platform.mouse_pos(s.p)) do wheel = -ui.action_scroll_consume(s, false, {r.x, r.y}, {r.x + r.width, r.y + r.height}, true) * rows_per_tick
	first, fraction = ui.scroll_page(s, &l.scroll)
	return
}

// An overlay's list scrolls itself; a manual scroll drops a pending show.
list_wheel :: proc(l: ^List, wheel: f32) {
	if wheel == 0 do return
	animation.scroll_by(&l.scroll, wheel)
	l.contain = false
}

// Once the rows are counted: the scroll stays within them, and a row asked
// to show comes into view.
list_limit :: proc(l: ^List, rows, visible: int) {
	ui.list_scroll_contain_selection(&l.scroll, &l.contain, l.cursor, visible, i32(max(0, rows - visible)))
}

// The letters of `label` the filter matched (fuzzy_positions), lit behind
// its text in `r`: left-aligned text `px` high, `pad` in.
match_marks :: proc(s: ^ui.State, r: Workspace_Rect, label, filter: string, px, pad: f32, id: string) {
	if filter == "" do return
	marks := fuzzy_positions(label, filter)
	if len(marks) == 0 do return
	// Byte offsets of the runs of consecutive matched letters.
	offsets := make([dynamic]int, context.temp_allocator)
	for _, at in label do append(&offsets, at)
	append(&offsets, len(label))
	for k := 0; k < len(marks); {
		run := k
		for run + 1 < len(marks) && marks[run + 1] == marks[run] + 1 do run += 1
		x0 := ui.line_edit_text_width(s, label[:offsets[marks[k]]], px)
		x1 := ui.line_edit_text_width(s, label[:offsets[marks[run] + 1]], px)
		place(s, {r.x + pad + x0, r.y + r.height * 0.15, max(1, x1 - x0), r.height * 0.7})
		ui.set_next_bg_color(s, {96, 150, 230, 70})
		ui.build_box(s, {.Draw_Background}, fmt.tprintf("###mark_%s_%d", id, k))
		k = run + 1
	}
}

// A view's list, presentation the view's data doesn't keep.
view_list :: proc(pv: ^Preview_State, view: View_Id) -> ^List {
	if len(pv.view_lists) < int(view) do resize(&pv.view_lists, int(view))
	return &pv.view_lists[view - 1]
}

// A view's rows: its list eases to the view's scroll (data, which
// View_Scroll sets), and the wheel over it sends View_Scroll, within the
// rows last counted.
view_list_begin :: proc(app: ^App_State, s: ^ui.State, r: Workspace_Rect, view: View_Id, key: string, rows_per_tick: f32 = 1) -> (first: int, fraction: f32) {
	v := workspace_view(&app.preview.workspace, view)
	l := view_list(&app.preview, view)
	animation.scroll_to(&l.scroll, f32(v.scroll))
	wheel: f32
	first, fraction, wheel = list_begin(s, l, r, key, rows_per_tick)
	if wheel != 0 do command_push(&app.commands, .View_Scroll, {view = view, count = int(clamp(l.scroll.track.target + wheel, 0, l.scroll.maximum) + 0.5)})
	return
}

// A view's filter as typed: the text follows the view's filter while the
// field is idle, and an edit sends View_Filter.
Filter_Field :: struct {
	text:   [dynamic]u8,
	cursor: int,
	key:    ui.Key, // its field's, once drawn
	open:   bool, // Ctrl+F asked for it
}

filter_field :: proc(app: ^App_State, s: ^ui.State, field: ^Filter_Field, r: Workspace_Rect, view: View_Id) {
	v := workspace_view(&app.preview.workspace, view)
	filter := string(v.filter[:])
	place(s, r)
	idle := s.keyboard_focus == 0 || string(field.text[:]) == filter
	if idle && string(field.text[:]) != filter {clear(&field.text); append(&field.text, filter); field.cursor = len(field.text)}
	sig := ui.line_edit(s, &field.text, &field.cursor)
	field.key = sig.box.key
	if string(field.text[:]) != filter do command_push(&app.commands, .View_Filter, {view = view, spec = string(field.text[:])})
	// The field keeps the keys until a press elsewhere or Escape.
	if s.keyboard_focus == sig.box.key && (platform.mouse_pressed(s.p, .Left) && !inside(r, platform.mouse_pos(s.p)) || ui.action_pressed(s, .Cancel)) do s.keyboard_focus = 0
}

FILTER_ROW :: 28

// A listing view's header: its filter row, open while the filter holds
// text or its field has the keys, and opened by Ctrl+F over the view
// (after RAD Debugger's search row, which slides open). Returns the rows'
// rect below.
view_header :: proc(app: ^App_State, s: ^ui.State, r: Workspace_Rect, view: View_Id, dpi: f32) -> Workspace_Rect {
	pv := &app.preview
	if len(pv.view_filters) < int(view) do resize(&pv.view_filters, int(view))
	field := &pv.view_filters[view - 1]
	focused := field.key != 0 && s.keyboard_focus == field.key
	if platform.ctrl_down(s.p) && platform.key_pressed(s.p, .F) && inside(r, platform.mouse_pos(s.p)) do field.open = true
	open := len(workspace_view(&pv.workspace, view).filter) > 0 || focused || field.open
	t := ui.anim_f32(s, ui.key_from_string(0, fmt.tprintf("filter_open_%d", view)), open ? 1 : 0, {initial = open ? 1 : 0, duration = 0.14, easing = .Cubic_Out})
	height := FILTER_ROW * dpi * t
	if t > 0.05 {
		filter_field(app, s, field, {r.x + 4 * dpi, r.y + 2 * dpi, r.width - 8 * dpi, height - 4 * dpi}, view)
		// Ctrl+F gives it the keys; it closes once they leave it empty.
		if field.open && field.key != 0 {s.keyboard_focus = field.key; field.open = false}
	}
	return {r.x, r.y + height, r.width, max(0, r.height - height)}
}
