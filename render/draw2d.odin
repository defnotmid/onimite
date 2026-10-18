package render

import sdl "vendor:sdl3"

// General instanced-rect submission (used by draw_rect*, the font layer, and the
// UI draw bucket). `tex_size` is the bound texture's dimensions in texels, for
// src->uv in the shader. Consecutive instances with the same texture + clip/
// viewport target coalesce into one draw.
rect_inst :: proc(r: ^Renderer, inst: Rect_Inst, tex: ^sdl.GPUTexture, tex_size: [2]f32) {
	append(&r.rect_insts, inst)
	idx := u32(len(r.rect_insts) - 1)

	if len(r.cmds) > 0 {
		last := &r.cmds[len(r.cmds) - 1]
		if last.tex == tex &&
		   last.first + last.count == idx &&
		   _same_target(r, last) {
			last.count += 1
			return
		}
	}
	t := tex != nil ? tex : r.white_tex
	cmd := Draw_Cmd {
		first = idx,
		count = 1,
		tex = t,
		rect_u = {viewport = {f32(r.fb_w), f32(r.fb_h)}, tex_size = tex_size},
	}
	_fill_target(r, &cmd)
	append(&r.cmds, cmd)
}

_same_target :: proc(r: ^Renderer, c: ^Draw_Cmd) -> bool {
	return(
		c.use_viewport == r.use_viewport &&
		c.viewport == r.viewport &&
		c.use_scissor == r.use_scissor &&
		c.scissor == r.scissor \
	)
}

_solid_inst :: proc(x, y, w, h: f32, c: [4]u8, radius, border, softness: f32) -> Rect_Inst {
	cf := color_f32(c)
	return {
		dst = {x, y, x + w, y + h},
		src = {0, 0, 1, 1},
		col_tl = cf,
		col_tr = cf,
		col_bl = cf,
		col_br = cf,
		radii = {radius, radius, radius, radius},
		style = {border, softness, SAMPLE_SOLID, 0},
	}
}

draw_rect :: proc(r: ^Renderer, x, y, w, h: f32, c: [4]u8) {
	rect_inst(r, _solid_inst(x, y, w, h, c, 0, 0, 0), r.white_tex, {1, 1})
}

draw_rect_rounded :: proc(r: ^Renderer, x, y, w, h, radius: f32, c: [4]u8) {
	rect_inst(r, _solid_inst(x, y, w, h, c, radius, 0, 1), r.white_tex, {1, 1})
}

// draw_image_contain fits the image inside the rect (letterboxed),
// bilinear-filtered unless `nearest`.
draw_image_contain :: proc(r: ^Renderer, image: ^Image, x, y, w, h: f32, opacity: f32 = 1, nearest := false) {
	if !image_loaded(image) || w <= 0 || h <= 0 || opacity <= 0 {
		return
	}
	scale := min(w / f32(image.width), h / f32(image.height))
	draw_image_rect(r, image, x + (w - f32(image.width) * scale) * 0.5, y + (h - f32(image.height) * scale) * 0.5, f32(image.width) * scale, f32(image.height) * scale, opacity, nearest)
}

// draw_image_rect draws `image` filling `(x, y, w, h)` in pixels.
draw_image_rect :: proc(r: ^Renderer, image: ^Image, x, y, w, h: f32, opacity: f32 = 1, nearest := false) {
	if !image_loaded(image) || w <= 0 || h <= 0 || opacity <= 0 {
		return
	}
	color := [4]f32{1, 1, 1, clamp(opacity, 0, 1)}
	rect_inst(
		r,
		{
			dst = {x, y, x + w, y + h},
			src = {0, 0, f32(image.width), f32(image.height)},
			col_tl = color,
			col_tr = color,
			col_bl = color,
			col_br = color,
			style = {0, 0, SAMPLE_RGBA_NEAREST if nearest else SAMPLE_RGBA, 0},
		},
		image.texture,
		{f32(image.width), f32(image.height)},
	)
}

// draw_image_src draws the texels `src` (x0, y0, x1, y1) of `image` into
// `(x, y, w, h)` by a sample mode: a stretch of a strip texture (a
// spectrogram's rows, SAMPLE_HEAT).
draw_image_src :: proc(r: ^Renderer, image: ^Image, src: [4]f32, x, y, w, h: f32, sample := SAMPLE_RGBA) {
	if !image_loaded(image) || w <= 0 || h <= 0 {
		return
	}
	color := [4]f32{1, 1, 1, 1}
	rect_inst(
		r,
		{
			dst = {x, y, x + w, y + h},
			src = src,
			col_tl = color,
			col_tr = color,
			col_bl = color,
			col_br = color,
			style = {0, 0, sample, 0},
		},
		image.texture,
		{f32(image.width), f32(image.height)},
	)
}

// outline (border ring) via the SDF border in the shader. A square ring is
// drawn with no extra softness so a 1 px border stays 1 px; only rounded
// rings take the anti-aliasing the corners need.
draw_rect_outline :: proc(r: ^Renderer, x, y, w, h, thickness: f32, c: [4]u8, radius: f32 = 0) {
	rect_inst(
		r,
		_solid_inst(x, y, w, h, c, radius, max(thickness, 1), radius > 0 ? 0.5 : 0),
		r.white_tex,
		{1, 1},
	)
}

// ---- scissor clip stack ----

clip_push :: proc(r: ^Renderer, x, y, w, h: f32) {
	cur := r.use_scissor ? r.scissor : sdl.Rect{0, 0, i32(r.fb_w), i32(r.fb_h)}
	append(&r.clip_stack, cur)
	r.scissor = _intersect(cur, {i32(x), i32(y), i32(w), i32(h)})
	r.use_scissor = true
}

clip_pop :: proc(r: ^Renderer) {
	if len(r.clip_stack) == 0 {
		r.use_scissor = false
		return
	}
	prev := pop(&r.clip_stack)
	r.scissor = prev
	r.use_scissor = len(r.clip_stack) > 0 || (prev != sdl.Rect{0, 0, i32(r.fb_w), i32(r.fb_h)})
}

_intersect :: proc(a, b: sdl.Rect) -> sdl.Rect {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x + a.w, b.x + b.w)
	y1 := min(a.y + a.h, b.y + b.h)
	return {x0, y0, max(x1 - x0, 0), max(y1 - y0, 0)}
}
