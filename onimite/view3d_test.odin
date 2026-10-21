package onimite

import "core:encoding/base64"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "deps:o3d"
import vgsdl "deps:ovg/sdlgpu"
import sdl "vendor:sdl3"

// A lit red box and an unlit green sphere over a shadow-receiving floor,
// the camera on +Z: the box fills the middle of the frame.
@(private = "file")
render_view3d_scene :: proc(f: Frame, ctx: ^Context) {
	box := MATERIAL_RED
	box.flags = {.Cast_Shadow}
	view3d(ctx, f, {
		x = 8, y = 4, w = 64, h = 40,
		camera = {position = {0, 0.5, 4}, target = {0, 0, 0}, fov = 45, near = 0.1, far = 100},
		lights = {{kind = .Ambient, color = {1, 1, 1}, intensity = 0.4}, {kind = .Directional, color = {1, 1, 1}, intensity = 3, position = {1, 3, 2}, cast_shadow = true}},
		meshes = {
			{geometry = {.Box, {1.4, 1, 1, 1, 1, 1, 0}}, rotation = {0, 0.3, 0}, scale = {1, 1, 1}, material = box},
			{geometry = {.Sphere, {0.3, 16, 8, 0, 0, 0, 0}}, position = {1.3, 0.2, 0}, scale = {1, 1, 1}, material = MATERIAL_GREEN_BASIC},
			{geometry = {.Plane, {8, 8, 1, 1, 0, 0, 0}}, position = {0, -0.5, 0}, rotation = {-math.PI / 2, 0, 0}, scale = {1, 1, 1}, material = MATERIAL_FLOOR},
		},
	})
}

@(private = "file", rodata)
MATERIAL_RED := o3d.Material{color = {1, 0, 0}, roughness = 0.5, emissive_intensity = 1, opacity = 1}
@(private = "file", rodata)
MATERIAL_GREEN_BASIC := o3d.Material{color = {0, 1, 0}, roughness = 1, emissive_intensity = 1, opacity = 1, flags = {.Basic}}
@(private = "file", rodata)
MATERIAL_FLOOR := o3d.Material{color = {0.8, 0.8, 0.8}, roughness = 1, emissive_intensity = 1, opacity = 1, flags = {.Receive_Shadow}}

@(private = "file")
pixel :: proc(px: []u8, w, x, y: int) -> [4]u8 {
	i := (y * w + x) * 4
	return {px[i], px[i + 1], px[i + 2], px[i + 3]}
}

// view3d on the CPU: the box is red where it is, the basic sphere pure
// green, the area outside the box the video's background; on the GPU (when
// there is a device, so not on macOS, where tests run off the main thread)
// the same frame within 30 dB.
@(test)
test_view3d_layer :: proc(t: ^testing.T) {
	@(static) scenes: [1]Scene
	scenes = [1]Scene{{name = "Only", duration = Frames(1), render = render_view3d_scene}}
	v := Video{width = 80, height = 48, fps = 30, background = BLACK, scenes = scenes[:]}
	media: Media
	media_init(&media)
	defer media_destroy(&media)
	r: Renderer
	testing.expect_value(t, renderer_init(&r, &v, &media), Error.None)
	defer renderer_destroy(&r)
	px := render_frame(&r, 0)
	testing.expectf(t, len(r.ctx.diagnostics) == 0, "diagnostics: %v", r.ctx.diagnostics[:])
	mid := pixel(px, 80, 40, 24)
	testing.expectf(t, mid.r > 100 && mid.g < 40 && mid.b < 40, "box: %v", mid)
	testing.expect_value(t, pixel(px, 80, 2, 2), [4]u8{0, 0, 0, 255})
	green := false
	for y in 4 ..< 44 {
		for x in 8 ..< 72 {
			if pixel(px, 80, x, y) == {0, 255, 0, 255} {
				green = true
			}
		}
	}
	testing.expect(t, green, "the basic sphere is unlit green")
	cpu := strings.clone(string(px), context.temp_allocator)

	sync.guard(&sdl_lock)
	if !sdl.Init({.VIDEO}) {
		sdl.SetHint(sdl.HINT_VIDEO_DRIVER, "offscreen")
		if !sdl.Init({.VIDEO}) {
			log.info("no SDL video: GPU skipped")
			return
		}
	}
	defer sdl.Quit()
	device := sdl.CreateGPUDevice({.SPIRV, .MSL}, false, nil)
	if device == nil {
		log.infof("no SDL_GPU device (%s): GPU skipped", sdl.GetError())
		return
	}
	defer sdl.DestroyGPUDevice(device)
	backend: vgsdl.SDL_Backend
	if !testing.expect(t, vgsdl.init(&backend, device) == nil) {
		return
	}
	defer vgsdl.destroy(&backend)
	gpu3d := View3d_Gpu{device = device}
	defer view3d_gpu_destroy(&gpu3d)
	g: Renderer
	testing.expect_value(t, renderer_init(&g, &v, &media, 1, vgsdl.backend(&backend)), Error.None)
	defer renderer_destroy(&g)
	g.gpu3d = &gpu3d
	gpx := render_frame(&g, 0)
	testing.expectf(t, len(g.ctx.diagnostics) == 0, "diagnostics: %v", g.ctx.diagnostics[:])
	if !testing.expect_value(t, len(gpx), len(cpu)) {
		return
	}
	sum: f64
	for b, i in gpx {
		d := f64(b) - f64(cpu[i])
		sum += d * d
	}
	mse := sum / f64(len(gpx))
	psnr := 10 * math.log10(255 * 255 / max(mse, 1e-9))
	log.infof("GPU vs CPU: %.1f dB", psnr)
	testing.expectf(t, psnr > 30, "GPU vs CPU: %.1f dB", psnr)
}

