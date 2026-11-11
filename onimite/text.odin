package onimite

import "core:strings"
import vg "deps:ovg"

// Text measuring for layout, using the same fonts and advances as drawing.
// Only the media's fonts are needed, so these work outside a render too
// (scripts measure at load). `ok = false` when the family isn't in the
// media: the text is then measured with the fallback font.

Font_Query :: struct {
	family:         string,
	size:           f32,
	weight:         int,
	italic:         bool,
	letter_spacing: f32,
	features:       []Font_Feature,
	// A variable font's instance: axis tags ("wght", "wdth", "opsz") and
	// values in the axis's units (`media_text_variations`).
	variations:     []Font_Variation,
}

// A variable font axis's tag ("wght") and value in its own units.
Font_Variation :: vg.Font_Variation

// An OpenType feature's tag ("smcp", "ss01") and value: 0 off, 1 on, n > 1
// the nth alternate (salt, cv01); set over the font's defaults.
Font_Feature :: vg.Font_Feature

// Width of `s` in pixels.
text_width :: proc(m: ^Media, q: Font_Query, s: string) -> (width: f32, ok: bool) {
	return measure(m, q, s), font_found(m, q)
}

// `s` if it fits in `max_width`, otherwise as much of its first line as
// fits before `ellipsis`, cut only between clusters (ovg's
// text_layout_fit: never inside a grapheme, a ligature or a syllable), its
// trailing spaces trimmed, then `ellipsis`. One layout of `s`; the result
// is in the temp allocator.
text_fit :: proc(m: ^Media, q: Font_Query, s: string, max_width: f32, ellipsis := "…") -> (fitted: string, ok: bool) {
	ok = font_found(m, q)
	layout: vg.Text_Layout
	vg.text_layout_init(&layout, context.temp_allocator)
	vg.text_layout(&m.fonts, {text_piece(m, q, s)}, {}, &layout)
	if len(layout.lines) == 0 || vg.text_layout_width(&layout) <= max_width {
		return s, ok
	}
	room := max_width - measure(m, q, ellipsis)
	for {
		cut, kept := vg.text_layout_fit(&layout, 0, room)
		fitted = strings.concatenate({strings.trim_right_space(s[:codepoint_offset(s, int(cut))]), ellipsis}, context.temp_allocator)
		// shaped again, the kept text and the ellipsis can come out wider
		// (a joining form or a kern pair at the cut): give up the overshoot
		over := measure(m, q, fitted) - max_width
		if over <= 0 || cut <= layout.lines[0].text_start {
			return fitted, ok
		}
		room = kept - over
	}
}

// Splits `s` into lines no wider than `max_width` where Unicode allows a
// line break (ovg's layout, UAX #14: at spaces, after hyphens, between CJK
// characters, at newlines); a word wider than `max_width` keeps a line of
// its own. One layout of `s` at that width, sliced at its lines. Lines are
// slices of `s` without the spaces or newline they break at; the list is
// allocated with `allocator`.
text_break_lines :: proc(m: ^Media, q: Font_Query, s: string, max_width: f32, allocator := context.temp_allocator) -> (lines: []string, ok: bool) {
	layout: vg.Text_Layout
	vg.text_layout_init(&layout, context.temp_allocator)
	vg.text_layout(&m.fonts, {text_piece(m, q, s)}, {width = max_width}, &layout)
	// each codepoint's byte offset in `s` (a line's ends are codepoint indices), and the end
	at := make([dynamic]int, 0, len(s) + 1, context.temp_allocator)
	for _, i in s {
		append(&at, i)
	}
	append(&at, len(s))
	list := make([dynamic]string, 0, max(len(layout.lines), 1), allocator)
	for line in layout.lines {
		a := at[clamp(int(line.text_start), 0, len(at) - 1)]
		b := at[clamp(int(line.text_end), 0, len(at) - 1)]
		append(&list, strings.trim_right(s[a:b], " \t\r\n"))
	}
	if len(list) == 0 {
		append(&list, "")
	}
	return list[:], font_found(m, q)
}

// The warning drawing gives for a family that isn't in the media (fframes /
// usvg wording; the text still renders), once per frame.
report_missing_font :: proc(ctx: ^Context, family: string) {
	if family != "" && !has_diagnostic(ctx, .Missing_Font, family) {
		report(ctx, .Warning, {code = .Missing_Font, name = family})
	}
}

@(private)
font_found :: proc(m: ^Media, q: Font_Query) -> bool {
	_, found := media_find_font(m, q.family, q.weight, q.italic)
	return found
}

@(private)
measure :: proc(m: ^Media, q: Font_Query, s: string) -> f32 {
	layout: vg.Text_Layout
	vg.text_layout_init(&layout, context.temp_allocator)
	vg.text_layout(&m.fonts, {text_piece(m, q, s)}, {}, &layout)
	return vg.text_layout_width(&layout)
}

// The byte offset of codepoint `index` in `s` (len(s) past its end).
@(private)
codepoint_offset :: proc(s: string, index: int) -> int {
	k := 0
	for _, i in s {
		if k == index {
			return i
		}
		k += 1
	}
	return len(s)
}

// `s` as one piece in the query's style (its variations as drawn:
// `media_text_variations`).
text_piece :: proc(m: ^Media, q: Font_Query, s: string) -> vg.Text_Piece {
	return {text = s, style = {family = q.family, size = q.size, weight = q.weight, italic = q.italic, letter_spacing = q.letter_spacing, features = q.features, variations = media_text_variations(m, q.family, q.weight, q.italic, q.variations)}}
}
