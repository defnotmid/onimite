// Package render is an SDL_GPU immediate-mode 2D renderer for the preview UI.
// Draw calls append to per-frame CPU batches; end_frame streams them to the GPU
// via cycling (shared) transfer buffers and replays a recorded command list in
// a single color pass, all through one pipeline: rect2d (instanced
// rounded-rect for all 2D + UI + glyphs).
//
// Ported from ../paf/render (itself from odincade's sketch_and_extrude), with
// paf's 3D, point-cloud, map, event and splat pipelines removed.
package render

import sdl "vendor:sdl3"

// ---- vertex formats ----

// pipe_rect2d: one instance per rounded-rect. 8 * vec4 = 128 bytes (std140-friendly).
Rect_Inst :: struct {
	dst:    [4]f32, // x0,y0,x1,y1 pixels
	src:    [4]f32, // u0,v0,u1,v1 texels
	col_tl: [4]f32,
	col_tr: [4]f32,
	col_bl: [4]f32,
	col_br: [4]f32,
	radii:  [4]f32, // TL,TR,BL,BR
	style:  [4]f32, // border, softness, sample_mode(0 solid/1 rgba/2 glyph), _
}

// ---- uniform blocks (must match GLSL std140 layout in shaders/) ----

Rect_VS_Uniforms :: struct {
	viewport: [2]f32,
	tex_size: [2]f32,
}

// sample modes encoded into Rect_Inst.style.z
SAMPLE_SOLID :: f32(0)
SAMPLE_RGBA :: f32(1)
SAMPLE_GLYPH :: f32(2)
SAMPLE_RGBA_NEAREST :: f32(3)
SAMPLE_HEAT :: f32(4) // a level texture (R8) as heat, filtered

// Convert a packed byte color to a straight-alpha float color.
color_f32 :: #force_inline proc "contextless" (c: [4]u8) -> [4]f32 {
	return {f32(c[0]) / 255, f32(c[1]) / 255, f32(c[2]) / 255, f32(c[3]) / 255}
}

// A recorded draw, captured by value at record time.
Draw_Cmd :: struct {
	first, count: u32, // instance range
	rect_u:       Rect_VS_Uniforms,
	tex:          ^sdl.GPUTexture, // bound to the fragment sampler
	use_scissor:  bool,
	scissor:      sdl.Rect,
	use_viewport: bool,
	viewport:     sdl.GPUViewport,
	// The output's owner (ui's box draw scope); draws of different owners
	// never coalesce.
	scope:        u32,
}