// A sphere whose radius follows the frame makes a mesh every frame:
// `geometry_growth` once that happens on consecutive frames. One that keeps its
// radius and grows through `scale` makes one mesh and reports nothing.
@(private = "file")
render_growing :: proc(f: Frame, ctx: ^Context) {
	k := 1 + f32(f.index) * 0.1
	view3d(ctx, f, {
		w = 32, h = 32,
		camera = o3d.CAMERA_DEFAULT,
		meshes = {{geometry = {.Sphere, {k, 16, 8, 0, 0, 0, 0}}, scale = {1, 1, 1}, material = MATERIAL_RED}},
	})
}

@(private = "file")
render_scaled :: proc(f: Frame, ctx: ^Context) {
	k := 1 + f32(f.index) * 0.1
	view3d(ctx, f, {
		w = 32, h = 32,
		camera = o3d.CAMERA_DEFAULT,
		meshes = {{geometry = {.Sphere, {1, 16, 8, 0, 0, 0, 0}}, scale = {k, k, k}, material = MATERIAL_RED}},
	})
}

@(test)
test_view3d_geometry_growth :: proc(t: ^testing.T) {
	@(static) scenes: [2]Scene
	scenes = [2]Scene{{name = "Scaled", duration = Frames(3), render = render_scaled}, {name = "Growing", duration = Frames(3), render = render_growing}}
	v := Video{width = 32, height = 32, fps = 30, background = BLACK, scenes = scenes[:]}
	media: Media
	media_init(&media)
	defer media_destroy(&media)
	r: Renderer
	testing.expect_value(t, renderer_init(&r, &v, &media), Error.None)
	defer renderer_destroy(&r)
	growth := [6]int{}
	for f in 0 ..< 6 {
		diagnostics_clear(&r.ctx)
		render_frame(&r, f)
		for d in r.ctx.diagnostics {
			if d.code == .Geometry_Growth {
				growth[f] += 1
				testing.expect_value(t, d.name, "SphereGeometry")
				testing.expect_value(t, d.scene, "Growing")
			}
		}
	}
	// The scaled sphere: one mesh, no growth. The growing one's first frame
	// reuses the scaled sphere's (radius 1), then each frame makes another:
	// growth once it is made again frame after frame.
	testing.expect_value(t, growth, [6]int{0, 0, 0, 0, 0, 1})
	testing.expect_value(t, len(media.view3d.geometries.list), 3)
}

// Shapes of fixed parameters that first show up on later frames (a puff,
// then a plume) are no growth: each makes its one mesh.
@(test)
test_view3d_late_shapes_are_not_growth :: proc(t: ^testing.T) {
	render_late :: proc(f: Frame, ctx: ^Context) {
		meshes := make([dynamic]Mesh, context.temp_allocator)
		append(&meshes, Mesh{geometry = {.Sphere, {1, 16, 8, 0, 0, 0, 0}}, scale = {1, 1, 1}, material = MATERIAL_RED})
		if f.index >= 2 {
			append(&meshes, Mesh{geometry = {.Sphere, {2, 16, 8, 0, 0, 0, 0}}, scale = {1, 1, 1}, material = MATERIAL_RED})
		}
		if f.index >= 4 {
			append(&meshes, Mesh{geometry = {.Sphere, {3, 16, 8, 0, 0, 0, 0}}, scale = {1, 1, 1}, material = MATERIAL_RED})
		}
		view3d(ctx, f, {w = 32, h = 32, camera = o3d.CAMERA_DEFAULT, meshes = meshes[:]})
	}
	@(static) scenes: [1]Scene
	scenes = [1]Scene{{name = "Late", duration = Frames(6), render = render_late}}
	v := Video{width = 32, height = 32, fps = 30, background = BLACK, scenes = scenes[:]}
	media: Media
	media_init(&media)
	defer media_destroy(&media)
	r: Renderer
	testing.expect_value(t, renderer_init(&r, &v, &media), Error.None)
	defer renderer_destroy(&r)
	for f in 0 ..< 6 {
		diagnostics_clear(&r.ctx)
		render_frame(&r, f)
		for d in r.ctx.diagnostics {
			testing.expectf(t, d.code != .Geometry_Growth, "frame %d: %v", f, d)
		}
	}
	testing.expect_value(t, len(media.view3d.geometries.list), 3)
}

