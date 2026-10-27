package onimite

import "core:encoding/json"
import "core:math"
import "core:strings"
import "core:testing"
import vg "deps:ovg"

// ---- timeline ------------------------------------------------------------------

@(test)
test_sample_holds_and_gaps :: proc(t: ^testing.T) {
	keys := []Key(f32){{start = 1, end = 2, from = 0, to = 10}, {start = 3, end = 4, from = 10, to = 20}}
	testing.expect_value(t, sample(keys, 0), 0)
	testing.expect_value(t, sample(keys, 1.5), 5)
	testing.expect_value(t, sample(keys, 2.5), 10) // gap holds the previous `to`
	testing.expect_value(t, sample(keys, 3.5), 15)
	testing.expect_value(t, sample(keys, 9), 20)
}

@(test)
test_sample_open_end :: proc(t: ^testing.T) {
	// No `end`: the tween lasts until the next key.
	keys := []Key(f32){{start = 0, from = 0, to = 10}, {start = 2, end = 3, from = 10, to = 0}}
	testing.expect_value(t, sample(keys, 1), 5)
	// A last key without an end is instant (except springs).
	last := []Key(f32){{start = 1, from = 0, to = 10}}
	testing.expect_value(t, sample(last, 0.5), 0)
	testing.expect_value(t, sample(last, 1), 10)
}

@(test)
test_bezier :: proc(t: ^testing.T) {
	css_in := cubic_bezier(0.42, 0, 1, 1)
	testing.expect(t, abs(bezier_solve(cubic_bezier(0.42, 0, 0.58, 1).p, 0.5) - 0.5) < 1e-4)
	testing.expect(t, bezier_solve(css_in.p, 0.25) < 0.25)
	testing.expect(t, bezier_solve(cubic_bezier(0, 0, 0.58, 1).p, 0.25) > 0.25)
	testing.expect_value(t, bezier_solve(css_in.p, 0), 0)
	testing.expect_value(t, bezier_solve(css_in.p, 1), 1)
	testing.expect(t, abs(ease(EASE_IN_OUT, 0.5, 1) - 0.5) < 1e-6)
	testing.expect(t, abs(ease(EASE_IN, 0.5, 1) - 0.125) < 1e-6)
	testing.expect(t, abs(ease(EASE_OUT, 0.5, 1) - 0.875) < 1e-6)
	// Projection symmetry (as in bezier-easing's tests).
	e := cubic_bezier(0.25, 0.1, 0.75, 0.9)
	p := cubic_bezier(0.1, 0.25, 0.9, 0.75)
	for i in 0 ..= 20 {
		x := f32(i) / 20
		testing.expect(t, abs(bezier_solve(p.p, bezier_solve(e.p, x)) - x) < 0.02)
	}
}

@(test)
test_spring :: proc(t: ^testing.T) {
	s := spring(1, 180, 20)
	d := spring_duration(s)
	testing.expect(t, d > 0.5 && d < 2)
	testing.expect(t, abs(spring_solve(s, d) - 1) <= 0.0011)
	testing.expect_value(t, spring_solve(s, 0), 0)
	// Under-damped springs overshoot.
	bouncy := spring(1, 200, 5)
	overshoot := false
	for i in 0 ..< 100 {
		if spring_solve(bouncy, f32(i) / 50) > 1.01 {
			overshoot = true
		}
	}
	testing.expect(t, overshoot)
	// A trailing spring key runs until it settles.
	keys := []Key(f32){{start = 0, from = 0, to = 100, easing = s}}
	testing.expect(t, sample(keys, 0.1) > 0 && sample(keys, 0.1) < 100)
	testing.expect_value(t, sample(keys, 10), 100)
}

