package onimite

import "core:encoding/base64"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import vg "deps:ovg"
import odimg "deps:odecs/image"

// SVG export (`onimite frame --svg`, fframes' `frame --svg`): the frame's
// node tree written as an SVG document in one walk into a string builder.
//
// Groups become <g> with transform="matrix(..)", clip-path, mask (alpha or
// luminance), filter (with its region) and mix-blend-mode; shapes, paths
// and polygons their elements with fill / stroke properties and dashes;
// text <text> / <tspan> with font properties, anchors and baselines.
// Gradients, patterns, clip paths, masks and filters are written in a
// <defs> just before the element that uses them, with ids from the node
// index (`n12f` is node 12's fill). Images reference their media file (or
// embed a PNG data: URI); SVG nodes inline their source document in nested
// <svg> viewports, with ids prefixed and per-id overrides applied to the
// elements; video clip frames and shader layers are drawn with the
// renderer to PNGs embedded as data: URIs.
//
// The document's user space is the video's size; `width` / `height` are
// the renderer's output size, so it renders like the PNG.

@(private = "file")
Svg_Export :: struct {
	r: ^Renderer,
	b: ^strings.Builder,
	// The video's size (the document's user space).
	vw, vh: f32,
}

// Writes the frame built last (`render_frame`, still in `r.ctx.tree`) as an
// SVG document into `b`. Video clips and shaders are drawn with `r`, which
// invalidates the pixels `render_frame` returned.
svg_export :: proc(r: ^Renderer, b: ^strings.Builder) {
	e := Svg_Export{r = r, b = b, vw = f32(r.video.width), vh = f32(r.video.height)}
	strings.write_string(b, `<?xml version="1.0" encoding="UTF-8"?>`)
	strings.write_string(b, "\n<!-- onimite frame ")
	strings.write_int(b, r.ctx.frame.index)
	strings.write_string(b, " -->\n<svg xmlns=\"http://www.w3.org/2000/svg\"")
	num_attr(b, "width", f32(r.width))
	num_attr(b, "height", f32(r.height))
	strings.write_string(b, ` viewBox="0 0 `)
	num(b, e.vw)
	strings.write_byte(b, ' ')
	num(b, e.vh)
	strings.write_string(b, "\">\n<rect")
	num_attr(b, "width", e.vw)
	num_attr(b, "height", e.vh)
	color_attr(b, "fill", r.video.background, 1)
	strings.write_string(b, "/>\n")
	export_children(&e, 0, vg.TRANSFORM_IDENTITY)
	strings.write_string(b, "</svg>\n")
}

// `m` maps the parent's coordinates to the document's (filter and mask
// regions, raster sizes).
@(private = "file")
export_children :: proc(e: ^Svg_Export, parent: i32, m: vg.Transform2D) {
	nodes := e.r.ctx.tree.nodes[:]
	for i := nodes[parent].first_child; i != NO_NODE; i = nodes[i].next {
		export_node(e, i, m)
	}
}

@(private = "file")
export_node :: proc(e: ^Svg_Export, i: i32, m: vg.Transform2D) {
	b := e.b
	switch n in e.r.ctx.tree.nodes[i].kind {
	case Group:
		export_group(e, i, n, m)
	case Rect:
		if n.w <= 0 || n.h <= 0 {
			return
		}
		shape_defs(e, i, n.style, m)
		if dashed(n.stroke) {
			vg.path_rounded_rect_elliptic(shape_path(e), n.x, n.y, n.w, n.h, n.rx, n.ry)
			path_data(e)
		} else {
			strings.write_string(b, "<rect")
			rect_attrs(b, {n.x, n.y, n.w, n.h})
			if n.rx > 0 || n.ry > 0 {
				num_attr(b, "rx", n.rx)
				num_attr(b, "ry", n.ry if n.ry > 0 else n.rx)
			}
		}
		shape_attrs(e, i, n.style)
	case Circle:
		if n.r <= 0 {
			return
		}
		shape_defs(e, i, n.style, m)
		if dashed(n.stroke) {
			vg.path_circle(shape_path(e), n.cx, n.cy, n.r)
			path_data(e)
		} else {
			strings.write_string(b, "<circle")
			num_attr(b, "cx", n.cx)
			num_attr(b, "cy", n.cy)
			num_attr(b, "r", n.r)
		}
		shape_attrs(e, i, n.style)
	case Ellipse:
		if n.rx <= 0 || n.ry <= 0 {
			return
		}
		shape_defs(e, i, n.style, m)
		if dashed(n.stroke) {
			vg.path_ellipse(shape_path(e), n.cx, n.cy, n.rx, n.ry)
			path_data(e)
		} else {
			strings.write_string(b, "<ellipse")
			num_attr(b, "cx", n.cx)
			num_attr(b, "cy", n.cy)
			num_attr(b, "rx", n.rx)
			num_attr(b, "ry", n.ry)
		}
		shape_attrs(e, i, n.style)
	case Line:
		shape_defs(e, i, n.style, m)
		strings.write_string(b, "<line")
		num_attr(b, "x1", n.x1)
		num_attr(b, "y1", n.y1)
		num_attr(b, "x2", n.x2)
		num_attr(b, "y2", n.y2)
		shape_attrs(e, i, n.style)
	case Path:
		shape_defs(e, i, n.style, m)
		if len(n.points) > 0 {
			strings.write_string(b, "<polygon points=\"" if n.closed else "<polyline points=\"")
			for p, k in n.points {
				if k > 0 {
					strings.write_byte(b, ' ')
				}
				num(b, p.x)
				strings.write_byte(b, ',')
				num(b, p.y)
			}
			strings.write_byte(b, '"')
		} else if n.asset != nil {
			p := &e.r.bbox_path
			vg.path_reset(p)
			vg.path_append(p, n.asset.verbs, n.asset.coords)
			path_data(e)
		} else {
			strings.write_string(b, "<path")
			str_attr(b, "d", n.d)
		}
		shape_attrs(e, i, n.style, n.fill_rule)
	case Text:
		export_text(e, i, n, m)
	case Image:
		export_image(e, n)
	case Video_Clip:
		note_begin(b, n, e.r.ctx.videos.names[n.clip])
		strings.write_string(b, " at ")
		num(b, f32(n.seconds))
		strings.write_string(b, "s, drawn to a PNG -->\n")
		export_raster(e, i, node_bbox(e.r, i), m)
	case Shader:
		note_begin(b, n, e.r.ctx.shaders.labels[n.program])
		strings.write_string(b, ", drawn to a PNG -->\n")
		export_raster(e, i, node_bbox(e.r, i), m)
	case View3d:
		note_begin(b, n, view3d_contents(n))
		strings.write_string(b, ", drawn to a PNG -->\n")
		export_raster(e, i, node_bbox(e.r, i), m)
	case Svg:
		export_svg_node(e, i, n, m)
	case Lottie:
		note_begin(b, n, n.src)
		strings.write_string(b, " at frame ")
		num(b, n.frame)
		strings.write_string(b, ", drawn to a PNG -->\n")
		export_raster(e, i, node_bbox(e.r, i), m)
	}
}

