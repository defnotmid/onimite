package ui

// Scope-guard / container ergonomics
// ===================================
//
// This port uses TWO complementary patterns, matching raddbg's split between
// "set_next_*" (one-shot, applies to the very next box) and "push/pop"
// (scoped, applies to all boxes until popped):
//
//   1. set_next_* procs  -- one-shot override consumed by the next build_box.
//      e.g.  set_next_pref_width(s, ui.px(120)); ui.button(s, "OK")
//
//   2. `with_*` scope guards using @(deferred_in) -- push a value, auto-pop at
//      end of the enclosing scope. Because Odin's @(deferred_in) runs the
//      paired proc when the CALLING scope exits, you write:
//
//          ui.with_pref_width(s, ui.px(120))   // no braces of its own
//          {
//              ui.button(s, "A")               // both inherit width 120
//              ui.button(s, "B")
//          }                                    // width popped here
//
//      NOTE: the guard pops at the end of the scope it is *written in*. Wrap the
//      affected widgets in an explicit `{ ... }` block (as above) to bound it.
//
//   3. Container scopes (row/column/panel) return a bool and push themselves as
//      parent. Use with `if` + `defer pop_parent`:
//
//          if ui.column(s, "left") { defer ui.pop_parent(s)
//              ui.label(s, "hello")
//          }
//
// All three are demonstrated in ui_probe/main.odin.

////////////////////////////////
// set_next_* one-shot overrides

set_next_pref_width :: proc(s: ^State, v: Size) {s.pref_width.next = v}
set_next_pref_height :: proc(s: ^State, v: Size) {s.pref_height.next = v}
set_next_flags :: proc(s: ^State, v: Box_Flags) {s.flags.next = v}
set_next_child_layout_axis :: proc(s: ^State, v: Axis2) {s.child_layout_axis.next = v}
set_next_fixed_x :: proc(s: ^State, v: f32) {s.fixed_x.next = v}
set_next_fixed_y :: proc(s: ^State, v: f32) {s.fixed_y.next = v}
set_next_fixed_width :: proc(s: ^State, v: f32) {s.fixed_width.next = v}
set_next_fixed_height :: proc(s: ^State, v: f32) {s.fixed_height.next = v}
set_next_text_align :: proc(s: ^State, v: Text_Align) {s.text_align.next = v}
set_next_bg_color :: proc(s: ^State, v: [4]u8) {s.bg_color.next = v}
set_next_text_color :: proc(s: ^State, v: [4]u8) {s.text_color.next = v}
set_next_border_color :: proc(s: ^State, v: [4]u8) {s.border_color.next = v}
set_next_corner_radius :: proc(s: ^State, v: f32) {s.corner_radius.next = v}
set_next_font_size :: proc(s: ^State, v: f32) {s.font_size.next = v}
set_next_text_padding :: proc(s: ^State, v: f32) {s.text_padding.next = v}
set_next_opacity :: proc(s: ^State, v: f32) {s.opacity.next = v}

////////////////////////////////
// push_* / pop_* scoped overrides

push_pref_width :: proc(s: ^State, v: Size) {append(&s.pref_width.items, v)}
pop_pref_width :: proc(s: ^State) {if len(s.pref_width.items) > 0 do pop(&s.pref_width.items)}

push_pref_height :: proc(s: ^State, v: Size) {append(&s.pref_height.items, v)}
pop_pref_height :: proc(s: ^State) {if len(s.pref_height.items) > 0 do pop(&s.pref_height.items)}

push_flags :: proc(s: ^State, v: Box_Flags) {append(&s.flags.items, v)}
pop_flags :: proc(s: ^State) {if len(s.flags.items) > 0 do pop(&s.flags.items)}

push_child_layout_axis :: proc(s: ^State, v: Axis2) {append(&s.child_layout_axis.items, v)}
pop_child_layout_axis :: proc(s: ^State) {if len(s.child_layout_axis.items) > 0 do pop(&s.child_layout_axis.items)}

push_fixed_x :: proc(s: ^State, v: f32) {append(&s.fixed_x.items, v)}
pop_fixed_x :: proc(s: ^State) {if len(s.fixed_x.items) > 0 do pop(&s.fixed_x.items)}

push_fixed_y :: proc(s: ^State, v: f32) {append(&s.fixed_y.items, v)}
pop_fixed_y :: proc(s: ^State) {if len(s.fixed_y.items) > 0 do pop(&s.fixed_y.items)}

push_fixed_width :: proc(s: ^State, v: f32) {append(&s.fixed_width.items, v)}
pop_fixed_width :: proc(s: ^State) {if len(s.fixed_width.items) > 0 do pop(&s.fixed_width.items)}

push_fixed_height :: proc(s: ^State, v: f32) {append(&s.fixed_height.items, v)}
pop_fixed_height :: proc(s: ^State) {if len(s.fixed_height.items) > 0 do pop(&s.fixed_height.items)}

