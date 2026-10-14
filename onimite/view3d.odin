package onimite

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "deps:o3d"
import "deps:oksl"
import vg "deps:ovg"

// 3D layers (`view3d{}`): a scene in three.js's terms (a camera, lights,
// meshes of primitive geometry with a material, glTF models of the media
// posed at a time of their animation, an environment and a background
// from media images) drawn by o3d into an image of the box's on-screen
// pixel size and filled into the box like an image, so transforms, clips,
// masks, opacity and blending apply as to any node. The node keeps the
// scene as the script described it. Drawing makes what the media's 3D
// tables lack (its meshes, its images' textures, its custom shaders), turns
// the node into an `o3d.Scene` against them (`view3d_scene`) and renders
// that: on the CPU at once (`o3d.software_render` on the renderer's pool),
// or, when the renderer's 3D layers render on a GPU (`Renderer.gpu3d`), as
// a job the GPU's thread runs into the image before the frame is drawn
// (view3d_gpu.odin).
//
// o3d keeps every mesh it makes for the life of its tables, one per set of
// geometry parameters, so a size changes through a mesh's `scale`, as
// three.js animates `mesh.scale`. A frame that makes a mesh of a geometry
// type its renderer drew on an earlier frame of the same scene reports
// `geometry_growth`.

View3d :: struct {
	x, y, w, h:            f32,
	opacity:               Maybe(f32),
	camera:                o3d.Camera,
	lights:                []o3d.Light,
	meshes:                []Mesh,
	models:                []Model_Pose,
	// Media images: the equirectangular environment lighting the scene
	// and the background behind it ("" for none), and their strengths.
	environment:           string,
	environment_intensity: f32,
	background:            string,
	background_intensity:  f32,
	background_blurriness: f32,
	// The timeline index of the scene that drew it (-1: the video's own
	// render), for `geometry_growth`.
	scene_index:           int,
}

// A custom shader material (`type = "ShaderMaterial"`): its GLSL ES
// sources, GLSL 3 flag and per-frame uniforms.
Shader_Material :: struct {
	vertex_shader:   string,
	fragment_shader: string,
	glsl3:           bool,
	uniforms:        []o3d.Uniform,
}

// A material override on a glTF model: its material, texture maps and
// optional ShaderMaterial.
Model_Material :: struct {
	material: o3d.Material,
	maps:     [Texture_Map]string,
	shader:   Maybe(Shader_Material),
}

// A mesh: primitive geometry (its type and three.js parameters, see
// `GEOMETRY_TYPES`), its transform (position, Euler XYZ rotation in
// radians, scale) and its material, whose texture maps are media images
// by name (or a custom `ShaderMaterial`).
Mesh :: struct {
	geometry: o3d.Geometry_Key,
	position: o3d.Vec3,
	rotation: o3d.Vec3,
	scale:    o3d.Vec3,
	material: o3d.Material,
	maps:     [Texture_Map]string,
	shader:   Maybe(Shader_Material),
}

// A material's texture maps, by their three.js names (`TEXTURE_MAPS`).
Texture_Map :: enum u8 {
	Color,
	Normal,
	Roughness,
	Metalness,
	Emissive,
}

@(rodata)
TEXTURE_MAPS := [Texture_Map]cstring {
	.Color     = "map",
	.Normal    = "normal_map",
	.Roughness = "roughness_map",
	.Metalness = "metalness_map",
	.Emissive  = "emissive_map",
}

// The material's texture of map `k`.
material_map :: proc "contextless" (m: ^o3d.Material, k: Texture_Map) -> ^o3d.Texture_Id {
	switch k {
	case .Color:
		return &m.color_map
	case .Normal:
		return &m.normal_map
	case .Roughness:
		return &m.roughness_map
	case .Metalness:
		return &m.metalness_map
	case .Emissive:
		return &m.emissive_map
	}
	return &m.color_map
}

// A glTF model of the media, posed at `time` seconds of an animation (by
// name, else by index; neither: its rest pose), placed by a transform, its
// materials given `flags` (shadows) or replaced by `material`.
Model_Pose :: struct {
	src:             string,
	position:        o3d.Vec3,
	rotation:        o3d.Vec3,
	scale:           o3d.Vec3,
	animation:       string,
	animation_index: int,
	time:            f32,
	loop:            bool,
	flags:           o3d.Material_Flags,
	material:        Maybe(Model_Material),
}

