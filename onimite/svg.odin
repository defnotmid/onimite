package onimite

import "core:hash"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import vg "deps:ovg"

// SVG documents as nodes: a parsed document (ovg svg.odin) drawn as
// vectors into a box like an image, with per-id overrides to animate its
// parts. Documents come from .svg media files (parsed once when the media
// loads) or from markup given in the script (parsed once per renderer,
// cached by content).
//
//     om.svg(ctx, {src = "logo.svg", x = 100, y = 100, w = 400,
//         overrides = {{id = "wing", transform = om.rotate(a, {120, 80})}}})

// Replaces properties of the elements with `id` while drawing. `transform`
// applies in the element's own coordinates (inside its SVG transform), so a
// rotation's origin is a point of the part's drawing.
Svg_Override :: struct {
	id:        string,
	transform: Maybe(Transform),
	opacity:   Maybe(f32),
	fill:      Maybe(Color),
	stroke:    Maybe(Color),
	visible:   Maybe(bool),
}

// An SVG document from the media (`src`, a .svg file) or `markup`, placed
// in the box `x, y, w, h` like an image (`fit_box`). The document's
// viewport clips it.
Svg :: struct {
	src:        string,
	markup:     string,
	x, y, w, h: f32,
	fit:        Image_Fit,
	align:      Maybe(Vec2),
	opacity:    Maybe(f32),
	overrides:  []Svg_Override,
	// Resolved by the builder.
	asset:      ^Svg_Asset,
}

// An SVG document, parsed once, and its text laid out once with the
// media's fonts (`vg.svg_layout`): read-only while drawing, so every
// renderer shares it (each draws it with its own `vg.Svg_Renderer`).
Svg_Asset :: struct {
	doc:  vg.Svg_Document,
	text: vg.Svg_Layout,
}

// Parses `data` (`<image>` files resolve against `dir`) and lays its text
// out with `fonts`.
@(private)
svg_asset_make :: proc(data: []u8, dir: string, fonts: ^vg.Font_Collection) -> (^Svg_Asset, vg.Svg_Error) {
	a := new(Svg_Asset)
	loader := Svg_Loader{dir = dir}
	err: vg.Svg_Error
	a.doc, err = vg.svg_parse(data, {load_file = svg_load_file, user = &loader, fonts = fonts})
	if err != nil {
		vg.svg_destroy(&a.doc)
		free(a)
		return nil, err
	}
	vg.svg_layout(&a.doc, fonts, &a.text)
	return a, nil
}

@(private)
svg_asset_destroy :: proc(a: ^Svg_Asset) {
	vg.svg_layout_destroy(&a.text)
	vg.svg_destroy(&a.doc)
	free(a)
}

// Markup documents parsed by one context (by content hash).
@(private)
Svg_Cache :: struct {
	docs:    map[u64]^Svg_Asset,
	// The markup of each document (the SVG export inlines it).
	sources: map[^Svg_Asset]string,
}

@(private)
svg_cache_destroy :: proc(c: ^Svg_Cache) {
	for _, a in c.docs {
		svg_asset_destroy(a)
	}
	delete(c.docs)
	for _, src in c.sources {
		delete(src)
	}
	delete(c.sources)
	c^ = {}
}

// Adds an SVG node. The document is looked up (or parsed) here; a missing
// or broken one is reported and adds nothing.
svg :: proc(ctx: ^Context, s: Svg) {
	s := s
	a := svg_resolve(ctx, s.src, s.markup)
	if a == nil {
		return
	}
	s.asset = a
	s.src = strings.clone(s.src, ctx.tree.arena)
	s.markup = ""
	if len(s.overrides) > 0 {
		ovs := make([]Svg_Override, len(s.overrides), ctx.tree.arena)
		for o, i in s.overrides {
			ovs[i] = o
			ovs[i].id = strings.clone(o.id, ctx.tree.arena)
		}
		s.overrides = ovs
	}
	if a.doc.uses_blend {
		ctx.tree.uses_blend = true
	}
	tree_add(&ctx.tree, s)
}

// The bounding box of element `id` in its own coordinates (inside its SVG
// transform: the space of an override's `transform`), e.g. to rotate a part
// about its center.
svg_local_bbox :: proc(ctx: ^Context, src, markup: string, id: string) -> (vg.Rect, bool) {
	a := svg_resolve(ctx, src, markup)
	if a == nil {
		return {}, false
	}
	n := vg.svg_find(&a.doc, id)
	if n < 0 {
		return {}, false
	}
	return a.doc.nodes[n].bbox, true
}