@(test)
test_animate_types :: proc(t: ^testing.T) {
	f := Frame{index = 15, global_index = 15, fps = 30}
	c := animate(f, []Key(Color){{start = 0, end = 1, from = BLACK, to = WHITE}})
	testing.expect(t, abs(c.r - 0.5) < 1e-5 && c.a == 1)
	tr := animate(f, []Key(Transform){{start = 0, end = 1, from = translate(0, 0), to = translate(100, 50)}})
	testing.expect_value(t, tr.translate, Vec2{50, 25})
	testing.expect_value(t, tr.scale, Vec2{1, 1})
	looped := animate_loop(Frame{index = 45, fps = 30}, []Key(f32){{start = 0, end = 1, from = 0, to = 1}})
	testing.expect(t, abs(looped - 0.5) < 1e-5)
}

// An SVG matrix is the whole transform; it interpolates component-wise,
// also against a field transform.
@(test)
test_affine_transform :: proc(t: ^testing.T) {
	m, ok := vg.transform_svg("translate(100 40) rotate(30) scale(2 1)")
	testing.expect(t, ok)
	fields := Transform{translate = {100, 40}, rotate = 30, scale = {2, 1}}
	a := transform_matrix(affine(m))
	b := transform_matrix(fields)
	for i in 0 ..< 6 {
		testing.expectf(t, abs(a[i] - b[i]) < 1e-4, "matrix %v vs fields %v", a, b)
	}
	half := lerp_transform(translate(0, 0), affine({1, 0, 0, 1, 100, 50}), 0.5)
	testing.expect_value(t, transform_matrix(half), vg.Transform2D{1, 0, 0, 1, 50, 25})
}

// ---- scenes and time specs --------------------------------------------------------

@(private = "file")
test_video :: proc() -> Video {
	@(static) scenes: [3]Scene
	scenes = [3]Scene{
		{name = "Intro", duration = Seconds(2)},
		{name = "Main", duration = Frames(90), overlap = {previous = 0.5}},
		{name = "Outro", duration = Seconds(1)},
	}
	return {width = 320, height = 180, fps = 30, scenes = scenes[:]}
}

@(test)
test_resolve_timeline :: proc(t: ^testing.T) {
	v := test_video()
	tl, err := resolve_timeline(&v)
	defer timeline_destroy(&tl)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, tl.scenes[0].start_frame, 0)
	testing.expect_value(t, tl.scenes[0].end_frame, 60)
	// Main starts 15 frames early and runs its 90 frames plus the overlap.
	testing.expect_value(t, tl.scenes[1].start_frame, 45)
	testing.expect_value(t, tl.scenes[1].end_frame, 150)
	testing.expect_value(t, tl.scenes[2].start_frame, 150)
	testing.expect_value(t, tl.duration_frames, 180)
}

