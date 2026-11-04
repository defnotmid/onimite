package ui

import "../animation"
import "../render"
import "core:math"
import vg "deps:ovg"

// draw walks the box tree as RAD Debugger's window draw does, onto the
// frame's ovg canvas: a box's background, text and icon, then (a Clip box
// scissored to its rect inset a pixel) its custom draw and its children last
// to first, so the child built first, which took the pointer first, lies on
// top; then its border, a pixel wide just outside its rect, and its edge
// fades. hot_t and active_t animate toward their targets on the way.
draw :: proc(s: ^State) {
	if s.root == nil || s.canvas == nil do return
	c := s.canvas
	w, h := u32(max(s.p.width, 0)), u32(max(s.p.height, 0))
	vg.set_size(c, w, h, max(s.p.dpi_scale, 1))
	vg.reset_transform(c); vg.reset_scissor(c)
	// Everything into the frame's target, which its layers (a blur) read;
	// nothing is drawn to the screen once it is set back.
	vg.set_render_target(c, s.target)
	vg.layer_stack_begin(&s.layers, c, w, h, s.target)
	vg.clear_rect(c, 0, 0, w, h, color(s.theme.background))
	draw_box(s, s.root, s.p.frame_dt)
	hint_draw(s)
	vg.layer_stack_end(&s.layers, c)
	vg.set_render_target(c, nil)
}
// What a box draws itself with ovg, as RAD Debugger's custom draw: the box
// and the canvas, the box's clip in place.
Custom_Draw :: proc(s: ^State, box: ^Box, c: ^vg.Canvas)
box_equip_custom_draw :: proc(box: ^Box, draw: Custom_Draw, data: rawptr) {box.custom_draw, box.custom_data = draw, data}
// The byte ranges of the box's text a filter matched, lit behind its text
// this frame (RAD's ui_box_equip_fuzzy_match_ranges); frame-lived.
box_equip_fuzzy_match_ranges :: proc(box: ^Box, ranges: [][2]int) {
	box.fuzzy_ranges = ranges
	if len(ranges) > 0 do box.flags += {.Has_Fuzzy_Match_Ranges}
}

lerp_u8 :: proc(a, b: [4]u8, t: f32) -> [4]u8 {
	tt := clamp(t, 0, 1)
	out: [4]u8
	for i in 0 ..< 4 {
		out[i] = u8(f32(a[i]) + (f32(b[i]) - f32(a[i])) * tt)
	}
	return out
}
// A colour as ovg takes it, its alpha times `opacity`.
color :: proc(c: [4]u8, opacity: f32 = 1) -> vg.Color {
	return {f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, f32(c.a) / 255 * clamp(opacity, 0, 1)}
}
// A box's outline, square or rounded per corner (RAD's corners: 00
// top-left, 01 bottom-left, 10 top-right, 11 bottom-right).
box_path :: proc(p: ^vg.Path, x, y, w, h: f32, radii: [4]f32) {
	vg.path_reset(p)
	rect_append(p, x, y, w, h, radii)
}
@(private)
rect_append :: proc(p: ^vg.Path, x, y, w, h: f32, radii: [4]f32) {
	if radii == {} {vg.path_rect(p, x, y, w, h)} else {vg.path_rounded_rect_varying(p, x, y, w, h, radii[0], radii[2], radii[3], radii[1])}
}
// RAD's drop shadow fades over twice its softness of 8 px, its middle on the
// box's outline: ovg's feather of that width (its fringe spans 1.5 sigma
// sqrt(2 pi)).
DROP_SHADOW_SOFTNESS :: 8
DROP_SHADOW_FEATHER :: 2 * DROP_SHADOW_SOFTNESS / (1.5 * 2.5066283)

