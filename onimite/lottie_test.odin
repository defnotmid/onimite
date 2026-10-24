package onimite

import "core:strings"
import "core:testing"

// A 2 s animation at 10 fps (20 frames): a red square moving from x = 0 to
// x = 20 over its first second, then holding; and a camera (warned).
@(private = "file")
LOTTIE_TEST :: `{"v": "5.7.0", "fr": 10, "ip": 0, "op": 20, "w": 40, "h": 20, "layers": [
	{"ty": 13, "ind": 1, "ip": 0, "op": 20, "ks": {}},
	{"ty": 1, "ind": 2, "ip": 0, "op": 20, "sc": "#ff0000", "sw": 20, "sh": 20,
	 "ks": {"p": {"a": 1, "k": [{"t": 0, "s": [0, 0]}, {"t": 10, "s": [20, 0]}]}}}]}`

@(private = "file")
render_lottie_scene :: proc(f: Frame, ctx: ^Context) {
	// From the media at the scene's clock, scaled x2; from data, at a fixed
	// frame; reversed at half speed, holding at the end.
	lottie(ctx, f, {src = "move.json", x = 0, y = 0, w = 80})
	lottie(ctx, f, {data = LOTTIE_TEST, x = 0, y = 40, frame = 5})
	lottie(ctx, f, {data = LOTTIE_TEST, x = 0, y = 60, speed = -0.5, loop = false})
}

@(test)
test_lottie_node :: proc(t: ^testing.T) {
	@(static) scenes: [1]Scene
	scenes = [1]Scene{{name = "Lottie", duration = Frames(30), render = render_lottie_scene}}
	v := Video{width = 80, height = 80, fps = 30, background = WHITE, scenes = scenes[:]}
	media: Media
	media_init(&media)
	defer media_destroy(&media)
	testing.expect_value(t, media_load_test_files(&media, {"move.json", LOTTIE_TEST}, {"rows.json", `[{"a": 1}]`}), Error.None)
	testing.expect(t, "move.json" in media.lotties && "rows.json" not_in media.lotties)
	r: Renderer
	testing.expect_value(t, renderer_init(&r, &v, &media), Error.None)
	defer renderer_destroy(&r)
	at :: proc(px: []u8, x, y: int) -> [4]u8 {
		i := (y * 80 + x) * 4
		return {px[i], px[i + 1], px[i + 2], px[i + 3]}
	}
	RED :: [4]u8{255, 0, 0, 255}
	PAPER :: [4]u8{255, 255, 255, 255}

	// Video frame 15 = 0.5 s: animation frame 5, the square at x = 10 (x2).
	px := render_frame(&r, 15)
	testing.expect_value(t, at(px, 10, 20), PAPER)
	testing.expect_value(t, at(px, 30, 20), RED)
	testing.expect_value(t, at(px, 55, 20), RED)
	testing.expect_value(t, at(px, 65, 20), PAPER)
	// frame = 5 at 1:1: x in [10, 30).
	testing.expect_value(t, at(px, 5, 50), PAPER)
	testing.expect_value(t, at(px, 15, 50), RED)
	// Reversed without looping: held at the first frame (x in [0, 20)).
	testing.expect_value(t, at(px, 5, 70), RED)
	testing.expect_value(t, at(px, 25, 70), PAPER)

	// The camera is reported; the data is parsed once.
	warned := false
	for d in r.ctx.diagnostics {
		if strings.contains(diagnostic_message(d, context.temp_allocator), "cameras are not supported") {
			warned = true
		}
	}
	testing.expect(t, warned)
	render_frame(&r, 16)
	testing.expect_value(t, len(r.ctx.lotties.docs), 1)
}

@(test)
test_lottie_frame_mapping :: proc(t: ^testing.T) {
	media: Media
	media_init(&media)
	defer media_destroy(&media)
	testing.expect_value(t, media_load_test_files(&media, {"move.json", LOTTIE_TEST}), Error.None)
	doc := media.lotties["move.json"]
	f := Frame{index = 75, fps = 30} // 2.5 s
	// Loops by default: 25 frames -> 5.
	testing.expect_value(t, lottie_frame(doc, f, {}), 5)
	testing.expect_value(t, lottie_frame(doc, f, {loop = false}) > 19.9, true)
	testing.expect_value(t, lottie_frame(doc, f, {speed = 2, offset = 0.1}), 11)
	testing.expect_value(t, lottie_frame(doc, f, {time = 0.3}), 3)
	testing.expect_value(t, lottie_frame(doc, f, {frame = 7}), 7)
	testing.expect_value(t, lottie_frame(doc, f, {speed = -1}), 15)
}

@(private = "file")
render_lottie_overrides :: proc(f: Frame, ctx: ^Context) {
	lottie(ctx, f, {data = `{"v": "5.7.0", "fr": 10, "ip": 0, "op": 20, "w": 40, "h": 20, "layers": [
		{"ty": 1, "nm": "square", "ind": 1, "ip": 0, "op": 20, "sc": "#ff0000", "sw": 20, "sh": 20, "ks": {}}]}`,
		frame = 0,
		overrides = {{name = "square", fill = Color{0, 0, 1, 1}, transform = translate(20, 0)}, {name = "nope", visible = false}},
	})
}

