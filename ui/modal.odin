package ui

import "core:fmt"

MODAL_FADE_IN_DURATION  :: f32(0.10)
MODAL_FADE_OUT_DURATION :: f32(0.08)

Modal_Surface_Params :: struct {
	open:            bool,
	width:          f32,
	height:         f32,
	background:     [4]u8,
	border:         [4]u8,
	backdrop:       [4]u8,
	corner_radius:  f32,
	vertical_squish: f32,
}

Modal_Surface :: struct {
	panel:               ^Box,
	open_t:              f32,
	transition_finished: bool,
}

// modal_surface_begin builds a RAD-style floating surface: a keyed quick
// fade/vertical-unsquish plus a backdrop fade. It leaves the panel and opacity
// scopes pushed so callers can build contents, then pair with modal_surface_end.
modal_surface_begin :: proc(
	s: ^State,
	key: string,
	params: Modal_Surface_Params,
) -> Modal_Surface {
	animation_key := key_from_string(Key(0), fmt.tprintf("%s_open_t", key))
	open_t := anim_f32(
		s,
		animation_key,
		params.open ? 1 : 0,
		{
			initial = params.open ? 0 : 1,
			duration = params.open ? MODAL_FADE_IN_DURATION : MODAL_FADE_OUT_DURATION,
			easing = .Cubic_Out,
		},
	)
	visible_opacity := clamp(open_t, 0, 1)

	screen_w := f32(s.p.width)
	screen_h := f32(s.p.height)
	set_next_fixed_x(s, 0)
	set_next_fixed_y(s, 0)
	set_next_fixed_width(s, screen_w)
	set_next_fixed_height(s, screen_h)
	set_next_bg_color(s, params.backdrop)
	set_next_opacity(s, visible_opacity)
	build_box(s, {.Draw_Background}, fmt.tprintf("%s_backdrop", key))

	squish := clamp(params.vertical_squish, 0, 0.9)
	animated_height := params.height * (1 - squish + squish * open_t)
	x := (screen_w - params.width) * 0.5
	y := (screen_h - animated_height) * 0.5

	push_opacity(s, visible_opacity)
	set_next_bg_color(s, params.background)
	set_next_border_color(s, params.border)
	set_next_corner_radius(s, params.corner_radius)
	set_next_flags(s, {.Modal_Input_Root})
	_ = panel(s, key, x, y, params.width, animated_height)
	return {
		panel = top_parent(s),
		open_t = visible_opacity,
		transition_finished = !params.open && visible_opacity <= 1.0e-6,
	}
}

modal_surface_end :: proc(s: ^State) {
	pop_parent(s)
	pop_opacity(s)
}