// `<!-- kind name`: the start of a note on a node.
@(private = "file")
note_begin :: proc(b: ^strings.Builder, kind: Node_Kind, name: string) {
	strings.write_string(b, "<!-- ")
	strings.write_string(b, node_kind_name(kind))
	strings.write_byte(b, ' ')
	comment_text(b, name)
}

@(private = "file")
export_group :: proc(e: ^Svg_Export, i: i32, g: Group, m: vg.Transform2D) {
	if g.is_mask || g.is_pattern {
		// Written by their owner (a <mask>, a <pattern>).
		return
	}
	opacity := g.opacity.? or_else 1
	if opacity <= 0 {
		return
	}
	b := e.b
	mg := m
	if t, ok := g.transform.?; ok {
		mg = vg.transform_multiply(transform_matrix(t), m)
	}
	fl, has_filter := g.filter.?
	clip, has_clip := g.clip.?
	mask := i32(NO_NODE)
	if g.masked {
		first := e.r.ctx.tree.nodes[i].first_child
		if first != NO_NODE {
			if mk, ok := e.r.ctx.tree.nodes[first].kind.(Group); ok && mk.is_mask {
				mask = first
			}
		}
	}
	if has_clip || g.clip_path != "" || mask != NO_NODE || has_filter || g.blur > 0 {
		strings.write_string(b, "<defs>")
		if has_clip {
			strings.write_string(b, "<clipPath")
			id_attr(b, i, 'r')
			strings.write_string(b, "><rect")
			rect_attrs(b, clip)
			strings.write_string(b, "/></clipPath>")
		}
		if g.clip_path != "" {
			strings.write_string(b, "<clipPath")
			id_attr(b, i, 'c')
			strings.write_string(b, "><path")
			str_attr(b, "d", g.clip_path)
			if g.clip_rule == .Even_Odd {
				strings.write_string(b, ` clip-rule="evenodd"`)
			}
			strings.write_string(b, "/></clipPath>")
		}
		if mask != NO_NODE {
			// Masks cover everything (SVG's default region is the bounding
			// box grown by 10%).
			strings.write_string(b, "\n<mask")
			id_attr(b, i, 'm')
			strings.write_string(b, ` maskUnits="userSpaceOnUse"`)
			region_attrs(e, mg)
			if g.mask_alpha {
				strings.write_string(b, ` mask-type="alpha"`)
			}
			strings.write_string(b, ">\n")
			export_children(e, mask, mg)
			strings.write_string(b, "</mask>")
		}
		if has_filter || g.blur > 0 {
			strings.write_string(b, "\n<filter")
			id_attr(b, i, 'x')
			region := fl.region if has_filter else {}
			switch region.units {
			case .None:
				strings.write_string(b, ` filterUnits="userSpaceOnUse"`)
				region_attrs(e, mg)
			case .User_Space_On_Use:
				strings.write_string(b, ` filterUnits="userSpaceOnUse"`)
				fallthrough
			case .Object_Bounding_Box:
				num_attr(b, "x", region.x)
				num_attr(b, "y", region.y)
				num_attr(b, "width", region.w)
				num_attr(b, "height", region.h)
			}
			// The group blur runs in sRGB, filters in linearRGB unless set.
			if !has_filter || fl.srgb {
				strings.write_string(b, ` color-interpolation-filters="sRGB"`)
			}
			strings.write_string(b, ">\n")
			if has_filter {
				for p, k in fl.primitives {
					export_primitive(e, fl, g.filter_images, p, k)
				}
			}
			if g.blur > 0 {
				// After the filter, as the layer applies it.
				strings.write_string(b, "<feGaussianBlur")
				num_attr(b, "stdDeviation", g.blur)
				strings.write_string(b, "/>\n")
			}
			strings.write_string(b, "</filter>")
		}
		strings.write_string(b, "</defs>\n")
	}

	// Both clips: the rectangle (and the blend, which a clipped child group
	// would isolate) on an outer group.
	both_clips := has_clip && g.clip_path != ""
	strings.write_string(b, "<g")
	if t, ok := g.transform.?; ok {
		matrix_attr(b, "transform", transform_matrix(t))
	}
	if has_clip {
		ref_attr(b, "clip-path", i, 'r')
	}
	if g.blend != .Normal {
		strings.write_string(b, ` style="mix-blend-mode:`)
		strings.write_string(b, BLEND_NAMES[g.blend])
		strings.write_string(b, `"`)
	}
	if both_clips {
		strings.write_string(b, ">\n<g")
	}
	if g.clip_path != "" {
		ref_attr(b, "clip-path", i, 'c')
	}
	if mask != NO_NODE {
		ref_attr(b, "mask", i, 'm')
	}
	if has_filter || g.blur > 0 {
		ref_attr(b, "filter", i, 'x')
	}
	if opacity < 1 {
		num_attr(b, "opacity", opacity)
	}
	if g.crisp {
		strings.write_string(b, ` shape-rendering="crispEdges"`)
	}
	strings.write_string(b, ">\n")
	export_children(e, i, mg)
	strings.write_string(b, "</g>\n</g>\n" if both_clips else "</g>\n")
}