// A geometry type: its three.js class and its constructor's parameters in
// order (`o3d.Geometry_Key.params`; a nil name ends them), each with its
// default and, for counts, its least value.
Geometry_Param :: struct {
	name:    cstring,
	kind:    enum u8 {
		Size,
		Count,
		Flag,
	},
	default: f32,
	least:   f32,
}

Geometry_Type :: struct {
	name:   string,
	params: [o3d.PARAMS]Geometry_Param,
}

@(rodata)
GEOMETRY_TYPES := [o3d.Primitive]Geometry_Type {
	.None     = {},
	.Box      = {"BoxGeometry", {{"width", .Size, 1, 0}, {"height", .Size, 1, 0}, {"depth", .Size, 1, 0}, {"width_segments", .Count, 1, 1}, {"height_segments", .Count, 1, 1}, {"depth_segments", .Count, 1, 1}, {}}},
	.Sphere   = {"SphereGeometry", {{"radius", .Size, 1, 0}, {"width_segments", .Count, 32, 3}, {"height_segments", .Count, 16, 2}, {}, {}, {}, {}}},
	.Plane    = {"PlaneGeometry", {{"width", .Size, 1, 0}, {"height", .Size, 1, 0}, {"width_segments", .Count, 1, 1}, {"height_segments", .Count, 1, 1}, {}, {}, {}}},
	.Cylinder = {"CylinderGeometry", {{"radius_top", .Size, 1, 0}, {"radius_bottom", .Size, 1, 0}, {"height", .Size, 1, 0}, {"radial_segments", .Count, 32, 3}, {"height_segments", .Count, 1, 1}, {"open_ended", .Flag, 0, 0}, {}}},
	.Torus    = {"TorusGeometry", {{"radius", .Size, 1, 0}, {"tube", .Size, 0.4, 0}, {"radial_segments", .Count, 12, 3}, {"tubular_segments", .Count, 48, 3}, {}, {}, {}}},
}

// Adds a 3D layer drawing at frame `f` (its scene keys `geometry_growth`).
view3d :: proc(ctx: ^Context, f: Frame, v: View3d) {
	v := v
	arena := ctx.tree.arena
	v.lights = clone_slice(v.lights, arena)
	v.meshes = clone_slice(v.meshes, arena)
	for &m in v.meshes {
		for &name in m.maps {
			name = strings.clone(name, arena)
		}
		clone_shader_material(&m.shader, arena)
	}
	v.models = clone_slice(v.models, arena)
	for &m in v.models {
		m.src = strings.clone(m.src, arena)
		m.animation = strings.clone(m.animation, arena)
		if over, ok := &m.material.?; ok {
			for &name in over.maps {
				name = strings.clone(name, arena)
			}
			clone_shader_material(&over.shader, arena)
		}
	}
	v.environment = strings.clone(v.environment, arena)
	v.background = strings.clone(v.background, arena)
	v.scene_index = f.scene.index if f.scene != nil else -1
	tree_add(&ctx.tree, v)
}

@(private = "file")
clone_shader_material :: proc(sh: ^Maybe(Shader_Material), arena: runtime.Allocator) {
	s, ok := &sh.?
	if !ok {
		return
	}
	s.vertex_shader = strings.clone(s.vertex_shader, arena)
	s.fragment_shader = strings.clone(s.fragment_shader, arena)
	s.uniforms = clone_slice(s.uniforms, arena)
	for &u in s.uniforms {
		u.name = strings.clone(u.name, arena)
		u.value = clone_slice(u.value, arena)
	}
}

// What a 3D layer shows, in a few words ("3 meshes, 1 model").
view3d_contents :: proc(n: View3d) -> string {
	meshes, models := len(n.meshes), len(n.models)
	return fmt.tprintf("%d mesh%s, %d model%s", meshes, "" if meshes == 1 else "es", models, "" if models == 1 else "s")
}

@(private = "file")
clone_slice :: proc(s: []$T, allocator: runtime.Allocator) -> []T {
	out := make([]T, len(s), allocator)
	copy(out, s)
	return out
}

// ---- the media's 3D tables ----------------------------------------------------------------

