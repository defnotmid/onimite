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
	italic:         bool,
	letter_spacing: f32,
	features:       []Font_Feature,
}

// An OpenType feature's tag ("smcp", "ss01") and value: 0 off, 1 on, n > 1
// the nth alternate (salt, cv01); set over the font's defaults.
Font_Feature :: vg.Font_Feature

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
	ends := make([dynamic]int, 0, len(s), context.temp_allocator)
	for i := 0; i < len(s); {
		_, n := utf8.decode_rune_in_string(s[i:])
		i += n
		append(&ends, i)
	}
	lo, hi := 0, len(ends)
	for lo < hi {
		mid := (lo + hi) / 2
		if measure(m, q, s[:ends[mid]]) + ell <= max_width {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	end := ends[lo - 1] if lo > 0 else 0
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
			for i < len(paragraph) && paragraph[i] == ' ' {
				last_space = i
				i += 1
			}
			word_end := i
			for word_end < len(paragraph) && paragraph[word_end] != ' ' {
				_, n := utf8.decode_rune_in_string(paragraph[word_end:])
				word_end += n
			}
			if word_end == i || measure(m, q, paragraph[line_start:word_end]) <= max_width {
				i = word_end
				continue
			}
			if last_space > line_start {
				append(&list, strings.trim_right_space(paragraph[line_start:last_space]))
				line_start = last_space
				for line_start < len(paragraph) && paragraph[line_start] == ' ' {
					line_start += 1
				}
				last_space = -1
				i = line_start
				continue
			}
			// A single word wider than max_width: binary search the rune where it overflows.
			ends := make([dynamic]int, 0, word_end - line_start, context.temp_allocator)
			for p := line_start; p < word_end; {
				_, n := utf8.decode_rune_in_string(paragraph[p:])
				p += n
				append(&ends, p)
			}
			lo, hi := 1, len(ends)
			for lo < hi {
				mid := (lo + hi) / 2
				if measure(m, q, paragraph[line_start:ends[mid]]) <= max_width {
					lo = mid + 1
				} else {
					hi = mid
				}
			}
			brk := ends[lo - 1]
			append(&list, strings.trim_right_space(paragraph[line_start:brk]))
			line_start = brk
			last_space = -1
			i = line_start
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
	_, found := media_find_font(m, q.family, q.weight, q.italic)
	return found
}

@(private)
measure :: proc(m: ^Media, q: Font_Query, s: string) -> f32 {
	layout: vg.Text_Layout
	vg.text_layout_init(&layout, context.temp_allocator)
	piece := vg.Text_Piece{text = s, style = {family = q.family, size = q.size, weight = q.weight, italic = q.italic, letter_spacing = q.letter_spacing, features = q.features}}
	vg.text_layout(&m.fonts, {piece}, {}, &layout)
	return vg.text_layout_width(&layout)
}