@(private = "file")
export_primitive :: proc(e: ^Svg_Export, fl: vg.Filter, images: []string, p: vg.Filter_Primitive, k: int) {
	b := e.b
	// Elements with children close with this tag.
	close := ""
	switch p.op {
	case .Gaussian_Blur:
		strings.write_string(b, "<feGaussianBlur")
		filter_ref_attr(b, "in", p.in1, k)
		std_attr(b, p.std)
	case .Offset:
		strings.write_string(b, "<feOffset")
		filter_ref_attr(b, "in", p.in1, k)
		num_attr(b, "dx", p.dx)
		num_attr(b, "dy", p.dy)
	case .Flood:
		strings.write_string(b, "<feFlood")
		flood_attrs(b, p.color)
	case .Composite:
		strings.write_string(b, "<feComposite")
		filter_ref_attr(b, "in", p.in1, k)
		filter_ref_attr(b, "in2", p.in2, k)
		strings.write_string(b, ` operator="`)
		strings.write_string(b, COMPOSITE_NAMES[p.composite])
		strings.write_byte(b, '"')
		if p.composite == .Arithmetic {
			num_attr(b, "k1", p.k[0])
			num_attr(b, "k2", p.k[1])
			num_attr(b, "k3", p.k[2])
			num_attr(b, "k4", p.k[3])
		}
	case .Merge:
		strings.write_string(b, "<feMerge")
	case .Blend:
		strings.write_string(b, "<feBlend")
		filter_ref_attr(b, "in", p.in1, k)
		filter_ref_attr(b, "in2", p.in2, k)
		strings.write_string(b, ` mode="`)
		strings.write_string(b, BLEND_NAMES[p.blend])
		strings.write_byte(b, '"')
	case .Color_Matrix:
		strings.write_string(b, "<feColorMatrix")
		filter_ref_attr(b, "in", p.in1, k)
		strings.write_string(b, ` type="matrix" values="`)
		for v, j in p.color_matrix {
			if j > 0 {
				strings.write_byte(b, ' ')
			}
			num(b, v)
		}
		strings.write_byte(b, '"')
	case .Drop_Shadow:
		strings.write_string(b, "<feDropShadow")
		filter_ref_attr(b, "in", p.in1, k)
		num_attr(b, "dx", p.dx)
		num_attr(b, "dy", p.dy)
		std_attr(b, p.std)
		flood_attrs(b, p.color)
	case .Component_Transfer:
		strings.write_string(b, "<feComponentTransfer")
		filter_ref_attr(b, "in", p.in1, k)
		close = "feComponentTransfer"
	case .Morphology:
		strings.write_string(b, "<feMorphology")
		filter_ref_attr(b, "in", p.in1, k)
		strings.write_string(b, ` operator="dilate"` if p.dilate else ` operator="erode"`)
		pair_attr(b, "radius", p.radius)
	case .Turbulence:
		strings.write_string(b, "<feTurbulence")
		strings.write_string(b, ` type="fractalNoise"` if p.fractal_noise else ` type="turbulence"`)
		pair_attr(b, "baseFrequency", p.base_frequency)
		num_attr(b, "numOctaves", f32(p.octaves))
		num_attr(b, "seed", f32(p.seed))
		if p.stitch {
			strings.write_string(b, ` stitchTiles="stitch"`)
		}
	case .Diffuse_Lighting:
		strings.write_string(b, "<feDiffuseLighting")
		filter_ref_attr(b, "in", p.in1, k)
		num_attr(b, "diffuseConstant", p.light_constant)
		close = "feDiffuseLighting"
	case .Specular_Lighting:
		strings.write_string(b, "<feSpecularLighting")
		filter_ref_attr(b, "in", p.in1, k)
		num_attr(b, "specularConstant", p.light_constant)
		num_attr(b, "specularExponent", p.specular_exponent)
		close = "feSpecularLighting"
	case .Tile:
		strings.write_string(b, "<feTile")
		filter_ref_attr(b, "in", p.in1, k)
	case .Displacement_Map:
		strings.write_string(b, "<feDisplacementMap")
		filter_ref_attr(b, "in", p.in1, k)
		filter_ref_attr(b, "in2", p.in2, k)
		num_attr(b, "scale", p.scale)
		CHANNELS := [4]string{"R", "G", "B", "A"}
		str_attr(b, "xChannelSelector", CHANNELS[p.channels[0] & 3])
		str_attr(b, "yChannelSelector", CHANNELS[p.channels[1] & 3])
	case .Convolve_Matrix:
		strings.write_string(b, "<feConvolveMatrix")
		filter_ref_attr(b, "in", p.in1, k)
		pair_attr(b, "order", {f32(p.order.x), f32(p.order.y)})
		strings.write_string(b, ` kernelMatrix="`)
		end := min(int(p.kernel_first) + int(p.kernel_count), len(fl.values))
		for v, j in fl.values[min(int(p.kernel_first), end):end] {
			if j > 0 {
				strings.write_byte(b, ' ')
			}
			num(b, v)
		}
		strings.write_byte(b, '"')
		num_attr(b, "targetX", f32(p.target.x))
		num_attr(b, "targetY", f32(p.target.y))
		num_attr(b, "divisor", p.divisor)
		num_attr(b, "bias", p.bias)
		EDGES := [vg.Convolve_Edge]string{.Duplicate = "duplicate", .Wrap = "wrap", .None = "none"}
		str_attr(b, "edgeMode", EDGES[p.edge])
		if p.preserve_alpha {
			strings.write_string(b, ` preserveAlpha="true"`)
		}
	case .Image:
		strings.write_string(b, "<feImage")
		FITS := [vg.Image_Fit]string{.Meet = "meet", .Slice = "slice", .None = ""}
		if p.image_fit == .None {
			strings.write_string(b, ` preserveAspectRatio="none"`)
		} else {
			axis :: proc(v: f32) -> string {
				return "Min" if v <= 0.25 else ("Max" if v >= 0.75 else "Mid")
			}
			strings.write_string(b, ` preserveAspectRatio="x`)
			strings.write_string(b, axis(p.image_align.x))
			strings.write_string(b, "Y")
			strings.write_string(b, axis(p.image_align.y))
			strings.write_byte(b, ' ')
			strings.write_string(b, FITS[p.image_fit])
			strings.write_byte(b, '"')
		}
		if int(p.image) < len(images) {
			if img, found := media_image(e.r.media, images[p.image]); found {
				png_href(b, img.pixels, img.width, img.height)
			}
		}
	}
	if p.has_subregion {
		rect_attrs(b, p.subregion)
	}
	strings.write_string(b, ` result="r`)
	strings.write_int(b, k)
	strings.write_byte(b, '"')
	if p.op == .Diffuse_Lighting || p.op == .Specular_Lighting {
		strings.write_string(b, ` lighting-color="`)
		hex_color(b, p.color)
		strings.write_byte(b, '"')
		num_attr(b, "surfaceScale", p.surface_scale)
	}
	if close != "" {
		strings.write_string(b, ">")
		export_primitive_children(b, fl, p)
		strings.write_string(b, "</")
		strings.write_string(b, close)
		strings.write_string(b, ">\n")
		return
	}
	if p.op != .Merge {
		strings.write_string(b, "/>\n")
		return
	}
	strings.write_string(b, ">")
	for ref in fl.merge_refs[p.merge_first:][:p.merge_count] {
		strings.write_string(b, "<feMergeNode")
		filter_ref_attr(b, "in", ref, k)
		strings.write_string(b, "/>")
	}
	strings.write_string(b, "</feMerge>\n")
}

// The feFunc* of a component transfer, the light of a lighting primitive.
@(private = "file")
export_primitive_children :: proc(b: ^strings.Builder, fl: vg.Filter, p: vg.Filter_Primitive) {
	if p.op == .Component_Transfer {
		TAGS := [4]string{"feFuncR", "feFuncG", "feFuncB", "feFuncA"}
		KINDS := [vg.Transfer_Kind]string{.Identity = "identity", .Table = "table", .Discrete = "discrete", .Linear = "linear", .Gamma = "gamma"}
		for fn, c in p.transfer {
			strings.write_byte(b, '<')
			strings.write_string(b, TAGS[c])
			str_attr(b, "type", KINDS[fn.kind])
			#partial switch fn.kind {
			case .Table, .Discrete:
				strings.write_string(b, ` tableValues="`)
				end := min(int(fn.first) + int(fn.count), len(fl.values))
				for v, j in fl.values[min(int(fn.first), end):end] {
					if j > 0 {
						strings.write_byte(b, ' ')
					}
					num(b, v)
				}
				strings.write_byte(b, '"')
			case .Linear:
				num_attr(b, "slope", fn.slope)
				num_attr(b, "intercept", fn.intercept)
			case .Gamma:
				num_attr(b, "amplitude", fn.amplitude)
				num_attr(b, "exponent", fn.exponent)
				num_attr(b, "offset", fn.offset)
			}
			strings.write_string(b, "/>")
		}
		return
	}
	l := p.light
	switch l.kind {
	case .Distant:
		strings.write_string(b, "<feDistantLight")
		num_attr(b, "azimuth", l.azimuth)
		num_attr(b, "elevation", l.elevation)
	case .Point:
		strings.write_string(b, "<fePointLight")
	case .Spot:
		strings.write_string(b, "<feSpotLight")
		num_attr(b, "pointsAtX", l.points_at.x)
		num_attr(b, "pointsAtY", l.points_at.y)
		num_attr(b, "pointsAtZ", l.points_at.z)
		num_attr(b, "specularExponent", l.spot_exponent)
		if l.has_cone {
			num_attr(b, "limitingConeAngle", l.cone_angle)
		}
	}
	if l.kind != .Distant {
		num_attr(b, "x", l.position.x)
		num_attr(b, "y", l.position.y)
		num_attr(b, "z", l.position.z)
	}
	strings.write_string(b, "/>")
}