// A glTF model of the media folder (a triangle moving along x over one
// second, its "Slide" animation, and a "Shift" morph target): loaded with
// the media, posed at a time or with morph overrides, its errors reported;
// a file that is not glTF or requires an unsupported extension is a media
// problem.
@(test)
test_view3d_gltf :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_view3d_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	write :: proc(dir, name, text: string) -> bool {
		path, _ := filepath.join({dir, name}, context.temp_allocator)
		return os.write_entire_file(path, transmute([]u8)text) == nil
	}
	testing.expect(t, write(dir, "tri.gltf", test_gltf()))
	testing.expect(t, write(dir, "broken.glb", "not a model"))
	testing.expect(t, write(dir, "draco.gltf", `{"asset":{"version":"2.0"},"extensionsUsed":["KHR_draco_mesh_compression"],"extensionsRequired":["KHR_draco_mesh_compression"]}`))
	media: Media
	media_init(&media)
	defer media_destroy(&media)
	testing.expect_value(t, media_load_dir(&media, dir), Error.None)
	model, loaded := &media.view3d.models["tri.gltf"]
	testing.expect(t, loaded)
	if loaded {
		testing.expect_value(t, o3d.gltf_morph_target(model, "Shift"), 0)
	}
	kind, _ := media_kind_of("tri.gltf")
	testing.expect_value(t, kind, Media_Kind.Model)
	testing.expect_value(t, len(media.problems), 2)
	problems := make([dynamic]string, context.temp_allocator)
	for p in media.problems {
		append(&problems, diagnostic_message(p, context.temp_allocator))
	}
	broken_ok, draco_ok := false, false
	for msg in problems {
		if msg == `media file "broken.glb" can not be decoded as a 3D model (the data ends early)` {
			broken_ok = true
		}
		if msg == `media file "draco.gltf" can not be decoded as a 3D model (requires an unsupported glTF extension: KHR_draco_mesh_compression)` {
			draco_ok = true
		}
	}
	testing.expectf(t, broken_ok && draco_ok, "media problems: %v", problems[:])

	@(static) scenes: [1]Scene
	scenes = [1]Scene{{name = "Only", duration = Frames(1), render = proc(f: Frame, ctx: ^Context) {
		at := o3d.CAMERA_DEFAULT
		at.position = {0, 0, 3}
		view3d(ctx, f, {
			w = 40, h = 40,
			camera = at,
			lights = {{kind = .Ambient, color = {1, 1, 1}, intensity = 3}},
			models = {
				{src = "tri.gltf", scale = {1, 1, 1}, animation = "Slide", animation_index = -1, time = 0.5, loop = true, morphs = {{name = "Shift", weight = 1}, {name = "Wink", weight = 0.5}, {index = 4, weight = 0.2}}},
				{src = "tri.gltf", scale = {1, 1, 1}, animation = "Jump", animation_index = -1},
				{src = "missing.glb", scale = {1, 1, 1}, animation_index = -1},
			},
		})
	}}}
	v := Video{width = 40, height = 40, fps = 30, background = BLACK, scenes = scenes[:]}
	r: Renderer
	testing.expect_value(t, renderer_init(&r, &v, &media), Error.None)
	defer renderer_destroy(&r)
	px := render_frame(&r, 0)
	got := make([dynamic]string, context.temp_allocator)
	for d in r.ctx.diagnostics {
		append(&got, diagnostic_message(d, context.temp_allocator))
	}
	testing.expectf(
		t,
		len(got) == 4 &&
		got[0] == `model "tri.gltf" has no morph target "Wink"` &&
		got[1] == `model "tri.gltf" has no morph target "5"` &&
		got[2] == `model "tri.gltf" has no animation "Jump"` &&
		got[3] == `no model "missing.glb" in the media`,
		"diagnostics: %v",
		got[:],
	)
	// Halfway through "Slide" the node is at x = 0, and morph target "Shift"
	// (+0.8 in x) shifts the first triangle into the right half (around x = 29);
	// the second model draws at rest (x = -1, in the left half).
	lit_mid, lit_right := 0, 0
	for y in 0 ..< 40 {
		if pixel(px, 40, 20, y).r > 50 {
			lit_mid += 1
		}
		if pixel(px, 40, 29, y).r > 50 {
			lit_right += 1
		}
	}
	testing.expectf(t, lit_right > 4 && lit_mid == 0, "morphed triangle on right: right=%d mid=%d", lit_right, lit_mid)
	testing.expect_value(t, pixel(px, 40, 39, 20), [4]u8{0, 0, 0, 255})
}

