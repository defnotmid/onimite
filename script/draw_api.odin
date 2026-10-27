package onimite_script

import "core:c"
import "core:math"
import "core:slice"
import "core:strings"
import om "../onimite"
import vg "deps:ovg"
import vglottie "deps:ovg/lottie"
import lua "vendor:lua/5.4"

// Script API for SVG features beyond the basic nodes: polygons, patterns,
// skew, text spans and baselines, filters, blend modes, paint spaces and
// SVG documents.

// polygon{ points = {x1, y1, x2, y2, ...} or {{x, y}, ...}, fill, stroke, ... }
@(private)
l_polygon :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	return poly(L, s, true)
}

@(private)
l_polyline :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	return poly(L, s, false)
}

@(private)
poly :: proc(L: ^lua.State, s: ^Script, closed: bool) -> c.int {
	ctx := render_ctx(L, s)
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	fields_begin(L, 1)
	points := read_points(L, 1, ctx)
	rule := vg.Fill_Rule.Non_Zero
	if get_str(L, 1, "fill_rule", "") == "evenodd" {
		rule = .Even_Odd
	}
	om.path(
		ctx,
		{
			points = points,
			closed = closed,
			fill_rule = rule,
			style = read_style(L, 1, ctx),
		},
	)
	fields_end(L, s, 1, "polygon" if closed else "polyline")
	return 0
}

@(private)
read_points :: proc(L: ^lua.State, t: c.int, ctx: ^om.Context) -> []om.Vec2 {
	field(L, t, "points")
	defer lua.pop(L, 1)
	if !lua.istable(L, -1) {
		return nil
	}
	n := int(lua.rawlen(L, -1))
	if n == 0 {
		return nil
	}
	lua.rawgeti(L, -1, 1)
	nested := lua.istable(L, -1)
	lua.pop(L, 1)
	count := n if nested else n / 2
	pts := make([]om.Vec2, count, ctx.tree.arena)
	for &p, i in pts {
		if nested {
			lua.rawgeti(L, -1, lua.Integer(i + 1))
			p = read_vec2(L, -1)
			lua.pop(L, 1)
		} else {
			lua.rawgeti(L, -1, lua.Integer(2 * i + 1))
			lua.rawgeti(L, -2, lua.Integer(2 * i + 2))
			p = {f32(lua.tonumber(L, -2)), f32(lua.tonumber(L, -1))}
			lua.pop(L, 2)
		}
	}
	return pts
}

// pattern{ x, y, w, h, units = "user"|"bbox", transform, content = function() ... end }
// returns a paint for `fill` / `stroke`. Call it while rendering.
@(private)
l_pattern :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	ctx := render_ctx(L, s)
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	node := om.pattern_begin(ctx)
	field(L, 1, "content")
	status: c.int = 0
	if lua.isfunction(L, -1) {
		status = lua.pcall(L, 0, 0, 0)
	} else {
		lua.pop(L, 1)
	}
	om.group_end(ctx)
	if status != 0 {
		return c.int(lua.error(L))
	}
	lua.pushvalue(L, 1)
	lua.pushstring(L, "pattern")
	lua.setfield(L, -2, "kind")
	lua.pushinteger(L, lua.Integer(node))
	lua.setfield(L, -2, "node")
	return 1
}

// skew(x_degrees, y_degrees[, ox, oy])
@(private)
l_skew :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	push_transform(L, om.skew(f32(lua.L_checknumber(L, 1)), f32(lua.L_optnumber(L, 2, 0)), {f32(lua.L_optnumber(L, 3, 0)), f32(lua.L_optnumber(L, 4, 0))}))
	return 1
}

// Units, transform and spread shared by gradients and patterns:
// `units = "bbox"` (objectBoundingBox), `transform` (an SVG matrix
// `{a, b, c, d, e, f}`, an SVG transform list string or a transform table,
// see `read_transform`), `spread = "pad"|"reflect"|"repeat"`.
@(private)
read_paint_space :: proc(L: ^lua.State, t: c.int) -> (sp: om.Paint_Space) {
	switch get_str(L, t, "units", "user") {
	case "bbox", "objectBoundingBox", "bounding_box":
		sp.units = .Bounding_Box
	}
	switch get_str(L, t, "spread", "pad") {
	case "reflect":
		sp.spread = .Reflect
	case "repeat":
		sp.spread = .Repeat
	}
	field(L, t, "transform")
	defer lua.pop(L, 1)
	if lua.istable(L, -1) || lua.type(L, -1) == .STRING {
		sp.transform = om.transform_matrix(read_transform(L, -1))
	}
	return
}

// text spans: `spans = { {"bold part", weight = 700, fill = "#f00"}, ... }`
@(private)
read_spans :: proc(L: ^lua.State, t: c.int, ctx: ^om.Context) -> []om.Text_Span {
	field(L, t, "spans")
	defer lua.pop(L, 1)
	if !lua.istable(L, -1) {
		return nil
	}
	list := lua.absindex(L, -1)
	n := int(lua.rawlen(L, list))
	spans := make([]om.Text_Span, n, ctx.tree.arena)
	for &sp, i in spans {
		lua.rawgeti(L, list, lua.Integer(i + 1))
		e := lua.absindex(L, -1)
		outer := fields_push(L, e)
		sp.text = text_arg(L, e)
		sp.font = get_str(L, e, "font", "")
		sp.size = get_num(L, e, "size", 0)
		sp.weight = int(get_num(L, e, "weight", 0))
		if has_field(L, e, "italic") || has_field(L, e, "style") {
			sp.italic = read_italic(L, e)
		}
		if v, ok := get_opt_num(L, e, "letter_spacing"); ok {
			sp.letter_spacing = v
		}
		sp.features = read_features(L, e)
		sp.fill = get_paint(L, e, "fill", ctx)
		sp.fill_opacity = get_maybe(L, e, "fill_opacity")
		sp.dx = get_num(L, e, "dx", 0)
		sp.dy = get_num(L, e, "dy", 0)
		fields_pop(L, host(L), e, "text span", outer)
		lua.pop(L, 1)
	}
	return spans
}

