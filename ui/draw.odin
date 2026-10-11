package ui

import "core:math"

import render "../render"

// draw walks the box tree in pre-order, animating hot_t/active_t toward their
// targets and emitting background / border / text via the render package.
// Clip boxes push a scissor rect for the duration of their subtree.
draw :: proc(s: ^State) {
	if s.root == nil {
		return
	}
	dt := s.p.frame_time
	draw_box(s, s.root, dt)
}

lerp_u8 :: proc(a, b: [4]u8, t: f32) -> [4]u8 {
	tt := clamp(t, 0, 1)
	out: [4]u8
	for i in 0 ..< 4 {
		out[i] = u8(f32(a[i]) + (f32(b[i]) - f32(a[i])) * tt)
	}
	return out
}

approach :: proc(current, target, rate, dt: f32) -> f32 {
	// exponential approach, framerate-independent
	t := 1 - math.pow(f32(2), -rate * dt)
	return current + (target - current) * t
}

draw_box :: proc(s: ^State, box: ^Box, dt: f32) {
	x := box.rect.min.x
	y := box.rect.min.y
	w := box.rect.max.x - box.rect.min.x
	h := box.rect.max.y - box.rect.min.y

	// animate hot/active toward target based on interaction keys
	hot_target: f32 = (s.hot == box.key && box.key != Key(0)) ? 1 : 0
	active_target: f32 = (s.active == box.key && box.key != Key(0)) ? 1 : 0
	if .Draw_Hot_Effects in box.flags {
		box.hot_t = approach(box.hot_t, hot_target, s.theme.hot_anim_rate, dt)
	}
	if .Draw_Active_Effects in box.flags {
		box.active_t = approach(box.active_t, active_target, s.theme.active_anim_rate, dt)
	}

	// clip: push scissor for subtree
	clipped := false
	if .Clip in box.flags && w > 0 && h > 0 {
		render.clip_push(s.r, x, y, w, h)
		clipped = true
	}

	if w > 0 && h > 0 {
		if .Draw_Image in box.flags && box.image != nil {
			render.draw_image_contain(s.r, box.image, x, y, w, h)
		}
		// background (+ hot/active tint)
		if .Draw_Background in box.flags {
			col := box.bg_color
			if .Draw_Hot_Effects in box.flags {
				col = lerp_u8(col, box.hot_color, box.hot_t)
			}
			if .Draw_Active_Effects in box.flags {
				col = lerp_u8(col, box.active_color, box.active_t)
			}
			if box.corner_radius > 0 {
				render.draw_rect_rounded(s.r, x, y, w, h, box.corner_radius, col)
			} else {
				render.draw_rect(s.r, x, y, w, h, col)
			}
		}

		// border
		if .Draw_Border in box.flags {
			render.draw_rect_outline(
				s.r,
				x,
				y,
				w,
				h,
				box.border_thickness,
				s.theme.border,
				box.corner_radius,
			)
		}

		// text
		if .Draw_Text in box.flags && len(box.str) > 0 {
			tw := render.measure_text(s.font, box.str, box.font_size)
			lh := render.line_height(s.font, box.font_size)
			tx: f32
			switch box.text_align {
			case .Left:
				tx = x + box.text_padding
			case .Center:
				tx = x + (w - tw) * 0.5
			case .Right:
				tx = x + w - tw - box.text_padding
			}
			ty := y + (h - lh) * 0.5
			render.draw_text(
				s.r,
				s.font,
				box.str,
				tx,
				ty,
				box.font_size,
				box.text_color,
			)
		}
	}

	if box.custom_draw != nil && w > 0 && h > 0 {
		box.custom_draw(s, box, box.custom_draw_data)
	}

	// children
	for c := box.first; c != nil; c = c.next {
		draw_box(s, c, dt)
	}

	if clipped {
		render.clip_pop(s.r)
	}
}