// What 3D layers draw from, kept as long as the media: o3d's geometry,
// texture and shader tables, the glTF models of the media folder by file
// name (loaded with it), and the media images used as textures by name
// (added the first time a frame uses them). Frames built on several
// threads at once read and add to them: `lock` is taken shared to read
// (filling a scene, rendering it) and exclusive to add. Models are posed in
// each renderer's own `View3d_State.pose`, so posing only reads them.
View3d_Media :: struct {
	lock:        sync.RW_Mutex,
	geometries:  o3d.Geometries,
	textures:    o3d.Textures,
	shaders:     o3d.Shaders,
	models:      map[string]o3d.Model,
	textures_of: map[string]o3d.Texture_Id,
	// What the tables grow in, whichever thread adds to them.
	allocator:   runtime.Allocator,
}

@(private)
view3d_media_init :: proc(v: ^View3d_Media) {
	v.allocator = context.allocator
	v.models = make(map[string]o3d.Model)
	v.textures_of = make(map[string]o3d.Texture_Id)
}

@(private)
view3d_media_destroy :: proc(v: ^View3d_Media) {
	context.allocator = v.allocator
	for name, &m in v.models {
		delete(name)
		o3d.model_destroy(&m)
	}
	delete(v.models)
	for name in v.textures_of {
		delete(name)
	}
	delete(v.textures_of)
	o3d.geometries_destroy(&v.geometries)
	o3d.textures_destroy(&v.textures)
	o3d.shaders_destroy(&v.shaders)
	v^ = {}
}

// Loads glTF 2.0 file `path` (.glb, or .gltf with its files beside it) as
// model `name`: its meshes and images join the tables. Why it did not load
// otherwise.
@(private)
view3d_add_model :: proc(v: ^View3d_Media, name, path: string) -> o3d.Gltf_Error {
	context.allocator = v.allocator
	sync.guard(&v.lock)
	model, err := o3d.gltf_load(path, &v.geometries, &v.textures)
	if err != .None {
		return err
	}
	if old, exists := &v.models[name]; exists {
		o3d.model_destroy(old)
		old^ = model
	} else {
		v.models[strings.clone(name)] = model
	}
	return .None
}

// Makes the meshes of node `n` that the tables lack; returns the geometry
// types it made meshes of.
@(private = "file")
view3d_make_geometry :: proc(m: ^Media, n: View3d) -> (made: bit_set[o3d.Primitive]) {
	v := &m.view3d
	context.allocator = v.allocator
	for mesh in n.meshes {
		sync.shared_lock(&v.lock)
		_, known := v.geometries.keys[mesh.geometry]
		sync.shared_unlock(&v.lock)
		if known {
			continue
		}
		sync.guard(&v.lock)
		before := o3d.geometries_made(&v.geometries)
		o3d.primitive(&v.geometries, mesh.geometry)
		if o3d.geometries_made(&v.geometries) > before {
			made += {mesh.geometry.kind}
		}
	}
	return
}

// Makes the textures of the media images node `n` names that the tables
// lack, decoding them for frame `frame`, with the environment maps of its
// environment and of a blurred background: the heavy part of a first use,
// which a render's look-ahead does early (`prefetch_frame_images`). A name
// the media lacks is left to `view3d_scene` to report.
view3d_make_textures :: proc(m: ^Media, n: View3d, frame: int) {
	context.allocator = m.view3d.allocator
	for mesh in n.meshes {
		for name in mesh.maps {
			view3d_texture_make(m, name, frame, false)
		}
	}
	for pose in n.models {
		if over, ok := pose.material.?; ok {
			for name in over.maps {
				view3d_texture_make(m, name, frame, false)
			}
		}
	}
	view3d_texture_make(m, n.environment, frame, true)
	view3d_texture_make(m, n.background, frame, n.background_blurriness > 0)
}

