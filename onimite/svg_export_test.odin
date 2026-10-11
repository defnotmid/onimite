package onimite

import "core:math"
import "core:strings"
import "core:testing"
import vg "deps:ovg"

@(private = "file")
STAR :: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20">
	<defs><linearGradient id="g"><stop offset="0" stop-color="#ff0000"/><stop offset="1" stop-color="#0000ff"/></linearGradient></defs>
	<rect id="body" width="20" height="20" fill="url(#g)"/>
	<circle id="dot" cx="10" cy="10" r="4" fill="#ffffff"/>
</svg>`

// Every node kind the exporter maps, drawn over a white background.
@(private = "file")
render_export_scene :: proc(f: Frame, ctx: ^Context) {
	stops := []vg.Gradient_Stop{{0, Color{1, 0.5, 0, 1}}, {1, Color{0, 0.4, 1, 1}}}
	rect(ctx, {x = 10, y = 10, w = 100, h = 60, rx = 12, fill = Linear_Gradient{x1 = 0, y1 = 0, x2 = 1, y2 = 0, stops = stops, space = {units = .Bounding_Box}}})
	circle(ctx, {cx = 170, cy = 40, r = 30, fill = Radial_Gradient{cx = 170, cy = 40, r = 30, focal = Vec2{160, 30}, stops = stops}, stroke = {paint = BLACK, width = 4, dash = {8, 4}}})
	path(ctx, {points = {{220, 10}, {300, 40}, {220, 70}}, closed = true, fill = Color{0.2, 0.7, 0.3, 1}, fill_opacity = 0.5})
	line(ctx, {x1 = 10, y1 = 90, x2 = 300, y2 = 90, stroke = {paint = Color{0.5, 0, 0.5, 1}, width = 3, cap = .Round}})
	// A pattern of dots.
	tile := pattern_begin(ctx)
	circle(ctx, {cx = 5, cy = 5, r = 3, fill = Color{0, 0, 0.6, 1}})
	group_end(ctx)
	rect(ctx, {x = 10, y = 100, w = 90, h = 50, fill = Pattern{content = tile, w = 10, h = 10}})
	// A masked, transformed group (a luminance mask: a white circle).
	{
		group(ctx, {transform = translate(110, 100), masked = true})
		mask_begin(ctx)
		circle(ctx, {cx = 25, cy = 25, r = 22, fill = WHITE})
		group_end(ctx)
		rect(ctx, {x = 0, y = 0, w = 50, h = 50, fill = Color{0.9, 0.1, 0.1, 1}})
	}
	// A filtered group (offset drop shadow) and a multiply blend.
	{
		prims := [?]vg.Filter_Primitive{{op = .Drop_Shadow, dx = 3, dy = 3, std = {2, 2}, color = Color{0, 0, 0, 0.6}}}
		group(ctx, {filter = vg.Filter{primitives = prims[:], srgb = true}})
		rect(ctx, {x = 180, y = 100, w = 40, h = 40, fill = Color{1, 0.8, 0, 1}})
	}
	{
		group(ctx, {blend = .Multiply, clip_path = "M240 100 h60 v50 h-60 Z", opacity = 0.8})
		circle(ctx, {cx = 270, cy = 125, r = 30, fill = Color{0, 0.8, 0.8, 1}})
	}
	text(ctx, {text = "Hi", x = 20, y = 190, size = 28, fill = BLACK, spans = {{text = " there", fill = Color{0.8, 0, 0, 1}}}})
	svg(ctx, {markup = STAR, x = 200, y = 160, w = 30, h = 30, overrides = {{id = "dot", fill = Color{0, 0, 0, 1}}}})
}

@(private = "file")
render_reimport :: proc(f: Frame, ctx: ^Context) {
	svg(ctx, {src = "frame.svg", x = 0, y = 0, w = 320, h = 200})
}

@(test)
test_svg_export_round_trip :: proc(t: ^testing.T) {
	@(static) scenes: [1]Scene
	@(static) back: [1]Scene
	scenes = [1]Scene{{name = "Export", duration = Frames(1), render = render_export_scene}}
	back = [1]Scene{{name = "Back", duration = Frames(1), render = render_reimport}}
	v := Video{width = 320, height = 200, fps = 30, background = WHITE, scenes = scenes[:]}
	media: Media
	media_init(&media)
	defer media_destroy(&media)
	r: Renderer
	testing.expect_value(t, renderer_init(&r, &v, &media), Error.None)
	defer renderer_destroy(&r)
	want := make([]u8, 320 * 200 * 4)
	defer delete(want)
	copy(want, render_frame(&r, 0))

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	svg_export(&r, &b)
	doc := strings.to_string(b)
	for part in ([]string{"<linearGradient", "<radialGradient", "<pattern", "<mask", "<filter", "<feDropShadow", "mix-blend-mode:multiply", "<clipPath", "stroke-dasharray", "<polygon", "<tspan", `id="s`, "fill:#000000"}) {
		testing.expectf(t, strings.contains(doc, part), "no %s in the export", part)
	}

	// Drawn back through the SVG import, it matches the frame.
	testing.expect_value(t, media_load_test_files(&media, {"frame.svg", doc}), Error.None)
	v2 := Video{width = 320, height = 200, fps = 30, background = TRANSPARENT, scenes = back[:]}
	r2: Renderer
	testing.expect_value(t, renderer_init(&r2, &v2, &media), Error.None)
	defer renderer_destroy(&r2)
	got := render_frame(&r2, 0)
	sum: f64
	for k in 0 ..< len(want) {
		d := f64(want[k]) - f64(got[k])
		sum += d * d
	}
	mse := sum / f64(len(want))
	psnr := 10 * math.log10(255 * 255 / mse) if mse > 0 else 99
	testing.expectf(t, psnr > 40, "round trip PSNR %.1f dB", psnr)
}