draw_box :: proc(s: ^State, box: ^Box, dt: f32) {
	c := s.canvas
	x := box.rect.min.x
	y := box.rect.min.y
	w := box.rect.max.x - box.rect.min.x
	h := box.rect.max.y - box.rect.min.y
	// Its visual rect: the rect less its visual margin (RAD's), where its
	// background, border and icon draw.
	vx, vy := x + box.visual_margin.x, y + box.visual_margin.y
	vw, vh := max(w - 2 * box.visual_margin.x, 0), max(h - 2 * box.visual_margin.y, 0)

	// animate hot/active toward target based on interaction keys
	hot_target: f32 = (s.hot == box.key && box.key != Key(0)) ? 1 : 0
	active_target: f32 = (s.active[.Left] == box.key && box.key != Key(0)) ? 1 : 0
	if .Draw_Hot_Effects in box.flags {
		box.hot_t = animation.approach(box.hot_t, hot_target, s.theme.hot_anim_rate * math.LN2, dt)
	}
	// Active, at once; let go, easing out (RAD's active_t).
	if .Draw_Active_Effects in box.flags {
		box.active_t = active_target > 0 ? 1 : animation.approach(box.active_t, 0, s.theme.active_anim_rate * math.LN2, dt)
	}

	visible := w > 0 && h > 0
	// Squished, the box and what it holds draw scaled about its pivot: its
	// top-left corner when anchored, else an eighth of its height below its
	// top's middle (RAD's squish).
	if box.squish > 0.001 {
		pivot := .Squish_Anchored in box.flags ? [2]f32{x, y} : [2]f32{x + w / 2, y + h / 8}
		vg.save(c)
		vg.translate(c, pivot.x, pivot.y); vg.scale(c, 1 - box.squish, 1 - box.squish); vg.translate(c, -pivot.x, -pivot.y)
	}
	defer if box.squish > 0.001 do vg.restore(c)
	if visible {
		// drop shadow: the box shifted 4 px down and right, its corners 8 px
		// rounder, fading over 16 px (RAD's pad 8, shift 4, softness 8)
		if .Draw_Drop_Shadow in box.flags {
			r := box.corner_radii
			box_path(&s.path, x + 4, y + 4, w, h, {r[0] + DROP_SHADOW_SOFTNESS, r[1] + DROP_SHADOW_SOFTNESS, r[2] + DROP_SHADOW_SOFTNESS, r[3] + DROP_SHADOW_SOFTNESS})
			shadow := vg.paint_color(color(s.theme.drop_shadow, box.opacity)); shadow.feather = DROP_SHADOW_FEATHER
			vg.fill_path(c, &s.path, shadow)
		}
		// background blur: what lies beneath, inside the rect grown a pixel,
		// blurred as RAD's (a Gaussian of deviation (size - 1) / 2, its size
		// fading with the box)
		if .Draw_Background_Blur in box.flags {
			if sigma := (box.blur_size * box.opacity - 1) / 2; sigma > 0 {
				box_path(&s.path, x - 1, y - 1, w + 2, h + 2, box.corner_radii)
				vg.layer_backdrop_blur(&s.layers, c, &s.path, sigma)
			}
		}
		if .Draw_Horizontal_Gradient in box.flags {
			box_path(&s.path, x, y, w, h, box.corner_radii)
			vg.fill_path(c, &s.path, vg.paint_linear_gradient(x, y, x + w, y, color(box.gradient_left, box.opacity), color(box.gradient_right, box.opacity)))
		}
		// background (+ RAD's hot drop shadow, hover brighten, and active inner
		// shadows), in its visual rect
		if .Draw_Background in box.flags {
			if .Draw_Hot_Effects in box.flags {
				effective_active_t: f32 = .Draw_Active_Effects in box.flags ? box.active_t : 0
				t := box.hot_t * (1 - effective_active_t)
				shadow_alpha := box.opacity * t * (f32(box.bg_color.a) / 255)
				if shadow_alpha > 0 {
					r := box.corner_radii
					box_path(&s.path, vx + 4, vy + 4, vw, vh, {r[0] + DROP_SHADOW_SOFTNESS, r[1] + DROP_SHADOW_SOFTNESS, r[2] + DROP_SHADOW_SOFTNESS, r[3] + DROP_SHADOW_SOFTNESS})
					shadow := vg.paint_color(color(s.theme.drop_shadow, shadow_alpha)); shadow.feather = DROP_SHADOW_FEATHER
					vg.fill_path(c, &s.path, shadow)
				}
			}
			box_path(&s.path, vx, vy, vw, vh, box.corner_radii)
			vg.fill_path(c, &s.path, vg.paint_color(color(box.bg_color, box.opacity)))
			if .Draw_Hot_Effects in box.flags && hot_target > 0 {
				vg.fill_path(c, &s.path, vg.paint_color(color(s.theme.hover, box.opacity * 0.015)))
			}
			if .Draw_Active_Effects in box.flags && box.active_t > 0 {
				r := box.corner_radii
				shadow := color(s.theme.drop_shadow, box.opacity * 0.5 * box.active_t)
				none := shadow; none.a = 0
				light := vg.Color{1, 1, 1, clamp(box.opacity, 0, 1) * 0.08 * box.active_t}
				light_none := vg.Color{1, 1, 1, 0}
				sx := clamp(vw * 0.60 * box.active_t, 0, box.font_size * 2)
				sy := clamp(vh * 0.60 * box.active_t, 0, box.font_size * 2)
				if sy > 0 {
					box_path(&s.path, vx, vy, vw, sy, {r[0], 0, r[2], 0})
					vg.fill_path(c, &s.path, vg.paint_linear_gradient(vx, vy, vx, vy + sy, shadow, none))
					box_path(&s.path, vx, vy + vh - sy, vw, sy, {0, r[1], 0, r[3]})
					vg.fill_path(c, &s.path, vg.paint_linear_gradient(vx, vy + vh - sy, vx, vy + vh, light_none, light))
				}
				if sx > 0 {
					box_path(&s.path, vx, vy, sx, vh, {r[0], r[1], 0, 0})
					vg.fill_path(c, &s.path, vg.paint_linear_gradient(vx, vy, vx + sx, vy, shadow, none))
					box_path(&s.path, vx + vw - sx, vy, sx, vh, {0, 0, r[2], r[3]})
					vg.fill_path(c, &s.path, vg.paint_linear_gradient(vx + vw - sx, vy, vx + vw, vy, none, shadow))
				}
			}
		}
		// text, from its baseline, cut to "..." where it passes the box's
		// right edge unless the box keeps it whole
		if .Draw_Text in box.flags && len(box.str) > 0 {
			at := box_text_position(s, box)
			top := at.y - render.ascent(s.font, box.font_size)
			// What it draws: whole, or cut to "..." where it passes the box's
			// right edge (render.slot_cut).
			max_w := .Disable_Text_Trunc in box.flags ? max(f32) : box.rect.max.x - at.x
			cut := render.slot_cut(s.font, box.text_slot, box.str, "...", box.font_size, max_w)
			// The matched ranges behind it, as RAD's
			// dr_truncated_fancy_run_fuzzy_matches: each its drawn glyphs'
			// span widened a quarter ascent, from a descent and an eighth
			// ascent above the line's top to an eighth below its baseline,
			// rounded a quarter of the line, cut at the box's end.
			if .Has_Fuzzy_Match_Ranges in box.flags {
				ascent := render.ascent(s.font, box.font_size)
				descent := box.font_size - ascent
				for r in box.fuzzy_ranges {
					x0, x1, ok := render.cut_span(s.font, cut, box.str, r[0], r[1])
					if !ok do continue
					rx0 := min(at.x + x0 - ascent / 4, box.rect.max.x)
					rx1 := min(at.x + x1 + ascent / 4, box.rect.max.x)
					ry0 := at.y - descent - ascent - ascent / 8
					ry1 := at.y - descent - ascent + ascent / 8 + box.text_height
					radius := (descent + ascent) / 4
					box_path(&s.path, rx0, ry0, rx1 - rx0, ry1 - ry0, {radius, radius, radius, radius})
					vg.fill_path(c, &s.path, vg.paint_color(color(s.theme.match, box.opacity)))
				}
			}
			render.draw_slot_cut(c, s.font, cut, at.x, top, color(box.text_color, box.opacity), &s.path)
		}
		// icon: its stroke's shape filled into the box
		if .Draw_Icon in box.flags && box.icon != "" {
			if icon, ok := &s.icons[box.icon]; ok {
				// a square of its visual rect's least side, centred in it
				side := min(vw, vh)
				ix, iy := vx + (vw - side) / 2, vy + (vh - side) / 2
				vg.fill_shape(c, icon, vg.paint_color(color(box.text_color, box.opacity)), {side / ICON_BOX, 0, 0, side / ICON_BOX, ix, iy})
			}
		}
	}

	// clip: the custom draw and the subtree, to the rect inset a pixel
	clipped := .Clip in box.flags && visible
	if clipped {vg.save(c); vg.intersect_scissor(c, x + 1, y + 1, max(0, w - 2), max(0, h - 2))}
	if box.custom_draw != nil && visible do box.custom_draw(s, box, c)
	// children, last to first
	for child := box.last; child != nil; child = child.prev {
		draw_box(s, child, dt)
	}
	if clipped do vg.restore(c)
	if !visible do return
	// border, after what it holds: the ring a pixel wide just outside the
	// visual rect, filled (the rect grown a pixel, less the rect)
	if .Draw_Border in box.flags {
		r := box.corner_radii
		box_path(&s.path, vx - 1, vy - 1, vw + 2, vh + 2, r)
		rect_append(&s.path, vx, vy, vw, vh, {max(r[0] - 1, 0), max(r[1] - 1, 0), max(r[2] - 1, 0), max(r[3] - 1, 0)})
		vg.path_solidity(&s.path, .Hole)
		vg.fill_path(c, &s.path, vg.paint_color(color(box.border_color, box.opacity)))
		if .Draw_Hot_Effects in box.flags {
			ht := hot_target > 0 ? 1 : box.hot_t
			if ht > 0 {
				vg.fill_path(c, &s.path, vg.paint_color(color(s.theme.hover, box.opacity * ht * 0.01)))
			}
		}
	}
	// Edge fades, as RAD's scroll fades: a twentieth of the box, easing in
	// from its edge (RAD's catchall rate), its shadow to nothing.
	if box.flags & {.Draw_Fade_Top, .Draw_Fade_Bottom} != {} {
		shadow := color(s.theme.drop_shadow, box.opacity)
		none := shadow; none.a = 0
		params := Animation_Params{initial = 0}
		if .Draw_Fade_Top in box.flags {
			fh := h * 0.05 * anim_f32(s, key_from_string(box.key, "###fade_top"), 1, params)
			box_path(&s.path, x, y, w, fh, {})
			vg.fill_path(c, &s.path, vg.paint_linear_gradient(x, y, x, y + fh, shadow, none))
		}
		if .Draw_Fade_Bottom in box.flags {
			fh := h * 0.05 * anim_f32(s, key_from_string(box.key, "###fade_bottom"), 1, params)
			box_path(&s.path, x, y + h - fh, w, fh, {})
			vg.fill_path(c, &s.path, vg.paint_linear_gradient(x, y + h - fh, x, y + h, none, shadow))
		}
	}
	// RAD's focus overlay over a clickable box focus hot, and its focus
	// border, a pixel wide, around one focus active (a floating one's a pixel
	// outside it), unless the box disables them.
	if .Clickable in box.flags && .Disable_Focus_Overlay not_in box.flags && box.focus_hot_t > 0.01 {
		box_path(&s.path, x, y, w, h, box.corner_radii)
		vg.fill_path(c, &s.path, vg.paint_color(color(s.theme.focus_overlay, box.opacity * box.focus_hot_t)))
	}
	if .Clickable in box.flags && .Disable_Focus_Border not_in box.flags && box.focus_active_t > 0.01 {
		r := box.corner_radii
		g: f32 = box.flags & {.Floating_X, .Floating_Y} != {} ? 1 : 0
		box_path(&s.path, x - g, y - g, w + 2 * g, h + 2 * g, r)
		rect_append(&s.path, x - g + 1, y - g + 1, w + 2 * g - 2, h + 2 * g - 2, {max(r[0] - 1, 0), max(r[1] - 1, 0), max(r[2] - 1, 0), max(r[3] - 1, 0)})
		vg.path_solidity(&s.path, .Hole)
		vg.fill_path(c, &s.path, vg.paint_color(color(s.theme.focus_border, box.opacity * box.focus_active_t)))
	}
}