// Media image `name` as a texture of the tables, added the first time, with
// its environment maps when `environment` (heavy, so once, here, not in a
// render).
@(private = "file")
view3d_texture_make :: proc(m: ^Media, name: string, frame: int, environment: bool) {
	if name == "" {
		return
	}
	v := &m.view3d
	sync.shared_lock(&v.lock)
	id, added := v.textures_of[name]
	_, _, prefiltered := o3d.texture_environment(&v.textures, id)
	sync.shared_unlock(&v.lock)
	if added && (prefiltered || !environment) {
		return
	}
	img, decoded := media_image(m, name, frame)
	if img == nil || !decoded {
		return
	}
	sync.guard(&v.lock)
	if id, added = v.textures_of[name]; !added {
		id = o3d.texture_add(&v.textures, img.pixels, img.width, img.height)
		v.textures_of[strings.clone(name)] = id
	}
	if environment {
		o3d.environment_prefilter(&v.textures, id)
	}
}

// Compiles the ShaderMaterials of node `n` that the tables lack.
@(private = "file")
view3d_make_shaders :: proc(m: ^Media, n: View3d) {
	context.allocator = m.view3d.allocator
	for mesh in n.meshes {
		if sh, ok := mesh.shader.?; ok {
			view3d_shader_make(m, sh)
		}
	}
	for pose in n.models {
		if over, ok := pose.material.?; ok {
			if sh, has_sh := over.shader.?; has_sh {
				view3d_shader_make(m, sh)
			}
		}
	}
}

@(private = "file")
view3d_shader_make :: proc(m: ^Media, sh: Shader_Material) {
	v := &m.view3d
	key := o3d_shader_key(sh)
	sync.shared_lock(&v.lock)
	_, known := v.shaders.keys[key]
	sync.shared_unlock(&v.lock)
	if known {
		return
	}
	sync.guard(&v.lock)
	o3d.shader(&v.shaders, sh.vertex_shader, sh.fragment_shader, sh.glsl3)
}

@(private = "file")
o3d_shader_key :: proc(sh: Shader_Material) -> string {
	return strings.concatenate({sh.vertex_shader, "\x00", sh.fragment_shader, "\x01" if sh.glsl3 else "\x00"}, context.temp_allocator)
}

// ---- drawing ------------------------------------------------------------------------------

// A 3D render the GPU's thread runs before the frame that shows it is drawn:
// `scene` into canvas image `image` (`width x height` pixels).
View3d_Job :: struct {
	image:         vg.Image_Id,
	width, height: u32,
	scene:         o3d.Scene,
}

// The jobs of a frame, the first `count` of `list`; the list and its
// scenes' arrays are reused frame after frame.
View3d_Jobs :: struct {
	list:  [dynamic]View3d_Job,
	count: int,
}

view3d_jobs_destroy :: proc(j: ^View3d_Jobs) {
	for &job in j.list {
		o3d.scene_destroy(&job.scene)
	}
	delete(j.list)
	j^ = {}
}

@(private = "file")
view3d_jobs_next :: proc(j: ^View3d_Jobs) -> ^View3d_Job {
	if j.count == len(j.list) {
		append(&j.list, View3d_Job{})
	}
	j.count += 1
	return &j.list[j.count - 1]
}

// A renderer's 3D state: the CPU renderer, the frame's GPU jobs, and per
// scene the geometry types drawn on earlier frames and on the frame being
// drawn (`geometry_growth`).
View3d_State :: struct {
	software: o3d.Software,
	jobs:     View3d_Jobs,
	drawn:    [dynamic]Drawn_Geometry,
	// Where this renderer poses glTF models (sized on first use).
	pose:     o3d.Model_Pose,
}

@(private)
Drawn_Geometry :: struct {
	scene:   int,
	frame:   int,
	earlier: bit_set[o3d.Primitive],
	now:     bit_set[o3d.Primitive],
}

@(private)
view3d_state_destroy :: proc(s: ^View3d_State) {
	o3d.software_destroy(&s.software)
	o3d.model_pose_destroy(&s.pose)
	view3d_jobs_destroy(&s.jobs)
	delete(s.drawn)
	s^ = {}
}

