package onimite

import "core:hash"
import "core:strings"
import "core:testing"

@(private = "file")
SPLIT :: `
uniform float3 iResolution;
uniform float4 uLeft;
uniform float uGain;
half4 main(float2 c) {
    // Left half uLeft, right half white scaled by uGain; the box is
    // 100 units wide whatever its pixel size.
    return c.x < iResolution.x * 0.5 ? half4(uLeft) : half4(half3(uGain), 1.0);
}`

@(private = "file")
render_shader_scene :: proc(f: Frame, ctx: ^Context) {
	// Drawn at 2x: iResolution stays in user units.
	group(ctx, {transform = scale(2, 2)})
	shader(ctx, f, {source = SPLIT, x = 10, y = 10, w = 100, h = 40, uniforms = {{name = "uLeft", values = {1, 0, 0, 1}}, {name = "uGain", values = {0.5}}}})
	// Shadertoy code: opaque output whatever alpha it writes; iFrame
	// declared as a float is still filled.
	shader(ctx, f, {source = "void mainImage(out vec4 o, in vec2 c) { o = vec4(0.0, 1.0, 0.0, 0.0); }", profile = .Shadertoy, x = 10, y = 60, w = 20, h = 20})
	// Errors are reported (lines of the original source), the layer skipped.
	shader(ctx, f, {src = "broken.glsl", source = "void mainImage(out vec4 o, in vec2 c) {\n  o = nope;\n}", profile = .Shadertoy, x = 0, y = 0, w = 10, h = 10})
	shader(ctx, f, {source = SPLIT, x = 0, y = 0, w = 10, h = 10, uniforms = {{name = "uTypo", values = {1}}}})
	shader(ctx, f, {source = "uniform float iFrame;\nhalf4 main(float2 c) { return half4(iFrame / 255.0, 0, 0, 1); }", x = 140, y = 60, w = 10, h = 10})
}

@(test)
test_shader_layers :: proc(t: ^testing.T) {
	@(static) scenes: [1]Scene
	scenes = [1]Scene{{name = "Only", duration = Frames(2), render = render_shader_scene}}
	v := Video{width = 320, height = 180, fps = 30, background = BLACK, scenes = scenes[:]}
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
	// Box (10, 10, 100, 40) at 2x: x 20..220, the split at x = 120.
	testing.expect_value(t, at(px, 60, 50), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, at(px, 180, 50), [4]u8{128, 128, 128, 255})
	testing.expect_value(t, at(px, 30, 140), [4]u8{0, 255, 0, 255})
	testing.expect_value(t, at(px, 290, 130), [4]u8{0, 0, 0, 255}) // frame 0

	compile_error, typo, unset := false, false, false
	for d in r.ctx.diagnostics {
		if d.severity == .Error && strings.has_prefix(diagnostic_message(d, context.temp_allocator), "shader broken.glsl:2:7: ") {
			compile_error = true
		}
		if strings.contains(diagnostic_message(d, context.temp_allocator), "`uTypo` is not declared") {
			typo = true
		}
		if strings.contains(diagnostic_message(d, context.temp_allocator), "`uLeft` is not set") {
			unset = true
		}
	}
	testing.expectf(t, compile_error && typo && unset, "diagnostics: %v", r.ctx.diagnostics[:])

	// Compiled once per source, across frames.
	px = render_frame(&r, 1)
	testing.expect_value(t, at(px, 290, 130), [4]u8{1, 0, 0, 255})
	testing.expect_value(t, len(r.ctx.shaders.graphs), 4)
	// Four layers draw per frame (at three sizes); their images are reused.
	testing.expect_value(t, len(r.shader_state.image), 4)
}

@(private = "file")
MIRROR :: `
uniform shader uScene;
uniform float3 iResolution;
half4 main(float2 coord) {
    float2 p = float2(iResolution.x - coord.x, coord.y);
    return uScene.eval(p);
}`