@(test)
test_time_specs :: proc(t: ^testing.T) {
	v := test_video()
	tl, _ := resolve_timeline(&v)
	defer timeline_destroy(&tl)
	check :: proc(t: ^testing.T, tl: Timeline, spec: string, want: int, loc := #caller_location) {
		f, err := parse_frame(tl, 30, spec)
		testing.expectf(t, err == nil && f == want, "%q -> %d, %v (want %d)", spec, f, err, want, loc = loc)
	}
	check(t, tl, "12", 12)
	check(t, tl, "12f", 12)
	check(t, tl, "1.5s", 45)
	check(t, tl, "0:02", 60)
	check(t, tl, "50%", 90)
	check(t, tl, "start", 0)
	check(t, tl, "end", 179)
	check(t, tl, "main", 45)
	check(t, tl, "#2", 150)
	check(t, tl, "Main@1s", 75)
	check(t, tl, "Outro@end", 179)
	check(t, tl, "Intro@50%", 30)

	_, err := parse_frame(tl, 30, "Credits")
	testing.expect_value(t, err, Error.Unknown_Scene)
	_, err = parse_frame(tl, 30, "999")
	testing.expect_value(t, err, Error.Out_Of_Range)

	a, b, rerr := parse_range(tl, 30, "Main")
	testing.expect(t, rerr == nil && a == 45 && b == 150)
	a, b, rerr = parse_range(tl, 30, "Intro@1s..Main")
	testing.expect(t, rerr == nil && a == 30 && b == 150)
	a, b, rerr = parse_range(tl, 30, "..1s")
	testing.expect(t, rerr == nil && a == 0 && b == 30)
	// The end is exclusive: it may be the frame count, a start may not.
	a, b, rerr = parse_range(tl, 30, "0..180")
	testing.expect(t, rerr == nil && a == 0 && b == 180)
	_, _, rerr = parse_range(tl, 30, "0..181")
	testing.expect_value(t, rerr, Error.Out_Of_Range)
	_, _, rerr = parse_range(tl, 30, "180..")
	testing.expect_value(t, rerr, Error.Out_Of_Range)
	_, err = parse_frame(tl, 30, "180")
	testing.expect_value(t, err, Error.Out_Of_Range)
	// An offset stays inside its scene (Intro is 60 frames): a point may not
	// land past it, a range may end on the scene's end.
	_, err = parse_frame(tl, 30, "Intro@2s")
	testing.expect_value(t, err, Error.Past_Scene)
	_, err = parse_frame(tl, 30, "Intro@3s")
	testing.expect_value(t, err, Error.Past_Scene)
	a, b, rerr = parse_range(tl, 30, "Intro@0..Intro@2s")
	testing.expect(t, rerr == nil && a == 0 && b == 60)
	_, _, rerr = parse_range(tl, 30, "Intro@0..Intro@3s")
	testing.expect_value(t, rerr, Error.Past_Scene)

	// Cues and sync ids are named times: every form a scene takes but
	// `@50%` / `@end` (a moment has no length); a scene's name wins.
	names := []Named_Time{{"drop", 2.1}, {"beat[3]", 4}, {"main", 0.5}}
	frame :: proc(tl: Timeline, spec: string, names: []Named_Time) -> (int, Error) {return parse_frame(tl, 30, spec, names)}
	f, ferr := frame(tl, "drop", names)
	testing.expect(t, ferr == nil && f == 63)
	f, ferr = frame(tl, "drop@0.5s", names)
	testing.expect(t, ferr == nil && f == 78)
	f, ferr = frame(tl, "drop@-3", names)
	testing.expect(t, ferr == nil && f == 60)
	f, ferr = frame(tl, "beat[3]", names)
	testing.expect(t, ferr == nil && f == 120)
	f, ferr = frame(tl, "main", names)
	testing.expect(t, ferr == nil && f == 45)
	_, ferr = frame(tl, "drop@50%", names)
	testing.expect_value(t, ferr, Error.Invalid_Time_Spec)
	_, ferr = frame(tl, "dorp", names)
	testing.expect_value(t, ferr, Error.Unknown_Scene)
	a, b, rerr = parse_range(tl, 30, "drop..beat[3]", names)
	testing.expect(t, rerr == nil && a == 63 && b == 120)
	a, b, rerr = parse_range(tl, 30, "Intro..drop@1s", names)
	testing.expect(t, rerr == nil && a == 0 && b == 93)
}

// ---- rendering --------------------------------------------------------------------

@(private = "file")
render_test_scene :: proc(f: Frame, ctx: ^Context) {
	rect(ctx, {x = 10, y = 10, w = 100, h = 60, fill = rgb(255, 0, 0)})
	{
		// Two overlapping squares in a half-transparent group: the overlap
		// must not be darker than either square.
		group(ctx, {opacity = 0.5})
		rect(ctx, {x = 150, y = 10, w = 60, h = 60, fill = BLACK})
		rect(ctx, {x = 180, y = 40, w = 60, h = 60, fill = BLACK})
	}
	{
		// One child that paints twice (filled, then stroked over the fill):
		// the group fades as a whole, so the fill doesn't show under the
		// stroke.
		group(ctx, {opacity = 0.5})
		rect(ctx, {x = 260, y = 110, w = 40, h = 40, fill = rgb(255, 0, 0), stroke = {paint = rgb(0, 0, 255), width = 16}})
	}
	{
		group(ctx, {transform = translate(0, 100), clip = vg.Rect{0, 0, 50, 50}})
		circle(ctx, {cx = 50, cy = 25, r = 40, fill = rgb(0, 0, 255)})
	}
	text(ctx, {text = "Hi", x = 300, y = 170, font = "Nope", size = 24, fill = BLACK})
}

