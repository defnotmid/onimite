package onimite_app

import "core:fmt"
import "core:math"
import "../animation"
import ui "../ui"

// What every list in the preview is built from, after onib's
// (view/workspace_ui.odin, view/watch.odin) and laid out as RAD Debugger's:
// the UI's one scroll list, a filter's matched letters lit (RAD's fuzzy
// match ranges), and the filter row.

// The next box at `r` (window pixels), whatever its parents' places: only
// what floats over the layout (the panels' places in their tree, the
// lister, drop sites, a drag's label).
place :: proc(s: ^ui.State, r: Workspace_Rect) {
	ui.set_next_rect(s, {r.x, r.y, max(r.width, 0), max(r.height, 0)})
}

inside :: proc(r: Workspace_Rect, p: [2]f32) -> bool {return p.x >= r.x && p.y >= r.y && p.x < r.x + r.width && p.y < r.y + r.height}

// A text box in its parent's layout: `width` and `height` its sizes, its
// text left-aligned in `color`, `font_px` high and `padding` in.
text_box :: proc(s: ^ui.State, width, height: ui.Size, key: string, font_px, padding: f32, color := COLOR_TEXT) -> ^ui.Box {
	ui.set_next_pref_width(s, width); ui.set_next_pref_height(s, height)
	ui.set_next_font_size(s, font_px); ui.set_next_text_padding(s, padding)
	ui.set_next_text_align(s, .Left); ui.set_next_text_color(s, color)
	return ui.build_box(s, {.Draw_Text}, key)
}

// Every scrolled list in the preview is the UI's scroll list
// (ui.scroll_list_begin, after RAD Debugger's ui_scroll_list): its rows in a
// clipping box beside a scroll bar, `pitch` tall each, the rows' box fading
// at an edge while rows lie past it and taking the wheel at the list's end,
// unless a box in front of it took it first. A view's list follows the
// view's scroll register (View_Scroll sets it); an overlay's (the lister's)
// keeps its own. With a `cursor`, the list moves it by the keys while its
// focus is active and keeps it in view (RAD's Nav and Snap). The rows are
// built between list_begin and list_end, from `first` up to `last`.
list_begin :: proc(s: ^ui.State, l: ^animation.Scroll, dim: [2]f32, key: string, rows: int, pitch: f32, cursor: ^int = nil) -> (first, last: int) {
	return ui.scroll_list_begin(s, key, {max(dim.x, 0), max(dim.y, 0)}, l, rows, pitch, cursor)
}

// End an overlay's list: it goes where its bar, the wheel or its cursor asks
// (at once where its thumb is dragged).
list_end :: proc(s: ^ui.State, l: ^animation.Scroll) {
	if target, moved, jump := ui.scroll_list_end(s); moved {
		if jump do animation.scroll_jump(l, target)
		else do animation.scroll_to(l, target)
	}
}

// A view's list, presentation the view's data doesn't keep: its scroll,
// which follows the view's register, and its cursor row (RAD's).
View_List :: struct {
	scroll: animation.Scroll,
	cursor: int,
}

view_list :: proc(pv: ^Preview_State, view: View_Id) -> ^View_List {
	if len(pv.view_lists) < int(view) do resize(&pv.view_lists, int(view))
	return &pv.view_lists[view - 1]
}

// A view's rows: its list eases to the view's scroll register...
view_list_begin :: proc(app: ^App_State, s: ^ui.State, dim: [2]f32, view: View_Id, key: string, rows: int, pitch: f32, cursor: ^int = nil) -> (first, last: int) {
	l := view_list(&app.preview, view)
	animation.scroll_to(&l.scroll, f32(workspace_view(&app.preview.workspace, view).scroll))
	return list_begin(s, &l.scroll, dim, key, rows, pitch, cursor)
}

// ...and where its bar, the wheel or its cursor asks it to go (a whole
// row) is View_Scroll, its one writer (`flag`: a dragged thumb's, there at
// once).
view_list_end :: proc(app: ^App_State, s: ^ui.State, view: View_Id) {
	if target, moved, jump := ui.scroll_list_end(s); moved do command_push(&app.commands, .View_Scroll, {view = view, count = int(target), flag = jump})
}

// The byte ranges of `label` the filter matched (fuzzy_find), for a box to
// light (RAD's fuzzy match ranges); frame-lived.
fuzzy_ranges :: proc(label, filter: string) -> [][2]int {
	matched := make([dynamic]Fuzzy_Range, context.temp_allocator)
	if filter == "" || !fuzzy_find(label, filter, &matched) do return nil
	return column_ranges(matched[:], 0, len(label))
}

// The matched ranges falling in bytes [lo, hi) of what the matcher read (a
// column of it), from lo.
column_ranges :: proc(matched: []Fuzzy_Range, lo, hi: int) -> [][2]int {
	out := make([dynamic][2]int, context.temp_allocator)
	for m in matched {
		a, b := max(m.first, lo), min(m.last, hi)
		if a < b do append(&out, [2]int{a - lo, b - lo})
	}
	return out[:]
}