@(private = "file")
render_group_child_scene :: proc(f: Frame, ctx: ^Context) {
	group(ctx, {transform = scale(2, 2)})
	// A group child in the box's units: red on the left, mirrored to the
	// right; inside it a nested mirror of a 10 x 10 group child (green on
	// its left) in a 20 x 20 box.
	scene := shader_content_begin(ctx)
	rect(ctx, {x = 0, y = 0, w = 50, h = 40, fill = Color{1, 0, 0, 1}})
	inner := shader_content_begin(ctx)
	rect(ctx, {x = 0, y = 0, w = 5, h = 10, fill = Color{0, 1, 0, 1}})
	group_end(ctx)
	shader(ctx, f, {source = MIRROR, x = 60, y = 10, w = 20, h = 20, uniforms = {{name = "uScene", input = Shader_Input{content = inner, w = 10, h = 10}}}})
	group_end(ctx)
	shader(ctx, f, {source = MIRROR, x = 10, y = 10, w = 100, h = 40, uniforms = {{name = "uScene", input = Shader_Input{content = scene}}}})
}

@(test)
test_shader_group_child :: proc(t: ^testing.T) {
	@(static) scenes: [1]Scene
	scenes = [1]Scene{{name = "Only", duration = Frames(1), render = render_group_child_scene}}
	v := Video{width = 320, height = 180, fps = 30, background = BLACK, scenes = scenes[:]}
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
	// Box (10, 10, 100, 40) at 2x: x 20..220; the content's red half
	// (0..50) shows mirrored on the right (x 120..220).
	testing.expect_value(t, at(px, 110, 70), [4]u8{0, 0, 0, 255})
	testing.expect_value(t, at(px, 200, 70), [4]u8{255, 0, 0, 255})
	// The nested box (content 60..80 x 10..30) is mirrored to box 20..40,
	// px 60..100 x 40..80. Its child is 10 x 10 units over 20 x 20: inner
	// x 15..20 samples the green column (0..5), the outer mirror puts it at
	// px 60..70; inner x 0..10 samples past the edge (clamped, clear).
	testing.expect_value(t, at(px, 64, 60), [4]u8{0, 255, 0, 255})
	testing.expect_value(t, at(px, 90, 60), [4]u8{0, 0, 0, 255})
	testing.expect_value(t, at(px, 64, 90), [4]u8{0, 0, 0, 255})
	testing.expectf(t, len(r.ctx.diagnostics) == 0, "diagnostics: %v", r.ctx.diagnostics[:])
}

// Shadertoy code samples iChannel0 (bound by name like a child) with
// texture() in 0..1 uv, origin bottom-left: the group shows upright.
@(private = "file")
render_shadertoy_channel_scene :: proc(f: Frame, ctx: ^Context) {
	content := shader_content_begin(ctx)
	rect(ctx, {x = 0, y = 0, w = 100, h = 20, fill = Color{1, 0, 0, 1}})
	group_end(ctx)
	src := "void mainImage(out vec4 c, in vec2 p) { c = texture(iChannel0, p / iResolution.xy); }"
	shader(ctx, f, {source = src, profile = .Shadertoy, x = 10, y = 10, w = 100, h = 40, uniforms = {{name = "iChannel0", input = Shader_Input{content = content}}}})
}

@(test)
test_shadertoy_channel :: proc(t: ^testing.T) {
	@(static) scenes: [1]Scene
	scenes = [1]Scene{{name = "Only", duration = Frames(1), render = render_shadertoy_channel_scene}}
	v := Video{width = 320, height = 180, fps = 30, background = BLACK, scenes = scenes[:]}
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
	// Red on the box's top half (y 10..30), clear (made opaque) below.
	testing.expect_value(t, at(px, 60, 15), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, at(px, 60, 45), [4]u8{0, 0, 0, 255})
	testing.expectf(t, len(r.ctx.diagnostics) == 0, "diagnostics: %v", r.ctx.diagnostics[:])
}