@(test)
test_render_frame :: proc(t: ^testing.T) {
	@(static) scenes: [1]Scene
	scenes = [1]Scene{{name = "Only", duration = Frames(1), render = render_test_scene}}
	v := Video{width = 320, height = 180, fps = 30, background = WHITE, scenes = scenes[:]}
	media: Media
	media_init(&media)
	defer media_destroy(&media)
	r: Renderer
	testing.expect_value(t, renderer_init(&r, &v, &media), Error.None)
	defer renderer_destroy(&r)

	px := render_frame(&r, 0)
	at :: proc(px: []u8, x, y: int) -> [4]u8 {
		i := (y * 320 + x) * 4
		return {px[i], px[i + 1], px[i + 2], px[i + 3]}
	}
	testing.expect_value(t, at(px, 50, 40), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, at(px, 5, 5), [4]u8{255, 255, 255, 255})
	single := at(px, 160, 20)
	overlap := at(px, 200, 60)
	testing.expectf(t, single == overlap, "group opacity: single %v overlap %v", single, overlap)
	testing.expect(t, single.r > 120 && single.r < 135)
	stroked := at(px, 264, 130)
	testing.expectf(t, stroked.r > 115 && stroked.r < 140 && stroked.g > 115 && stroked.g < 140 && stroked.b > 245, "half the stroke over white, no fill under it: %v", stroked)
	// Clipped circle: inside the clip is blue, outside the clip is white.
	testing.expect_value(t, at(px, 25, 125), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, at(px, 70, 125), [4]u8{255, 255, 255, 255})

	// The missing font and the text leaving the frame are reported.
	missing, outside := false, false
	for d in r.ctx.diagnostics {
		// fframes' wording and severities: a missing font warns, text
		// leaving the frame warns (cut off) or informs (outside).
		if d.severity == .Warning && d.scene == "Only" && strings.has_prefix(diagnostic_message(d, context.temp_allocator), "No match for") {
			missing = true
		}
		if strings.has_prefix(diagnostic_message(d, context.temp_allocator), "text \"Hi\"") {
			outside = true
		}
	}
	testing.expect(t, missing && outside)
}

overlap_scene :: proc(f: Frame, ctx: ^Context) {
	text(ctx, {text = "Hello there", x = 20, y = 60, size = 30, fill = BLACK})
	text(ctx, {text = "General Kenobi", x = 30, y = 66, size = 30, fill = BLACK}) // over the first
	text(ctx, {text = "Glow", x = 20, y = 140, size = 30, fill = BLACK})
	text(ctx, {text = "Glow", x = 22, y = 141, size = 30, fill = BLACK}) // a shadow: the same text
	text(ctx, {text = "A", x = 200, y = 140, size = 30, fill = BLACK})
	text(ctx, {text = "B", x = 204, y = 140, size = 30, fill = BLACK}) // letters animating in
	text(ctx, {text = "Below", x = 20, y = 100, size = 30, fill = BLACK}) // a line under: touching is fine
	text(ctx, {text = "Faded out", x = 30, y = 100, size = 30, fill = BLACK, opacity = 0.1})
}