@(private)
svg_resolve :: proc(ctx: ^Context, src, markup: string) -> ^Svg_Asset {
	if markup != "" {
		key := hash.fnv64a(transmute([]u8)markup)
		if a, ok := ctx.svgs.docs[key]; ok {
			return a
		}
		a, err := svg_asset_make(transmute([]u8)markup, ctx.media.dir, &ctx.media.fonts)
		if err != nil {
			report(ctx, .Error, {code = .Svg_Markup, n = i64(key), svg = err})
			return nil
		}
		ctx.svgs.docs[key] = a
		ctx.svgs.sources[a] = strings.clone(markup)
		return a
	}
	if a, ok := ctx.media.svgs[src]; ok {
		return a
	}
	report(ctx, .Error, {code = .Missing_Svg, name = src})
	return nil
}

// Reads files an SVG's <image> elements name, relative to the media
// directory (or absolute).
@(private)
Svg_Loader :: struct {
	dir: string,
}

@(private)
svg_load_file :: proc(user: rawptr, href: string, allocator: mem.Allocator) -> (data: []u8, ok: bool) {
	l := (^Svg_Loader)(user)
	if strings.contains(href, "://") {
		return
	}
	// Absolute paths as given (the SVG export references media files so).
	path := href
	if !filepath.is_abs(href) {
		if l.dir == "" {
			return
		}
		path, _ = filepath.join({l.dir, href}, context.temp_allocator)
	}
	bytes, err := os.read_entire_file(path, allocator)
	return bytes, err == nil
}

@(private)
put_svg :: proc(m: ^Media, name: string, a: ^Svg_Asset) {
	if old, ok := m.svgs[name]; ok {
		svg_asset_destroy(old)
		m.svgs[name] = a
	} else {
		m.svgs[strings.clone(name)] = a
	}
}

// The renderer's `vg.Svg_Renderer` for asset `a`, bound to its document's
// images on first use (one per document, as ovg wants).
@(private)
svg_renderer_of :: proc(r: ^Renderer, a: ^Svg_Asset) -> ^vg.Svg_Renderer {
	for d, i in r.svg_assets {
		if d == a {
			return &r.svg_renderers[i]
		}
	}
	append(&r.svg_assets, a)
	append(&r.svg_renderers, vg.Svg_Renderer{})
	sr := &r.svg_renderers[len(r.svg_renderers) - 1]
	vg.svg_renderer_bind(sr, &r.canvas, &a.doc)
	return sr
}

@(private)
draw_svg :: proc(r: ^Renderer, n: Svg) {
	a := n.asset
	if a == nil || a.doc.width <= 0 || a.doc.height <= 0 {
		return
	}
	doc := &a.doc
	label := n.src if n.src != "" else "markup"
	for w in doc.warnings {
		report(&r.ctx, .Warning, {code = .Svg_Warning, name = label, a = w})
	}
	box, pic := fit_box(n.x, n.y, n.w, n.h, doc.width, doc.height, n.fit, n.align)
	c := &r.canvas
	vg.save(c)
	defer vg.restore(c)
	// The viewport clips, as an SVG shown as an image.
	shown := box if n.fit == .Cover else pic
	vg.intersect_scissor(c, shown.x, shown.y, shown.w, shown.h)
	clear(&r.svg_overrides)
	for o in n.overrides {
		ov := vg.Svg_Override {
			id      = o.id,
			opacity = o.opacity,
			fill    = o.fill,
			stroke  = o.stroke,
			visible = o.visible,
		}
		if t, ok := o.transform.?; ok {
			ov.transform = transform_matrix(t)
		}
		append(&r.svg_overrides, ov)
		if _, found := doc.id_map[o.id]; !found {
			report(&r.ctx, .Warning, {code = .Svg_Missing_Id, name = label, a = o.id})
		}
	}
	opacity := n.opacity.? or_else 1
	if opacity <= 0 {
		return
	}
	if opacity < 1 {
		vg.layer_push(&r.layers, c, {opacity = opacity})
	}
	xf := vg.Transform2D{pic.w / doc.width, 0, 0, pic.h / doc.height, pic.x, pic.y}
	vg.svg_draw(c, &r.layers, svg_renderer_of(r, a), doc, &a.text, xf, r.svg_overrides[:])
	if opacity < 1 {
		vg.layer_pop(&r.layers, c)
	}
	for family in a.text.missing {
		report(&r.ctx, .Warning, {code = .Missing_Font, name = family})
	}
}