// A self-contained glTF 2.0 file: one red triangle (positions, normals,
// indices), a morph target "Shift" (+0.8 along x), and an animation "Slide"
// moving its node from x = -1 to 1 over one second, the buffer embedded as
// base64.
@(private = "file")
test_gltf :: proc() -> string {
	Bin :: struct #packed {
		pos:   [3][3]f32,
		norm:  [3][3]f32,
		idx:   [3]u16,
		_:     u16,
		times: [2]f32,
		trans: [2][3]f32,
		dpos:  [3][3]f32,
	}
	#assert(size_of(Bin) == 148)
	b := Bin {
		pos   = {{-0.5, -0.5, 0}, {0.5, -0.5, 0}, {0, 0.5, 0}},
		norm  = {{0, 0, 1}, {0, 0, 1}, {0, 0, 1}},
		idx   = {0, 1, 2},
		times = {0, 1},
		trans = {{-1, 0, 0}, {1, 0, 0}},
		dpos  = {{0.8, 0, 0}, {0.8, 0, 0}, {0.8, 0, 0}},
	}
	data, _ := base64.encode(([^]u8)(&b)[:size_of(Bin)], allocator = context.temp_allocator)
	return fmt.tprintf(`{{
  "asset": {{"version": "2.0"}},
  "buffers": [{{"uri": "data:application/octet-stream;base64,%s", "byteLength": 148}}],
  "bufferViews": [
    {{"buffer": 0, "byteOffset": 0, "byteLength": 36}},
    {{"buffer": 0, "byteOffset": 36, "byteLength": 36}},
    {{"buffer": 0, "byteOffset": 72, "byteLength": 6}},
    {{"buffer": 0, "byteOffset": 80, "byteLength": 8}},
    {{"buffer": 0, "byteOffset": 88, "byteLength": 24}},
    {{"buffer": 0, "byteOffset": 112, "byteLength": 36}}
  ],
  "accessors": [
    {{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [-0.5, -0.5, 0], "max": [0.5, 0.5, 0]}},
    {{"bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3"}},
    {{"bufferView": 2, "componentType": 5123, "count": 3, "type": "SCALAR"}},
    {{"bufferView": 3, "componentType": 5126, "count": 2, "type": "SCALAR", "min": [0], "max": [1]}},
    {{"bufferView": 4, "componentType": 5126, "count": 2, "type": "VEC3"}},
    {{"bufferView": 5, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0.8, 0, 0], "max": [0.8, 0, 0]}}
  ],
  "materials": [{{"name": "Red", "pbrMetallicRoughness": {{"baseColorFactor": [1, 0, 0, 1], "metallicFactor": 0, "roughnessFactor": 1}}, "doubleSided": true}}],
  "meshes": [{{
    "primitives": [{{"attributes": {{"POSITION": 0, "NORMAL": 1}}, "indices": 2, "material": 0, "targets": [{{"POSITION": 5}}]}}],
    "weights": [0],
    "extras": {{"targetNames": ["Shift"]}}
  }}],
  "nodes": [{{"name": "tri", "mesh": 0, "translation": [-1, 0, 0]}}],
  "scenes": [{{"nodes": [0]}}],
  "scene": 0,
  "animations": [{{
    "name": "Slide",
    "samplers": [{{"input": 3, "output": 4, "interpolation": "LINEAR"}}],
    "channels": [{{"sampler": 0, "target": {{"node": 0, "path": "translation"}}}}]
  }}]
}}`, data)
}

@(private = "file")
sdl_lock: sync.Mutex

@(private = "file")
SHADER_VERT :: `varying vec2 vUv;
uniform float uShift;
void main() {
  vUv = uv;
  vec3 p = position + vec3(uShift, 0.0, 0.0);
  gl_Position = projectionMatrix * modelViewMatrix * vec4(p, 1.0);
}`

@(private = "file")
SHADER_FRAG :: `varying vec2 vUv;
uniform vec3 uColor;
void main() {
  gl_FragColor = vec4(uColor * (0.5 + 0.5 * vUv.x), 1.0);
}`