// `name="x y"` (one value when both are equal).
@(private = "file")
pair_attr :: proc(b: ^strings.Builder, name: string, v: [2]f32) {
	strings.write_byte(b, ' ')
	strings.write_string(b, name)
	strings.write_string(b, `="`)
	num(b, v.x)
	if v.y != v.x {
		strings.write_byte(b, ' ')
		num(b, v.y)
	}
	strings.write_byte(b, '"')
}

@(private = "file")
filter_ref_attr :: proc(b: ^strings.Builder, name: string, ref: vg.Filter_Ref, k: int) {
	strings.write_byte(b, ' ')
	strings.write_string(b, name)
	strings.write_string(b, `="`)
	switch ref.kind {
	case .Previous:
		if k == 0 {
			strings.write_string(b, "SourceGraphic")
		} else {
			strings.write_byte(b, 'r')
			strings.write_int(b, k - 1)
		}
	case .Source_Graphic:
		strings.write_string(b, "SourceGraphic")
	case .Source_Alpha:
		strings.write_string(b, "SourceAlpha")
	case .Result:
		strings.write_byte(b, 'r')
		strings.write_int(b, int(ref.index))
	}
	strings.write_byte(b, '"')
}

@(private = "file")
std_attr :: proc(b: ^strings.Builder, std: [2]f32) {
	strings.write_string(b, ` stdDeviation="`)
	num(b, std.x)
	if std.y != std.x {
		strings.write_byte(b, ' ')
		num(b, std.y)
	}
	strings.write_byte(b, '"')
}

@(private = "file")
flood_attrs :: proc(b: ^strings.Builder, col: Color) {
	strings.write_string(b, ` flood-color="`)
	hex_color(b, col)
	strings.write_byte(b, '"')
	if col.a < 1 {
		num_attr(b, "flood-opacity", col.a)
	}
}

// x / y / width / height of a region covering the whole canvas in the
// coordinates `m` maps to the document's.
@(private = "file")
region_attrs :: proc(e: ^Svg_Export, m: vg.Transform2D) {
	inv := vg.transform_inverse(m)
	lo := vg.Vec2{max(f32), max(f32)}
	hi := vg.Vec2{-max(f32), -max(f32)}
	for p in ([4]vg.Vec2{{0, 0}, {e.vw, 0}, {0, e.vh}, {e.vw, e.vh}}) {
		q := vg.transform_point(inv, p.x, p.y)
		lo = {min(lo.x, q.x), min(lo.y, q.y)}
		hi = {max(hi.x, q.x), max(hi.y, q.y)}
	}
	if !(hi.x - lo.x < 1e7 && hi.y - lo.y < 1e7) {
		lo, hi = {-1e6, -1e6}, {1e6, 1e6}
	}
	num_attr(e.b, "x", math.floor(lo.x) - 1)
	num_attr(e.b, "y", math.floor(lo.y) - 1)
	num_attr(e.b, "width", math.ceil(hi.x - lo.x) + 2)
	num_attr(e.b, "height", math.ceil(hi.y - lo.y) + 2)
}

// ---- shapes ----------------------------------------------------------------------

// Dashes start where the outline does, and onimite' rects and ellipses
// start elsewhere than SVG's: dashed ones are written as their path.
@(private = "file")
dashed :: proc(s: Stroke) -> bool {
	return len(s.dash) > 0 && s.width > 0 && s.paint != nil
}

// The renderer's scratch path, emptied.
@(private = "file")
shape_path :: proc(e: ^Svg_Export) -> ^vg.Path {
	vg.path_reset(&e.r.bbox_path)
	return &e.r.bbox_path
}

// `<path d=".."` of the scratch path.
@(private = "file")
path_data :: proc(e: ^Svg_Export) {
	b := e.b
	p := &e.r.bbox_path
	strings.write_string(b, `<path d="`)
	k := 0
	for v in p.verbs {
		n := 0
		switch v {
		case .Move_To:
			strings.write_byte(b, 'M')
			n = 1
		case .Line_To:
			strings.write_byte(b, 'L')
			n = 1
		case .Bezier_To:
			strings.write_byte(b, 'C')
			n = 3
		case .Close:
			strings.write_byte(b, 'Z')
		case .Solid, .Hole:
		}
		for q in p.coords[k:][:n] {
			num(b, q.x)
			strings.write_byte(b, ' ')
			num(b, q.y)
			strings.write_byte(b, ' ')
		}
		k += n
	}
	strings.write_byte(b, '"')
}

// The <defs> of a shape's gradient or pattern paints.
@(private = "file")
shape_defs :: proc(e: ^Svg_Export, i: i32, style: Shape_Style, m: vg.Transform2D) {
	stroked := style.stroke.width > 0 && needs_def(style.stroke.paint)
	if !needs_def(style.fill) && !stroked {
		return
	}
	strings.write_string(e.b, "<defs>")
	paint_def(e, style.fill, i, 'f', -1, m)
	if stroked {
		paint_def(e, style.stroke.paint, i, 's', -1, m)
	}
	strings.write_string(e.b, "</defs>\n")
}

@(private = "file")
shape_attrs :: proc(e: ^Svg_Export, i: i32, style: Shape_Style, rule := vg.Fill_Rule.Non_Zero) {
	b := e.b
	paint_attr(b, "fill", style.fill, style.fill_opacity, i, 'f', -1)
	if rule == .Even_Odd {
		strings.write_string(b, ` fill-rule="evenodd"`)
	}
	stroke_attrs(b, i, style.stroke, true)
	if o, ok := style.opacity.?; ok && o < 1 {
		num_attr(b, "opacity", o)
	}
	if style.crisp {
		strings.write_string(b, ` shape-rendering="crispEdges"`)
	}
	strings.write_string(b, "/>\n")
}

