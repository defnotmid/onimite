package render

import "core:math"
import "core:mem"
import "core:slice"
import vg "deps:ovg"
import sdl "vendor:sdl3"

// Text is laid out by ovg (oglyph's OpenType shaper over a Font_Collection: kerning,
// ligatures, bidi, per-glyph fallback) and rasterized into ovg's CPU glyph
// atlas; we mirror the atlas rows it wrote into an R8 GPU texture and draw
// each glyph quad through the shared rect2d (glyph) pipeline.
Font :: struct {
	text:  ^Font_Text, // heap-allocated so Font stays trivially movable
	atlas: ^sdl.GPUTexture,
	r:     ^Renderer,
	ttf:   []u8, // owned; the collection and the atlas's glyph keys borrow it
}

Font_Text :: struct {
	fonts:     vg.Font_Collection,
	glyphs:    vg.Glyph_Atlas,
	layout:    vg.Text_Layout,
	// The UI sizes text by pixel height (ascent to descent): the em size per
	// pixel of height, and the ascent and line advance per pixel of height.
	em_per_px: f32,
	ascent:    f32,
	line:      f32,
	// In the renderer's dirty_fonts this frame.
	queued:    bool,
}

ATLAS_DIM :: 1024

font_load :: proc(r: ^Renderer, ttf: []u8, base_px: f32) -> (font: Font, ok: bool) {
	font.r = r
	font.ttf = slice.clone(ttf)
	t := new(Font_Text)
	font.text = t
	vg.font_collection_init(&t.fonts, font.ttf)
	if vg.font_collection_add(&t.fonts, font.ttf) == 0 || vg.glyph_atlas_init(&t.glyphs, ATLAS_DIM, ATLAS_DIM) != nil {
		font_unload(r, &font)
		return {}, false
	}
	f := &t.fonts.faces[0].font
	m := vg.font_v_metrics(f)
	height := f32(m.ascent - m.descent)
	t.em_per_px = vg.font_scale_for_pixel_height(f, 1) / vg.font_scale_for_em(f, 1)
	t.ascent = f32(m.ascent) / height
	t.line = f32(m.ascent - m.descent + m.line_gap) / height
	font.atlas = _make_r8_texture(r, ATLAS_DIM, ATLAS_DIM, t.glyphs.pixels)
	return font, true
}

font_unload :: proc(r: ^Renderer, f: ^Font) {
	if t := f.text; t != nil {
		vg.text_layout_destroy(&t.layout)
		vg.glyph_atlas_destroy(&t.glyphs)
		vg.font_collection_destroy(&t.fonts)
		free(t)
	}
	if f.atlas != nil {
		defer_release_texture(r, f.atlas)
	}
	delete(f.ttf)
	f^ = {}
}

line_height :: proc(f: ^Font, px: f32) -> f32 {
	return px * f.text.line
}

// text advance width in pixels at the given size (the widest line).
measure_text :: proc(f: ^Font, s: string, px: f32) -> f32 {
	l := _layout(f, s, 0, 0, px)
	w: f32
	for line in l.lines {
		w = max(w, line.width)
	}
	return w
}

// draw UTF-8 text with its top-left (the ascent) at (x, y).
draw_text :: proc(r: ^Renderer, f: ^Font, s: string, x, y, px: f32, color: [4]u8) {
	_glyph_quads(r, f, _layout(f, s, x, y + px * f.text.ascent, px), color)
}

// font_warm rasterizes printable ASCII at each size up front, so the first
// frames that show text at those sizes don't rasterize (and upload) glyphs.
font_warm :: proc(r: ^Renderer, f: ^Font, sizes: []f32) {
	ASCII :: " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~·…–×%"
	for px in sizes {
		_glyph_quads(nil, f, _layout(f, ASCII, 0, 0, px), {})
	}
}

// `s` laid out with its baseline at (x, y) and `px` of pixel height.
@(private)
_layout :: proc(f: ^Font, s: string, x, y, px: f32) -> ^vg.Text_Layout {
	t := f.text
	piece := vg.Text_Piece{text = s, style = {size = px * t.em_per_px}}
	vg.text_layout(&t.fonts, {piece}, {x = x, y = y}, &t.layout)
	return &t.layout
}

// Rasterizes the layout's glyphs into the atlas and, with a renderer, draws
// them, snapped to whole pixels. The atlas holds every size the UI shows;
// if it fills (unusual scripts at many sizes) it starts over, and quads
// already recorded this frame show the new atlas until the next frame.
@(private)
_glyph_quads :: proc(r: ^Renderer, f: ^Font, l: ^vg.Text_Layout, color: [4]u8) {
	t := f.text
	cf := color_f32(color)
	aw, ah := f32(t.glyphs.width), f32(t.glyphs.height)
	for run in l.runs {
		for g in l.glyphs[run.first:][:run.count] {
			cg, err := vg.glyph_atlas_get(&t.glyphs, run.font, g.glyph, run.em)
			if err == .Atlas_Full {
				vg.glyph_atlas_reset(&t.glyphs)
				cg, err = vg.glyph_atlas_get(&t.glyphs, run.font, g.glyph, run.em)
			}
			if err != nil || !cg.visible || r == nil {
				continue
			}
			x0 := math.round(g.x) + f32(cg.bearing_x)
			y0 := math.round(g.y) + f32(cg.bearing_y)
			u0, v0 := f32(cg.atlas_x) / aw, f32(cg.atlas_y) / ah
			rect_inst(r, Rect_Inst{
				dst    = {x0, y0, x0 + f32(cg.width), y0 + f32(cg.height)},
				src    = {u0, v0, u0 + f32(cg.width) / aw, v0 + f32(cg.height) / ah}, // normalized uv (tex_size = 1 below)
				col_tl = cf, col_tr = cf, col_bl = cf, col_br = cf,
				style  = {0, 0, SAMPLE_GLYPH, 0},
			}, f.atlas, {1, 1})
		}
	}
	if !t.queued {
		t.queued = true
		append(&f.r.dirty_fonts, f)
	}
}

// Uploads the atlas rows fonts rasterized into this frame (called by
// end_frame before the draws replay).
font_flush :: proc(r: ^Renderer) {
	for f in r.dirty_fonts {
		t := f.text
		t.queued = false
		if y0, y1, ok := vg.glyph_atlas_take_dirty(&t.glyphs); ok && y1 > y0 {
			w := t.glyphs.width
			_upload_r8_rows(r, f.atlas, w, y0, y1 - y0, t.glyphs.pixels[int(y0 * w):])
		}
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
	// A texture that could not be made (no device: a headless test) is not written.
	if tex == nil do return
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