// ShaderMaterial on a mesh and a material override on a glTF model: rendered
// on the CPU and on the GPU (within 40 dB), compiled once across frames, and
// reporting compile errors, undeclared uniforms and unset uniforms while
// skipping failed draws.
@(test)
test_view3d_shader_material :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_view3d_shader_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	tri_path, _ := filepath.join({dir, "tri.gltf"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(tri_path, transmute([]u8)test_gltf()) == nil)

	media: Media
	media_init(&media)
	defer media_destroy(&media)
	testing.expect_value(t, media_load_dir(&media, dir), Error.None)

	render_clean :: proc(f: Frame, ctx: ^Context) {
		cam := o3d.CAMERA_DEFAULT
		cam.position = {0, 0, 3.5}
		override := Model_Material{material = MATERIAL_GREEN_BASIC}
		override.material.side = .Double
		view3d(ctx, f, {
			w = 80, h = 48,
			camera = cam,
			meshes = {{
				geometry = {.Box, {1, 1, 1, 1, 1, 1, 0}},
				position = {-0.8, 0, 0},
				rotation = {0.2, 0.4, 0},
				scale    = {1, 1, 1},
				shader   = Shader_Material{
					vertex_shader   = SHADER_VERT,
					fragment_shader = SHADER_FRAG,
					uniforms        = {{name = "uShift", value = {0}}, {name = "uColor", value = {0, 0.5, 1}}},
				},
			}},
			models = {{
				src             = "tri.gltf",
				position        = {0.8, 0, 0},
				scale           = {1.2, 1.2, 1.2},
				animation       = "Slide",
				animation_index = -1,
				time            = 0.5,
				loop            = true,
				material        = override,
			}},
		})
	}

	@(static) scenes: [1]Scene
	scenes = [1]Scene{{name = "Only", duration = Frames(2), render = render_clean}}
	v := Video{width = 80, height = 48, fps = 30, background = BLACK, scenes = scenes[:]}
	r: Renderer
	testing.expect_value(t, renderer_init(&r, &v, &media), Error.None)
	defer renderer_destroy(&r)
	px := render_frame(&r, 0)
	testing.expectf(t, len(r.ctx.diagnostics) == 0, "diagnostics: %v", r.ctx.diagnostics[:])
	// The ShaderMaterial box on the left is blue, the overridden glTF
	// triangle on the right is unlit green (its glTF material was red).
	left := pixel(px, 80, 28, 24)
	right := pixel(px, 80, 52, 24)
	testing.expectf(t, left.b > 120 && left.r == 0, "shader box: %v", left)
	testing.expect_value(t, right, [4]u8{0, 255, 0, 255})
	cpu := strings.clone(string(px), context.temp_allocator)
	// Second frame reuses the compiled shader.
	render_frame(&r, 1)
	testing.expect_value(t, len(media.view3d.shaders.list), 1)

	{
		sync.guard(&sdl_lock)
		if sdl.Init({.VIDEO}) || (sdl.SetHint(sdl.HINT_VIDEO_DRIVER, "offscreen") && sdl.Init({.VIDEO})) {
			defer sdl.Quit()
			if device := sdl.CreateGPUDevice({.SPIRV, .MSL}, false, nil); device != nil {
				defer sdl.DestroyGPUDevice(device)
				backend: vgsdl.SDL_Backend
				if testing.expect(t, vgsdl.init(&backend, device) == nil) {
					defer vgsdl.destroy(&backend)
					gpu3d := View3d_Gpu{device = device}
					defer view3d_gpu_destroy(&gpu3d)
					g: Renderer
					testing.expect_value(t, renderer_init(&g, &v, &media, 1, vgsdl.backend(&backend)), Error.None)
					defer renderer_destroy(&g)
					g.gpu3d = &gpu3d
					gpx := render_frame(&g, 0)
					testing.expectf(t, len(g.ctx.diagnostics) == 0, "diagnostics: %v", g.ctx.diagnostics[:])
					sum: f64
					for b, i in gpx {
						d := f64(b) - f64(cpu[i])
						sum += d * d
					}
					mse := sum / f64(len(gpx))
					psnr := 10 * math.log10(255 * 255 / max(mse, 1e-9))
					log.infof("ShaderMaterial GPU vs CPU: %.1f dB", psnr)
					testing.expectf(t, psnr > 40, "ShaderMaterial GPU vs CPU: %.1f dB", psnr)
				}
			}
		}
	}

	// Diagnostics: a broken shader reports its stage:line:col and skips its
	// draw; undeclared and unset uniforms warn.
	render_problems :: proc(f: Frame, ctx: ^Context) {
		view3d(ctx, f, {
			w = 80, h = 48,
			camera = o3d.CAMERA_DEFAULT,
			meshes = {
				{
					geometry = {.Box, {2, 2, 2, 1, 1, 1, 0}},
					scale    = {1, 1, 1},
					shader   = Shader_Material{
						vertex_shader   = SHADER_VERT,
						fragment_shader = "void main() {\n  gl_FragColor = nope;\n}",
					},
				},
				{
					geometry = {.Sphere, {0.5, 8, 6, 0, 0, 0, 0}},
					scale    = {1, 1, 1},
					shader   = Shader_Material{
						vertex_shader   = SHADER_VERT,
						fragment_shader = SHADER_FRAG,
						uniforms        = {{name = "uColor", value = {1, 0, 0}}, {name = "uExtra", value = {1}}},
					},
				},
			},
		})
	}
	scenes = [1]Scene{{name = "Problems", duration = Frames(1), render = render_problems}}
	diagnostics_clear(&r.ctx)
	px = render_frame(&r, 0)
	compile_err, undeclared, unset := false, false, false
	for d in r.ctx.diagnostics {
		msg := diagnostic_message(d, context.temp_allocator)
		if d.code == .Shader_Compile && strings.has_prefix(msg, "shader Fragment:2:") {
			compile_err = true
		}
		if d.code == .Shader_Undeclared_Uniform && msg == "shader ShaderMaterial: uniform `uExtra` is not declared" {
			undeclared = true
		}
		if d.code == .Shader_Unset_Uniform && msg == "shader ShaderMaterial: uniform `uShift` is not set" {
			unset = true
		}
	}
	testing.expectf(t, compile_err && undeclared && unset, "diagnostics: %v", r.ctx.diagnostics[:])
}

// Per-frame polylines, points, wireframe and instanced meshes: animating
// path points across frames adds nothing to `media.view3d.geometries` and
// never triggers `geometry_growth`.
@(test)
test_view3d_manim :: proc(t: ^testing.T) {
	render_manim :: proc(f: Frame, ctx: ^Context) {
		k := f32(f.index) * 0.2
		line_mat := MATERIAL_GREEN_BASIC
		line_mat.mode = .Lines
		line_mat.size = 0.08
		pt_mat := MATERIAL_RED
		pt_mat.flags = {.Basic}
		pt_mat.mode = .Points
		pt_mat.size = 0.15
		view3d(ctx, f, {
			w = 64, h = 48,
			tone_mapping = .AgX,
			tone_mapping_exposure = 1,
			fog = {kind = .Exp2, color = {0.1, 0.1, 0.2}, density = 0.02},
			camera = {position = {0, 0, 4}, target = {0, 0, 0}, fov = 45, near = 0.1, far = 100},
			lights = {{kind = .Ambient, color = {1, 1, 1}, intensity = 0.5}, {kind = .Spot, color = {1, 1, 1}, intensity = 10, position = {0, 2, 3}, angle = math.PI / 3, decay = 2}},
			meshes = {
				{
					path_kind = .Polyline,
					points    = {{-1, -0.5 + k, 0}, {0, 0.5 - k, 0}, {1, -0.5 + k, 0}},
					scale     = {1, 1, 1},
					material  = line_mat,
				},
				{
					path_kind = .Points,
					points    = {{0, 0, 0}},
					scale     = {1, 1, 1},
					material  = pt_mat,
				},
				{
					geometry  = {.Box, {0.4, 0.4, 0.4, 1, 1, 1, 0}},
					scale     = {1, 1, 1},
					material  = MATERIAL_RED,
					instances = {
						{transform = o3d.compose({-1.2, 0, 0}, {}, {1, 1, 1}), color = {0, 0.5, 1}, has_color = true},
						{transform = o3d.compose({1.2, 0, 0}, {}, {1, 1, 1}), color = {1, 0.8, 0}, has_color = true},
					},
				},
			},
		})
	}
	@(static) scenes: [1]Scene
	scenes = [1]Scene{{name = "Manim", duration = Frames(3), render = render_manim}}
	v := Video{width = 64, height = 48, fps = 30, background = BLACK, scenes = scenes[:]}
	media: Media
	media_init(&media)
	defer media_destroy(&media)
	r: Renderer
	testing.expect_value(t, renderer_init(&r, &v, &media), Error.None)
	defer renderer_destroy(&r)
	for f in 0 ..< 3 {
		diagnostics_clear(&r.ctx)
		px := render_frame(&r, f)
		testing.expectf(t, len(r.ctx.diagnostics) == 0, "frame %d diagnostics: %v", f, r.ctx.diagnostics[:])
		if f == 0 {
			mid := pixel(px, 64, 32, 24)
			testing.expectf(t, mid.r > 150, "center point lit: %v", mid)
		}
	}
	// Only the unit box was added to the media's geometry table.
	testing.expect_value(t, len(media.view3d.geometries.list), 1)
}

