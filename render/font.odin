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
		for &slot in t.slots do vg.text_layout_destroy(&slot)
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
// The ascent of text `px` high: its top to its baseline.
ascent :: proc(f: ^Font, px: f32) -> f32 {return px * f.text.ascent}

// text advance width in pixels at the given size (the widest line).
measure_text :: proc(f: ^Font, s: string, px: f32) -> f32 {
	l := _layout(f, s, 0, 0, px)
	w: f32
	for line in l.lines {
		w = max(w, line.width)
	}
	return w
}

// Draw UTF-8 text with its top-left (the ascent) at (x, y).
draw_text :: proc(c: ^vg.Canvas, f: ^Font, s: string, x, y, px: f32, color: vg.Color, scratch: ^vg.Path) {
	draw_layout(c, f, _layout(f, s, 0, px * f.text.ascent, px), x, y, color, scratch)
}

// Text measured now and drawn later in the same frame, laid out once: its
// slot among the font's warm layouts, with its top-left at the origin. A
// `tail` is laid out after `s` as more of the same text. Taking a slot may
// move the others: index them again after it.
text_slot :: proc(f: ^Font, s: string, px: f32, tail := "") -> int {
	t := f.text
	if t.used == len(t.slots) do append(&t.slots, vg.Text_Layout{})
	t.used += 1
	style := vg.Text_Style{size = px * t.em_per_px}
	pieces := [2]vg.Text_Piece{{text = s, style = style}, {text = tail, style = style}}
	vg.text_layout(&t.fonts, pieces[:tail == "" ? 1 : 2], {x = 0, y = px * t.ascent}, &t.slots[t.used - 1])
	return t.used - 1
}
// A slot's advance width (its widest line).
slot_width :: proc(f: ^Font, slot: int) -> f32 {
	w: f32
	for line in f.text.slots[slot].lines do w = max(w, line.width)
	return w
}
// Draw a slot's text with its top-left at (x, y).
draw_slot :: proc(c: ^vg.Canvas, f: ^Font, slot: int, x, y: f32, color: vg.Color, scratch: ^vg.Path) {
	draw_layout(c, f, &f.text.slots[slot], x, y, color, scratch)
}
// A laid-out text's glyph outlines filled with its origin at (x, y), on a
// whole pixel.
draw_layout :: proc(c: ^vg.Canvas, f: ^Font, l: ^vg.Text_Layout, x, y: f32, color: vg.Color, scratch: ^vg.Path) {
	draw_glyphs(c, f, l, x, y, 0, len(l.glyphs), color, scratch)
}
// As RAD's fnt_char_pos_from_tag_size_string_p: the byte offset in `s` (the
// slot's text) of the glyph boundary nearest `x` along it.
slot_offset_at :: proc(f: ^Font, slot: int, s: string, x: f32) -> int {
	l := &f.text.slots[slot]
	// The byte offset each codepoint starts at.
	starts := make([dynamic]int, 0, len(s) + 1, context.temp_allocator)
	for _, i in s do append(&starts, i)
	append(&starts, len(s))
	best, nearest := 0, max(f32)
	pen := f32(0)
	for i in 0 ..= len(l.glyphs) {
		offset := i < len(l.glyphs) ? starts[min(int(l.clusters[i]), len(starts) - 1)] : len(s)
		if d := abs(pen - x); d < nearest {best, nearest = offset, d}
		if i < len(l.glyphs) do pen += l.advances[i]
	}
	return best
}
// What a slot's text (`s` laid out at `px`) draws in `max_w`, as RAD
// Debugger's dr_truncated_fancy_run_list draws it: whole when it fits, else
// cut where `trailer` (its "...") still fits, the trailer after it; with no
// room for the trailer, cut where it fills `max_w`. RAD never splits a
// piece, so the cut falls between clusters (text_layout_fit). It follows
// the text's order, as Pango, CoreText and Qt elide: the trailer goes at the
// line's end edge, the left of a line read right to left, and a line mixing
// directions, whose kept glyphs can lie apart, has its kept text and trailer
// laid out again. The kept text is `layout`'s glyphs [first, first+count)
// with the layout's origin `origin` past x; the trailer `tail`'s glyphs
// [tail_first, tail_first+tail_count) with its origin `tail_x` past x
// (`tail_left`: it lies left of the text; tail -1: none).
Slot_Cut :: struct {
	layout, first, count:           int,
	origin:                         f32,
	tail, tail_first, tail_count:   int,
	tail_left:                      bool,
	tail_x:                         f32,
}
slot_cut :: proc(f: ^Font, slot: int, s, trailer: string, px, max_w: f32) -> (c: Slot_Cut) {
	c = {layout = slot, count = len(f.text.slots[slot].glyphs), tail = -1}
	if slot_width(f, slot) <= max_w do return
	ln := f.text.slots[slot].lines[0]
	c.first, c.count = ln.first, ln.count
	tail := text_slot(f, trailer, px) // (moves the slots: indexed after it)
	tail_w := slot_width(f, tail)
	enabled := tail_w < max_w
	if !enabled do tail_w = 0
	l := &f.text.slots[slot]
	cut, kept := vg.text_layout_fit(l, 0, max_w - tail_w)
	n, lead, trail := kept_glyphs(l, 0, cut)
	tail_count := len(f.text.slots[tail].glyphs)
	switch {
	case lead: // left to right, or nothing kept
		c.count = n
		if enabled do c.tail, c.tail_first, c.tail_count, c.tail_x = tail, 0, tail_count, kept
	case trail: // right to left: the trailer at x, the kept glyphs moved past it
		c.first, c.count, c.origin = ln.first + ln.count - n, n, tail_w - (ln.width - kept)
		if enabled do c.tail, c.tail_first, c.tail_count, c.tail_left = tail, 0, tail_count, true
	case: // apart: bidi places the kept text and the trailer laid out again
		end, k := len(s), i32(0)
		for _, i in s {
			if k == cut {end = i; break}
			k += 1
		}
		again := text_slot(f, s[:end], px, enabled ? trailer : "")
		m := &f.text.slots[again]
		mln := m.lines[0]
		mn, mlead, _ := kept_glyphs(m, 0, cut)
		c.layout, c.tail, c.tail_count = again, again, mln.count - mn
		if mlead {
			c.first, c.count, c.tail_first = mln.first, mn, mln.first + mn
		} else {
			c.first, c.count, c.tail_first, c.tail_left = mln.first + mln.count - mn, mn, mln.first, true
		}
	}
	return
}
// A cut slot (slot_cut) drawn with its top-left at (x, y): the kept text,
// then the trailer, each of its glyphs half as opaque as the one before going
// away from the text.
draw_slot_cut :: proc(c: ^vg.Canvas, f: ^Font, cut: Slot_Cut, x, y: f32, color: vg.Color, scratch: ^vg.Path) {
	draw_glyphs(c, f, &f.text.slots[cut.layout], x + cut.origin, y, cut.first, cut.count, color, scratch)
	if cut.tail >= 0 do draw_trailer(c, f, &f.text.slots[cut.tail], cut.tail_first, cut.tail_count, cut.tail_left, x + cut.tail_x, y, color, scratch)
}
// Where the kept glyphs of a cut slot (slot_cut) of `s` that start in its
// bytes [a, b) lie past x, as drawn: from the first one's start to the last
// one's end (RAD's fuzzy match pixel range); ok when any does.
cut_span :: proc(f: ^Font, cut: Slot_Cut, s: string, a, b: int) -> (x0, x1: f32, ok: bool) {
	l := &f.text.slots[cut.layout]
	starts := make([dynamic]int, 0, len(s) + 1, context.temp_allocator)
	for _, i in s do append(&starts, i)
	append(&starts, len(s))
	x0, x1 = max(f32), 0
	pen := cut.origin
	for i in l.lines[0].first ..< cut.first do pen += l.advances[i]
	for i in cut.first ..< cut.first + cut.count {
		offset := starts[min(int(l.clusters[i]), len(starts) - 1)]
		if offset >= a && offset < b {
			x0, x1, ok = min(x0, pen), max(x1, pen + l.advances[i]), true
		}
		pen += l.advances[i]
	}
	return
}
// How many of line `line`'s glyphs come before codepoint `cut`, and whether
// they are its first (it reads left to right) or its last (right to left);
// neither on a line mixing directions, where they can lie apart.
@(private)
kept_glyphs :: proc(l: ^vg.Text_Layout, line: int, cut: i32) -> (n: int, lead, trail: bool) {
	ln := l.lines[line]
	clusters := l.clusters[ln.first:][:ln.count]
	for k in clusters do if k < cut do n += 1
	lead, trail = true, true
	for k in clusters[:n] do if k >= cut do lead = false
	for k in clusters[ln.count - n:] do if k >= cut do trail = false
	return
}
// A layout's glyphs [first, first+count) filled with its origin at (x, y),
// on a whole pixel.
@(private)
draw_glyphs :: proc(c: ^vg.Canvas, f: ^Font, l: ^vg.Text_Layout, x, y: f32, first, count: int, color: vg.Color, scratch: ^vg.Path) {
	paint := vg.paint_color(color)
	vg.save(c); defer vg.restore(c)
	vg.translate(c, math.round(x), math.round(y))
	for run in l.runs {
		a, b := max(run.first, first), min(run.first + run.count, first + count)
		if a >= b do continue
		font := vg.text_layout_font(l, run)
		if font == nil do continue
		vg.fill_glyph_outlines(c, font, l.glyphs[a:b], run.em, paint, scratch)
	}
}
// A trailer, a layout's glyphs [first, first+count) with its origin at (x,
// y), each half as opaque as the one before it going away from the text: from
// its first glyph, or from its last when it lies left of the text.
@(private)
draw_trailer :: proc(c: ^vg.Canvas, f: ^Font, l: ^vg.Text_Layout, first, count: int, left: bool, x, y: f32, color: vg.Color, scratch: ^vg.Path) {
	dot := color
	for k in 0 ..< count {
		draw_glyph(c, f, l, left ? first + count - 1 - k : first + k, x, y, dot, scratch)
		dot.a *= 0.5
	}
}
// A layout's glyph i alone, its origin at (x, y).
@(private)
draw_glyph :: proc(c: ^vg.Canvas, f: ^Font, l: ^vg.Text_Layout, i: int, x, y: f32, color: vg.Color, scratch: ^vg.Path) {
	vg.save(c); defer vg.restore(c)
	vg.translate(c, math.round(x), math.round(y))
	for run in l.runs {
		if i < run.first || i >= run.first + run.count do continue
		if font := vg.text_layout_font(l, run); font != nil do vg.fill_glyph_outlines(c, font, l.glyphs[i:][:1], run.em, vg.paint_color(color), scratch)
	}
}
// A new frame: every slot is free.
font_frame :: proc(f: ^Font) {f.text.used = 0}

// `s` laid out with its baseline at (x, y) and `px` of pixel height.
@(private)
_layout :: proc(f: ^Font, s: string, x, y, px: f32) -> ^vg.Text_Layout {
	t := f.text
	piece := vg.Text_Piece{text = s, style = {size = px * t.em_per_px}}
	vg.text_layout(&t.fonts, {piece}, {x = x, y = y}, &t.layout)
	return &t.layout
}