@(private = "file")
render_filters_scene :: proc(f: Frame, ctx: ^Context) {
	@(static) values := [?]f32{0.2, 1, 0, -1, 0, -1, 5, -1, 0, -1, 0}
	region :: proc(x, y, w, h: f32) -> vg.Filter_Region {
		return {units = .User_Space_On_Use, x = x, y = y, w = w, h = h}
	}
	{
		prims := [?]vg.Filter_Primitive{{op = .Morphology, radius = {3, 1}, dilate = true}, {op = .Component_Transfer}}
		prims[1].transfer = vg.TRANSFER_IDENTITY
		prims[1].transfer[0] = {kind = .Table, first = 0, count = 2}
		prims[1].transfer[2] = {kind = .Gamma, amplitude = 1, exponent = 0.5}
		group(ctx, {filter = vg.Filter{primitives = prims[:], region = region(0, 0, 100, 100), values = values[:]}})
		rect(ctx, {x = 30, y = 30, w = 40, h = 40, fill = Color{0.8, 0.4, 0.2, 1}})
	}
	{
		prims := [?]vg.Filter_Primitive {
			{op = .Gaussian_Blur, std = {2, 2}, in1 = {kind = .Source_Alpha}},
			{op = .Specular_Lighting, color = WHITE, surface_scale = 3, light_constant = 1, specular_exponent = 10, light = {kind = .Spot, position = {150, 20, 60}, points_at = {150, 50, 0}, spot_exponent = 1, cone_angle = 40, has_cone = true}},
			{op = .Convolve_Matrix, order = {3, 3}, target = {1, 1}, kernel_first = 2, kernel_count = 9, divisor = 1},
		}
		group(ctx, {filter = vg.Filter{primitives = prims[:], region = region(100, 0, 100, 100), values = values[:]}})
		circle(ctx, {cx = 150, cy = 50, r = 25, fill = BLACK})
	}
	{
		prims := [?]vg.Filter_Primitive{{op = .Turbulence, base_frequency = {0.05, 0.05}, octaves = 2, seed = 5, fractal_noise = true}}
		group(ctx, {filter = vg.Filter{primitives = prims[:], region = region(200, 0, 100, 100)}})
		rect(ctx, {x = 210, y = 10, w = 2, h = 2, fill = BLACK})
	}
}

// The later filter primitives survive the export: drawn back through the
// SVG import, the frame matches.
@(test)
test_svg_export_filters :: proc(t: ^testing.T) {
	@(static) scenes: [1]Scene
	@(static) back: [1]Scene
	scenes = [1]Scene{{name = "Filters", duration = Frames(1), render = render_filters_scene}}
	back = [1]Scene{{name = "Back", duration = Frames(1), render = proc(f: Frame, ctx: ^Context) {
				svg(ctx, {src = "filters.svg", x = 0, y = 0, w = 300, h = 100})
			}}}
	v := Video{width = 300, height = 100, fps = 30, background = WHITE, scenes = scenes[:]}
	media: Media
	media_init(&media)
	defer media_destroy(&media)
	r: Renderer
	testing.expect_value(t, renderer_init(&r, &v, &media), Error.None)
	defer renderer_destroy(&r)
	want := make([]u8, 300 * 100 * 4)
	defer delete(want)
	copy(want, render_frame(&r, 0))
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	svg_export(&r, &b)
	doc := strings.to_string(b)
	for part in ([]string{"<feMorphology", "<feComponentTransfer", "<feFuncR", "<feSpecularLighting", "<feSpotLight", "<feConvolveMatrix", "<feTurbulence"}) {
		testing.expectf(t, strings.contains(doc, part), "no %s in the export", part)
	}
	testing.expect_value(t, media_load_test_files(&media, {"filters.svg", doc}), Error.None)
	v2 := Video{width = 300, height = 100, fps = 30, background = TRANSPARENT, scenes = back[:]}
	r2: Renderer
	testing.expect_value(t, renderer_init(&r2, &v2, &media), Error.None)
	defer renderer_destroy(&r2)
	got := render_frame(&r2, 0)
	sum: f64
	for k in 0 ..< len(want) {
		d := f64(want[k]) - f64(got[k])
		sum += d * d
	}
	mse := sum / f64(len(want))
	psnr := 10 * math.log10(255 * 255 / mse) if mse > 0 else 99
	testing.expectf(t, psnr > 40, "round trip PSNR %.1f dB", psnr)
}