// `features = { "smcp", liga = 0, ss01 = true, salt = 2 }`: OpenType
// features over the font's defaults; a listed tag is on, a keyed one takes
// its value (false 0, true 1, n the nth alternate). nil when absent.
@(private)
read_features :: proc(L: ^lua.State, t: c.int) -> []om.Font_Feature {
	field(L, t, "features")
	defer lua.pop(L, 1)
	if lua.isnil(L, -1) {
		return nil
	}
	if !lua.istable(L, -1) {
		lua.L_error(L, "features: a table of OpenType tags, as { \"smcp\", liga = 0 }")
	}
	f := lua.absindex(L, -1)
	n := 0
	lua.pushnil(L)
	for lua.next(L, f) != 0 {
		n += 1
		lua.pop(L, 1)
	}
	out := make([]om.Font_Feature, n, context.temp_allocator)
	i := 0
	lua.pushnil(L)
	for lua.next(L, f) != 0 {
		ft := &out[i]
		i += 1
		if lua.type(L, -2) == .STRING {
			ft.tag = feature_tag(L, -2)
			#partial switch lua.type(L, -1) {
			case .BOOLEAN:
				ft.value = u32(lua.toboolean(L, -1))
			case .NUMBER:
				v := lua.tonumber(L, -1)
				if v < 0 || v != lua.Number(u32(v)) {
					lua.L_error(L, "features: %s = %f: a value is 0 (off), 1 (on) or the nth alternate", strings.clone_to_cstring(ft.tag, context.temp_allocator), v)
				}
				ft.value = u32(v)
			case:
				lua.L_error(L, "features: %s takes true, false or a number", strings.clone_to_cstring(ft.tag, context.temp_allocator))
			}
		} else {
			if lua.type(L, -1) != .STRING {
				lua.L_error(L, "features: list a tag as a string (\"smcp\") or key it (liga = 0)")
			}
			ft.tag = feature_tag(L, -1)
			ft.value = 1
		}
		lua.pop(L, 1)
	}
	return out
}

// `variations = { wght = 333, opsz = 32 }`: a variable font's instance, an
// axis tag and its value in the axis's units each (`media_text_fonts` makes
// the instance the first time it is drawn). nil when absent.
@(private)
read_variations :: proc(L: ^lua.State, t: c.int) -> []om.Font_Variation {
	field(L, t, "variations")
	defer lua.pop(L, 1)
	if lua.isnil(L, -1) {
		return nil
	}
	if !lua.istable(L, -1) {
		lua.L_error(L, "variations: a table of axis tags and values, as { wght = 333, opsz = 32 }")
	}
	v := lua.absindex(L, -1)
	out := make([dynamic]om.Font_Variation, context.temp_allocator)
	lua.pushnil(L)
	for lua.next(L, v) != 0 {
		if lua.type(L, -2) != .STRING || lua.type(L, -1) != .NUMBER {
			lua.L_error(L, "variations: key an axis by its tag with a number, as { wght = 333 }")
		}
		append(&out, om.Font_Variation{feature_tag(L, -2), f32(lua.tonumber(L, -1))})
		lua.pop(L, 1)
	}
	// one order for one instance, whatever order the table walked in
	slice.sort_by(out[:], proc(a, b: om.Font_Variation) -> bool {return a.tag < b.tag})
	return out[:]
}

