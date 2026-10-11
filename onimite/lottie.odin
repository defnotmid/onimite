package onimite

import "core:hash"
import "core:math"
import "core:strings"
import vg "deps:ovg"

// Lottie (Bodymovin JSON) animations as nodes: a parsed document (ovg
// lottie.odin) drawn as vectors into a box like an image, at the frame the
// video's clock maps to. Documents come from .json media files that are
// Lottie files (parsed once when the media loads, shared by every frame
// builder) or from JSON given in the script (parsed once per renderer,
// cached by content).
//
//     om.lottie(ctx, f, {src = "confetti.json", x = 100, y = 100, w = 400})

// A Lottie animation from the media (`src`) or `data` (the JSON), scaled
// into the box `x, y, w, h` (0 = the composition's size, or its aspect) like
// an image. Which frame shows: `frame` (the animation's frames from its in
// point), else `time` (seconds into it), else the clock of `f` times
// `speed` plus `offset` seconds: by default the animation plays from the
// frame `f` starts at, at its native rate. `loop` wraps past the end;
// without it the last frame holds. `overrides` change layers by name.
Lottie_Params :: struct {
	src:        string,
	data:       string,
	x, y, w, h: f32,
	fit:        Image_Fit,
	align:      Maybe(Vec2),
	opacity:    Maybe(f32),
	frame:      Maybe(f32),
	time:       Maybe(f32),
	speed:      Maybe(f32),
	offset:     f32,
	loop:       Maybe(bool),
	overrides:  []Lottie_Override,
}

// Replaces properties of the layers named `name` (Lottie's `nm`) while
// drawing. `transform` applies in the layer's own coordinates (inside its
// transform; layers parented to it follow), `fill` / `stroke` replace the
// colour of its fills / strokes (and of a precomp's layers, and a text
// layer's fill / stroke), `text` replaces a text layer's string.
Lottie_Override :: struct {
	name:      string,
	transform: Maybe(Transform),
	opacity:   Maybe(f32),
	fill:      Maybe(Color),
	stroke:    Maybe(Color),
	visible:   Maybe(bool),
	text:      Maybe(string),
}

// The node: the document and the frame it shows.
Lottie :: struct {
	src:        string,
	x, y, w, h: f32,
	fit:        Image_Fit,
	align:      Maybe(Vec2),
	opacity:    Maybe(f32),
	// The document's frame (its own numbering, from `in_frame`).
	frame:      f32,
	doc:        ^vg.Lottie_Document,
	overrides:  []Lottie_Override,
}

// Lottie JSON parsed by one context (by content hash).
@(private)
Lottie_Cache :: struct {
	docs: map[u64]^vg.Lottie_Document,
}

@(private)
lottie_cache_destroy :: proc(c: ^Lottie_Cache) {
	for _, doc in c.docs {
		vg.lottie_destroy(doc)
		free(doc)
	}
	delete(c.docs)
	c^ = {}
}

// Adds a Lottie node showing the frame `f`'s clock maps to. A missing or
// broken document is reported and adds nothing.
lottie :: proc(ctx: ^Context, f: Frame, p: Lottie_Params) {
	doc := lottie_resolve(ctx, p.src, p.data)
	if doc == nil {
		return
	}
	overrides: []Lottie_Override
	if len(p.overrides) > 0 {
		overrides = make([]Lottie_Override, len(p.overrides), ctx.tree.arena)
		for o, i in p.overrides {
			overrides[i] = o
			overrides[i].name = strings.clone(o.name, ctx.tree.arena)
			if txt, ok := o.text.?; ok {
				overrides[i].text = strings.clone(txt, ctx.tree.arena)
			}
		}
	}
	tree_add(&ctx.tree, Lottie {
		src       = strings.clone(p.src if p.src != "" else "data", ctx.tree.arena),
		x         = p.x,
		y         = p.y,
		w         = p.w,
		h         = p.h,
		fit       = p.fit,
		align     = p.align,
		opacity   = p.opacity,
		frame     = lottie_frame(doc, f, p),
		doc       = doc,
		overrides = overrides,
	})
	if doc.uses_blend {
		ctx.tree.uses_blend = true
	}
}

// The document frame `p` asks for at `f`.
lottie_frame :: proc(doc: ^vg.Lottie_Document, f: Frame, p: Lottie_Params) -> f32 {
	local: f32
	switch {
	case p.frame != nil:
		local = p.frame.?
	case p.time != nil:
		local = p.time.? * doc.fps
	case:
		speed := p.speed.? or_else 1
		local = (frame_seconds(f) * speed + p.offset) * doc.fps
	}
	span := doc.out_frame - doc.in_frame
	if span <= 0 {
		return doc.in_frame
	}
	if p.loop.? or_else true {
		local -= math.floor(local / span) * span
	} else {
		// Holds the first and last frames (op is exclusive).
		local = clamp(local, 0, span - 0.001)
	}
	return doc.in_frame + local
}

// The size, frame rate and length of a Lottie document (`ok = false` when
// it is missing or does not parse).
lottie_info :: proc(ctx: ^Context, src, data: string) -> (doc: ^vg.Lottie_Document, ok: bool) {
	doc = lottie_resolve(ctx, src, data)
	return doc, doc != nil
}

