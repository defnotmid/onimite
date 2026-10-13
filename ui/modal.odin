package ui

import "core:fmt"

// After oasic's ui/modal.odin (RAD's floating surfaces): a panel centred
// over the window on a backdrop, both fading in while the panel unsquishes
// vertically. Input belongs to the panel's subtree while the caller keeps
// `modal_input_set` on (see State.modal_input).

MODAL_FADE_IN :: f32(0.10)

Modal_Surface_Params :: struct {
	width, height:   f32,
	background:      [4]u8,
	backdrop:        [4]u8,
	corner_radius:   f32,
	// The share of its height the panel starts short by.
	vertical_squish: f32,
}

Modal_Surface :: struct {
	panel:  ^Box,
	open_t: f32,
}

// Builds the backdrop and pushes the panel as parent, laying its children
// top to bottom; build the contents, then call modal_surface_end.
modal_surface_begin :: proc(s: ^State, key: string, params: Modal_Surface_Params) -> Modal_Surface {
	open_t := clamp(anim_f32(s, key_from_string(Key(0), fmt.tprintf("%s_open_t", key)), 1, {initial = 0, duration = MODAL_FADE_IN, easing = .Cubic_Out}), 0, 1)
	screen_w, screen_h := f32(s.p.width), f32(s.p.height)
	set_next_fixed_x(s, 0)
	set_next_fixed_y(s, 0)
	set_next_fixed_width(s, screen_w)
	set_next_fixed_height(s, screen_h)
	set_next_bg_color(s, params.backdrop)
	set_next_corner_radius(s, 0)
	set_next_opacity(s, open_t)
	build_box(s, {.Draw_Background}, fmt.tprintf("%s_backdrop", key))

	squish := clamp(params.vertical_squish, 0, 0.9)
	height := params.height * (1 - squish + squish * open_t)
	set_next_bg_color(s, params.background)
	set_next_corner_radius(s, params.corner_radius)
	set_next_opacity(s, open_t)
	panel(s, key, (screen_w - params.width) * 0.5, (screen_h - height) * 0.5, params.width, height)
	b := top_parent(s)
	b.flags += {.Modal_Input_Root}
	return {panel = b, open_t = open_t}
}

modal_surface_end :: proc(s: ^State) {
	pop_parent(s)
}