// The string at `i` if it is an OpenType tag: one to four letters, digits
// or spaces.
@(private = "file")
feature_tag :: proc(L: ^lua.State, i: c.int) -> string {
	n: c.size_t
	p := lua.tolstring(L, i, &n)
	tag := string((cast([^]u8)p)[:n])
	ok := len(tag) >= 1 && len(tag) <= 4
	for ch in transmute([]u8)tag {
		ok &&= (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == ' '
	}
	if !ok {
		lua.L_error(L, "features: \"%s\" is not an OpenType tag (four characters, as \"smcp\" or \"ss01\")", p)
	}
	return tag
}

// `italic = true` or `style = "italic"|"oblique"`.
@(private)
read_italic :: proc(L: ^lua.State, t: c.int) -> bool {
	field(L, t, "italic")
	defer lua.pop(L, 1)
	if lua.type(L, -1) == .BOOLEAN {
		return bool(lua.toboolean(L, -1))
	}
	style := get_str(L, t, "style", "normal")
	return style == "italic" || style == "oblique"
}

@(private)
read_baseline :: proc(L: ^lua.State, t: c.int) -> om.Text_Baseline {
	switch get_str(L, t, "baseline", "alphabetic") {
	case "middle":
		return .Middle
	case "central":
		return .Central
	case "hanging":
		return .Hanging
	case "top", "text-before-edge", "text-top":
		return .Top
	case "bottom", "text-after-edge", "text-bottom", "ideographic":
		return .Bottom
	}
	return .Alphabetic
}

@(private)
read_blend :: proc(L: ^lua.State, t: c.int) -> vg.Blend_Mode {
	return blend_mode(get_str(L, t, "blend", "normal"))
}

// A CSS / SVG blend mode name (`multiply`, `color-dodge`, ...).
@(private)
blend_mode :: proc(name: string) -> vg.Blend_Mode {
	switch name {
	case "multiply":
		return .Multiply
	case "screen":
		return .Screen
	case "overlay":
		return .Overlay
	case "darken":
		return .Darken
	case "lighten":
		return .Lighten
	case "color-dodge", "color_dodge":
		return .Color_Dodge
	case "color-burn", "color_burn":
		return .Color_Burn
	case "hard-light", "hard_light":
		return .Hard_Light
	case "soft-light", "soft_light":
		return .Soft_Light
	case "difference":
		return .Difference
	case "exclusion":
		return .Exclusion
	case "hue":
		return .Hue
	case "saturation":
		return .Saturation
	case "color":
		return .Color
	case "luminosity":
		return .Luminosity
	}
	return .Normal
}

// SVG filter effects on a group:
//   filter = {
//     { "blur", std = 4, input = "SourceAlpha", result = "b" },
//     { "offset", dx = 2, dy = 4, input = "b", result = "o" },
//     { "flood", color = "#000", opacity = 0.5, result = "f" },
//     { "composite", op = "in", input = "f", input2 = "o", result = "s" },
//     { "merge", "s", "SourceGraphic" },
//     region = { x = -0.1, y = -0.1, w = 1.2, h = 1.2, units = "objectBoundingBox" },
//   }
// Primitives: blur (std or {sx, sy}), offset, flood, composite (op = over,
// in, out, atop, xor, lighter, arithmetic with k = {k1..k4}), merge, blend
// (mode), color_matrix (type = matrix|saturate|hueRotate|luminanceToAlpha,
// values), drop_shadow (dx, dy, std, color, opacity), component_transfer
// (r, g, b, a = {type = identity|table|discrete|linear|gamma, values,
// slope, intercept, amplitude, exponent, offset}), morphology (operator =
// erode|dilate, radius), turbulence (type = turbulence|fractalNoise,
// base_frequency, octaves, seed, stitch), diffuse_lighting and
// specular_lighting (color, surface_scale, constant, exponent, light =
// {"distant", azimuth, elevation} | {"point", x, y, z} | {"spot", x, y, z,
// points_at = {x, y, z}, exponent, cone}), tile, displacement_map (scale,
// x_channel, y_channel = R|G|B|A, input2 = the map), convolve_matrix
// (kernel, order, target, divisor, bias, edge = duplicate|wrap|none,
// preserve_alpha) and image (src, fit, align). `subregion = {x, y, w, h}`
// (user units) cuts any primitive's result. Inputs default to the
// previous result. `srgb = true` computes in sRGB instead of linear RGB.
// The `shadow = { dx, dy, blur, color }` shortcut is one drop_shadow.
// `region = {...}` in the list sets the filter region (`read_filter_region`).
// `images` are the media names of image primitives (`Filter_Primitive.image`
// indexes them).
@(private)
read_filter :: proc(L: ^lua.State, t: c.int) -> (f: vg.Filter, images: []string, ok: bool) {
	prims := make([dynamic]vg.Filter_Primitive, context.temp_allocator)
	refs := make([dynamic]vg.Filter_Ref, context.temp_allocator)
	values := make([dynamic]f32, context.temp_allocator)
	image_names := make([dynamic]string, context.temp_allocator)
	names := make(map[string]u16, context.temp_allocator)

	field(L, t, "shadow")
	if lua.istable(L, -1) {
		e := lua.absindex(L, -1)
		group_fields := fields_push(L, e)
		col := read_color_field(L, e, "color", om.rgba(0, 0, 0, 128))
		col.a *= get_num(L, e, "opacity", 1)
		std := get_num(L, e, "blur", get_num(L, e, "std", 2))
		append(&prims, vg.Filter_Primitive{op = .Drop_Shadow, std = {std, std}, dx = get_num(L, e, "dx", 2), dy = get_num(L, e, "dy", 2), color = col})
		fields_pop(L, host(L), e, "shadow", group_fields)
	}
	lua.pop(L, 1)

	read_bloom_into(L, t, &prims)

	region: vg.Filter_Region
	field(L, t, "filter")
	if lua.istable(L, -1) {
		list := lua.absindex(L, -1)
		group_fields := fields_push(L, list)
		defer fields_pop(L, host(L), list, "filter", group_fields)
		field_used("srgb")
		region = read_filter_region(L, list)
		n := int(lua.rawlen(L, list))
		for i in 0 ..< n {
			lua.rawgeti(L, list, lua.Integer(i + 1))
			e := lua.absindex(L, -1)
			outer := fields_push(L, e)
			kind := text_arg(L, e)
			if kind == "" {
				kind = get_str(L, e, "op", "")
			}
			p := vg.Filter_Primitive{in1 = filter_ref(L, e, "input", names), in2 = filter_ref(L, e, "input2", names)}
			switch kind {
			case "blur", "gaussian_blur", "feGaussianBlur":
				p.op = .Gaussian_Blur
				p.std = read_std(L, e)
			case "offset", "feOffset":
				p.op = .Offset
				p.dx, p.dy = get_num(L, e, "dx", 0), get_num(L, e, "dy", 0)
			case "flood", "feFlood":
				p.op = .Flood
				p.color = read_color_field(L, e, "color", om.BLACK)
				p.color.a *= get_num(L, e, "opacity", 1)
			case "composite", "feComposite":
				p.op = .Composite
				p.composite = composite_op(get_str(L, e, "operator", get_str(L, e, "op", "over")))
				field(L, e, "k")
				if lua.istable(L, -1) {
					for j in 0 ..< 4 {
						lua.rawgeti(L, -1, lua.Integer(j + 1))
						p.k[j] = f32(lua.tonumber(L, -1))
						lua.pop(L, 1)
					}
					p.composite = .Arithmetic
				}
				lua.pop(L, 1)
			case "blend", "feBlend":
				p.op = .Blend
				p.blend = blend_mode(get_str(L, e, "mode", "normal"))
			case "color_matrix", "feColorMatrix":
				p.op = .Color_Matrix
				p.color_matrix = read_color_matrix(L, e)
			case "drop_shadow", "feDropShadow":
				p.op = .Drop_Shadow
				p.std = read_std(L, e)
				p.dx, p.dy = get_num(L, e, "dx", 2), get_num(L, e, "dy", 2)
				p.color = read_color_field(L, e, "color", om.BLACK)
				p.color.a *= get_num(L, e, "opacity", 1)
			case "merge", "feMerge":
				p.op = .Merge
				p.merge_first = u16(len(refs))
				count := int(lua.rawlen(L, e))
				for j in 2 ..= count {
					lua.rawgeti(L, e, lua.Integer(j))
					append(&refs, named_ref(string(lua.tostring(L, -1)), names))
					lua.pop(L, 1)
				}
				field(L, e, "inputs")
				if lua.istable(L, -1) {
					m := int(lua.rawlen(L, -1))
					for j in 1 ..= m {
						lua.rawgeti(L, -1, lua.Integer(j))
						append(&refs, named_ref(string(lua.tostring(L, -1)), names))
						lua.pop(L, 1)
					}
				}
				lua.pop(L, 1)
				p.merge_count = u16(len(refs)) - p.merge_first
			case "component_transfer", "feComponentTransfer":
				p.op = .Component_Transfer
				p.transfer = vg.TRANSFER_IDENTITY
				for key, k in ([4]cstring{"r", "g", "b", "a"}) {
					field(L, e, key)
					if lua.istable(L, -1) {
						primitive_fields := fields_push(L, -1)
						p.transfer[k] = read_transfer(L, lua.absindex(L, -1), &values)
						fields_pop(L, host(L), -1, "transfer", primitive_fields)
					}
					lua.pop(L, 1)
				}
			case "morphology", "feMorphology":
				p.op = .Morphology
				p.dilate = get_str(L, e, "operator", get_str(L, e, "op", "erode")) == "dilate"
				p.radius = {1, 1}
				field(L, e, "radius")
				if !lua.isnil(L, -1) {
					p.radius = read_vec2(L, -1)
				}
				lua.pop(L, 1)
			case "turbulence", "feTurbulence":
				p.op = .Turbulence
				noise := get_str(L, e, "type", "turbulence")
				p.fractal_noise = noise == "fractalNoise" || noise == "fractal_noise"
				field(L, e, "base_frequency")
				p.base_frequency = read_vec2(L, -1)
				lua.pop(L, 1)
				p.octaves = u32(max(get_num(L, e, "octaves", get_num(L, e, "num_octaves", 1)), 0))
				p.seed = i32(get_num(L, e, "seed", 0))
				field(L, e, "stitch")
				p.stitch = bool(lua.toboolean(L, -1))
				lua.pop(L, 1)
			case "diffuse_lighting", "feDiffuseLighting", "specular_lighting", "feSpecularLighting":
				specular := kind == "specular_lighting" || kind == "feSpecularLighting"
				p.op = .Specular_Lighting if specular else .Diffuse_Lighting
				p.color = read_color_field(L, e, "color", om.WHITE)
				p.surface_scale = get_num(L, e, "surface_scale", 1)
				p.light_constant = get_num(L, e, "constant", 1)
				p.specular_exponent = clamp(get_num(L, e, "exponent", 1), 1, 128)
				field(L, e, "light")
				if lua.istable(L, -1) {
					primitive_fields := fields_push(L, -1)
					p.light = read_light(L, lua.absindex(L, -1))
					fields_pop(L, host(L), -1, "light", primitive_fields)
				} else {
					p.light = {kind = .Distant, elevation = 45}
				}
				lua.pop(L, 1)
			case "tile", "feTile":
				p.op = .Tile
			case "displacement_map", "feDisplacementMap":
				p.op = .Displacement_Map
				p.scale = get_num(L, e, "scale", 0)
				for key, k in ([2]cstring{"x_channel", "y_channel"}) {
					switch get_str(L, e, key, "A") {
					case "R", "r":
						p.channels[k] = 0
					case "G", "g":
						p.channels[k] = 1
					case "B", "b":
						p.channels[k] = 2
					case:
						p.channels[k] = 3
					}
				}
			case "convolve_matrix", "feConvolveMatrix":
				p.op = .Convolve_Matrix
				read_convolve(L, e, &p, &values)
			case "image", "feImage":
				p.op = .Image
				p.image = u16(len(image_names))
				append(&image_names, get_str(L, e, "src", ""))
				switch read_fit(L, e) {
				case .Contain:
					p.image_fit = .Meet
				case .Cover:
					p.image_fit = .Slice
				case .Fill:
					p.image_fit = .None
				}
				p.image_align = read_align(L, e).? or_else {0.5, 0.5}
			case:
				field_log = outer
				if ctx := host(L).ctx; ctx != nil {
					om.report(ctx, .Error, {code = .Invalid_Value, name = "filter primitive", a = kind, b = "blur, offset, flood, composite, merge, blend, color_matrix, drop_shadow, component_transfer, morphology, turbulence, diffuse_lighting, specular_lighting, tile, displacement_map, convolve_matrix or image"})
				}
				lua.pop(L, 1)
				continue
			}
			field(L, e, "subregion")
			if lua.istable(L, -1) {
				r := lua.absindex(L, -1)
				primitive_fields := fields_push(L, r)
				sub := [4]f32{get_num(L, r, "x", 0), get_num(L, r, "y", 0), get_num(L, r, "w", 0), get_num(L, r, "h", 0)}
				fields_pop(L, host(L), r, "subregion", primitive_fields)
				for k in 0 ..< 4 {
					lua.rawgeti(L, r, lua.Integer(k + 1))
					if lua.isnumber(L, -1) {
						sub[k] = f32(lua.tonumber(L, -1))
					}
					lua.pop(L, 1)
				}
				p.subregion = {sub[0], sub[1], sub[2], sub[3]}
				p.has_subregion = true
			}
			lua.pop(L, 1)
			if result := get_str(L, e, "result", ""); result != "" {
				names[result] = u16(len(prims))
			}
			fields_pop(L, host(L), e, strings.concatenate({"filter ", kind}, context.temp_allocator), outer)
			append(&prims, p)
			lua.pop(L, 1)
		}
	}
	// `srgb = true` in the filter list (as documented), or on the group.
	srgb := false
	if lua.istable(L, -1) {
		field(L, -1, "srgb")
		srgb = bool(lua.toboolean(L, -1))
		lua.pop(L, 1)
	}
	lua.pop(L, 1)
	if len(prims) == 0 {
		return {}, nil, false
	}
	field(L, t, "srgb")
	srgb ||= bool(lua.toboolean(L, -1))
	lua.pop(L, 1)
	return {primitives = prims[:], merge_refs = refs[:], srgb = srgb, region = region, values = values[:]}, image_names[:], true
}

// `bloom = { threshold = 0.65, intensity = 0.6, radius = 12 }` (or `bloom = 12`):
// extracts pixels above `threshold`, blurs them by `radius`, and adds them
// back scaled by `intensity`.
@(private)
read_bloom_into :: proc(L: ^lua.State, t: c.int, prims: ^[dynamic]vg.Filter_Primitive) -> bool {
	field(L, t, "bloom")
	defer lua.pop(L, 1)
	threshold := f32(0.65)
	intensity := f32(0.6)
	radius := f32(0)
	if lua.type(L, -1) == .NUMBER {
		radius = max(f32(lua.tonumber(L, -1)), 0)
	} else if lua.istable(L, -1) {
		e := lua.absindex(L, -1)
		bloom_fields := fields_push(L, e)
		threshold = clamp(get_num(L, e, "threshold", 0.65), 0, 0.999)
		intensity = max(get_num(L, e, "intensity", 0.6), 0)
		radius = max(get_num(L, e, "radius", 12), 0)
		fields_pop(L, host(L), e, "bloom", bloom_fields)
	} else {
		return false
	}
	if radius <= 0 || intensity <= 0 {
		return false
	}
	base_ref := vg.Filter_Ref{kind = .Source_Graphic} if len(prims) == 0 else vg.Filter_Ref{kind = .Result, index = u16(len(prims) - 1)}
	// What passes the threshold, as light: slope (c - threshold) on the
	// premultiplied colour and alpha alike (an arithmetic composite works
	// on premultiplied values; a component transfer would divide by alpha
	// first, so a faint glow over nothing would bloom as if it were bright).
	slope := 1.0 / max(1.0 - threshold, 1e-3)
	append(
		prims,
		vg.Filter_Primitive{
			op = .Composite,
			in1 = base_ref,
			in2 = base_ref,
			composite = .Arithmetic,
			k = {0, slope, 0, -threshold * slope},
		},
		vg.Filter_Primitive{
			op = .Gaussian_Blur,
			in1 = {kind = .Previous},
			std = {radius, radius},
		},
		vg.Filter_Primitive{
			op = .Composite,
			in1 = base_ref,
			in2 = {kind = .Previous},
			composite = .Arithmetic,
			k = {0, 1, intensity, 0},
		},
	)
	return true
}

@(private)
read_bloom_filter :: proc(L: ^lua.State, t: c.int) -> (f: vg.Filter, ok: bool) {
	prims := make([dynamic]vg.Filter_Primitive, context.temp_allocator)
	if !read_bloom_into(L, t, &prims) {
		return {}, false
	}
	return {primitives = prims[:]}, true
}

// A component transfer function table: `{type = "table", values = {...}}`.
@(private)
read_transfer :: proc(L: ^lua.State, t: c.int, values: ^[dynamic]f32) -> vg.Transfer_Function {
	fn := vg.TRANSFER_IDENTITY
	switch kind := get_str(L, t, "type", "identity"); kind {
	case "identity":
	case "table", "discrete":
		fn.kind = .Table if kind == "table" else .Discrete
		fn.first = u16(len(values))
		field(L, t, "values")
		if lua.istable(L, -1) {
			for j in 1 ..= int(lua.rawlen(L, -1)) {
				lua.rawgeti(L, -1, lua.Integer(j))
				append(values, f32(lua.tonumber(L, -1)))
				lua.pop(L, 1)
			}
		}
		lua.pop(L, 1)
		fn.count = u16(len(values)) - fn.first
	case "linear":
		fn.kind = .Linear
		fn.slope = get_num(L, t, "slope", 1)
		fn.intercept = get_num(L, t, "intercept", 0)
	case "gamma":
		fn.kind = .Gamma
		fn.amplitude = get_num(L, t, "amplitude", 1)
		fn.exponent = get_num(L, t, "exponent", 1)
		fn.offset = get_num(L, t, "offset", 0)
	case:
		bad_string(L, "transfer function type", kind, "identity, table, discrete, linear or gamma")
	}
	return fn
}

// A light: `{"distant", azimuth = .., elevation = ..}`, `{"point", x, y, z}`
// or `{"spot", x, y, z, points_at = {x, y, z}, exponent, cone}`.
@(private)
read_light :: proc(L: ^lua.State, t: c.int) -> (l: vg.Filter_Light) {
	kind := text_arg(L, t)
	if kind == "" {
		kind = get_str(L, t, "type", "distant")
	}
	switch kind {
	case "distant":
		l.kind = .Distant
		l.azimuth = get_num(L, t, "azimuth", 0)
		l.elevation = get_num(L, t, "elevation", 0)
		return
	case "point":
		l.kind = .Point
	case "spot":
		l.kind = .Spot
	case:
		bad_string(L, "light type", kind, "distant, point or spot")
	}
	l.position = {get_num(L, t, "x", 0), get_num(L, t, "y", 0), get_num(L, t, "z", 0)}
	field(L, t, "points_at")
	if lua.istable(L, -1) {
		at := lua.absindex(L, -1)
		for k in 0 ..< 3 {
			lua.rawgeti(L, at, lua.Integer(k + 1))
			l.points_at[k] = f32(lua.tonumber(L, -1))
			lua.pop(L, 1)
		}
	}
	lua.pop(L, 1)
	l.spot_exponent = max(get_num(L, t, "exponent", 1), 0)
	l.cone_angle, l.has_cone = get_opt_num(L, t, "cone")
	return
}

// convolve_matrix: `kernel` (row-major), `order` (n or {columns, rows};
// by default 3, or the kernel's side when it is square), `target`
// ({x, y}, the center by default), `divisor` (the kernel's sum, or 1),
// `bias`, `edge` and `preserve_alpha`.
@(private)
read_convolve :: proc(L: ^lua.State, e: c.int, p: ^vg.Filter_Primitive, values: ^[dynamic]f32) {
	p.kernel_first = u16(len(values))
	sum: f32
	field(L, e, "kernel")
	if lua.istable(L, -1) {
		for j in 1 ..= int(lua.rawlen(L, -1)) {
			lua.rawgeti(L, -1, lua.Integer(j))
			v := f32(lua.tonumber(L, -1))
			append(values, v)
			sum += v
			lua.pop(L, 1)
		}
	}
	lua.pop(L, 1)
	p.kernel_count = u16(len(values)) - p.kernel_first
	side := int(math.round(math.sqrt(f32(p.kernel_count))))
	order := [2]f32{3, 3} if side * side != int(p.kernel_count) else {f32(side), f32(side)}
	field(L, e, "order")
	if !lua.isnil(L, -1) {
		order = read_vec2(L, -1)
	}
	lua.pop(L, 1)
	p.order = {u8(clamp(order.x, 0, 255)), u8(clamp(order.y, 0, 255))}
	target := [2]f32{f32(p.order.x / 2), f32(p.order.y / 2)}
	field(L, e, "target")
	if !lua.isnil(L, -1) {
		target = read_vec2(L, -1)
	}
	lua.pop(L, 1)
	p.target = {u8(clamp(target.x, 0, 255)), u8(clamp(target.y, 0, 255))}
	p.divisor = get_num(L, e, "divisor", sum if sum != 0 else 1)
	p.bias = get_num(L, e, "bias", 0)
	switch edge := get_str(L, e, "edge", "duplicate"); edge {
	case "duplicate":
		p.edge = .Duplicate
	case "wrap":
		p.edge = .Wrap
	case "none":
		p.edge = .None
	case:
		bad_string(L, "convolve edge", edge, "duplicate, wrap or none")
	}
	field(L, e, "preserve_alpha")
	p.preserve_alpha = bool(lua.toboolean(L, -1))
	lua.pop(L, 1)
}

// `region = { x, y, w, h, units = "userSpaceOnUse"|"objectBoundingBox" }`
// in a filter list: the SVG filter region, which cuts what the filter sees
// and makes. Units default to objectBoundingBox (fractions of the group's
// bounding box) and the rectangle to SVG's -10% / 120%; without `region`
// the filter covers the whole frame.
@(private)
read_filter_region :: proc(L: ^lua.State, list: c.int) -> (r: vg.Filter_Region) {
	field(L, list, "region")
	defer lua.pop(L, 1)
	if !lua.istable(L, -1) {
		return
	}
	e := lua.absindex(L, -1)
	filter_fields := fields_push(L, e)
	defer fields_pop(L, host(L), e, "region", filter_fields)
	r = vg.FILTER_REGION_DEFAULT
	switch units := get_str(L, e, "units", "objectBoundingBox"); units {
	case "userSpaceOnUse", "user":
		r.units = .User_Space_On_Use
	case "objectBoundingBox", "bbox":
	case:
		bad_string(L, "filter region units", units, "userSpaceOnUse or objectBoundingBox")
	}
	r.x = get_num(L, e, "x", r.x)
	r.y = get_num(L, e, "y", r.y)
	r.w = get_num(L, e, "w", get_num(L, e, "width", r.w))
	r.h = get_num(L, e, "h", get_num(L, e, "height", r.h))
	return
}

@(private)
filter_ref :: proc(L: ^lua.State, t: c.int, key: cstring, names: map[string]u16) -> vg.Filter_Ref {
	name := get_str(L, t, key, "")
	if name == "" {
		return {kind = .Previous}
	}
	return named_ref(name, names)
}

@(private)
named_ref :: proc(name: string, names: map[string]u16) -> vg.Filter_Ref {
	switch name {
	case "SourceGraphic", "source":
		return {kind = .Source_Graphic}
	case "SourceAlpha", "alpha":
		return {kind = .Source_Alpha}
	}
	if i, ok := names[name]; ok {
		return {kind = .Result, index = i}
	}
	return {kind = .Previous}
}

@(private)
read_std :: proc(L: ^lua.State, t: c.int) -> [2]f32 {
	field(L, t, "std")
	defer lua.pop(L, 1)
	if lua.istable(L, -1) {
		v := read_vec2(L, -1)
		return {v.x, v.y}
	}
	s := f32(lua.tonumber(L, -1)) if lua.isnumber(L, -1) else get_num(L, t, "blur", 0)
	return {s, s}
}

@(private)
read_color_field :: proc(L: ^lua.State, t: c.int, key: cstring, def: om.Color) -> om.Color {
	field(L, t, key)
	defer lua.pop(L, 1)
	if col, ok := read_paint(L, -1, nil).(om.Color); ok {
		return col
	}
	return def
}

@(private)
composite_op :: proc(name: string) -> vg.Composite_Operator {
	switch name {
	case "in":
		return .In
	case "out":
		return .Out
	case "atop":
		return .Atop
	case "xor":
		return .Xor
	case "lighter":
		return .Lighter
	case "arithmetic":
		return .Arithmetic
	}
	return .Over
}

@(private)
read_color_matrix :: proc(L: ^lua.State, t: c.int) -> [20]f32 {
	kind := get_str(L, t, "type", "matrix")
	field(L, t, "values")
	defer lua.pop(L, 1)
	switch kind {
	case "saturate":
		v := f32(lua.tonumber(L, -1)) if lua.isnumber(L, -1) else 1
		return vg.color_matrix_saturate(v).m
	case "hueRotate", "hue_rotate":
		v := f32(lua.tonumber(L, -1)) if lua.isnumber(L, -1) else 0
		return vg.color_matrix_hue_rotate(v).m
	case "luminanceToAlpha", "luminance_to_alpha":
		return vg.color_matrix_luminance_to_alpha().m
	}
	m := vg.COLOR_MATRIX_IDENTITY.m
	if lua.istable(L, -1) && lua.rawlen(L, -1) >= 20 {
		for i in 0 ..< 20 {
			lua.rawgeti(L, -1, lua.Integer(i + 1))
			m[i] = f32(lua.tonumber(L, -1))
			lua.pop(L, 1)
		}
	}
	return m
}


// svg{ src = "logo.svg" | markup = [[<svg>...</svg>]], x, y, w, h, fit,
//      align, preserve_aspect_ratio, opacity,
//      overrides = { wing = { transform = rotate(a, {cx, cy}), opacity = 0.5,
//                             fill = "#f00", stroke = "#000", visible = false } } }
// (also svg(f, {...})). Draws an SVG document into the box like an image;
// overrides change the elements with that id (every instance). An override
// transform applies in the element's own coordinates (see svg_bbox).
@(private)
l_svg :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	ctx := render_ctx(L, s)
	t: c.int = 2 if lua.istable(L, 2) else 1
	lua.L_checktype(L, t, i32(lua.Type.TABLE))
	fields_begin(L, t)
	overrides, _ := read_overrides(L, t)
	om.svg(
		ctx,
		{
			src = get_str(L, t, "src", ""),
			markup = get_str(L, t, "markup", ""),
			x = get_num(L, t, "x", 0),
			y = get_num(L, t, "y", 0),
			w = get_num(L, t, "w", get_num(L, t, "width", 0)),
			h = get_num(L, t, "h", get_num(L, t, "height", 0)),
			fit = read_fit(L, t),
			align = read_align(L, t),
			opacity = get_maybe(L, t, "opacity"),
			overrides = overrides[:],
		},
	)
	fields_end(L, s, t, "svg")
	return 0
}

