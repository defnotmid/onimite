package onimite

import "core:fmt"
import "core:math"
import "core:strings"
import "core:unicode/utf8"
import vg "deps:ovg"

// Checks of the frame just drawn that fframes' inspect reports and the
// drawing doesn't: an empty frame, NaN or infinite values, characters no
// font can draw, and texts drawn over each other. Every drawn frame runs
// them (`draw_frame`), so inspect, render and the preview find the same
// problems. They read the node tree (a flat array) and the texts drawing
// noted.
@(private)
check_frame :: proc(r: ^Renderer) {
	nodes := r.ctx.tree.nodes[:]
	leaves := 0
	for n, i in nodes {
		bad := false
		#partial switch v in n.kind {
		case Group:
			if t, ok := v.transform.?; ok {
				bad = !finite(t.translate.x, t.translate.y, t.scale.x, t.scale.y, t.rotate, t.origin.x, t.origin.y)
				if m, has := t.affine.?; has {
					bad |= !finite(m[0], m[1], m[2], m[3], m[4], m[5])
				}
			}
			if o, ok := v.opacity.?; ok {
				bad |= !finite(o)
			}
		case Rect:
			bad = !finite(v.x, v.y, v.w, v.h, v.rx)
			leaves += 1
		case Circle:
			bad = !finite(v.cx, v.cy, v.r)
			leaves += 1
		case Ellipse:
			bad = !finite(v.cx, v.cy, v.rx, v.ry)
			leaves += 1
		case Line:
			bad = !finite(v.x1, v.y1, v.x2, v.y2)
			leaves += 1
		case Path:
			leaves += 1
		case Text:
			bad = !finite(v.x, v.y, v.size)
			leaves += 1
			check_glyphs(r, v, i32(i) + 1)
		case Image:
			bad = !finite(v.x, v.y, v.w, v.h)
			leaves += 1
		case:
			leaves += 1
		}
		if bad {
			report(&r.ctx, .Error, {code = .Nan_Transform, name = node_kind_name(n.kind), n = i64(i), node = i32(i) + 1})
		}
	}
	if leaves == 0 {
		report(&r.ctx, .Warning, {code = .Empty_Frame})
	}
	check_text_overlaps(r)
}

@(private = "file")
finite :: proc(values: ..f32) -> bool {
	for v in values {
		if math.is_nan(v) || math.is_inf(v) {
			return false
		}
	}
	return true
}

// Characters of `t` no font has a glyph for, after per-glyph fallback
// (they are not drawn).
@(private = "file")
check_glyphs :: proc(r: ^Renderer, t: Text, node: i32) {
	check_str :: proc(r: ^Renderer, text, family: string, weight: int, italic: bool, node: i32) {
		font, _ := media_find_font(r.media, family, weight, italic)
		for c in text {
			if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 0xA0 || c < 0x20 || vg.rune_is_default_ignorable(c) {
				continue
			}
			if _, g := vg.font_collection_glyph(&r.media.fonts, c, font); g == 0 {
				report(&r.ctx, .Error, {code = .Missing_Glyph, name = text, a = fmt.tprintf("%c", c), n = i64(c), node = node})
			}
		}
	}
	check_str(r, t.text, t.font, t.weight, t.italic, node)
	for s in t.spans {
		check_str(r, s.text, s.font if s.font != "" else t.font, s.weight if s.weight != 0 else t.weight, s.italic.? or_else t.italic, node)
	}
}

// Reports texts drawn over each other this frame (rendering only records
// the boxes). Neighbouring words and lines may touch, so only a cover of a
// third of the smaller box each way counts. Not clashes: the same string
// twice (a glow or shadow), two scenes' texts (one cross-fading into the
// other), single characters (the letters of a word animating in).
@(private = "file")
check_text_overlaps :: proc(r: ^Renderer) {
	s := r.scale if r.scale > 0 else 1
	for a, i in r.texts {
		for b in r.texts[i + 1:] {
			ix := min(a.hi.x, b.hi.x) - max(a.lo.x, b.lo.x)
			iy := min(a.hi.y, b.hi.y) - max(a.lo.y, b.lo.y)
			if ix <= 0 || iy <= 0 || a.text == b.text || a.scene != b.scene || one_char(a.text) || one_char(b.text) {
				continue
			}
			if ix < min(a.hi.x - a.lo.x, b.hi.x - b.lo.x) / 3 || iy < min(a.hi.y - a.lo.y, b.hi.y - b.lo.y) / 3 {
				continue
			}
			report(&r.ctx, .Warning, {code = .Text_Overlap, name = b.text, a = a.text, w = ix / s, h = iy / s, node = b.node})
		}
	}
}

@(private = "file")
one_char :: proc(s: string) -> bool {
	return utf8.rune_count_in_string(strings.trim_space(s)) <= 1
}
