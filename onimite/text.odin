package onimite

import "core:strings"
import "core:unicode/utf8"
import vg "deps:ovg"

// Text measuring for layout, using the same fonts and advances as drawing.
// Only the media's fonts are needed, so these work outside a render too
// (scripts measure at load). `ok = false` when the family isn't in the
// media: the text is then measured with the fallback font.

Font_Query :: struct {
	family:         string,
	size:           f32,
	weight:         int,
	letter_spacing: f32,
}

// Width of `s` in pixels.
text_width :: proc(m: ^Media, q: Font_Query, s: string) -> (width: f32, ok: bool) {
	return measure(m, q, s), font_found(m, q)
}

// `s` if it fits in `max_width`, otherwise the longest prefix that fits
// followed by `ellipsis` (allocated with `allocator`).
text_fit :: proc(m: ^Media, q: Font_Query, s: string, max_width: f32, ellipsis := "…", allocator := context.temp_allocator) -> (fitted: string, ok: bool) {
	ok = font_found(m, q)
	if measure(m, q, s) <= max_width {
		return s, ok
	}
	ell := measure(m, q, ellipsis)
	end := 0
	for i := 0; i < len(s); {
		_, n := utf8.decode_rune_in_string(s[i:])
		if measure(m, q, s[:i + n]) + ell > max_width {
			break
		}
		i += n
		end = i
	}
	return strings.concatenate({strings.trim_right_space(s[:end]), ellipsis}, allocator), ok
}

// Splits `s` into lines no wider than `max_width`, breaking at spaces (and
// inside words longer than a line). Lines are slices of `s` without trailing
// spaces, and a wrapped line starts after the spaces it broke at; the list
// is allocated with `allocator`.
text_break_lines :: proc(m: ^Media, q: Font_Query, s: string, max_width: f32, allocator := context.temp_allocator) -> (lines: []string, ok: bool) {
	list := make([dynamic]string, allocator)
	for paragraph in strings.split_lines(s, context.temp_allocator) {
		line_start := 0
		last_space := -1
		i := 0
		for i < len(paragraph) {
			r, n := utf8.decode_rune_in_string(paragraph[i:])
			if r == ' ' {
				last_space = i
			}
			if measure(m, q, paragraph[line_start:i + n]) > max_width && i > line_start {
				brk := last_space if last_space > line_start else i
				append(&list, strings.trim_right_space(paragraph[line_start:brk]))
				line_start = brk
				for line_start < len(paragraph) && paragraph[line_start] == ' ' {
					line_start += 1
				}
				last_space = -1
				i = line_start
				continue
			}
			i += n
		}
		append(&list, strings.trim_right_space(paragraph[line_start:]))
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
	_, found := media_find_font(m, q.family, q.weight)
	return found
}

@(private)
measure :: proc(m: ^Media, q: Font_Query, s: string) -> f32 {
	layout: vg.Text_Layout
	layout.glyphs.allocator = context.temp_allocator
	layout.clusters.allocator = context.temp_allocator
	layout.runs.allocator = context.temp_allocator
	layout.lines.allocator = context.temp_allocator
	layout.missing.allocator = context.temp_allocator
	piece := vg.Text_Piece{text = s, style = {q.family, q.size, q.weight, false, q.letter_spacing, 0}}
	vg.text_layout(&m.fonts, {piece}, {}, &layout)
	return vg.text_layout_width(&layout)
}