// The `overrides` table of an svg{} / lottie{} call: `{ [key] = { transform,
// opacity, fill, stroke, visible, text } }`, keyed by element id or layer
// name (`id` holds the key; temp allocated). `texts` (Lottie text layers'
// strings) parallels the overrides.
@(private)
read_overrides :: proc(L: ^lua.State, t: c.int) -> (list_out: []om.Svg_Override, texts: []Maybe(string)) {
	overrides := make([dynamic]om.Svg_Override, context.temp_allocator)
	text_list := make([dynamic]Maybe(string), context.temp_allocator)
	field(L, t, "overrides")
	defer lua.pop(L, 1)
	if !lua.istable(L, -1) {
		return nil, nil
	}
	list := lua.absindex(L, -1)
	for key in sorted_keys(L, list) {
		push_key(L, list, key)
		if lua.istable(L, -1) {
			e := lua.absindex(L, -1)
			outer := fields_push(L, e)
			o := om.Svg_Override {
				id = key,
			}
			field(L, e, "transform")
			if lua.istable(L, -1) || lua.type(L, -1) == .STRING {
				o.transform = read_transform(L, -1)
			}
			lua.pop(L, 1)
			o.opacity = get_maybe(L, e, "opacity")
			o.fill = override_color(L, e, "fill")
			o.stroke = override_color(L, e, "stroke")
			field(L, e, "visible")
			if lua.type(L, -1) == .BOOLEAN {
				o.visible = bool(lua.toboolean(L, -1))
			}
			lua.pop(L, 1)
			txt: Maybe(string)
			field(L, e, "text")
			if lua.type(L, -1) == .STRING || lua.type(L, -1) == .NUMBER {
				txt = strings.clone(string(lua.tostring(L, -1)), context.temp_allocator)
			}
			lua.pop(L, 1)
			fields_pop(L, host(L), e, "overrides entry", outer)
			append(&overrides, o)
			append(&text_list, txt)
		}
		lua.pop(L, 1)
	}
	return overrides[:], text_list[:]
}

