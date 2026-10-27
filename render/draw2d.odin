package render

import vg "deps:ovg"
import vgsdl "deps:ovg/sdlgpu"

// A straight-alpha byte colour as ovg takes it, its alpha times `opacity`.
color :: proc "contextless" (c: [4]u8, opacity: f32 = 1) -> vg.Color {
	return {f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, f32(c.a) / 255 * clamp(opacity, 0, 1)}
}

draw_rect :: proc(r: ^Renderer, x, y, w, h: f32, c: [4]u8) {
	vg.path_reset(&r.path)
	vg.path_rect(&r.path, x, y, w, h)
	vg.fill_path(&r.canvas, &r.path, vg.paint_color(color(c)))
}

draw_rect_rounded :: proc(r: ^Renderer, x, y, w, h, radius: f32, c: [4]u8) {
	vg.path_reset(&r.path)
	vg.path_rounded_rect(&r.path, x, y, w, h, radius)
	vg.fill_path(&r.canvas, &r.path, vg.paint_color(color(c)))
}

draw_rect_gradient_horizontal :: proc(r: ^Renderer, x, y, w, h: f32, left, right: [4]u8, radius: f32 = 0) {
	vg.path_reset(&r.path)
	vg.path_rounded_rect(&r.path, x, y, w, h, radius)
	vg.fill_path(&r.canvas, &r.path, vg.paint_linear_gradient(x, y, x + w, y, color(left), color(right)))
}

// The ring `thickness` wide inside the rect: the rect less the rect inset.
draw_rect_outline :: proc(r: ^Renderer, x, y, w, h, thickness: f32, c: [4]u8, radius: f32 = 0) {
	t := max(thickness, 1)
	vg.path_reset(&r.path)
	vg.path_rounded_rect(&r.path, x, y, w, h, radius)
	vg.path_rounded_rect(&r.path, x + t, y + t, max(w - 2 * t, 0), max(h - 2 * t, 0), max(radius - t, 0))
	vg.path_solidity(&r.path, .Hole)
	vg.fill_path(&r.canvas, &r.path, vg.paint_color(color(c)))
}

// ---- images ----

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
	id := show(r, image, nearest)
	vg.path_reset(&r.path)
	vg.path_rect(&r.path, x, y, w, h)
	vg.fill_path(&r.canvas, &r.path, vg.paint_image(id, x, y, w, h, 0, clamp(opacity, 0, 1)))
}

// draw_image_src draws the texels `src` (x0, y0, x1, y1) of `image` into
// `(x, y, w, h)`: a stretch of a strip texture (a spectrogram's rows).
draw_image_src :: proc(r: ^Renderer, image: ^Image, src: [4]f32, x, y, w, h: f32) {
	if !image_loaded(image) || w <= 0 || h <= 0 || src[2] <= src[0] || src[3] <= src[1] {
		return
	}
	sx, sy := w / (src[2] - src[0]), h / (src[3] - src[1])
	id := show(r, image, false)
	vg.path_reset(&r.path)
	vg.path_rect(&r.path, x, y, w, h)
	vg.fill_path(&r.canvas, &r.path, vg.paint_image(id, x - src[0] * sx, y - src[1] * sy, f32(image.width) * sx, f32(image.height) * sy, 0))
}

// The next of the frame's borrowed images, showing `image`'s texture.
@(private = "file")
show :: proc(r: ^Renderer, image: ^Image, nearest: bool) -> vg.Image_Id {
	if r.shown == len(r.borrowed) {
		append(&r.borrowed, vg.Image_Id{})
	}
	flags: vg.Image_Flags = {.Nearest} if nearest else {}
	r.borrowed[r.shown] = vgsdl.image_borrow_texture(&r.canvas, r.borrowed[r.shown], image.texture, image.width, image.height, .RGBA8, flags)
	r.shown += 1
	return r.borrowed[r.shown - 1]
}

// ---- scissor clip stack ----

clip_push :: proc(r: ^Renderer, x, y, w, h: f32) {
	vg.save(&r.canvas)
	vg.intersect_scissor(&r.canvas, x, y, w, h)
	r.clips += 1
}

clip_pop :: proc(r: ^Renderer) {
	if r.clips == 0 {
		return
	}
	vg.restore(&r.canvas)
	r.clips -= 1
}
