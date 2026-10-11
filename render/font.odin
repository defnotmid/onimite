package render

import "core:mem"
import "core:slice"
import sdl "vendor:sdl3"
import fs "vendor:fontstash"

// Text is rendered through vendor:fontstash — a native-Odin glyph atlas manager
// (dynamic per-codepoint/size caching, kerning, fallbacks) that rasterizes via
// stb_truetype. fontstash owns a CPU atlas bitmap; we mirror it into an R8 GPU
// texture and draw each glyph quad through the shared rect2d (glyph) pipeline.
Font :: struct {
	ctx:    ^fs.FontContext, // heap-allocated so Font stays trivially movable
	id:     int,
	atlas:  ^sdl.GPUTexture,
	aw, ah: int,
	r:      ^Renderer,
	ttf:    []u8, // owned; fontstash references it (freeLoadedData=false)
	// Atlas rows rasterized into since the last upload ([0, 0): none); the
	// renderer uploads them once per frame (font_flush).
	dirty_y0, dirty_y1: int,
}

ATLAS_DIM :: 1024

font_load :: proc(r: ^Renderer, ttf: []u8, base_px: f32) -> (font: Font, ok: bool) {
	font.r = r
	font.ttf = slice.clone(ttf)
	font.ctx = new(fs.FontContext)
	fs.Init(font.ctx, ATLAS_DIM, ATLAS_DIM, .TOPLEFT)
	font.aw, font.ah = ATLAS_DIM, ATLAS_DIM
	font.id = fs.AddFontMem(font.ctx, "app", font.ttf, false)
	if font.id < 0 {
		fs.Destroy(font.ctx); free(font.ctx); delete(font.ttf)
		return {}, false
	}
	// initial (mostly empty) atlas — grows as glyphs are cached, re-uploaded lazily
	font.atlas = _make_r8_texture(r, ATLAS_DIM, ATLAS_DIM, font.ctx.textureData)
	return font, true
}

font_unload :: proc(r: ^Renderer, f: ^Font) {
	if f.ctx != nil {
		fs.Destroy(f.ctx)
		free(f.ctx)
	}
	if f.atlas != nil {
		defer_release_texture(r, f.atlas)
	}
	delete(f.ttf)
	f^ = {}
}

line_height :: proc(f: ^Font, px: f32) -> f32 {
	fs.PushState(f.ctx)
	defer fs.PopState(f.ctx)
	fs.SetFont(f.ctx, f.id)
	fs.SetSize(f.ctx, px)
	_, _, lh := fs.VerticalMetrics(f.ctx)
	return lh
}

// text advance width in pixels at the given size.
measure_text :: proc(f: ^Font, s: string, px: f32) -> f32 {
	fs.PushState(f.ctx)
	defer fs.PopState(f.ctx)
	fs.SetFont(f.ctx, f.id)
	fs.SetSize(f.ctx, px)
	return fs.TextBounds(f.ctx, s)
}

// draw ASCII/UTF-8 text with its top-left at (x, y).
draw_text :: proc(r: ^Renderer, f: ^Font, s: string, x, y, px: f32, color: [4]u8) {
	fs.PushState(f.ctx)
	fs.SetFont(f.ctx, f.id)
	fs.SetSize(f.ctx, px)
	fs.SetAlignHorizontal(f.ctx, .LEFT)
	fs.SetAlignVertical(f.ctx, .TOP)

	cf := color_f32(color)
	iter := fs.TextIterInit(f.ctx, x, y, s)
	q: fs.Quad
	for fs.TextIterNext(f.ctx, &iter, &q) {
		rect_inst(r, Rect_Inst{
			dst    = {q.x0, q.y0, q.x1, q.y1},
			src    = {q.s0, q.t0, q.s1, q.t1}, // normalized uv (tex_size = 1 below)
			col_tl = cf, col_tr = cf, col_bl = cf, col_br = cf,
			style  = {0, 0, SAMPLE_GLYPH, 0},
		}, f.atlas, {1, 1})
	}
	fs.PopState(f.ctx)

	_font_mark_dirty(r, f)
}