// An override's fill / stroke: a color string or table (SVG color names
// included); anything else is an error.
@(private)
override_color :: proc(L: ^lua.State, t: c.int, key: cstring) -> Maybe(om.Color) {
	field(L, t, key)
	defer lua.pop(L, 1)
	if lua.isnoneornil(L, -1) {
		return nil
	}
	if lua.type(L, -1) == .STRING {
		str := string(lua.tostring(L, -1))
		if col, ok := vg.css_color_parse(str); ok {
			return col
		}
	}
	if col, ok := read_paint(L, -1, nil).(om.Color); ok {
		return col
	}
	str := string(lua.tostring(L, -1)) if lua.type(L, -1) == .STRING else "(not a string)"
	bad_string(L, "override color", str, "a CSS color")
	return nil
}

// svg_bbox{ src = "logo.svg" | markup = ..., id = "wing" } -> {x, y, w, h}
// (or nil): the element's bounding box in its own coordinates, the space
// override transforms use (e.g. rotate about its center).
@(private)
l_svg_bbox :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	ctx := render_ctx(L, s)
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	b, ok := om.svg_local_bbox(ctx, get_str(L, 1, "src", ""), get_str(L, 1, "markup", ""), get_str(L, 1, "id", ""))
	if !ok {
		lua.pushnil(L)
		return 1
	}
	keys := [4]cstring{"x", "y", "w", "h"}
	lua.createtable(L, 0, 4)
	for v, k in ([4]f32{b.x, b.y, b.w, b.h}) {
		lua.pushnumber(L, lua.Number(v))
		lua.setfield(L, -2, keys[k])
	}
	return 1
}