@(private)
lottie_resolve :: proc(ctx: ^Context, src, data: string) -> ^vg.Lottie_Document {
	if data != "" {
		key := hash.fnv64a(transmute([]u8)data)
		if doc, ok := ctx.lotties.docs[key]; ok {
			return doc
		}
		doc := new(vg.Lottie_Document)
		loader := Svg_Loader{dir = ctx.media.dir}
		err: vg.Lottie_Error
		doc^, err = vg.lottie_parse(transmute([]u8)data, {load_file = svg_load_file, user = &loader})
		if err != nil {
			report(ctx, .Error, {code = .Lottie_Data, n = i64(key), lottie = err})
			vg.lottie_destroy(doc)
			free(doc)
			return nil
		}
		ctx.lotties.docs[key] = doc
		return doc
	}
	if doc, ok := ctx.media.lotties[src]; ok {
		return doc
	}
	report(ctx, .Error, {code = .Missing_Lottie, name = src})
	return nil
}

@(private)
lottie_parse_media :: proc(data: []u8, dir: string) -> (^vg.Lottie_Document, bool) {
	loader := Svg_Loader{dir = dir}
	doc := new(vg.Lottie_Document)
	err: vg.Lottie_Error
	doc^, err = vg.lottie_parse(data, {load_file = svg_load_file, user = &loader})
	if err != nil {
		vg.lottie_destroy(doc)
		free(doc)
		return nil, false
	}
	return doc, true
}

@(private)
put_lottie :: proc(m: ^Media, name: string, doc: ^vg.Lottie_Document) {
	if old, ok := m.lotties[name]; ok {
		vg.lottie_destroy(old)
		free(old)
		m.lotties[name] = doc
	} else {
		m.lotties[strings.clone(name)] = doc
	}
}

@(private)
draw_lottie :: proc(r: ^Renderer, n: Lottie) {
	doc := n.doc
	if doc == nil || doc.width <= 0 || doc.height <= 0 {
		return
	}
	for w in doc.warnings {
		report(&r.ctx, .Warning, {code = .Lottie_Warning, name = n.src, a = w})
	}
	clear(&r.lottie_overrides)
	for o in n.overrides {
		ov := vg.Lottie_Override {
			name    = o.name,
			opacity = o.opacity,
			fill    = o.fill,
			stroke  = o.stroke,
			visible = o.visible,
			text    = o.text,
		}
		if t, ok := o.transform.?; ok {
			ov.transform = transform_matrix(t)
		}
		append(&r.lottie_overrides, ov)
		if !vg.lottie_has_layer(doc, o.name) {
			report(&r.ctx, .Warning, {code = .Lottie_Missing_Layer, name = n.src, a = o.name})
		}
	}
	iw, ih := doc.width, doc.height
	w, h := n.w, n.h
	switch {
	case w <= 0 && h <= 0:
		w, h = iw, ih
	case w <= 0:
		w = h * iw / ih
	case h <= 0:
		h = w * ih / iw
	}
	ix, iy, dw, dh := n.x, n.y, w, h
	if n.fit != .Fill {
		k := min(w / iw, h / ih) if n.fit == .Contain else max(w / iw, h / ih)
		dw, dh = iw * k, ih * k
		al := n.align.? or_else {0.5, 0.5}
		ix = n.x + (w - dw) * al.x
		iy = n.y + (h - dh) * al.y
	}
	opacity := n.opacity.? or_else 1
	if opacity <= 0 {
		return
	}
	c := &r.canvas
	vg.save(c)
	defer vg.restore(c)
	// The composition's bounds clip (and the box, when covering).
	if n.fit == .Cover {
		vg.intersect_scissor(c, n.x, n.y, w, h)
	}
	vg.intersect_scissor(c, ix, iy, dw, dh)
	if opacity < 1 {
		vg.layer_push(&r.layers, c, {opacity = opacity})
	}
	lr := lottie_renderer_of(r, doc)
	lr.fonts = &r.media.fonts
	vg.lottie_draw(c, &r.layers, lr, doc, n.frame, {dw / iw, 0, 0, dh / ih, ix, iy}, r.lottie_overrides[:])
	if opacity < 1 {
		vg.layer_pop(&r.layers, c)
	}
	for family in lr.missing {
		report(&r.ctx, .Warning, {code = .Missing_Font, name = family})
	}
}

// The renderer's `vg.Lottie_Renderer` for `doc`, bound to its images on
// first use (one per document, as ovg wants).
@(private = "file")
lottie_renderer_of :: proc(r: ^Renderer, doc: ^vg.Lottie_Document) -> ^vg.Lottie_Renderer {
	for d, i in r.lottie_docs {
		if d == doc {
			return &r.lottie_renderers[i]
		}
	}
	append(&r.lottie_docs, doc)
	append(&r.lottie_renderers, vg.Lottie_Renderer{})
	lr := &r.lottie_renderers[len(r.lottie_renderers) - 1]
	vg.lottie_renderer_bind(lr, &r.canvas, doc)
	return lr
}