@(private = "file")
stroke_attrs :: proc(b: ^strings.Builder, i: i32, s: Stroke, dashes: bool) {
	if s.paint == nil || s.width <= 0 {
		return
	}
	paint_attr(b, "stroke", s.paint, s.opacity, i, 's', -1)
	num_attr(b, "stroke-width", s.width)
	switch s.cap {
	case .Butt:
	case .Round:
		strings.write_string(b, ` stroke-linecap="round"`)
	case .Square:
		strings.write_string(b, ` stroke-linecap="square"`)
	}
	switch s.join {
	case .Miter:
	case .Round:
		strings.write_string(b, ` stroke-linejoin="round"`)
	case .Bevel:
		strings.write_string(b, ` stroke-linejoin="bevel"`)
	}
	if s.miter_limit > 0 && s.miter_limit != 4 {
		num_attr(b, "stroke-miterlimit", s.miter_limit)
	}
	if !dashes || len(s.dash) == 0 {
		return
	}
	strings.write_string(b, ` stroke-dasharray="`)
	for d, k in s.dash {
		if k > 0 {
			strings.write_byte(b, ' ')
		}
		num(b, d)
	}
	strings.write_byte(b, '"')
	if s.dash_offset != 0 {
		num_attr(b, "stroke-dashoffset", s.dash_offset)
	}
	if s.path_length > 0 {
		num_attr(b, "pathLength", s.path_length)
	}
}

// ---- paints ----------------------------------------------------------------------

@(private = "file")
needs_def :: proc(p: Paint) -> bool {
	switch _ in p {
	case Linear_Gradient, Radial_Gradient, Pattern:
		return true
	case Color:
	}
	return false
}

// `fill="#rrggbb" fill-opacity=".."` or a reference to the paint's def
// (`id_tag` / `sub` name it as in `paint_def`).
@(private = "file")
paint_attr :: proc(b: ^strings.Builder, name: string, p: Paint, opacity: Maybe(f32), i: i32, id_tag: u8, sub: int) {
	o := opacity.? or_else 1
	switch v in p {
	case Color:
		color_attr(b, name, v, o)
		return
	case Linear_Gradient, Radial_Gradient, Pattern:
		strings.write_byte(b, ' ')
		strings.write_string(b, name)
		strings.write_string(b, `="url(#`)
		node_id(b, i, id_tag, sub)
		strings.write_string(b, `)"`)
	case:
		strings.write_byte(b, ' ')
		strings.write_string(b, name)
		strings.write_string(b, `="none"`)
		return
	}
	if o < 1 {
		opacity_attr(b, name, o)
	}
}

@(private = "file")
paint_def :: proc(e: ^Svg_Export, p: Paint, i: i32, id_tag: u8, sub: int, m: vg.Transform2D) {
	b := e.b
	switch v in p {
	case Color:
		return
	case Linear_Gradient:
		strings.write_string(b, "<linearGradient")
		id_attr(b, i, id_tag, sub)
		num_attr(b, "x1", v.x1)
		num_attr(b, "y1", v.y1)
		num_attr(b, "x2", v.x2)
		num_attr(b, "y2", v.y2)
		gradient_space(b, v.space)
		strings.write_byte(b, '>')
		stops(b, v.stops)
		strings.write_string(b, "</linearGradient>")
	case Radial_Gradient:
		strings.write_string(b, "<radialGradient")
		id_attr(b, i, id_tag, sub)
		num_attr(b, "cx", v.cx)
		num_attr(b, "cy", v.cy)
		num_attr(b, "r", v.r)
		if f, ok := v.focal.?; ok {
			num_attr(b, "fx", f.x)
			num_attr(b, "fy", f.y)
		}
		if v.inner_r > 0 {
			num_attr(b, "fr", v.inner_r)
		}
		gradient_space(b, v.space)
		strings.write_byte(b, '>')
		stops(b, v.stops)
		strings.write_string(b, "</radialGradient>")
	case Pattern:
		strings.write_string(b, "\n<pattern")
		id_attr(b, i, id_tag, sub)
		num_attr(b, "x", v.x)
		num_attr(b, "y", v.y)
		num_attr(b, "width", v.w)
		num_attr(b, "height", v.h)
		if v.units == .User {
			strings.write_string(b, ` patternUnits="userSpaceOnUse"`)
		}
		if t, ok := v.transform.?; ok {
			matrix_attr(b, "patternTransform", t)
		}
		strings.write_string(b, ">\n")
		export_children(e, v.content, m)
		strings.write_string(b, "</pattern>")
	}
}

@(private = "file")
gradient_space :: proc(b: ^strings.Builder, s: Paint_Space) {
	if s.units == .User {
		strings.write_string(b, ` gradientUnits="userSpaceOnUse"`)
	}
	switch s.spread {
	case .Pad:
	case .Reflect:
		strings.write_string(b, ` spreadMethod="reflect"`)
	case .Repeat:
		strings.write_string(b, ` spreadMethod="repeat"`)
	}
	if t, ok := s.transform.?; ok {
		matrix_attr(b, "gradientTransform", t)
	}
}

@(private = "file")
stops :: proc(b: ^strings.Builder, stops: []vg.Gradient_Stop) {
	for s in stops {
		strings.write_string(b, "<stop")
		num_attr(b, "offset", s.offset)
		strings.write_string(b, ` stop-color="`)
		hex_color(b, s.color)
		strings.write_byte(b, '"')
		if s.color.a < 1 {
			num_attr(b, "stop-opacity", s.color.a)
		}
		strings.write_string(b, "/>")
	}
}

// ---- text ------------------------------------------------------------------------

@(private = "file")
export_text :: proc(e: ^Svg_Export, i: i32, t: Text, m: vg.Transform2D) {
	if t.text == "" && len(t.spans) == 0 {
		return
	}
	b := e.b
	stroked := t.stroke.width > 0 && needs_def(t.stroke.paint)
	defs := needs_def(t.fill) || stroked
	for s in t.spans {
		defs ||= needs_def(s.fill)
	}
	if defs {
		strings.write_string(b, "<defs>")
		paint_def(e, t.fill, i, 'f', -1, m)
		if stroked {
			paint_def(e, t.stroke.paint, i, 's', -1, m)
		}
		for s, k in t.spans {
			paint_def(e, s.fill, i, 't', k, m)
		}
		strings.write_string(b, "</defs>\n")
	}
	strings.write_string(b, "<text")
	num_attr(b, "x", t.x)
	num_attr(b, "y", t.y)
	family := text_family(e, t.font, t.weight, t.italic)
	font_attrs(b, family, t.size, t.weight, t.italic, t.letter_spacing, t.features)
	switch t.align {
	case .Left:
	case .Center:
		strings.write_string(b, ` text-anchor="middle"`)
	case .Right:
		strings.write_string(b, ` text-anchor="end"`)
	}
	switch t.baseline {
	case .Alphabetic:
	case .Middle:
		strings.write_string(b, ` dominant-baseline="middle"`)
	case .Central:
		strings.write_string(b, ` dominant-baseline="central"`)
	case .Hanging:
		strings.write_string(b, ` dominant-baseline="hanging"`)
	case .Top:
		strings.write_string(b, ` dominant-baseline="text-before-edge"`)
	case .Bottom:
		strings.write_string(b, ` dominant-baseline="text-after-edge"`)
	}
	paint_attr(b, "fill", t.fill, t.fill_opacity, i, 'f', -1)
	stroke_attrs(b, i, t.stroke, false)
	if o, ok := t.opacity.?; ok && o < 1 {
		num_attr(b, "opacity", o)
	}
	strings.write_string(b, ` xml:space="preserve">`)
	lh := (t.line_height if t.line_height > 0 else 1.2) * t.size
	text_lines(b, t.text, t.x, lh)
	for s, k in t.spans {
		strings.write_string(b, "<tspan")
		// A span without a family takes the face its weight and style pick.
		italic := s.italic.? or_else t.italic
		span_family := s.font
		if span_family == "" && t.font == "" {
			span_family = text_family(e, "", s.weight if s.weight != 0 else t.weight, italic)
			if span_family == family {
				span_family = ""
			}
		}
		font_attrs(b, span_family, s.size, s.weight, italic, s.letter_spacing.? or_else t.letter_spacing, s.features)
		if s.fill != nil {
			paint_attr(b, "fill", s.fill, s.fill_opacity.? or_else (t.fill_opacity.? or_else 1), i, 't', k)
		} else if o, ok := s.fill_opacity.?; ok {
			paint_attr(b, "fill", t.fill, o, i, 'f', -1)
		}
		if s.dx != 0 {
			num_attr(b, "dx", s.dx)
		}
		if s.dy != 0 {
			num_attr(b, "dy", s.dy)
		}
		strings.write_byte(b, '>')
		text_lines(b, s.text, t.x, lh)
		strings.write_string(b, "</tspan>")
	}
	strings.write_string(b, "</text>\n")
}