// lottie{ src = "anim.json" | data = [[{...}]], x, y, w, h, fit, align,
//         opacity, frame = n | time = s | speed = 1, offset = 0, loop = true,
//         overrides = { ["layer name"] = { transform, opacity, fill, stroke,
//                                          visible, text } } }
// (also lottie(f, {...})). Draws a Lottie animation into the box like an
// image, at the frame the clock maps to: `frame` (the animation's own,
// from its in point), else `time` seconds into it, else the clock of `f`
// (or of the render call: the scene's frame inside a scene) times `speed`
// plus `offset` seconds, so by default it plays from the start of the
// scene (or sequence) at its native rate. `loop = false` holds the last
// frame. Overrides change the layers with that name (`nm`), as svg{}'s do
// elements; `text` replaces a text layer's string.
@(private)
l_lottie :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	ctx := render_ctx(L, s)
	f := s.frame
	t: c.int = 1
	if lua.gettop(L) >= 2 {
		f = read_frame(L, ctx, 1)
		t = 2
	}
	lua.L_checktype(L, t, i32(lua.Type.TABLE))
	fields_begin(L, t)
	loop: Maybe(bool)
	field(L, t, "loop")
	if lua.type(L, -1) == .BOOLEAN {
		loop = bool(lua.toboolean(L, -1))
	}
	lua.pop(L, 1)
	svg_overrides, texts := read_overrides(L, t)
	overrides := make([]om.Lottie_Override, len(svg_overrides), context.temp_allocator)
	for o, i in svg_overrides {
		overrides[i] = {o.id, o.transform, o.opacity, o.fill, o.stroke, o.visible, texts[i]}
	}
	om.lottie(
		ctx,
		f,
		{
			src = get_str(L, t, "src", ""),
			data = get_str(L, t, "data", ""),
			x = get_num(L, t, "x", 0),
			y = get_num(L, t, "y", 0),
			w = get_num(L, t, "w", get_num(L, t, "width", 0)),
			h = get_num(L, t, "h", get_num(L, t, "height", 0)),
			fit = read_fit(L, t),
			align = read_align(L, t),
			opacity = get_maybe(L, t, "opacity"),
			frame = get_maybe(L, t, "frame"),
			time = get_maybe(L, t, "time"),
			speed = get_maybe(L, t, "speed"),
			offset = get_num(L, t, "offset", 0),
			loop = loop,
			overrides = overrides,
		},
	)
	fields_end(L, s, t, "lottie")
	return 0
}