@(test)
test_view3d_threemf :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_view3d_3mf_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)

	model_xml := `<?xml version="1.0" encoding="UTF-8"?>
<model unit="meter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
	<resources>
		<basematerials id="1">
			<base name="Red" displaycolor="#FF0000"/>
		</basematerials>
		<object id="2" pid="1" pindex="0" type="model">
			<mesh>
				<vertices>
					<vertex x="-1" y="0" z="-1"/>
					<vertex x="1" y="0" z="-1"/>
					<vertex x="0" y="0" z="1"/>
				</vertices>
				<triangles>
					<triangle v1="0" v2="1" v3="2"/>
				</triangles>
			</mesh>
		</object>
	</resources>
	<build>
		<item objectid="2"/>
	</build>
</model>`

	// Build a minimal Stored ZIP containing "3D/3dmodel.model".
	name_str :: "3D/3dmodel.model"
	zip_buf := make([dynamic]u8, 0, 512, context.temp_allocator)
	put16 :: proc(b: ^[dynamic]u8, v: u16) { append(b, u8(v), u8(v >> 8)) }
	put32 :: proc(b: ^[dynamic]u8, v: u32) { append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)) }
	put32(&zip_buf, 0x04034b50)
	put16(&zip_buf, 20); put16(&zip_buf, 0); put16(&zip_buf, 0); put16(&zip_buf, 0); put16(&zip_buf, 0)
	put32(&zip_buf, 0); put32(&zip_buf, u32(len(model_xml))); put32(&zip_buf, u32(len(model_xml)))
	put16(&zip_buf, u16(len(name_str))); put16(&zip_buf, 0)
	append(&zip_buf, ..transmute([]u8)string(name_str))
	append(&zip_buf, ..transmute([]u8)model_xml)
	cd_off := u32(len(zip_buf))
	put32(&zip_buf, 0x02014b50)
	put16(&zip_buf, 20); put16(&zip_buf, 20); put16(&zip_buf, 0); put16(&zip_buf, 0); put16(&zip_buf, 0); put16(&zip_buf, 0)
	put32(&zip_buf, 0); put32(&zip_buf, u32(len(model_xml))); put32(&zip_buf, u32(len(model_xml)))
	put16(&zip_buf, u16(len(name_str))); put16(&zip_buf, 0); put16(&zip_buf, 0); put16(&zip_buf, 0); put16(&zip_buf, 0)
	put32(&zip_buf, 0); put32(&zip_buf, 0)
	append(&zip_buf, ..transmute([]u8)string(name_str))
	cd_sz := u32(len(zip_buf)) - cd_off
	put32(&zip_buf, 0x06054b50)
	put16(&zip_buf, 0); put16(&zip_buf, 0); put16(&zip_buf, 1); put16(&zip_buf, 1)
	put32(&zip_buf, cd_sz); put32(&zip_buf, cd_off); put16(&zip_buf, 0)

	p_ok, _ := filepath.join({dir, "part.3mf"}, context.temp_allocator)
	p_bad, _ := filepath.join({dir, "broken.3mf"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(p_ok, zip_buf[:]) == nil)
	testing.expect(t, os.write_entire_file(p_bad, transmute([]u8)string("not a 3mf zip archive")) == nil)

	media: Media
	media_init(&media)
	defer media_destroy(&media)
	testing.expect_value(t, media_load_dir(&media, dir), Error.None)
	_, loaded := media.view3d.models["part.3mf"]
	testing.expect(t, loaded)
	testing.expect_value(t, len(media.problems), 1)
	if len(media.problems) == 1 {
		msg := diagnostic_message(media.problems[0], context.temp_allocator)
		testing.expect_value(t, msg, `media file "broken.3mf" can not be decoded as a 3MF model (not a 3MF ZIP archive)`)
	}

	@(static) scenes: [1]Scene
	scenes = [1]Scene{{name = "Only", duration = Frames(1), render = proc(f: Frame, ctx: ^Context) {
		at := o3d.CAMERA_DEFAULT
		at.position = {0, 0, 3}
		view3d(ctx, f, {
			w = 40, h = 40,
			camera = at,
			lights = {{kind = .Ambient, color = {1, 1, 1}, intensity = 3}},
			models = {{src = "part.3mf", scale = {1, 1, 1}, animation_index = -1}},
		})
	}}}
	v := Video{width = 40, height = 40, fps = 30, background = BLACK, scenes = scenes[:]}
	r: Renderer
	testing.expect_value(t, renderer_init(&r, &v, &media), Error.None)
	defer renderer_destroy(&r)
	px := render_frame(&r, 0)
	testing.expect(t, pixel(px, 40, 20, 20).r > 150)
}