// Readable texts drawn over each other are reported, once per pair.
@(test)
test_text_overlap :: proc(t: ^testing.T) {
	@(static) scenes: [1]Scene
	scenes = [1]Scene{{name = "Only", duration = Frames(1), render = overlap_scene}}
	v := Video{width = 320, height = 180, fps = 30, background = WHITE, scenes = scenes[:]}
	media: Media
	media_init(&media)
	defer media_destroy(&media)
	r: Renderer
	testing.expect_value(t, renderer_init(&r, &v, &media), Error.None)
	defer renderer_destroy(&r)
	render_frame(&r, 0)
	found := 0
	for d in r.ctx.diagnostics {
		if d.code == .Text_Overlap {
			found += 1
			testing.expect_value(t, d.name, "General Kenobi")
			testing.expect_value(t, d.a, "Hello there")
		}
	}
	testing.expect_value(t, found, 1)
}

@(test)
test_render_scale :: proc(t: ^testing.T) {
	@(static) scenes: [1]Scene
	scenes = [1]Scene{{name = "S", duration = Frames(1), render = render_test_scene}}
	v := Video{width = 320, height = 180, fps = 30, background = WHITE, scenes = scenes[:]}
	media: Media
	media_init(&media)
	defer media_destroy(&media)
	r: Renderer
	renderer_init(&r, &v, &media, 0.5)
	defer renderer_destroy(&r)
	px := render_frame(&r, 0)
	testing.expect_value(t, len(px), 160 * 90 * 4)
	i := (20 * 160 + 25) * 4
	testing.expect_value(t, px[i], 255)
	testing.expect_value(t, px[i + 1], 0)
}

// Emoji fall back to the bundled colour emoji face and draw in colour.
@(test)
test_render_emoji :: proc(t: ^testing.T) {
	@(static) scenes: [1]Scene
	scenes = [1]Scene {
		{name = "E", duration = Frames(1), render = proc(f: Frame, ctx: ^Context) {
				text(ctx, {text = "\U0001F525", x = 10, y = 130, size = 128, fill = BLACK})
			}},
	}
	v := Video{width = 160, height = 160, fps = 30, background = WHITE, scenes = scenes[:]}
	media: Media
	media_init(&media)
	defer media_destroy(&media)
	r: Renderer
	renderer_init(&r, &v, &media)
	defer renderer_destroy(&r)
	px := render_frame(&r, 0)
	orange := 0
	for i := 0; i < len(px); i += 4 {
		if px[i] > 200 && px[i + 1] > 60 && px[i + 1] < 200 && px[i + 2] < 80 {
			orange += 1
		}
	}
	testing.expectf(t, orange > 1000, "orange pixels: %d", orange)
}

// The built-in families need no media; a family the media has replaces the
// built-in one (its only weight wins over a closer built-in weight) and its
// first face is the default.
@(test)
test_builtin_fonts :: proc(t: ^testing.T) {
	media: Media
	media_init(&media)
	defer media_destroy(&media)
	for family in ([]string{"DM Sans", "instrument serif", "Bebas Neue", "JetBrains Mono"}) {
		_, ok := media_find_font(&media, family, 400)
		testing.expectf(t, ok, "%s is not built in", family)
	}
	builtin_bold, _ := media_find_font(&media, "DM Sans", 700)
	testing.expect_value(t, len(media_font_faces(&media)), 0)

	medium := #load("../assets/fonts/DMSans-Medium.ttf")
	testing.expect(t, media_add_font(&media, medium))
	testing.expect_value(t, len(media_font_faces(&media)), 1)
	regular, _ := media_find_font(&media, "DM Sans", 400)
	bold, _ := media_find_font(&media, "DM Sans", 700)
	testing.expect(t, regular == media.fonts.faces[0].id && bold == regular && bold != builtin_bold)
	first, _ := media_find_font(&media, "", 400)
	testing.expect(t, first == media.fonts.faces[0].id)
	_, mono := media_find_font(&media, "JetBrains Mono", 700)
	testing.expect(t, mono)
}

