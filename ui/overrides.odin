package ui

// One-shot overrides, as raddbg's set_next_*: each applies to the very next
// build_box only, which consumes them all.
//
//     ui.set_next_pref_width(s, ui.px(120))
//     ui.button(s, "OK")
//
// Containers (row/column/panel) push themselves as parent and return true;
// pop them with `defer`:
//
//     if ui.column(s, "left") { defer ui.pop_parent(s)
//         ui.label(s, "hello")
//     }
Box_Overrides :: struct {
	pref_width:        Maybe(Size),
	pref_height:       Maybe(Size),
	child_layout_axis: Maybe(Axis2),
	fixed_x:           Maybe(f32),
	fixed_y:           Maybe(f32),
	fixed_width:       Maybe(f32),
	fixed_height:      Maybe(f32),
	text_align:        Maybe(Text_Align),
	bg_color:          Maybe([4]u8),
	text_color:        Maybe([4]u8),
	corner_radius:     Maybe(f32),
	font_size:         Maybe(f32),
	text_padding:      Maybe(f32),
}

set_next_pref_width :: proc(s: ^State, v: Size) {s.next.pref_width = v}
set_next_pref_height :: proc(s: ^State, v: Size) {s.next.pref_height = v}
set_next_child_layout_axis :: proc(s: ^State, v: Axis2) {s.next.child_layout_axis = v}
set_next_fixed_x :: proc(s: ^State, v: f32) {s.next.fixed_x = v}
set_next_fixed_y :: proc(s: ^State, v: f32) {s.next.fixed_y = v}
set_next_fixed_width :: proc(s: ^State, v: f32) {s.next.fixed_width = v}
set_next_fixed_height :: proc(s: ^State, v: f32) {s.next.fixed_height = v}
set_next_text_align :: proc(s: ^State, v: Text_Align) {s.next.text_align = v}
set_next_bg_color :: proc(s: ^State, v: [4]u8) {s.next.bg_color = v}
set_next_text_color :: proc(s: ^State, v: [4]u8) {s.next.text_color = v}
set_next_corner_radius :: proc(s: ^State, v: f32) {s.next.corner_radius = v}
set_next_font_size :: proc(s: ^State, v: f32) {s.next.font_size = v}
set_next_text_padding :: proc(s: ^State, v: f32) {s.next.text_padding = v}
