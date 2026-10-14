package onimite

import "core:encoding/base64"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
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

// A sphere whose radius follows the frame makes a mesh every frame: from
// the scene's second frame on, `geometry_growth`. One that keeps its
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
	// The scaled sphere: one mesh, no growth; the growing one: its first
	// frame makes one, each later frame another.
	testing.expect_value(t, growth, [6]int{0, 0, 0, 0, 1, 1})
	testing.expect_value(t, len(media.view3d.geometries.list), 3)
}

// A glTF model of the media folder (a triangle moving along x over one
// second, its "Slide" animation): loaded with the media, posed at a time,
// its errors reported; a file that is not glTF is a media problem.
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
	media: Media
	media_init(&media)
	defer media_destroy(&media)
	testing.expect_value(t, media_load_dir(&media, dir), Error.None)
	_, loaded := media.view3d.models["tri.gltf"]
	testing.expect(t, loaded)
	kind, _ := media_kind_of("tri.gltf")
	testing.expect_value(t, kind, Media_Kind.Model)
	testing.expect_value(t, len(media.problems), 1)
	if len(media.problems) == 1 {
		testing.expect_value(t, diagnostic_message(media.problems[0], context.temp_allocator), `media file "broken.glb" can not be decoded as a glTF 2.0 model`)
	}

	@(static) scenes: [1]Scene
	scenes = [1]Scene{{name = "Only", duration = Frames(1), render = proc(f: Frame, ctx: ^Context) {
		at := o3d.CAMERA_DEFAULT
		at.position = {0, 0, 3}
		view3d(ctx, f, {
			w = 40, h = 40,
			camera = at,
			lights = {{kind = .Ambient, color = {1, 1, 1}, intensity = 3}},
			models = {
				{src = "tri.gltf", scale = {1, 1, 1}, animation = "Slide", animation_index = -1, time = 0.5, loop = true},
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
	testing.expectf(t, len(got) == 2 && got[0] == `glTF model "tri.gltf" has no animation "Jump"` && got[1] == `no glTF model "missing.glb" in the media`, "diagnostics: %v", got[:])
	// Halfway through "Slide" the triangle is at x = 0, drawn twice (the
	// second at rest, x = -1, in the left half); the right edge is empty.
	lit := 0
	for y in 0 ..< 40 {
		if pixel(px, 40, 20, y).r > 50 {
			lit += 1
		}
	}
	testing.expectf(t, lit > 4, "triangle at the middle: %d lit rows", lit)
	testing.expect_value(t, pixel(px, 40, 39, 20), [4]u8{0, 0, 0, 255})
}

// A self-contained glTF 2.0 file: one red triangle (positions, normals,
// indices) and an animation "Slide" moving its node from x = -1 to 1 over
// one second, the buffer embedded as base64.
@(private = "file")
test_gltf :: proc() -> string {
	Bin :: struct #packed {
		pos:   [3][3]f32,
		norm:  [3][3]f32,
		idx:   [3]u16,
		_:     u16,
		times: [2]f32,
		trans: [2][3]f32,
	}
	#assert(size_of(Bin) == 112)
	b := Bin {
		pos   = {{-0.5, -0.5, 0}, {0.5, -0.5, 0}, {0, 0.5, 0}},
		norm  = {{0, 0, 1}, {0, 0, 1}, {0, 0, 1}},
		idx   = {0, 1, 2},
		times = {0, 1},
		trans = {{-1, 0, 0}, {1, 0, 0}},
	}
	data, _ := base64.encode(([^]u8)(&b)[:size_of(Bin)], allocator = context.temp_allocator)
	return fmt.tprintf(`{{
  "asset": {{"version": "2.0"}},
  "buffers": [{{"uri": "data:application/octet-stream;base64,%s", "byteLength": 112}}],
  "bufferViews": [
    {{"buffer": 0, "byteOffset": 0, "byteLength": 36}},
    {{"buffer": 0, "byteOffset": 36, "byteLength": 36}},
    {{"buffer": 0, "byteOffset": 72, "byteLength": 6}},
    {{"buffer": 0, "byteOffset": 80, "byteLength": 8}},
    {{"buffer": 0, "byteOffset": 88, "byteLength": 24}}
  ],
  "accessors": [
    {{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [-0.5, -0.5, 0], "max": [0.5, 0.5, 0]}},
    {{"bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3"}},
    {{"bufferView": 2, "componentType": 5123, "count": 3, "type": "SCALAR"}},
    {{"bufferView": 3, "componentType": 5126, "count": 2, "type": "SCALAR", "min": [0], "max": [1]}},
    {{"bufferView": 4, "componentType": 5126, "count": 2, "type": "VEC3"}}
  ],
  "materials": [{{"pbrMetallicRoughness": {{"baseColorFactor": [1, 0, 0, 1], "metallicFactor": 0, "roughnessFactor": 1}}, "doubleSided": true}}],
  "meshes": [{{"primitives": [{{"attributes": {{"POSITION": 0, "NORMAL": 1}}, "indices": 2, "material": 0}}]}}],
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