// The family text with `family` draws with: an empty one takes the first
// face of the weight and style (font_collection_find), which an SVG reader
// would not know.
@(private = "file")
text_family :: proc(e: ^Svg_Export, family: string, weight: int, italic: bool) -> string {
	if family != "" {
		return family
	}
	fonts := &e.r.media.fonts
	font, _ := vg.font_collection_find(fonts, "", weight, italic)
	for &f in fonts.faces {
		if &f.font == font {
			return f.family
		}
	}
	return fonts.fallback.family
}

@(private = "file")
font_attrs :: proc(b: ^strings.Builder, family: string, size: f32, weight: int, italic: bool, letter_spacing: f32, features: []Font_Feature) {
	if family != "" {
		str_attr(b, "font-family", family)
	}
	if size > 0 {
		num_attr(b, "font-size", size)
	}
	if weight != 0 {
		num_attr(b, "font-weight", f32(weight))
	}
	if italic {
		strings.write_string(b, ` font-style="italic"`)
	}
	if letter_spacing != 0 {
		num_attr(b, "letter-spacing", letter_spacing)
	}
	for f, i in features {
		strings.write_string(b, ` font-feature-settings="` if i == 0 else ", ")
		strings.write_byte(b, '\'')
		strings.write_string(b, f.tag)
		strings.write_string(b, "' ")
		strings.write_uint(b, uint(f.value))
	}
	if len(features) > 0 {
		strings.write_byte(b, '"')
	}
}

// Text with each "\n" starting a line (a tspan back at `x`, `lh` lower).
@(private = "file")
text_lines :: proc(b: ^strings.Builder, text: string, x, lh: f32) {
	rest := text
	first := true
	for line in strings.split_lines_iterator(&rest) {
		if !first {
			strings.write_string(b, "<tspan")
			num_attr(b, "x", x)
			num_attr(b, "dy", lh)
			strings.write_byte(b, '>')
		}
		escape(b, line)
		if !first {
			strings.write_string(b, "</tspan>")
		}
		first = false
	}
}

// ---- images, rasters, SVG documents ------------------------------------------------

@(private = "file")
export_image :: proc(e: ^Svg_Export, n: Image) {
	b := e.b
	img, found := media_image(e.r.media, n.src)
	if !found {
		strings.write_string(b, "<!-- missing image ")
		comment_text(b, n.src)
		strings.write_string(b, " -->\n")
		return
	}
	box, pic := fit_box(n.x, n.y, n.w, n.h, f32(img.width), f32(img.height), n.fit, n.align)
	if n.fit == .Cover {
		clip_viewport_begin(b, box)
	}
	strings.write_string(b, "<image")
	rect_attrs(b, pic)
	strings.write_string(b, ` preserveAspectRatio="none"`)
	if o, ok := n.opacity.?; ok && o < 1 {
		num_attr(b, "opacity", o)
	}
	path := ""
	if e.r.media.dir != "" {
		joined, _ := filepath.join({e.r.media.dir, n.src}, context.temp_allocator)
		if os.exists(joined) {
			path, _ = filepath.abs(joined, context.temp_allocator)
		}
	}
	if path != "" {
		str_attr(b, "href", path)
	} else {
		png_href(b, img.pixels, img.width, img.height)
	}
	strings.write_string(b, "/>\n")
	if n.fit == .Cover {
		strings.write_string(b, "</svg>\n")
	}
}

// Node `i` drawn alone over `box` at the resolution it shows at, as an
// embedded PNG.
@(private = "file")
export_raster :: proc(e: ^Svg_Export, i: i32, box: vg.Rect, m: vg.Transform2D) {
	if box.w <= 0 || box.h <= 0 {
		return
	}
	s := vg.transform_average_scale(m) * e.r.scale
	pw := u32(clamp(math.ceil(box.w * s), 1, 8192))
	ph := u32(clamp(math.ceil(box.h * s), 1, 8192))
	px := render_node(e.r, i, box, pw, ph)
	if len(px) < int(pw * ph * 4) {
		return
	}
	b := e.b
	strings.write_string(b, "<image")
	rect_attrs(b, box)
	strings.write_string(b, ` preserveAspectRatio="none"`)
	png_href(b, straight_alpha(px[:int(pw * ph * 4)]), int(pw), int(ph))
	strings.write_string(b, "/>\n")
}

// ` href="data:image/png;base64,..."` of straight RGBA8 pixels.
@(private = "file")
png_href :: proc(b: ^strings.Builder, pixels: []u8, w, h: int) {
	png, _ := odimg.encode_png(pixels, w, h, context.temp_allocator)
	strings.write_string(b, ` href="data:image/png;base64,`)
	base64.encode_into(strings.to_writer(b), png)
	strings.write_byte(b, '"')
}

@(private = "file")
export_svg_node :: proc(e: ^Svg_Export, i: i32, n: Svg, m: vg.Transform2D) {
	if n.asset == nil || n.asset.doc.width <= 0 || n.asset.doc.height <= 0 {
		return
	}
	doc := &n.asset.doc
	b := e.b
	box, pic := fit_box(n.x, n.y, n.w, n.h, doc.width, doc.height, n.fit, n.align)
	source, ok := e.r.ctx.svgs.sources[n.asset]
	if !ok && n.src != "" && e.r.media.dir != "" {
		path, _ := filepath.join({e.r.media.dir, n.src}, context.temp_allocator)
		if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
			source, ok = string(data), true
		}
	}
	if !ok {
		note_begin(b, n, n.src)
		strings.write_string(b, " has no source file, drawn to a PNG -->\n")
		export_raster(e, i, box, m)
		return
	}
	opacity := n.opacity.? or_else 1
	if opacity <= 0 {
		return
	}
	if opacity < 1 {
		strings.write_string(b, "<g")
		num_attr(b, "opacity", opacity)
		strings.write_string(b, ">\n")
	}
	if n.fit == .Cover {
		clip_viewport_begin(b, box)
	}
	// The document's size scaled into the picture's rect, which clips it.
	strings.write_string(b, "<svg")
	rect_attrs(b, pic)
	strings.write_string(b, ` viewBox="0 0 `)
	num(b, doc.width)
	strings.write_byte(b, ' ')
	num(b, doc.height)
	strings.write_string(b, `" preserveAspectRatio="none">`)
	strings.write_string(b, "\n")
	inline_svg(b, i, source, n.overrides, doc.width, doc.height)
	strings.write_string(b, "\n</svg>\n")
	if n.fit == .Cover {
		strings.write_string(b, "</svg>\n")
	}
	if opacity < 1 {
		strings.write_string(b, "</g>\n")
	}
}