// Measuring needs only the media (scripts measure at load, outside a render).
@(test)
test_text_helpers :: proc(t: ^testing.T) {
	media: Media
	media_init(&media)
	defer media_destroy(&media)
	q := Font_Query{family = "Bitstream Vera Sans", size = 20}
	w, ok := text_width(&media, q, "Hello")
	testing.expect(t, !ok && w > 30 && w < 80)
	fitted, _ := text_fit(&media, q, "A long title that does not fit", 100)
	fw, _ := text_width(&media, q, fitted)
	testing.expect(t, fw <= 100 && len(fitted) < 30)
	lines, _ := text_break_lines(&media, q, "one two three four five six", 80)
	testing.expect(t, len(lines) >= 3)
	for l in lines {
		lw, _ := text_width(&media, q, l)
		testing.expectf(t, lw <= 80, "line %q is %v wide", l, lw)
	}

	// The same widths inside a render.
	v := Video{width = 320, height = 180, fps = 30, duration = Frames(1)}
	r: Renderer
	renderer_init(&r, &v, &media)
	defer renderer_destroy(&r)
	build_frame(&r, 0)
	rw, _ := text_width(r.ctx.media, q, "Hello")
	testing.expect_value(t, rw, w)
	_ = math.PI
}

// Diagnostics are codes with operands; their text, key, --json name and
// fields come from the tables.
@(test)
test_diagnostic_text :: proc(t: ^testing.T) {
	d := Diagnostic{code = .Text_Clipped, name = "Hi", x = 600, y = 62.9, w = 381.5, h = 46.4}
	testing.expect_value(t, diagnostic_message(d, context.temp_allocator), `text "Hi" is cut off by the canvas edge (x=600 y=63 w=382 h=46)`)
	testing.expect_value(t, diagnostic_key(d, context.temp_allocator), "text_clipped:Hi")
	testing.expect_value(t, diagnostic_code_name(d.code, context.temp_allocator), "text_clipped")
	fields := diagnostic_fields(d, context.temp_allocator)
	testing.expect_value(t, fields["text"].(json.String), "Hi")
	testing.expect_value(t, fields["x"].(json.Float), 600)

	// Without a key, the message groups.
	z := Diagnostic{code = .Rect_Zero_Size, x = 10, y = 10.5}
	testing.expect_value(t, diagnostic_key(z, context.temp_allocator), "rect with zero size at (10, 10.5) is skipped")

	g := Diagnostic{code = .Missing_Glyph, name = "a☃", a = "☃", n = 0x2603}
	testing.expect_value(t, diagnostic_message(g, context.temp_allocator), `No fonts with a glyph for "☃" (U+2603) in text "a☃"`)
	testing.expect_value(t, diagnostic_fields(g, context.temp_allocator)["codepoint"].(json.Integer), 0x2603)

	v := Diagnostic{code = .Undecodable_Video, name = "clip.mp4", video = {code = .Video_Decode, cause = "Invalid_Data", detail = "not a readable MP4 file"}}
	testing.expect_value(t, diagnostic_message(v, context.temp_allocator), `video "clip.mp4" can not be decoded: Invalid_Data not a readable MP4 file`)
	testing.expect_value(t, diagnostic_key(v, context.temp_allocator), "clip.mp4")

	// Every code has text, and every placeholder names an operand.
	for code in Diagnostic_Code {
		if code == .None {
			continue
		}
		testing.expectf(t, DIAGNOSTIC_TEXT[code] != "", "%v has no text", code)
		for text in ([2]string{DIAGNOSTIC_TEXT[code], DIAGNOSTIC_KEY[code]}) {
			for rest := text; len(rest) > 0; {
				open := strings.index_byte(rest, '{')
				close := strings.index_byte(rest[max(open, 0):], '}')
				if open < 0 || close < 0 {
					break
				}
				field := rest[open + 1:open + close]
				rest = rest[open + close + 1:]
				if colon := strings.index_byte(field, ':'); colon >= 0 {
					field = field[colon + 1:]
				}
				testing.expectf(t, operand_of(field) != .None, "%v: {%s} names no operand", code, field)
			}
		}
	}
}
