package onimite_script

import "core:c"
import "core:fmt"
import "core:hash"
import "core:mem/virtual"
import "core:slice"
import "core:sync"
import vg "deps:ovg"
import lua "vendor:lua/5.4"
import om "../onimite"

// Outlines: text, an SVG or path data as a path handle (the `path_data`
// kind), placed exactly where text{} / svg{} with the same fields draws, so
// one handle can be drawn (path{ d = h }), clip (clip_path = h), morph
// (morph(a, b)), collide (physics bodies' `outline`) and extrude (3D
// `ExtrudeGeometry`'s `shape`). Handles are made once by content in the
// Shared arena and never change.
//
//     local A = outline { "A", font = "Bebas Neue", size = 400, align = "center", baseline = "middle" }
//     local PIP = outline { svg = "pip.svg", x = -200, y = -200, w = 400 }
//     local M = shared("m", function() return morph(A, PIP) end)
//     path { d = morph_at(M, f.seconds / 2), fill = "#111" }

// A prepared morph: the points of both ends, read-only once made.
@(private)
Shared_Morph :: struct {
	m: vg.Path_Morph,
}

// The asset for the path in `p` (by its geometry and rule), copied into the
// Shared arena on first sight.
@(private)
shared_path_asset :: proc(sh: ^Shared, p: ^vg.Path, rule: vg.Fill_Rule) -> ^om.Path_Asset {
	key := path_key(p, rule)
	sync.guard(&sh.lock)
	if a, found := sh.paths[key]; found {
		return a
	}
	a := shared_asset_make(sh, p, rule)
	sh.paths[key] = a
	return a
}

// A path's content hash, by its geometry and fill rule.
@(private)
path_key :: proc(p: ^vg.Path, rule: vg.Fill_Rule) -> u64 {
	return hash.fnv64a(slice.to_bytes(p.verbs[:])) ~ hash.fnv64a(slice.to_bytes(p.coords[:])) * 31 ~ u64(rule)
}

@(private)
path_asset_copy :: proc(p: ^vg.Path, rule: vg.Fill_Rule, alloc := context.allocator) -> ^om.Path_Asset {
	a := new(om.Path_Asset, alloc)
	a.verbs = make([]vg.Verb, len(p.verbs), alloc)
	a.coords = make([]vg.Vec2, len(p.coords), alloc)
	copy(a.verbs, p.verbs[:])
	copy(a.coords, p.coords[:])
	a.fill_rule = rule
	a.key = path_key(p, rule)
	return a
}

// The path handle at stack index `idx`, or a Lua error naming `what`.
@(private)
check_outline :: proc(L: ^lua.State, idx: c.int, what: cstring) -> ^om.Path_Asset {
	if lua.type(L, idx) != .LIGHTUSERDATA {
		lua.L_error(L, "%s: expected an outline (from outline{} or path_data())", what)
	}
	return (^om.Path_Asset)(lua.touserdata(L, idx))
}