// Labels on the CPU: a label behind a green box is hidden where the box is
// nearer, one in front of nothing shows whole, its panel's bottom centre
// on its point.
@(test)
test_view3d_labels :: proc(t: ^testing.T) {
	render_labels :: proc(f: Frame, ctx: ^Context) {
		panel :: proc(ctx: ^Context) -> i32 {
			content := shader_content_begin(ctx)
			rect(ctx, {x = 0, y = 0, w = 10, h = 6, fill = rgb(0, 0, 255)})
			group_end(ctx)
			return content
		}
		behind, front := panel(ctx), panel(ctx)
		labels := make([]View3d_Label, 2, context.temp_allocator)
		labels[0] = {at = {0, -0.2, -1}, w = 10, h = 6, content = behind}
		labels[1] = {at = {1.4, -0.2, 1}, w = 10, h = 6, content = front}
		meshes := make([]Mesh, 1, context.temp_allocator)
		meshes[0] = {geometry = {.Box, {1.4, 1.4, 0.1, 1, 1, 1, 0}}, scale = {1, 1, 1}, material = MATERIAL_GREEN_BASIC}
		view3d(ctx, f, {w = 64, h = 48, camera = o3d.CAMERA_DEFAULT, meshes = meshes, labels = labels})
	}
	@(static) scenes: [1]Scene
	scenes = [1]Scene{{name = "Labels", duration = Frames(1), render = render_labels}}
	v := Video{width = 64, height = 48, fps = 30, background = BLACK, scenes = scenes[:]}
	media: Media
	media_init(&media)
	defer media_destroy(&media)
	r: Renderer
	testing.expect_value(t, renderer_init(&r, &v, &media), Error.None)
	defer renderer_destroy(&r)
	px := render_frame(&r, 0)
	testing.expectf(t, len(r.ctx.diagnostics) == 0, "diagnostics: %v", r.ctx.diagnostics[:])
	blue_on_box, blue := 0, 0
	for y in 0 ..< 48 {
		for x in 0 ..< 64 {
			p := pixel(px, 64, x, y)
			if p.b > 200 && p.r < 60 && p.g < 60 {
				blue += 1
				if x >= 22 && x < 42 && y >= 14 && y < 34 {
					blue_on_box += 1
				}
			}
		}
	}
	// the box hides the label behind it; the one in front shows its 10 x 6
	testing.expect_value(t, blue_on_box, 0)
	testing.expectf(t, blue >= 40 && blue <= 80, "%d blue pixels", blue)
}

// A lens flare's elements show over everything, `distance` of the way from
// its point to the point's mirror through the centre, and not at all while
// the scene hides its point.
@(test)
test_view3d_lensflares :: proc(t: ^testing.T) {
	CLEAR :: o3d.Vec3{1.0, 0.6, 0}
	render_flares :: proc(f: Frame, ctx: ^Context) {
		panel :: proc(ctx: ^Context) -> i32 {
			content := shader_content_begin(ctx)
			rect(ctx, {x = 0, y = 0, w = 6, h = 6, fill = rgb(0, 0, 255)})
			group_end(ctx)
			return content
		}
		labels := make([]View3d_Label, 3, context.temp_allocator)
		// behind the box: hidden, though drawn over it when seen
		labels[0] = {at = {0, 0, -1}, w = 6, h = 6, content = panel(ctx), flare = true, distance = 0.5, occlusion_radius = 2}
		// clear of it: on its point and on the point's mirror
		labels[1] = {at = CLEAR, w = 6, h = 6, content = panel(ctx), flare = true, distance = 0, occlusion_radius = 2}
		labels[2] = {at = CLEAR, w = 6, h = 6, content = panel(ctx), flare = true, distance = 1, occlusion_radius = 2}
		meshes := make([]Mesh, 1, context.temp_allocator)
		meshes[0] = {geometry = {.Box, {1.4, 1.4, 0.1, 1, 1, 1, 0}}, scale = {1, 1, 1}, material = MATERIAL_GREEN_BASIC}
		view3d(ctx, f, {w = 64, h = 48, camera = o3d.CAMERA_DEFAULT, meshes = meshes, labels = labels})
	}
	@(static) scenes: [1]Scene
	scenes = [1]Scene{{name = "Flares", duration = Frames(1), render = render_flares}}
	v := Video{width = 64, height = 48, fps = 30, background = BLACK, scenes = scenes[:]}
	media: Media
	media_init(&media)
	defer media_destroy(&media)
	r: Renderer
	testing.expect_value(t, renderer_init(&r, &v, &media), Error.None)
	defer renderer_destroy(&r)
	px := render_frame(&r, 0)
	testing.expectf(t, len(r.ctx.diagnostics) == 0, "diagnostics: %v", r.ctx.diagnostics[:])
	at, _, _ := o3d.camera_project(o3d.CAMERA_DEFAULT, 64, 48, CLEAR)
	mirror := o3d.Vec2{64, 48} - at
	near :: proc(x, y: int, p: o3d.Vec2) -> bool {
		return abs(f32(x) + 0.5 - p.x) < 5 && abs(f32(y) + 0.5 - p.y) < 5
	}
	on_point, on_mirror, centre, other := 0, 0, 0, 0
	for y in 0 ..< 48 {
		for x in 0 ..< 64 {
			p := pixel(px, 64, x, y)
			if p.b < 200 || p.r > 60 {
				continue
			}
			switch {
			case near(x, y, at):
				on_point += 1
			case near(x, y, mirror):
				on_mirror += 1
			case near(x, y, {32, 24}):
				centre += 1
			case:
				other += 1
			}
		}
	}
	testing.expectf(t, on_point >= 25 && on_point <= 49, "%d blue pixels on the point", on_point)
	testing.expectf(t, on_mirror >= 25 && on_mirror <= 49, "%d blue pixels on its mirror", on_mirror)
	testing.expect_value(t, centre, 0)
	testing.expect_value(t, other, 0)
}