// lottie_info("anim.json") or lottie_info{ src = ... | data = ... } ->
// { width, height, fps, frames, duration, markers = { {name, time, duration}, ... } }
// (or nil when missing): e.g. to size a box or a scene to the animation.
@(private)
l_lottie_info :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	ctx := render_ctx(L, s)
	src, data: string
	if lua.type(L, 1) == .STRING {
		src = string(lua.tostring(L, 1))
	} else {
		lua.L_checktype(L, 1, i32(lua.Type.TABLE))
		src = get_str(L, 1, "src", "")
		data = get_str(L, 1, "data", "")
	}
	doc, ok := om.lottie_info(ctx, src, data)
	if !ok {
		lua.pushnil(L)
		return 1
	}
	lua.createtable(L, 0, 6)
	set_num(L, "width", doc.width)
	set_num(L, "height", doc.height)
	set_num(L, "fps", doc.fps)
	set_num(L, "frames", doc.out_frame - doc.in_frame)
	set_num(L, "duration", vglottie.duration(doc))
	lua.createtable(L, i32(len(doc.markers)), 0)
	for m, i in doc.markers {
		lua.createtable(L, 0, 3)
		lua.pushstring(L, strings.clone_to_cstring(m.name, context.temp_allocator))
		lua.setfield(L, -2, "name")
		set_num(L, "time", (m.frame - doc.in_frame) / doc.fps)
		set_num(L, "duration", m.duration / doc.fps)
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	lua.setfield(L, -2, "markers")
	return 1
}
