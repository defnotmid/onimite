package render

import "core:math"
import "core:slice"
import vg "deps:ovg"

// Text is laid out by ovg (oglyph's OpenType shaper over a Font_Collection:
// kerning, ligatures, bidi, per-glyph fallback) and drawn by ovg as its
// glyphs' outlines, on the frame's canvas with everything else.
Font :: struct {
	text: ^Font_Text, // heap-allocated so Font stays trivially movable
	ttf:  []u8, // owned; the collection borrows it
}

Font_Text :: struct {
	fonts:     vg.Font_Collection,
	layout:    vg.Text_Layout,
	// The UI sizes text by pixel height (ascent to descent): the em size per
	// pixel of height, and the ascent and line advance per pixel of height.
	em_per_px: f32,
	ascent:    f32,
	line:      f32,
	// Texts laid out once this frame, to measure and then draw (text_slot):
	// warm layouts, the first `used` taken, all free again at font_frame.
	slots:     [dynamic]vg.Text_Layout,
	used:      int,
}

font_load :: proc(ttf: []u8) -> (font: Font, ok: bool) {
	font.ttf = slice.clone(ttf)
	t := new(Font_Text)
	font.text = t
	vg.font_collection_init(&t.fonts, font.ttf)
	if vg.font_collection_add(&t.fonts, font.ttf) == 0 {
		font_unload(&font)
		return {}, false
	}
	f := vg.font_collection_font(&t.fonts, t.fonts.faces[0].id)
	m := vg.font_v_metrics(f)
	height := f32(m.ascent - m.descent)
	t.em_per_px = vg.font_scale_for_pixel_height(f, 1) / vg.font_scale_for_em(f, 1)
	t.ascent = f32(m.ascent) / height
	t.line = f32(m.ascent - m.descent + m.line_gap) / height
	return font, true
}

font_unload :: proc(f: ^Font) {
	if t := f.text; t != nil {
		vg.text_layout_destroy(&t.layout)
		for &l in t.slots do vg.text_layout_destroy(&l)
		delete(t.slots)
		vg.font_collection_destroy(&t.fonts)
		free(t)
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
draw_text :: proc(r: ^Renderer, f: ^Font, s: string, x, y, px: f32, c: [4]u8) {
	draw_layout(r, _layout(f, s, 0, px * f.text.ascent, px), x, y, c)
}

// Text measured now and drawn later in the same frame, laid out once: its
// slot among the font's warm layouts, with its top-left at the origin.
text_slot :: proc(f: ^Font, s: string, px: f32) -> int {
	t := f.text
	if t.used == len(t.slots) do append(&t.slots, vg.Text_Layout{})
	t.used += 1
	piece := vg.Text_Piece{text = s, style = {size = px * t.em_per_px}}
	vg.text_layout(&t.fonts, {piece}, {x = 0, y = px * t.ascent}, &t.slots[t.used - 1])
	return t.used - 1
}
// A slot's advance width (its widest line).
slot_width :: proc(f: ^Font, slot: int) -> f32 {
	w: f32
	for line in f.text.slots[slot].lines do w = max(w, line.width)
	return w
}
// Draw a slot's text with its top-left at (x, y).
draw_slot :: proc(r: ^Renderer, f: ^Font, slot: int, x, y: f32, c: [4]u8) {
	draw_layout(r, &f.text.slots[slot], x, y, c)
}
// A new frame: every slot is free.
font_frame :: proc(f: ^Font) {f.text.used = 0}

// A laid-out text's glyph outlines filled with its origin at (x, y), on a
// whole pixel.
@(private)
draw_layout :: proc(r: ^Renderer, l: ^vg.Text_Layout, x, y: f32, c: [4]u8) {
	paint := vg.paint_color(color(c))
	vg.save(&r.canvas)
	defer vg.restore(&r.canvas)
	vg.translate(&r.canvas, math.round(x), math.round(y))
	for run in l.runs {
		if font := vg.text_layout_font(l, run); font != nil {
			vg.fill_glyph_outlines(&r.canvas, font, l.glyphs[run.first:][:run.count], run.em, paint, &r.path)
		}
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