// Draws a 3D layer: its scene rendered at the box's on-screen pixel size,
// then the image filled into the box.
@(private)
draw_view3d :: proc(r: ^Renderer, n: View3d) {
	if n.w <= 0 || n.h <= 0 {
		report(&r.ctx, .Warning, {code = .View3d_Zero_Size, x = n.x, y = n.y})
		return
	}
	c := &r.canvas
	sx, sy, shown := layer_scale(r)
	if !shown {
		return
	}
	pw, ph := layer_pixels(n.w, n.h, sx, sy)
	image := frame_image(r, pw, ph)
	if !vg.image_id_valid(image) {
		return
	}
	check_geometry_growth(r, n, view3d_make_geometry(r.media, n))
	view3d_make_textures(r.media, n, r.ctx.frame.index)
	view3d_make_shaders(r.media, n)
	v := &r.media.view3d
	s := &r.view3d
	job := view3d_jobs_next(&s.jobs)
	job.image, job.width, job.height = image, pw, ph
	sync.shared_lock(&v.lock)
	view3d_scene(r, n, &job.scene)
	if r.gpu3d == nil {
		// The CPU draws it now; the job's scene serves the next layer.
		pixels := o3d.software_render(&s.software, &job.scene, &v.geometries, &v.shaders, int(pw), int(ph), r.pool, &v.textures)
		sync.shared_unlock(&v.lock)
		s.jobs.count -= 1
		if err := vg.update_image(c, image, vg.image_source_rgba(pixels, pw, ph), 0, 0); err != nil {
			report(&r.ctx, .Error, {code = .Image_Upload, name = "view3d", gpu = err})
			return
		}
	} else {
		sync.shared_unlock(&v.lock)
	}
	fill_layer(r, image, {n.x, n.y, n.w, n.h}, n.opacity)
}

// Fills `scene` with node `n` from the media's 3D tables (holding its
// meshes, textures and shaders; the caller holds their lock shared),
// reporting the media it names that is missing or does not decode and any
// ShaderMaterial problems.
@(private = "file")
view3d_scene :: proc(r: ^Renderer, n: View3d, scene: ^o3d.Scene) {
	v := &r.media.view3d
	o3d.scene_clear(scene)
	scene.camera = n.camera
	append(&scene.lights, ..n.lights)
	for mesh in n.meshes {
		material := view3d_material(r, scene, mesh.material, mesh.maps, mesh.shader)
		append(&scene.draws, o3d.Draw{v.geometries.keys[mesh.geometry], o3d.compose(mesh.position, mesh.rotation, mesh.scale), material})
	}
	for pose in n.models {
		model, found := &v.models[pose.src]
		if !found {
			report(&r.ctx, .Error, {code = .Missing_Model, name = pose.src})
			continue
		}
		anim := -1
		if pose.animation != "" {
			anim = o3d.gltf_animation(model, pose.animation)
		} else if pose.animation_index >= 0 {
			anim = pose.animation_index if pose.animation_index < len(model.animations) else -1
		}
		if anim < 0 && (pose.animation != "" || pose.animation_index >= 0) {
			named := pose.animation if pose.animation != "" else fmt.tprint(pose.animation_index)
			report(&r.ctx, .Error, {code = .Missing_Animation, name = pose.src, a = named})
		}
		first := len(scene.draws)
		o3d.gltf_draw(scene, model, o3d.compose(pose.position, pose.rotation, pose.scale), anim, pose.time, pose.loop, pose.flags, &r.view3d.pose)
		if over, ok := pose.material.?; ok {
			mat := view3d_material(r, scene, over.material, over.maps, over.shader)
			mat.flags += pose.flags
			for i in first ..< len(scene.draws) {
				scene.draws[i].material = mat
			}
		}
	}
	scene.environment = view3d_texture(r, n.environment)
	scene.environment_intensity = n.environment_intensity
	scene.background = view3d_texture(r, n.background)
	scene.background_intensity = n.background_intensity
	scene.background_blurriness = n.background_blurriness
}

// Resolves a material's textures or ShaderMaterial (reporting compile and
// uniform problems and packing its per-frame uniforms into `scene`).
@(private = "file")
view3d_material :: proc(r: ^Renderer, scene: ^o3d.Scene, base: o3d.Material, maps: [Texture_Map]string, shader: Maybe(Shader_Material)) -> o3d.Material {
	material := base
	for name, k in maps {
		material_map(&material, k)^ = view3d_texture(r, name)
	}
	sh, is_shader := shader.?
	if !is_shader {
		return material
	}
	v := &r.media.view3d
	id := v.shaders.keys[o3d_shader_key(sh)]
	material.shader = id
	if id == 0 || int(id) > len(v.shaders.list) {
		return material
	}
	entry := &v.shaders.list[id - 1]
	if entry.pipeline == nil {
		view3d_report_shader_errors(r, entry.errors)
		return material
	}
	material.uniforms = view3d_shader_uniforms(r, scene, entry, sh.uniforms)
	return material
}