// A view's filter as typed: the text follows the view's filter while the
// field is idle, and an edit sends View_Filter. Its focus is RAD's search
// row's: it has the keys while `focused`, which a press on it (focusing its
// panel) or Search (Ctrl+F) sets, and a press elsewhere clears; Escape
// clears the filter and closes the row (RAD's query cancel).
Filter_Field :: struct {
	text:         [dynamic]u8,
	cursor, mark: int,
	focused:      bool,
}

// Whether a view has a filter row: every Watch.
view_filters :: proc(app: ^App_State, view: View_Id) -> bool {
	v := workspace_view(&app.preview.workspace, view)
	return v != nil && v.kind == .Watch
}

// A view's filter field, kept per view.
view_filter_field :: proc(pv: ^Preview_State, view: View_Id) -> ^Filter_Field {
	if len(pv.view_filters) < int(view) do resize(&pv.view_filters, int(view))
	return &pv.view_filters[view - 1]
}

// A row's height: three of the font's size (RAD's and onib's row_height),
// so rows follow the window's font size.
list_row_height :: proc(s: ^ui.State) -> f32 {return math.floor(ui.top_font_size(s) * 3)}

// A listing view's header, laid out: its filter row (a row tall, as RAD's
// search row), open while the filter holds text or its field has the keys,
// sliding open on Search (Ctrl+F) in its focused panel (after RAD
// Debugger's search row). Returns its height.
view_header :: proc(app: ^App_State, s: ^ui.State, view: View_Id, dpi: f32) -> f32 {
	pv := &app.preview
	field := view_filter_field(pv, view)
	v := workspace_view(&pv.workspace, view)
	open := len(v.filter) > 0 || field.focused
	t := ui.anim_f32(s, ui.key_from_string(0, fmt.tprintf("filter_open_%d", view)), open ? 1 : 0, {initial = open ? 1 : 0})
	height := list_row_height(s) * t
	if t <= 0.05 do return 0
	ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_pref_height(s, ui.px(height)); ui.set_next_child_layout_axis(s, .Y)
	row := ui.build_box(s, {.Clip}, fmt.tprintf("###filter_row_%d", view))
	ui.push_parent(s, row)
	defer ui.pop_parent(s)
	ui.spacer(s, ui.px(2 * dpi))
	ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_pref_height(s, ui.pct(1, 0)); ui.set_next_child_layout_axis(s, .X)
	ui.push_parent(s, ui.build_box(s, {}, fmt.tprintf("###filter_inset_%d", view)))
	ui.spacer(s, ui.px(4 * dpi))
	filter := string(v.filter[:])
	ui.push_focus(s, field.focused ? .On : .Off)
	focused := ui.is_focus_active(s)
	idle := !focused || string(field.text[:]) == filter
	if idle && string(field.text[:]) != filter {clear(&field.text); append(&field.text, filter); field.cursor = len(field.text); field.mark = field.cursor}
	// RAD's search row lights neither its overlay nor its border.
	ui.push_flags(s, {.Disable_Focus_Overlay, .Disable_Focus_Border})
	sig := ui.line_edit(s, &field.text, &field.cursor, &field.mark, {.Border})
	ui.pop_flags(s)
	ui.pop_focus(s)
	ui.spacer(s, ui.px(4 * dpi))
	ui.pop_parent(s)
	ui.spacer(s, ui.px(2 * dpi))
	// Pressed, it has the keys, its panel focused (RAD's search row press).
	if ui.pressed(sig) {field.focused = true; focus_panel(app, view)}
	// Escape, the row open and its panel focused (the keys or the rows
	// below had them), clears the filter and closes the row (RAD's query
	// cancel).
	ui.push_focus(s, .On)
	panel_focused := ui.is_focus_active(s)
	ui.pop_focus(s)
	if open && panel_focused && ui.action_pressed(s, .Cancel) {
		clear(&field.text); field.cursor, field.mark = 0, 0
		field.focused = false
	}
	if string(field.text[:]) != filter do command_push(&app.commands, .View_Filter, {view = view, spec = string(field.text[:])})
	// The field keeps the keys until a press elsewhere.
	r := sig.box.rect
	for a in s.actions.rows do if a.kind == .Mouse_Press && a.button == .Left && !inside({r.min.x, r.min.y, r.max.x - r.min.x, r.max.y - r.min.y}, a.position) do field.focused = false
	return height
}

// Before a view that takes keys builds: the left button's last press (RAD's
// press history), for view_press_focus after it.
view_press_mark :: proc(s: ^ui.State) -> f64 {return s.press_times[.Left][0]}

// After it builds: a press one of its boxes took focuses its panel (RAD's
// table-wide press, FocusPanel).
view_press_focus :: proc(app: ^App_State, s: ^ui.State, view: View_Id, mark: f64) {
	if s.press_times[.Left][0] != mark do focus_panel(app, view)
}

// A view that takes the pointer focuses its panel when pressed, as RAD's
// views run focus_panel: View_Select, sent only when its panel isn't
// focused already.
focus_panel :: proc(app: ^App_State, view: View_Id) {
	ws := &app.preview.workspace
	if v := workspace_view(ws, view); v != nil && v.panel != ws.focused do command_push(&app.commands, .View_Select, {view = view})
}