// outline{ "TEXT", font, size, weight, italic, letter_spacing, features, align,
// baseline, line_height, x, y } | outline{ svg = "file.svg", id, x, y, w, h,
// fit, align } | outline{ d = "M0 0 ..." } -> path handle
@(private)
l_outline :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	fields_begin(L, 1)
	p: vg.Path
	vg.path_init(&p, context.temp_allocator)
	rule := vg.Fill_Rule.Non_Zero
	switch {
	case has_field(L, 1, "svg"):
		m := measure_media(L, s, "outline")
		name := get_str(L, 1, "svg", "")
		a, owned := om.media_svg(m, name)
		if a == nil {
			lua.L_error(L, "%s", fmt.ctprintf("outline: no SVG %q in the media", name))
		}
		// (Released before any error below: a Lua error skips defers.)
		doc := &a.doc
		if doc.width <= 0 || doc.height <= 0 {
			om.media_svg_release(a, owned)
			lua.L_error(L, "%s", fmt.ctprintf("outline: %q has no size", name))
		}
		id := get_str(L, 1, "id", "")
		raw: vg.Path
		vg.path_init(&raw, context.temp_allocator)
		found: bool
		rule, _, found = vg.svg_element_path(doc, &raw, id, &a.text)
		if !found {
			om.media_svg_release(a, owned)
			lua.L_error(L, "%s", fmt.ctprintf("outline: %q has no element with id %q", name, id))
		}
		// Where svg{} puts the document: its picture box, scaled from the
		// document's width x height.
		_, pic := om.fit_box(get_num(L, 1, "x", 0), get_num(L, 1, "y", 0), get_num(L, 1, "w", get_num(L, 1, "width", 0)),
			get_num(L, 1, "h", get_num(L, 1, "height", 0)), doc.width, doc.height, read_fit(L, 1), read_align(L, 1))
		k := [2]f32{pic.w / doc.width, pic.h / doc.height}
		append(&p.verbs, ..raw.verbs[:])
		for v in raw.coords {
			append(&p.coords, vg.Vec2{pic.x, pic.y} + v * k)
		}
		om.media_svg_release(a, owned)
	case has_field(L, 1, "d"):
		d := get_str(L, 1, "d", "")
		if !vg.path_svg(&p, d) {
			lua.L_error(L, "outline: invalid path data")
		}
		if get_str(L, 1, "fill_rule", "") == "evenodd" {
			rule = .Even_Odd
		}
	case:
		m := measure_media(L, s, "outline")
		q := font_query(L, 1)
		str := text_arg(L, 1)
		align := om.Text_Align.Left
		switch get_str(L, 1, "align", "left") {
		case "center", "middle":
			align = .Center
		case "right", "end":
			align = .Right
		}
		l: vg.Text_Layout
		vg.text_layout_init(&l, context.temp_allocator)
		piece := vg.Text_Piece{text = str, style = {family = q.family, size = q.size, weight = q.weight, italic = q.italic, letter_spacing = q.letter_spacing, features = q.features, variations = q.variations}}
		opts := vg.Text_Options{get_num(L, 1, "x", 0), get_num(L, 1, "y", 0), vg.Text_Align(align), vg.Text_Baseline(read_baseline(L, 1)), get_num(L, 1, "line_height", 0)}
		vg.text_layout(om.media_text_fonts(m, q.family, q.weight, q.italic, q.variations), {piece}, opts, &l)
		measured(s, q, len(l.missing) == 0)
		vg.text_layout_path(&l, &p)
	}
	fields_end(L, s, 1, "outline")
	lua.pushlightuserdata(L, shared_path_asset(s.shared, &p, rule))
	return 1
}

// outline_bounds(h) -> x, y, w, h: the box around the outline's curves.
@(private)
l_outline_bounds :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	a := check_outline(L, 1, "outline_bounds")
	flat: vg.Flat_Path
	vg.flat_path_init(&flat, context.temp_allocator)
	om.outline_flatten(a, &flat)
	lo, hi := [2]f32{max(f32), max(f32)}, [2]f32{-max(f32), -max(f32)}
	for v in flat.points {
		lo, hi = {min(lo.x, v.x), min(lo.y, v.y)}, {max(hi.x, v.x), max(hi.y, v.y)}
	}
	if len(flat.points) == 0 {
		lo, hi = {}, {}
	}
	for v in ([4]f32{lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}) {
		lua.pushnumber(L, lua.Number(v))
	}
	return 4
}

