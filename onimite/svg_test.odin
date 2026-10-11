package onimite

import "core:strings"
import "core:testing"
import vg "deps:ovg"

@(private = "file")
SVG_TEST :: `<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20" viewBox="0 0 40 20">
	<rect id="left" width="20" height="20" fill="#ff0000"/>
	<rect id="right" x="20" width="20" height="20" fill="#0000ff"/>
</svg>`

@(private = "file")
render_svg_scene :: proc(f: Frame, ctx: ^Context) {
	// From the media, scaled x2 into a box; from markup, with overrides.
	svg(ctx, {src = "two.svg", x = 0, y = 0, w = 80, h = 40})
	svg(ctx, {markup = SVG_TEST, x = 100, y = 0, w = 80, h = 40, overrides = {{id = "left", fill = Color{0, 1, 0, 1}}, {id = "right", visible = false}, {id = "nope"}}})
	// A group filter cut by an objectBoundingBox region (the rect's box).
	prims := [?]vg.Filter_Primitive{{op = .Flood, color = Color{0, 0, 0, 1}}}
	group(ctx, {filter = vg.Filter{primitives = prims[:], srgb = true, region = {units = .Object_Bounding_Box, x = 0, y = 0, w = 1, h = 1}}})
	rect(ctx, {x = 200, y = 10, w = 20, h = 20, fill = Color{1, 1, 1, 1}})
}

@(test)
test_svg_node :: proc(t: ^testing.T) {
	@(static) scenes: [1]Scene
	scenes = [1]Scene{{name = "Svg", duration = Frames(1), render = render_svg_scene}}
	v := Video{width = 240, height = 60, fps = 30, background = WHITE, scenes = scenes[:]}
	media: Media
	media_init(&media)
	defer media_destroy(&media)
	testing.expect_value(t, media_load_test_files(&media, {"two.svg", SVG_TEST}), Error.None)
	r: Renderer
	testing.expect_value(t, renderer_init(&r, &v, &media), Error.None)
	defer renderer_destroy(&r)

	px := render_frame(&r, 0)
	at :: proc(px: []u8, x, y: int) -> [4]u8 {
		i := (y * 240 + x) * 4
		return {px[i], px[i + 1], px[i + 2], px[i + 3]}
	}
	testing.expect_value(t, at(px, 20, 20), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, at(px, 60, 20), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, at(px, 120, 20), [4]u8{0, 255, 0, 255})
	testing.expect_value(t, at(px, 160, 20), [4]u8{255, 255, 255, 255})
	testing.expect_value(t, at(px, 210, 20), [4]u8{0, 0, 0, 255})
	testing.expect_value(t, at(px, 230, 20), [4]u8{255, 255, 255, 255})
	testing.expect_value(t, at(px, 210, 5), [4]u8{255, 255, 255, 255})

	// The unknown override id is reported; the markup is parsed once.
	unknown := false
	for d in r.ctx.diagnostics {
		if strings.contains(diagnostic_message(d, context.temp_allocator), "no element with id \"nope\"") {
			unknown = true
		}
	}
	testing.expect(t, unknown)
	render_frame(&r, 0)
	testing.expect_value(t, len(r.ctx.svgs.docs), 1)
}