// New glyphs rasterized: remember the rows, uploaded once before the frame's
// draws replay (font_flush), however many strings added glyphs.
_font_mark_dirty :: proc(r: ^Renderer, f: ^Font) {
	dirty: [4]f32
	if !fs.ValidateTexture(f.ctx, &dirty) {
		return
	}
	y0, y1 := int(dirty[1]), int(dirty[3])
	if f.dirty_y1 <= f.dirty_y0 {
		f.dirty_y0, f.dirty_y1 = y0, y1
		append(&r.dirty_fonts, f)
	} else {
		f.dirty_y0, f.dirty_y1 = min(f.dirty_y0, y0), max(f.dirty_y1, y1)
	}
}

// font_warm rasterizes printable ASCII at each size up front, so the first
// frames that show text at those sizes don't rasterize (and upload) glyphs.
font_warm :: proc(r: ^Renderer, f: ^Font, sizes: []f32) {
	ASCII :: " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~·…–×%"
	fs.PushState(f.ctx)
	defer fs.PopState(f.ctx)
	fs.SetFont(f.ctx, f.id)
	for px in sizes {
		fs.SetSize(f.ctx, px)
		iter := fs.TextIterInit(f.ctx, 0, 0, ASCII)
		q: fs.Quad
		for fs.TextIterNext(f.ctx, &iter, &q) {}
	}
	_font_mark_dirty(r, f)
}

// Uploads the atlas rows fonts rasterized into this frame (called by
// end_frame before the draws replay).
font_flush :: proc(r: ^Renderer) {
	for f in r.dirty_fonts {
		y0 := clamp(f.dirty_y0, 0, f.ah)
		y1 := clamp(f.dirty_y1, y0, f.ah)
		if y1 > y0 {
			_upload_r8_rows(r, f.atlas, u32(f.aw), u32(y0), u32(y1 - y0), f.ctx.textureData[y0 * f.aw:])
		}
		f.dirty_y0, f.dirty_y1 = 0, 0
	}
	clear(&r.dirty_fonts)
}

_make_r8_texture :: proc(r: ^Renderer, w, h: u32, data: []u8) -> ^sdl.GPUTexture {
	tex := sdl.CreateGPUTexture(r.device, sdl.GPUTextureCreateInfo{
		type = .D2, format = .R8_UNORM, usage = {.SAMPLER},
		width = w, height = h, layer_count_or_depth = 1, num_levels = 1, sample_count = ._1,
	})
	_upload_r8_texture(r, tex, w, h, data)
	return tex
}

_upload_r8_texture :: proc(r: ^Renderer, tex: ^sdl.GPUTexture, w, h: u32, data: []u8) {
	_upload_r8_rows(r, tex, w, 0, h, data)
}

// Rows [y, y + h) of an R8 texture `w` wide from `data` (starting at row y).
_upload_r8_rows :: proc(r: ^Renderer, tex: ^sdl.GPUTexture, w, y, h: u32, data: []u8) {
	size := int(w * h)
	tbo := sdl.CreateGPUTransferBuffer(r.device, {usage = .UPLOAD, size = u32(size)})
	ptr := sdl.MapGPUTransferBuffer(r.device, tbo, false)
	mem.copy(ptr, raw_data(data), min(size, len(data)))
	sdl.UnmapGPUTransferBuffer(r.device, tbo)
	cmd := sdl.AcquireGPUCommandBuffer(r.device)
	cp := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUTexture(cp,
		{transfer_buffer = tbo, offset = 0, pixels_per_row = w, rows_per_layer = h},
		{texture = tex, y = y, w = w, h = h, d = 1}, false)
	sdl.EndGPUCopyPass(cp)
	_ = sdl.SubmitGPUCommandBuffer(cmd)
	defer_release_transfer_buffer(r, tbo)
}