// ` x=".." y=".." width=".." height=".."` of `r`.
@(private = "file")
rect_attrs :: proc(b: ^strings.Builder, r: vg.Rect) {
	num_attr(b, "x", r.x)
	num_attr(b, "y", r.y)
	num_attr(b, "width", r.w)
	num_attr(b, "height", r.h)
}

// A viewport clipping to `r` without changing coordinates.
@(private = "file")
clip_viewport_begin :: proc(b: ^strings.Builder, r: vg.Rect) {
	strings.write_string(b, "<svg")
	rect_attrs(b, r)
	strings.write_string(b, ` viewBox="`)
	num(b, r.x)
	strings.write_byte(b, ' ')
	num(b, r.y)
	strings.write_byte(b, ' ')
	num(b, r.w)
	strings.write_byte(b, ' ')
	num(b, r.h)
	strings.write_string(b, "\">\n")
}

@(private = "file")
Xml_Attr :: struct {
	name, value: string,
	quote:       u8,
}

// Copies an SVG document's markup without its prolog, its root at (0, 0)
// sized `w x h`, ids prefixed with `s<node>-` (and references to them),
// and the overrides applied to their elements: a transform appended to
// the element's own, the rest as style declarations.
@(private = "file")
inline_svg :: proc(b: ^strings.Builder, node: i32, src: string, overrides: []Svg_Override, w, h: f32) {
	prefix_buf: [16]u8
	prefix := strconv.write_int(prefix_buf[1:15], i64(node), 10)
	prefix_buf[0] = 's'
	prefix_buf[1 + len(prefix)] = '-'
	prefix = string(prefix_buf[:len(prefix) + 2])
	root := true
	pos := 0
	for pos < len(src) {
		lt := strings.index_byte(src[pos:], '<')
		if lt < 0 {
			lt = len(src) - pos
		}
		if !root {
			write_urls(b, src[pos:][:lt], prefix)
		}
		pos += lt
		if pos >= len(src) {
			break
		}
		rest := src[pos:]
		end := 0
		switch {
		case strings.has_prefix(rest, "<!--"):
			end = index_after(rest, "-->")
			if !root {
				strings.write_string(b, rest[:end])
			}
		case strings.has_prefix(rest, "<![CDATA["):
			end = index_after(rest, "]]>")
			write_urls(b, rest[:end], prefix)
		case strings.has_prefix(rest, "<?"), strings.has_prefix(rest, "<!"):
			end = index_after(rest, ">")
		case strings.has_prefix(rest, "</"):
			end = index_after(rest, ">")
			strings.write_string(b, rest[:end])
		case:
			end = inline_tag(b, rest, prefix, overrides, root, w, h)
			root = false
		}
		pos += end
	}
}

@(private = "file")
index_after :: proc(s, sep: string) -> int {
	k := strings.index(s, sep)
	return len(s) if k < 0 else k + len(sep)
}

// One start tag (`s` begins with it); returns its length.
@(private = "file")
inline_tag :: proc(b: ^strings.Builder, s: string, prefix: string, overrides: []Svg_Override, root: bool, w, h: f32) -> int {
	is_space :: proc(c: u8) -> bool {return c == ' ' || c == '\t' || c == '\n' || c == '\r'}
	j := 1
	for j < len(s) && !is_space(s[j]) && s[j] != '>' && s[j] != '/' {
		j += 1
	}
	name := s[1:j]
	attrs: [64]Xml_Attr
	count := 0
	self_closing := false
	for j < len(s) {
		for j < len(s) && is_space(s[j]) {
			j += 1
		}
		if j >= len(s) {
			break
		}
		if s[j] == '>' {
			j += 1
			break
		}
		if s[j] == '/' {
			self_closing = true
			j += 1
			continue
		}
		start := j
		for j < len(s) && !is_space(s[j]) && s[j] != '=' && s[j] != '>' && s[j] != '/' {
			j += 1
		}
		a := Xml_Attr{name = s[start:j], quote = '"'}
		for j < len(s) && is_space(s[j]) {
			j += 1
		}
		if j < len(s) && s[j] == '=' {
			j += 1
			for j < len(s) && is_space(s[j]) {
				j += 1
			}
			if j < len(s) && (s[j] == '"' || s[j] == '\'') {
				a.quote = s[j]
				k := strings.index_byte(s[j + 1:], a.quote)
				k = len(s) - j - 1 if k < 0 else k
				a.value = s[j + 1:][:k]
				j += k + 2
			} else {
				vs := j
				for j < len(s) && !is_space(s[j]) && s[j] != '>' {
					j += 1
				}
				a.value = s[vs:j]
			}
		}
		if count < len(attrs) && a.name != "" {
			attrs[count] = a
			count += 1
		}
	}
	j = min(j, len(s))

	ov: ^Svg_Override
	for a in attrs[:count] {
		if a.name == "id" {
			for &o in overrides {
				if o.id == a.value {
					ov = &o
				}
			}
		}
	}
	has_transform, has_style := false, false
	strings.write_byte(b, '<')
	strings.write_string(b, name)
	for a in attrs[:count] {
		if root && (a.name == "x" || a.name == "y" || a.name == "width" || a.name == "height") {
			continue
		}
		strings.write_byte(b, ' ')
		strings.write_string(b, a.name)
		strings.write_byte(b, '=')
		strings.write_byte(b, a.quote)
		switch {
		case a.name == "id":
			strings.write_string(b, prefix)
			strings.write_string(b, a.value)
		case (a.name == "href" || a.name == "xlink:href") && strings.has_prefix(a.value, "#"):
			strings.write_byte(b, '#')
			strings.write_string(b, prefix)
			strings.write_string(b, a.value[1:])
		case:
			write_urls(b, a.value, prefix)
		}
		if ov != nil && a.name == "transform" {
			has_transform = true
			override_transform(b, ov)
		}
		if ov != nil && a.name == "style" {
			has_style = true
			strings.write_byte(b, ';')
			override_style(b, ov)
		}
		strings.write_byte(b, a.quote)
	}
	if ov != nil && !has_transform && ov.transform != nil {
		strings.write_string(b, ` transform="`)
		override_transform(b, ov)
		strings.write_byte(b, '"')
	}
	if ov != nil && !has_style {
		strings.write_string(b, ` style="`)
		override_style(b, ov)
		strings.write_byte(b, '"')
	}
	if root {
		num_attr(b, "width", w)
		num_attr(b, "height", h)
	}
	strings.write_string(b, "/>" if self_closing else ">")
	return j
}