push_text_align :: proc(s: ^State, v: Text_Align) {append(&s.text_align.items, v)}
pop_text_align :: proc(s: ^State) {if len(s.text_align.items) > 0 do pop(&s.text_align.items)}

push_bg_color :: proc(s: ^State, v: [4]u8) {append(&s.bg_color.items, v)}
pop_bg_color :: proc(s: ^State) {if len(s.bg_color.items) > 0 do pop(&s.bg_color.items)}

push_text_color :: proc(s: ^State, v: [4]u8) {append(&s.text_color.items, v)}
pop_text_color :: proc(s: ^State) {if len(s.text_color.items) > 0 do pop(&s.text_color.items)}

push_border_color :: proc(s: ^State, v: [4]u8) {append(&s.border_color.items, v)}
pop_border_color :: proc(s: ^State) {if len(s.border_color.items) > 0 do pop(&s.border_color.items)}

push_corner_radius :: proc(s: ^State, v: f32) {append(&s.corner_radius.items, v)}
pop_corner_radius :: proc(s: ^State) {if len(s.corner_radius.items) > 0 do pop(&s.corner_radius.items)}

push_font_size :: proc(s: ^State, v: f32) {append(&s.font_size.items, v)}
pop_font_size :: proc(s: ^State) {if len(s.font_size.items) > 0 do pop(&s.font_size.items)}

push_text_padding :: proc(s: ^State, v: f32) {append(&s.text_padding.items, v)}
pop_text_padding :: proc(s: ^State) {if len(s.text_padding.items) > 0 do pop(&s.text_padding.items)}

push_opacity :: proc(s: ^State, v: f32) {append(&s.opacity.items, v)}
pop_opacity :: proc(s: ^State) {if len(s.opacity.items) > 0 do pop(&s.opacity.items)}

////////////////////////////////
// with_* scope guards (@(deferred_in) auto-pop)
//
// Odin's @(deferred_in) passes the ORIGINAL inputs to the deferred proc, so the
// paired "unwith" procs take the same signature and ignore the value.

unwith_pref_width :: proc(s: ^State, v: Size) {pop_pref_width(s)}
@(deferred_in = unwith_pref_width)
with_pref_width :: proc(s: ^State, v: Size) {push_pref_width(s, v)}

unwith_pref_height :: proc(s: ^State, v: Size) {pop_pref_height(s)}
@(deferred_in = unwith_pref_height)
with_pref_height :: proc(s: ^State, v: Size) {push_pref_height(s, v)}

unwith_flags :: proc(s: ^State, v: Box_Flags) {pop_flags(s)}
@(deferred_in = unwith_flags)
with_flags :: proc(s: ^State, v: Box_Flags) {push_flags(s, v)}

unwith_child_layout_axis :: proc(s: ^State, v: Axis2) {pop_child_layout_axis(s)}
@(deferred_in = unwith_child_layout_axis)
with_child_layout_axis :: proc(s: ^State, v: Axis2) {push_child_layout_axis(s, v)}

unwith_text_align :: proc(s: ^State, v: Text_Align) {pop_text_align(s)}
@(deferred_in = unwith_text_align)
with_text_align :: proc(s: ^State, v: Text_Align) {push_text_align(s, v)}

unwith_bg_color :: proc(s: ^State, v: [4]u8) {pop_bg_color(s)}
@(deferred_in = unwith_bg_color)
with_bg_color :: proc(s: ^State, v: [4]u8) {push_bg_color(s, v)}

unwith_text_color :: proc(s: ^State, v: [4]u8) {pop_text_color(s)}
@(deferred_in = unwith_text_color)
with_text_color :: proc(s: ^State, v: [4]u8) {push_text_color(s, v)}

unwith_border_color :: proc(s: ^State, v: [4]u8) {pop_border_color(s)}
@(deferred_in = unwith_border_color)
with_border_color :: proc(s: ^State, v: [4]u8) {push_border_color(s, v)}

unwith_corner_radius :: proc(s: ^State, v: f32) {pop_corner_radius(s)}
@(deferred_in = unwith_corner_radius)
with_corner_radius :: proc(s: ^State, v: f32) {push_corner_radius(s, v)}

unwith_font_size :: proc(s: ^State, v: f32) {pop_font_size(s)}
@(deferred_in = unwith_font_size)
with_font_size :: proc(s: ^State, v: f32) {push_font_size(s, v)}

unwith_text_padding :: proc(s: ^State, v: f32) {pop_text_padding(s)}
@(deferred_in = unwith_text_padding)
with_text_padding :: proc(s: ^State, v: f32) {push_text_padding(s, v)}

unwith_opacity :: proc(s: ^State, v: f32) {pop_opacity(s)}
@(deferred_in = unwith_opacity)
with_opacity :: proc(s: ^State, v: f32) {push_opacity(s, v)}