@(private = "file")
render_multipass_scene :: proc(f: Frame, ctx: ^Context) {
	// Buffer A accumulates into itself; Buffer B averages this frame's A
	// with its own previous frame; the Image pass shows B.
	passes := []Shader_Pass {
		{
			name = "Buffer A",
			profile = .Shadertoy,
			source = "void mainImage(out vec4 o, in vec2 c) { vec2 uv = c / iResolution.xy; o = texture(iChannel0, uv) + vec4(STEP * wobble(float(iFrame)), STEP * uv.x, 0.0, 0.0); }",
			inputs = {{index = 0, pass = "Buffer A"}},
		},
		{
			name = "Buffer B",
			profile = .Shadertoy,
			source = "void mainImage(out vec4 o, in vec2 c) { vec2 uv = c / iResolution.xy; o = 0.5 * (texture(iChannel0, uv) + texture(iChannel1, uv)); }",
			inputs = {{index = 0, pass = "Buffer A"}, {index = 1, pass = "Buffer B"}},
		},
		{
			name = "Image",
			profile = .Shadertoy,
			source = "void mainImage(out vec4 o, in vec2 c) { o = vec4(texture(iChannel0, c / iResolution.xy).rgb * 4.0, 1.0); }",
			inputs = {{index = 0, pass = "Buffer B"}},
		},
	}
	common := "#define STEP 0.01\nfloat wobble(float t) { return 1.0 + 0.5 * sin(t * 1.7); }"
	shader(ctx, f, {passes = passes, common = common, x = 0, y = 0, w = 16, h = 8})
}

@(test)
test_shader_multipass :: proc(t: ^testing.T) {
	@(static) scenes: [1]Scene
	scenes = [1]Scene{{name = "Only", duration = Frames(40), render = render_multipass_scene}}
	v := Video{width = 16, height = 8, fps = 30, background = BLACK, scenes = scenes[:]}
	media: Media
	media_init(&media)
	defer media_destroy(&media)
	pixels_hash :: proc(px: []u8) -> u64 {
		return hash.fnv64a(px)
	}

	// Drawn in order: the reference.
	straight: [40]u64
	red: [40]u8
	{
		r: Renderer
		testing.expect_value(t, renderer_init(&r, &v, &media), Error.None)
		defer renderer_destroy(&r)
		for f in 0 ..< 40 {
			px := render_frame(&r, f)
			straight[f] = pixels_hash(px)
			red[f] = px[0]
		}
		for d in r.ctx.diagnostics {
			testing.expectf(t, false, "unexpected diagnostic: %s", diagnostic_message(d, context.temp_allocator))
		}
	}
	// Frame 0: A = STEP * 1, B = A / 2 (no previous frame), shown * 4.
	testing.expect_value(t, red[0], u8(5)) // 0.02 * 255, rounded
	testing.expect(t, red[10] > red[5] && red[5] > red[0])

	// Seeks: a fresh renderer catches up from frame 0; one with checkpoints
	// restores the nearest earlier one; both give the frames drawn in order.
	{
		r: Renderer
		testing.expect_value(t, renderer_init(&r, &v, &media), Error.None)
		defer renderer_destroy(&r)
		testing.expect_value(t, pixels_hash(render_frame(&r, 25)), straight[25])
		testing.expect_value(t, pixels_hash(render_frame(&r, 9)), straight[9])
		testing.expect_value(t, pixels_hash(render_frame(&r, 10)), straight[10])
		testing.expect_value(t, pixels_hash(render_frame(&r, 10)), straight[10])
	}
	{
		r: Renderer
		testing.expect_value(t, renderer_init(&r, &v, &media), Error.None)
		defer renderer_destroy(&r)
		feedback_checkpoints(&r, 4)
		for f in 0 ..= 12 {
			render_frame(&r, f)
		}
		testing.expect_value(t, len(r.shader_state.feedback.checkpoints.frame), 4)
		for f in ([]int{17, 6, 30, 29, 3, 39}) {
			testing.expect_value(t, pixels_hash(render_frame(&r, f)), straight[f])
		}
		// A smaller budget keeps the most recently used: three of two
		// 16x8 half-float buffers.
		feedback_checkpoints(&r, 4, 3 * 2 * 16 * 8 * 8)
		testing.expect_value(t, len(r.shader_state.feedback.checkpoints.frame), 3)
		testing.expect_value(t, pixels_hash(render_frame(&r, 38)), straight[38])
		testing.expect_value(t, pixels_hash(render_frame(&r, 21)), straight[21])
	}
}