@(private = "file")
view3d_report_shader_errors :: proc(r: ^Renderer, errors: string) {
	rest := errors
	for line in strings.split_lines_iterator(&rest) {
		if line == "" {
			continue
		}
		if sep := strings.index(line, ": "); sep >= 0 {
			report(&r.ctx, .Error, {code = .Shader_Compile, name = line[:sep], a = line[sep + 2:]})
		} else {
			report(&r.ctx, .Error, {code = .Shader_Compile, name = "ShaderMaterial", a = line})
		}
	}
}

// Checks a ShaderMaterial's uniforms and packs the declared ones into
// `scene` using the compiled module's own name strings (which outlive the
// frame's tree arena when a recorded frame is played later).
@(private = "file")
view3d_shader_uniforms :: proc(r: ^Renderer, scene: ^o3d.Scene, sh: ^o3d.Shader, uniforms: []o3d.Uniform) -> o3d.Uniform_Range {
	vert := sh.pipeline.vertex
	frag := sh.pipeline.fragment
	kept := make([dynamic]o3d.Uniform, 0, len(uniforms), context.temp_allocator)
	for u in uniforms {
		v_info, in_v := oksl.find_uniform(vert, u.name)
		f_info, in_f := oksl.find_uniform(frag, u.name)
		if (!in_v && !in_f) || o3d_is_builtin(u.name) {
			report(&r.ctx, .Warning, {code = .Shader_Undeclared_Uniform, name = "ShaderMaterial", a = u.name})
			continue
		}
		name := v_info.name if in_v else f_info.name
		append(&kept, o3d.Uniform{name = name, value = u.value})
	}
	for stage in o3d.Shader_Stage {
		mod := vert if stage == .Vertex else frag
		unset: for info in mod.uniforms {
			if o3d_is_builtin(info.name) {
				continue
			}
			if stage == .Fragment {
				if _, in_v := oksl.find_uniform(vert, info.name); in_v {
					continue
				}
			}
			for u in uniforms {
				if u.name == info.name {
					continue unset
				}
			}
			report(&r.ctx, .Warning, {code = .Shader_Unset_Uniform, name = "ShaderMaterial", a = info.name})
		}
	}
	return o3d.scene_uniforms(scene, ..kept[:])
}

@(private = "file")
o3d_is_builtin :: proc(name: string) -> bool {
	for b in o3d.BUILTINS {
		if b.name == name {
			return true
		}
	}
	return false
}

// The texture of media image `name` (0 for none), reporting an image the
// media lacks or can not decode.
@(private = "file")
view3d_texture :: proc(r: ^Renderer, name: string) -> o3d.Texture_Id {
	if name == "" {
		return 0
	}
	if id, ok := r.media.view3d.textures_of[name]; ok {
		return id
	}
	if name in r.media.images {
		report(&r.ctx, .Error, {code = .Undecodable_Image, name = name})
	} else {
		report(&r.ctx, .Error, {code = .Missing_Image, name = name})
	}
	return 0
}

// Reports the geometry types this frame's node `n` made meshes of
// (`made`) that the renderer drew on an earlier frame of the node's scene:
// the shape changes through its geometry's parameters.
@(private = "file")
check_geometry_growth :: proc(r: ^Renderer, n: View3d, made: bit_set[o3d.Primitive]) {
	frame := r.ctx.frame.index
	d: ^Drawn_Geometry
	for &e in r.view3d.drawn {
		if e.scene == n.scene_index {
			d = &e
			break
		}
	}
	if d == nil {
		append(&r.view3d.drawn, Drawn_Geometry{scene = n.scene_index, frame = frame})
		d = &r.view3d.drawn[len(r.view3d.drawn) - 1]
	}
	if d.frame != frame {
		d.earlier += d.now
		d.now = {}
		d.frame = frame
	}
	for kind in made & d.earlier {
		report(&r.ctx, .Warning, {code = .Geometry_Growth, name = GEOMETRY_TYPES[kind].name})
	}
	for mesh in n.meshes {
		d.now += {mesh.geometry.kind}
	}
}