// morph(a, b) -> morph handle: the two outlines matched contour to contour
// (made once per pair, by content); morph_at(m, t) draws it at t.
@(private)
l_morph :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	a := check_outline(L, 1, "morph")
	b := check_outline(L, 2, "morph")
	sh := s.shared
	key := u64(uintptr(a)) * 1099511628211 ~ u64(uintptr(b))
	sync.guard(&sh.lock)
	if m, found := sh.morphs[key]; found {
		lua.pushlightuserdata(L, m)
		return 1
	}
	pa, pb: vg.Path
	vg.path_init(&pa, context.temp_allocator)
	vg.path_init(&pb, context.temp_allocator)
	append(&pa.verbs, ..a.verbs)
	append(&pa.coords, ..a.coords)
	append(&pb.verbs, ..b.verbs)
	append(&pb.coords, ..b.coords)
	scratch: vg.Path_Morph
	defer vg.path_morph_destroy(&scratch)
	vg.path_morph_prepare(&scratch, &pa, &pb, a.fill_rule, b.fill_rule)
	// Kept: the ends and the contours (the scratch is dropped).
	alloc := virtual.arena_allocator(&sh.arena)
	m := new(Shared_Morph, alloc)
	m.m.from = make([dynamic]vg.Vec2, len(scratch.from), alloc)
	m.m.to = make([dynamic]vg.Vec2, len(scratch.to), alloc)
	m.m.contours = make([dynamic]vg.Morph_Contour, len(scratch.contours), alloc)
	copy(m.m.from[:], scratch.from[:])
	copy(m.m.to[:], scratch.to[:])
	copy(m.m.contours[:], scratch.contours[:])
	sh.morphs[key] = m
	sh.morph_set[m] = true
	lua.pushlightuserdata(L, m)
	return 1
}

// morph_at(m, t) -> path handle: the morph at t (0: a, 1: b; beyond
// overshoots), for this frame (at load: kept for the render).
@(private)
l_morph_at :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	if lua.type(L, 1) != .LIGHTUSERDATA {
		lua.L_error(L, "morph_at: expected a morph (from morph(a, b))")
	}
	m := (^Shared_Morph)(lua.touserdata(L, 1))
	{
		sync.guard(&s.shared.lock)
		if _, known := s.shared.morph_set[m]; !known {
			lua.L_error(L, "morph_at: expected a morph (from morph(a, b)), got another handle")
		}
	}
	t := f32(lua.L_checknumber(L, 2))
	p: vg.Path
	vg.path_init(&p, context.temp_allocator)
	vg.path_morph_eval(&m.m, t, &p)
	// Drawn this frame: the frame's nodes hold it; at load, the render.
	if s.ctx != nil {
		lua.pushlightuserdata(L, path_asset_copy(&p, .Non_Zero, s.ctx.tree.arena))
		return 1
	}
	lua.pushlightuserdata(L, shared_path_asset(s.shared, &p, .Non_Zero))
	return 1
}

// outline_union(a, b, ...) | outline_subtract(a, b, ...) |
// outline_intersect(a, b, ...) | outline_exclude(a, b, ...) -> path handle:
// one outline of the outlines (or one list of them) by ovg's path booleans,
// their own curves kept: everything any covers, the first minus the rest,
// what all cover, what an odd number cover. A union of one resolves its own
// overlaps. For this frame when rendering (at load: kept for the render).
@(private)
l_outline_union :: proc "c" (L: ^lua.State) -> c.int {
	return outline_boolean(L, .Union, "outline_union")
}

@(private)
l_outline_subtract :: proc "c" (L: ^lua.State) -> c.int {
	return outline_boolean(L, .Difference, "outline_subtract")
}

@(private)
l_outline_intersect :: proc "c" (L: ^lua.State) -> c.int {
	return outline_boolean(L, .Intersection, "outline_intersect")
}

@(private)
l_outline_exclude :: proc "c" (L: ^lua.State) -> c.int {
	return outline_boolean(L, .Xor, "outline_exclude")
}

@(private = "file")
outline_boolean :: proc "c" (L: ^lua.State, op: vg.Bool_Op, what: cstring) -> c.int {
	s := host(L)
	context = s.odin_context
	operands := bool_operands(L, what)
	out: vg.Path
	vg.path_init(&out, context.temp_allocator)
	bool_check(L, vg.path_boolean_many(&out, operands, op, &s.bools), what)
	lua.pushlightuserdata(L, outline_result(s, &out))
	return 1
}