// A ShaderMaterial given to one part of a model (here its material "Red") is
// compiled and drawn in place of the file's material (red): the triangle
// draws green, with nothing else in the view to compile that shader first.
@(test)
test_view3d_part_shader :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_part_shader_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "tri.gltf"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, transmute([]u8)test_gltf()) == nil)
	media: Media
	media_init(&media)
	defer media_destroy(&media)
	testing.expect_value(t, media_load_dir(&media, dir), Error.None)
	@(static) scenes: [1]Scene
	scenes = [1]Scene{{name = "Only", duration = Frames(1), render = proc(f: Frame, ctx: ^Context) {
		at := o3d.CAMERA_DEFAULT
		at.position = {0, 0, 3}
		parts := make([]Model_Part, 1, context.temp_allocator)
		parts[0] = {of = .Material, name = "Red", state = {}, material = Model_Material{
			material = o3d.MATERIAL_DEFAULT,
			shader = Shader_Material{
				vertex_shader = "void main() { gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }",
				fragment_shader = "void main() { gl_FragColor = vec4(0.0, 1.0, 0.0, 1.0); }",
			},
		}}
		view3d(ctx, f, {
			w = 40, h = 40,
			camera = at,
			lights = {{kind = .Ambient, color = {1, 1, 1}, intensity = 3}},
			models = {{src = "tri.gltf", scale = {1, 1, 1}, animation_index = -1, parts = parts}},
		})
	}}}
	v := Video{width = 40, height = 40, fps = 30, background = BLACK, scenes = scenes[:]}
	r: Renderer
	testing.expect_value(t, renderer_init(&r, &v, &media), Error.None)
	defer renderer_destroy(&r)
	px := render_frame(&r, 0)
	testing.expectf(t, len(r.ctx.diagnostics) == 0, "diagnostics: %v", r.ctx.diagnostics[:])
	green, red := 0, 0
	for y in 0 ..< 40 {
		for x in 0 ..< 40 {
			p := pixel(px, 40, x, y)
			green += 1 if p.g > 200 && p.r < 50 else 0
			red += 1 if p.r > 50 else 0
		}
	}
	testing.expectf(t, green > 20 && red == 0, "green %d, red %d", green, red)
}

// An emitter's births: steady ones at i / rate from `start` until `stop`,
// bursts at once, each alive for its lifetime. On a body with `world_space`,
// a particle is placed by the body as it was when born and keeps the body's
// velocity from then (on a body speeding up, x = t², it falls behind); one
// riding the body stays with it.
@(test)
test_particle_births_and_world_space :: proc(t: ^testing.T) {
	bursts := [2]Particle_Burst{{t = 0.2, count = 5}, {t = 0.05, count = 3}}
	e := Particle_Emitter{rate = 10, lifetime = 1, time = 1, start = 0.5, stop = 0.8, bursts = bursts[:], size = {1, 1}}
	testing.expect_value(t, len(particle_births(e)), 3 + 5 + 3)       // 0.5, 0.6, 0.7; both bursts
	e.time = 1.1
	testing.expect_value(t, len(particle_births(e)), 3 + 5)           // the 0.05 burst is gone
	e.stop = max(f32)
	testing.expect_value(t, len(particle_births(e)), 7 + 5)           // 0.5 .. 1.1

	speeding :: proc(data: rawptr, body: int, at: f32) -> (pose: o3d.Mat4, velocity: o3d.Vec3) {
		return o3d.compose({at * at, 0, 0}), {2 * at, 0, 0}
	}
	steady := Particle_Emitter{rate = 4, lifetime = 2, time = 1, stop = max(f32), size = {1, 1}, world_space = true}
	steady.attach.track = {sample = speeding}
	births := particle_births(steady)
	testing.expect_value(t, len(births), 5)                           // 0, 0.25, .. 1
	behind := particle_rows(steady, 1, births)
	for b, k in births {
		want := b.at * b.at + 2 * b.at * (steady.time - b.at)
		testing.expectf(t, abs(behind[k].position.x - want) < 1e-5, "born at %v: x %v, want %v", b.at, behind[k].position.x, want)
	}
	steady.world_space = false
	pose, _ := speeding(nil, 0, steady.time)
	riding := particle_rows(steady, pose, births)
	for p in riding {
		testing.expectf(t, abs(p.position.x - 1) < 1e-5, "riding: x %v", p.position.x)
	}
}