@(private = "file")
override_transform :: proc(b: ^strings.Builder, ov: ^Svg_Override) {
	if t, ok := ov.transform.?; ok {
		m := transform_matrix(t)
		strings.write_string(b, " matrix(")
		for v, k in m {
			if k > 0 {
				strings.write_byte(b, ' ')
			}
			num(b, v)
		}
		strings.write_byte(b, ')')
	}
}

@(private = "file")
override_style :: proc(b: ^strings.Builder, ov: ^Svg_Override) {
	if o, ok := ov.opacity.?; ok {
		strings.write_string(b, "opacity:")
		num(b, o)
		strings.write_byte(b, ';')
	}
	if col, ok := ov.fill.?; ok {
		strings.write_string(b, "fill:")
		css_color(b, col)
		strings.write_byte(b, ';')
	}
	if col, ok := ov.stroke.?; ok {
		strings.write_string(b, "stroke:")
		css_color(b, col)
		strings.write_byte(b, ';')
	}
	if v, ok := ov.visible.?; ok {
		strings.write_string(b, "display:inline;visibility:visible;" if v else "display:none;")
	}
}

// Copies `s` with `url(#id)` references prefixed.
@(private = "file")
write_urls :: proc(b: ^strings.Builder, s: string, prefix: string) {
	rest := s
	for {
		k := strings.index(rest, "url(#")
		if k < 0 {
			strings.write_string(b, rest)
			return
		}
		strings.write_string(b, rest[:k + 5])
		strings.write_string(b, prefix)
		rest = rest[k + 5:]
	}
}

// ---- writing ---------------------------------------------------------------------

@(private = "file")
BLEND_NAMES := [vg.Blend_Mode]string {
	.Normal      = "normal",
	.Multiply    = "multiply",
	.Screen      = "screen",
	.Overlay     = "overlay",
	.Darken      = "darken",
	.Lighten     = "lighten",
	.Color_Dodge = "color-dodge",
	.Color_Burn  = "color-burn",
	.Hard_Light  = "hard-light",
	.Soft_Light  = "soft-light",
	.Difference  = "difference",
	.Exclusion   = "exclusion",
	.Hue         = "hue",
	.Saturation  = "saturation",
	.Color       = "color",
	.Luminosity  = "luminosity",
}

@(private = "file")
COMPOSITE_NAMES := [vg.Composite_Operator]string {
	.Over       = "over",
	.In         = "in",
	.Out        = "out",
	.Atop       = "atop",
	.Xor        = "xor",
	.Lighter    = "lighter",
	.Arithmetic = "arithmetic",
}

// A number in the shortest form that reads back as the same f32.
@(private = "file")
num :: proc(b: ^strings.Builder, v: f32) {
	if math.is_nan(v) || math.is_inf(v) {
		strings.write_byte(b, '0')
		return
	}
	buf: [64]u8
	s := strconv.write_float(buf[:], f64(v), 'f', -1, 32)
	if s[0] == '+' {
		s = s[1:]
	}
	strings.write_string(b, s)
}

@(private = "file")
num_attr :: proc(b: ^strings.Builder, name: string, v: f32) {
	strings.write_byte(b, ' ')
	strings.write_string(b, name)
	strings.write_string(b, `="`)
	num(b, v)
	strings.write_byte(b, '"')
}

@(private = "file")
str_attr :: proc(b: ^strings.Builder, name: string, v: string) {
	strings.write_byte(b, ' ')
	strings.write_string(b, name)
	strings.write_string(b, `="`)
	escape(b, v)
	strings.write_byte(b, '"')
}

@(private = "file")
matrix_attr :: proc(b: ^strings.Builder, name: string, m: vg.Transform2D) {
	strings.write_byte(b, ' ')
	strings.write_string(b, name)
	strings.write_string(b, `="matrix(`)
	for v, k in m {
		if k > 0 {
			strings.write_byte(b, ' ')
		}
		num(b, v)
	}
	strings.write_string(b, `)"`)
}

// `n12f`, `n12t3`: node 12's fill, its span 3's.
@(private = "file")
node_id :: proc(b: ^strings.Builder, i: i32, tag: u8, sub := -1) {
	strings.write_byte(b, 'n')
	strings.write_int(b, int(i))
	strings.write_byte(b, tag)
	if sub >= 0 {
		strings.write_int(b, sub)
	}
}

@(private = "file")
id_attr :: proc(b: ^strings.Builder, i: i32, tag: u8, sub := -1) {
	strings.write_string(b, ` id="`)
	node_id(b, i, tag, sub)
	strings.write_byte(b, '"')
}

@(private = "file")
ref_attr :: proc(b: ^strings.Builder, name: string, i: i32, tag: u8) {
	strings.write_byte(b, ' ')
	strings.write_string(b, name)
	strings.write_string(b, `="url(#`)
	node_id(b, i, tag)
	strings.write_string(b, `)"`)
}

@(private = "file")
hex_color :: proc(b: ^strings.Builder, col: Color) {
	DIGITS := "0123456789abcdef"
	strings.write_byte(b, '#')
	for v in ([3]f32{col.r, col.g, col.b}) {
		u := u8(math.round(clamp(v, 0, 1) * 255))
		strings.write_byte(b, DIGITS[u >> 4])
		strings.write_byte(b, DIGITS[u & 15])
	}
}

// `fill="#rrggbb"` and, below 1, `fill-opacity` (the color's alpha times
// `opacity`).
@(private = "file")
color_attr :: proc(b: ^strings.Builder, name: string, col: Color, opacity: f32) {
	strings.write_byte(b, ' ')
	strings.write_string(b, name)
	strings.write_string(b, `="`)
	hex_color(b, col)
	strings.write_byte(b, '"')
	if a := col.a * opacity; a < 1 {
		opacity_attr(b, name, a)
	}
}

// `fill-opacity="a"` for `name` "fill".
@(private = "file")
opacity_attr :: proc(b: ^strings.Builder, name: string, a: f32) {
	strings.write_byte(b, ' ')
	strings.write_string(b, name)
	strings.write_string(b, `-opacity="`)
	num(b, a)
	strings.write_byte(b, '"')
}

@(private = "file")
css_color :: proc(b: ^strings.Builder, col: Color) {
	if col.a >= 1 {
		hex_color(b, col)
		return
	}
	strings.write_string(b, "rgba(")
	for v in ([3]f32{col.r, col.g, col.b}) {
		strings.write_int(b, int(math.round(clamp(v, 0, 1) * 255)))
		strings.write_byte(b, ',')
	}
	num(b, col.a)
	strings.write_byte(b, ')')
}

@(private = "file")
escape :: proc(b: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '&':
			strings.write_string(b, "&amp;")
		case '<':
			strings.write_string(b, "&lt;")
		case '>':
			strings.write_string(b, "&gt;")
		case '"':
			strings.write_string(b, "&quot;")
		case:
			strings.write_byte(b, s[i])
		}
	}
}

// Text safe inside a comment (no "--").
@(private = "file")
comment_text :: proc(b: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		strings.write_byte(b, s[i])
		if s[i] == '-' && i + 1 < len(s) && s[i + 1] == '-' {
			strings.write_byte(b, ' ')
		}
	}
}