@(test)
test_lottie_overrides :: proc(t: ^testing.T) {
	@(static) scenes: [1]Scene
	scenes = [1]Scene{{name = "Lottie", duration = Frames(1), render = render_lottie_overrides}}
	v := Video{width = 40, height = 20, fps = 30, background = WHITE, scenes = scenes[:]}
	media: Media
	media_init(&media)
	defer media_destroy(&media)
	r: Renderer
	testing.expect_value(t, renderer_init(&r, &v, &media), Error.None)
	defer renderer_destroy(&r)
	px := render_frame(&r, 0)
	at :: proc(px: []u8, x, y: int) -> [4]u8 {
		i := (y * 40 + x) * 4
		return {px[i], px[i + 1], px[i + 2], px[i + 3]}
	}
	// Moved right and recolored.
	testing.expect_value(t, at(px, 10, 10), [4]u8{255, 255, 255, 255})
	testing.expect_value(t, at(px, 30, 10), [4]u8{0, 0, 255, 255})
	warned := false
	for d in r.ctx.diagnostics {
		if strings.contains(diagnostic_message(d, context.temp_allocator), `has no layer named "nope"`) {
			warned = true
		}
	}
	testing.expect(t, warned)
}

// A text layer "Title" whose document is a space: drawn with the media's
// fonts, its string replaced by an override.
@(private = "file")
render_lottie_text :: proc(f: Frame, ctx: ^Context) {
	doc := `{"v": "5.7.0", "fr": 10, "ip": 0, "op": 20, "w": 80, "h": 20,
		"fonts": {"list": [{"fName": "Missing-Regular", "fFamily": "Missing Sans", "fStyle": "Regular"}]}, "layers": [
		{"ty": 5, "nm": "Title", "ind": 1, "ip": 0, "op": 20, "ks": {"p": {"a": 0, "k": [4, 16]}},
		 "t": {"d": {"k": [{"t": 0, "s": {"t": " ", "f": "Missing-Regular", "s": 16, "fc": [0, 0, 0], "lh": 19}}]}, "a": []}}]}`
	lottie(ctx, f, {data = doc, frame = 0})
	lottie(ctx, f, {data = doc, frame = 0, y = 20, overrides = {{name = "Title", text = "Hello"}}})
}

@(test)
test_lottie_text_override :: proc(t: ^testing.T) {
	@(static) scenes: [1]Scene
	scenes = [1]Scene{{name = "Lottie", duration = Frames(1), render = render_lottie_text}}
	v := Video{width = 80, height = 40, fps = 30, background = WHITE, scenes = scenes[:]}
	media: Media
	media_init(&media)
	defer media_destroy(&media)
	r: Renderer
	testing.expect_value(t, renderer_init(&r, &v, &media), Error.None)
	defer renderer_destroy(&r)
	px := render_frame(&r, 0)
	ink :: proc(px: []u8, y0, y1: int) -> (n: int) {
		for y in y0 ..< y1 {
			for x in 0 ..< 80 {
				if px[(y * 80 + x) * 4] < 128 {
					n += 1
				}
			}
		}
		return
	}
	testing.expect_value(t, ink(px, 0, 20), 0)
	testing.expect(t, ink(px, 20, 40) > 40)
	// The family the file names is not in the media: reported.
	warned := false
	for d in r.ctx.diagnostics {
		warned ||= strings.contains(diagnostic_message(d, context.temp_allocator), "Missing Sans")
	}
	testing.expect(t, warned)
}

// Two nested repeaters of 300 copies each: 90,000 squares, past ovg's
// 20,000 repeater copies a draw, so the draw is cut short and says so.
@(private = "file")
LOTTIE_REPEATS :: `{"v": "5.7.0", "fr": 10, "ip": 0, "op": 20, "w": 40, "h": 20, "layers": [
	{"ty": 4, "ind": 1, "ip": 0, "op": 20, "ks": {}, "shapes": [
		{"ty": "rc", "p": {"a": 0, "k": [1, 1]}, "s": {"a": 0, "k": [1, 1]}, "r": {"a": 0, "k": 0}},
		{"ty": "fl", "c": {"a": 0, "k": [1, 0, 0, 1]}, "o": {"a": 0, "k": 100}},
		{"ty": "rp", "c": {"a": 0, "k": 300}, "o": {"a": 0, "k": 0}, "tr": {"p": {"a": 0, "k": [0.1, 0]}}},
		{"ty": "rp", "c": {"a": 0, "k": 300}, "o": {"a": 0, "k": 0}, "tr": {"p": {"a": 0, "k": [0, 0.05]}}}]}]}`

@(private = "file")
render_lottie_repeats :: proc(f: Frame, ctx: ^Context) {
	lottie(ctx, f, {src = "repeats.json", x = 0, y = 0, w = 40})
}

@(test)
test_lottie_draw_limit :: proc(t: ^testing.T) {
	@(static) scenes: [1]Scene
	scenes = [1]Scene{{name = "Repeats", duration = Frames(10), render = render_lottie_repeats}}
	v := Video{width = 40, height = 20, fps = 10, background = WHITE, scenes = scenes[:]}
	media: Media
	media_init(&media)
	defer media_destroy(&media)
	testing.expect_value(t, media_load_test_files(&media, {"repeats.json", LOTTIE_REPEATS}), Error.None)
	r: Renderer
	testing.expect_value(t, renderer_init(&r, &v, &media), Error.None)
	defer renderer_destroy(&r)
	render_frame(&r, 0)
	got := make([dynamic]string, context.temp_allocator)
	for d in r.ctx.diagnostics {
		append(&got, diagnostic_message(d, context.temp_allocator))
	}
	testing.expectf(t, len(got) == 1 && got[0] == `Lottie "repeats.json": reached the repeater copies per draw limit: drawn in part`, "diagnostics: %v", got[:])
}