// outline_divide(a, b, ...) -> { { outline = h, inside = { 1, 3 } }, ... }:
// every region the outlines make (Illustrator's divide), each with the
// numbers of the outlines it lies inside.
@(private)
l_outline_divide :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	operands := bool_operands(L, "outline_divide")
	out: vg.Path
	vg.path_init(&out, context.temp_allocator)
	faces := make([dynamic]vg.Range, context.temp_allocator)
	bool_check(L, vg.path_divide(&out, &faces, operands, &s.bools), "outline_divide")
	lua.createtable(L, c.int(len(faces)), 0)
	piece: vg.Path
	vg.path_init(&piece, context.temp_allocator)
	// the faces fill `out` back to back: their coordinates follow in order
	first := 0
	for f, i in faces {
		verbs := out.verbs[f.start:][:f.count]
		count := 0
		for v in verbs {
			count += vg.verb_num_coords(v)
		}
		clear(&piece.verbs)
		clear(&piece.coords)
		append(&piece.verbs, ..verbs)
		append(&piece.coords, ..out.coords[first:][:count])
		first += count
		lua.createtable(L, 0, 2)
		lua.pushlightuserdata(L, outline_result(s, &piece))
		lua.setfield(L, -2, "outline")
		lua.createtable(L, 2, 0)
		n := 0
		for o in 0 ..< len(operands) {
			if s.bools.core.faces_in[i * len(operands) + o] {
				n += 1
				lua.pushinteger(L, lua.Integer(o + 1))
				lua.rawseti(L, -2, lua.Integer(n))
			}
		}
		lua.setfield(L, -2, "inside")
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	return 1
}

// The outlines in the arguments (or in a list as the only one), as
// operands under their own fill rules (temp memory).
@(private = "file")
bool_operands :: proc(L: ^lua.State, what: cstring) -> []vg.Bool_Operand {
	assets := make([dynamic]^om.Path_Asset, context.temp_allocator)
	if lua.gettop(L) == 1 && lua.istable(L, 1) {
		n := int(lua.rawlen(L, 1))
		for i in 1 ..= n {
			lua.rawgeti(L, 1, lua.Integer(i))
			append(&assets, check_outline(L, -1, what))
			lua.pop(L, 1)
		}
	} else {
		for i in 1 ..= lua.gettop(L) {
			append(&assets, check_outline(L, i, what))
		}
	}
	if len(assets) == 0 {
		lua.L_error(L, "%s: expected outlines (from outline{} or path_data())", what)
	}
	operands := make([]vg.Bool_Operand, len(assets), context.temp_allocator)
	for a, i in assets {
		p := new(vg.Path, context.temp_allocator)
		vg.path_init(p, context.temp_allocator)
		append(&p.verbs, ..a.verbs)
		append(&p.coords, ..a.coords)
		operands[i] = {p, a.fill_rule}
	}
	return operands
}

// A boolean's error as the script's.
@(private = "file")
bool_check :: proc(L: ^lua.State, err: vg.Bool_Error, what: cstring) {
	switch err {
	case .None:
	case .Non_Finite:
		lua.L_error(L, "%s: an outline has a coordinate that is not a finite number", what)
	case .Limit:
		lua.L_error(L, "%s: reached the boolean work limit (fewer or simpler outlines)", what)
	case .Inconsistent:
		lua.L_error(L, "%s: the outlines' crossings did not resolve (nudge one by a little)", what)
	}
}

// A path made from outlines as a handle: the frame's when rendering, else
// kept for the render (Solid-wound: either fill rule fills it alike).
@(private = "file")
outline_result :: proc(s: ^Script, p: ^vg.Path) -> ^om.Path_Asset {
	if s.ctx != nil {
		return path_asset_copy(p, .Non_Zero, s.ctx.tree.arena)
	}
	return shared_path_asset(s.shared, p, .Non_Zero)
}
