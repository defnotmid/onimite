package onimite

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
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
	particles:             []Particle_Emitter,
	labels:                []View3d_Label,
	// Media images: the equirectangular environment lighting the scene
	// and the background behind it ("" for none), and their strengths.
	environment:           string,
	environment_intensity: f32,
	background:            string,
	background_intensity:  f32,
	background_blurriness: f32,
	tone_mapping:          o3d.Tone_Mapping,
	tone_mapping_exposure: f32,
	fog:                   o3d.Fog,
	// The timeline index of the scene that drew it (-1: the video's own
	// render), for `geometry_growth`.
	scene_index:           int,
	// The clock of the frame that drew it (scene-relative in a scene): video
	// clips used as maps play on it from its start, looping, each on the
	// clip stream its use was given (by media name).
	clock_index:           int,
	clock_fps:             int,
	video_streams:         []View3d_Video_Stream,
}

View3d_Video_Stream :: struct {
	name:   string,
	stream: int,
}

// A custom shader material (`type = "ShaderMaterial"`): its GLSL ES
// sources, GLSL 3 flag and per-frame uniforms.
Shader_Material :: struct {
	vertex_shader:   string,
	fragment_shader: string,
	glsl3:           bool,
	uniforms:        []o3d.Uniform,
	// Its `uniform sampler2D`s given an image of the media by name.
	maps:            []Shader_Map,
}

Shader_Map :: struct {
	name, src: string,
}

// Where a mesh or model rides: on node `node` of the view's model number
// `model` (1-based; 0: nowhere), as that node is posed this frame; or on a
// physics3d body (`track`), as it is at any time, in the space of the
// groups around it.
Attach :: struct {
	model: int,
	node:  string,
	// The model's `name` when it was named, numbered once the view is read.
	model_name: string,
	track:      Body_Track,
}

// A physics3d body something rides: `sample` gives its pose and velocity at
// time `t` from the simulation's tracks (`data`); nil when none.
Body_Track :: struct {
	sample: proc(data: rawptr, body: int, t: f32) -> (pose: o3d.Mat4, velocity: o3d.Vec3),
	data:   rawptr,
	body:   int,
}

// Whether `a` places nothing (no model's node, no body).
attach_none :: proc "contextless" (a: Attach) -> bool {
	return a.model == 0 && a.track.sample == nil
}

// The frame something attached by `a` in groups `group` is placed in: a
// body's pose at `t` inside the groups, or a posed node (`on`) around them.
@(private = "file")
attach_frame :: proc(on: o3d.Mat4, a: Attach, group: Maybe(o3d.Mat4), t: f32) -> o3d.Mat4 {
	if a.track.sample != nil {
		pose, _ := a.track.sample(a.track.data, a.track.body, t)
		return group_transform(group) * pose
	}
	return on * group_transform(group)
}

// A particle emitter (view3d's `particles`): a particle born every
// 1/`rate` seconds from `start` until `stop`, and `count` at once at each
// burst, lives `lifetime` seconds, placed and drawn from the emitter's seed
// and its own number alone, so a frame shows the same particles however it
// is reached. Each is born within `spread` (half sizes) of `position`,
// moves at `velocity` (give or take `velocity_spread`) under `gravity`, its
// size, colour and opacity going from the first to the second over its
// life, turning `spin` radians a second from a random angle. Attached to a
// body with `world_space`, each is placed by the body as it was at its
// birth and keeps the body's velocity from then (gas left behind);
// otherwise they ride the emitter.
Particle_Emitter :: struct {
	seed:            u64,
	rate, lifetime:  f32,
	time:            f32,
	start, stop:     f32,
	bursts:          []Particle_Burst,
	world_space:     bool,
	position:        o3d.Vec3,
	spread:          o3d.Vec3,
	velocity:        o3d.Vec3,
	velocity_spread: o3d.Vec3,
	gravity:         o3d.Vec3,
	size:            [2]f32,
	color:           [2]o3d.Vec4, // sRGB and opacity
	spin:            f32,
	// Additive or blended, `softness`, size attenuation; `sprite` its map.
	material:        o3d.Material,
	sprite:          string,
	attach:          Attach,
	group:           Maybe(o3d.Mat4),
}

// `count` particles born at once at `t` on the emitter's clock.
Particle_Burst :: struct {
	t:     f32,
	count: int,
}

// A 2D panel on a 3D point: its nodes (`content`, laid out in a `w x h`
// panel) drawn as a sprite of that size at `at`.
// - A label (view3d's `labels`): the panel's bottom centre on the point,
//   hidden pixel by pixel where the scene is nearer; `depth_offset` (world
//   units) pulls it toward the camera, so a label on a surface shows.
// - A lens flare's element (view3d's `lensflares`, three.js's
//   LensflareElement): centred `distance` of the way from the point to its
//   mirror through the layer's centre (0: on it, 1: mirrored), added to
//   what is behind, over everything, and faded as a whole by how much of a
//   disc of `occlusion_radius` pixels around the point the scene hides.
View3d_Label :: struct {
	at:               o3d.Vec3,
	w, h:             f32,
	depth_offset:     f32,
	content:          i32,
	attach:           Attach,
	group:            Maybe(o3d.Mat4),
	flare:            bool,
	distance:         f32,
	occlusion_radius: f32,
}

// The transform of the groups a mesh or model is in (view3d's `groups`),
// none when it is in none.
group_transform :: proc "contextless" (g: Maybe(o3d.Mat4)) -> o3d.Mat4 {
	return g.? or_else 1
}

// A change to one part of a model, named as in its file: a node (with
// what is under it) or every primitive of a material. Hidden, shadow
// flags added or removed, a node's own translation, rotation or scale
// replaced, a material drawn in place of the file's.
Model_Part :: struct {
	of:        enum u8 {Node, Material},
	name:      string,
	state:     o3d.Part_State,
	transform: o3d.Part_Transform,
	material:  Maybe(Model_Material),
}

// A material override on a glTF model: its material, texture maps and
// optional ShaderMaterial.
Model_Material :: struct {
	material: o3d.Material,
	maps:     [Texture_Map]string,
	shader:   Maybe(Shader_Material),
}

// Per-frame geometry on a mesh made from its `points` (`LineGeometry`,
// `LineSegmentsGeometry`, `PointsGeometry` or `TubeGeometry`).
Path_Kind :: enum u8 {
	None          = 0,
	Polyline      = 1,
	Line_Segments = 2,
	Points        = 3,
	Tube          = 4,
}

// A mesh: primitive geometry (its type and three.js parameters, see
// `GEOMETRY_TYPES`) or per-frame line, point or tube positions (`path_kind`,
// `points`; a tube's `tube_radius` and `tube_segments` around), optional `instances` (`InstancedMesh`), its transform
// (position, Euler XYZ rotation in radians, scale) and its material, whose
// texture maps are media images by name (or a custom `ShaderMaterial`).
Mesh :: struct {
	geometry:      o3d.Geometry_Key,
	// ShapeGeometry / ExtrudeGeometry of an outline (`outline.kind != .None`).
	outline:       Outline_Geometry,
	// The walls' material when given (three.js's [caps, sides] materials).
	side_material: Maybe(o3d.Material),
	path_kind:     Path_Kind,
	path_closed:   bool,
	points:        []o3d.Vec3,
	// One per point when given (sRGB and opacity): three.js's vertex colours.
	colors:        []o3d.Vec4,
	tube_radius:   f32,
	tube_segments: int,
	instances:     []o3d.Instance,
	position:      o3d.Vec3,
	rotation:      o3d.Vec3,
	scale:         o3d.Vec3,
	material:      o3d.Material,
	maps:          [Texture_Map]string,
	shader:        Maybe(Shader_Material),
	attach:        Attach,
	group:         Maybe(o3d.Mat4),
}

Outline_Kind :: enum u8 {
	None,
	// ShapeGeometry triangulated: for materials that draw its triangles
	// (wireframe, points, a ShaderMaterial, an outline pass).
	Shape,
	// ShapeGeometry drawn from its curves (o3d's exact shapes): one quad
	// whose pixels take their coverage from the curves.
	Exact,
	Extrude,
}

// A 2D outline made into geometry: flat (`ShapeGeometry`, exact or
// triangulated) or extruded with o3d's options, y flipped so it reads
// upright in 3D. Built once per outline content and options
// (`View3d_Media.outlines`).
Outline_Geometry :: struct {
	kind:    Outline_Kind,
	asset:   ^Path_Asset,
	options: o3d.Extrude_Options,
}

@(private)
Outline_Key :: struct {
	key:     u64,
	kind:    Outline_Kind,
	options: o3d.Extrude_Options,
}

// A material's texture maps, by their three.js names (`TEXTURE_MAPS`).
Texture_Map :: enum u8 {
	Color,
	Normal,
	Roughness,
	Metalness,
	Emissive,
	AO,
	Alpha,
	// MeshPhysicalMaterial's layers
	Clearcoat,
	Clearcoat_Roughness,
	Clearcoat_Normal,
	Sheen_Color,
	Sheen_Roughness,
	Transmission,
	Thickness,
}

@(rodata)
TEXTURE_MAPS := [Texture_Map]cstring {
	.Color               = "map",
	.Normal              = "normal_map",
	.Roughness           = "roughness_map",
	.Metalness           = "metalness_map",
	.Emissive            = "emissive_map",
	.AO                  = "ao_map",
	.Alpha               = "alpha_map",
	.Clearcoat           = "clearcoat_map",
	.Clearcoat_Roughness = "clearcoat_roughness_map",
	.Clearcoat_Normal    = "clearcoat_normal_map",
	.Sheen_Color         = "sheen_color_map",
	.Sheen_Roughness     = "sheen_roughness_map",
	.Transmission        = "transmission_map",
	.Thickness           = "thickness_map",
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
	case .AO:
		return &m.ao_map
	case .Alpha:
		return &m.alpha_map
	case .Clearcoat:
		return &m.clearcoat_map
	case .Clearcoat_Roughness:
		return &m.clearcoat_roughness_map
	case .Clearcoat_Normal:
		return &m.clearcoat_normal_map
	case .Sheen_Color:
		return &m.sheen_color_map
	case .Sheen_Roughness:
		return &m.sheen_roughness_map
	case .Transmission:
		return &m.transmission_map
	case .Thickness:
		return &m.thickness_map
	}
	return &m.color_map
}

// A glTF model of the media, posed at `time` seconds of an animation (by
// name, else by index; neither: its rest pose) with optional `morphs`
// weight overrides, placed by a transform, its materials given `flags`
// (shadows) or replaced by `material`.
Model_Pose :: struct {
	src:             string,
	position:        o3d.Vec3,
	rotation:        o3d.Vec3,
	scale:           o3d.Vec3,
	animation:       string,
	animation_index: int,
	time:            f32,
	loop:            bool,
	morphs:          []o3d.Morph_Weight,
	flags:           o3d.Material_Flags,
	outline_width:   f32,
	outline_color:   o3d.Vec3,
	material:        Maybe(Model_Material),
	parts:           []Model_Part,
	attach:          Attach,
	group:           Maybe(o3d.Mat4),
	// What `attach.model` may call it instead of its number.
	name:            string,
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
	.Capsule  = {"CapsuleGeometry", {{"radius", .Size, 1, 0}, {"height", .Size, 1, 0}, {"cap_segments", .Count, 4, 1}, {"radial_segments", .Count, 8, 3}, {}, {}, {}}},
}

// Adds a 3D layer drawing at frame `f` (its scene keys `geometry_growth`).
view3d :: proc(ctx: ^Context, f: Frame, v: View3d) {
	v := v
	arena := ctx.tree.arena
	v.lights = clone_slice(v.lights, arena)
	v.meshes = clone_slice(v.meshes, arena)
	for &m in v.meshes {
		m.points = clone_slice(m.points, arena)
		m.colors = clone_slice(m.colors, arena)
		m.instances = clone_slice(m.instances, arena)
		for &name in m.maps {
			name = strings.clone(name, arena)
		}
		clone_shader_material(&m.shader, arena)
		m.attach.node = strings.clone(m.attach.node, arena)
		m.attach.model_name = ""
	}
	v.models = clone_slice(v.models, arena)
	for &m in v.models {
		m.src = strings.clone(m.src, arena)
		m.animation = strings.clone(m.animation, arena)
		m.morphs = clone_slice(m.morphs, arena)
		for &mw in m.morphs {
			mw.name = strings.clone(mw.name, arena)
		}
		if over, ok := &m.material.?; ok {
			clone_model_material(over, arena)
		}
		m.attach.node = strings.clone(m.attach.node, arena)
		m.attach.model_name = ""
		m.name = strings.clone(m.name, arena)
		m.parts = clone_slice(m.parts, arena)
		for &part in m.parts {
			part.name = strings.clone(part.name, arena)
			if over, ok := &part.material.?; ok {
				clone_model_material(over, arena)
			}
		}
	}
	v.labels = clone_slice(v.labels, arena)
	for &l in v.labels {
		l.attach.node = strings.clone(l.attach.node, arena)
		l.attach.model_name = ""
	}
	v.particles = clone_slice(v.particles, arena)
	for &e in v.particles {
		e.sprite = strings.clone(e.sprite, arena)
		e.bursts = clone_slice(e.bursts, arena)
		e.attach.node = strings.clone(e.attach.node, arena)
		e.attach.model_name = ""
	}
	v.environment = strings.clone(v.environment, arena)
	v.background = strings.clone(v.background, arena)
	v.scene_index = f.scene.index if f.scene != nil else -1
	v.clock_index, v.clock_fps = f.index, f.fps
	v.video_streams = view3d_video_streams(ctx, v, arena)
	tree_add(&ctx.tree, v)
}

// The streams the node's video maps play on, a use each.
@(private = "file")
view3d_video_streams :: proc(ctx: ^Context, v: View3d, arena: runtime.Allocator) -> []View3d_Video_Stream {
	out := make([dynamic]View3d_Video_Stream, arena)
	add :: proc(ctx: ^Context, out: ^[dynamic]View3d_Video_Stream, name: string) {
		clip, is_video := ctx.videos.by_name[name]
		if name == "" || !is_video {
			return
		}
		for s in out {
			if s.name == name {
				return
			}
		}
		append(out, View3d_Video_Stream{name, clip_stream(ctx, clip)})
	}
	for name in view3d_image_names(v) {
		add(ctx, &out, name)
	}
	return out[:]
}

@(private = "file")
clone_model_material :: proc(m: ^Model_Material, arena: runtime.Allocator) {
	for &name in m.maps {
		name = strings.clone(name, arena)
	}
	clone_shader_material(&m.shader, arena)
}

// Every image name node `n` draws with: its meshes' and models' maps,
// their ShaderMaterials' images and the materials a model's parts are
// drawn in (temp memory).
@(private = "file")
view3d_image_names :: proc(n: View3d) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	material :: proc(out: ^[dynamic]string, maps: [Texture_Map]string, shader: Maybe(Shader_Material)) {
		for name in maps {
			if name != "" {
				append(out, name)
			}
		}
		if sh, ok := shader.?; ok {
			for m in sh.maps {
				append(out, m.src)
			}
		}
	}
	for mesh in n.meshes {
		material(&out, mesh.maps, mesh.shader)
	}
	for pose in n.models {
		if over, ok := pose.material.?; ok {
			material(&out, over.maps, over.shader)
		}
		for part in pose.parts {
			if over, ok := part.material.?; ok {
				material(&out, over.maps, over.shader)
			}
		}
	}
	for e in n.particles {
		if e.sprite != "" {
			append(&out, e.sprite)
		}
	}
	return out[:]
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
	s.maps = clone_slice(s.maps, arena)
	for &m in s.maps {
		m.name = strings.clone(m.name, arena)
		m.src = strings.clone(m.src, arena)
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
	// Skies made by name (`view3d_sky`), with what each was baked from, so
	// a script loaded again with the same sky gets the same image.
	skies:       map[string]View3d_Sky,
	// External textures labels are bound to, the ith label of a layer to
	// the ith (made as needed, under the lock).
	label_textures: [dynamic]o3d.Texture_Id,
	// Outline geometry by outline content and options (caps and sides
	// groups too; a ShapeGeometry's are its whole).
	outlines:    map[Outline_Key]o3d.Extruded,
	// What the tables grow in, whichever thread adds to them.
	allocator:   runtime.Allocator,
}

// A sky of three.js's Sky (Preetham) as baked: its settings and the
// image's width.
View3d_Sky :: struct {
	sky:   o3d.Sky,
	width: int,
}

// Bakes `sky` into an equirectangular HDR image `width` across named
// `name`, with its environment maps, which a view3d's `environment` and
// `background` then take like a media image: heavy, so at load. The image
// already made under `name` from the same sky is kept (another load of the
// script, a reload). False when `name` is a media image's or video's.
view3d_sky :: proc(m: ^Media, name: string, sky: View3d_Sky) -> bool {
	if name in m.images || name in m.videos.by_name {
		return false
	}
	v := &m.view3d
	context.allocator = v.allocator
	sync.guard(&v.lock)
	if made, ok := v.skies[name]; ok && made == sky {
		return true
	}
	id := o3d.sky_texture(&v.textures, sky.sky, sky.width)
	o3d.environment_prefilter(&v.textures, id)
	key := name
	if name not_in v.skies {
		key = strings.clone(name)
	}
	v.textures_of[key] = id
	v.skies[key] = sky
	return true
}

@(private)
view3d_media_init :: proc(v: ^View3d_Media) {
	v.allocator = context.allocator
	v.models = make(map[string]o3d.Model)
	v.textures_of = make(map[string]o3d.Texture_Id)
	v.skies = make(map[string]View3d_Sky)
	v.outlines = make(map[Outline_Key]o3d.Extruded)
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
	delete(v.skies) // its names are textures_of's
	delete(v.label_textures)
	delete(v.outlines)
	o3d.geometries_destroy(&v.geometries)
	o3d.textures_destroy(&v.textures)
	o3d.shaders_destroy(&v.shaders)
	v^ = {}
}

// Loads 3D model file `path` (.glb, .gltf or .obj with its files beside it, .3mf,
// or .usdz / binary .usdc)
// as model `name`: its meshes and images join the tables. Returns what kind of
// model failed to load and why when `ok == false`.
@(private)
view3d_add_model :: proc(v: ^View3d_Media, name, path: string) -> (what, why: string, ok: bool) {
	context.allocator = v.allocator
	sync.guard(&v.lock)
	model: o3d.Model
	if strings.equal_fold(file_ext(name), ".3mf") {
		err: o3d.Threemf_Error
		model, err = o3d.threemf_load(path, &v.geometries, &v.textures)
		if err != .None {
			ext := model.unsupported_extension
			why = fmt.tprintf("%s: %s", o3d.THREEMF_ERROR_TEXT[err], ext) if ext != "" else o3d.THREEMF_ERROR_TEXT[err]
			o3d.model_destroy(&model)
			return "a 3MF model", why, false
		}
	} else if ext := file_ext(name); strings.equal_fold(ext, ".usdz") || strings.equal_fold(ext, ".usdc") {
		err: o3d.Usd_Error
		model, err = o3d.usd_load(path, &v.geometries, &v.textures)
		if err != .None {
			o3d.model_destroy(&model)
			return "a USD model", o3d.USD_ERROR_TEXT[err], false
		}
	} else if strings.equal_fold(file_ext(name), ".obj") {
		err: o3d.Obj_Error
		model, err = o3d.obj_load(path, &v.geometries, &v.textures)
		if err != .None {
			o3d.model_destroy(&model)
			return "an OBJ model", o3d.OBJ_ERROR_TEXT[err], false
		}
	} else {
		err: o3d.Gltf_Error
		model, err = o3d.gltf_load(path, &v.geometries, &v.textures)
		if err != .None {
			ext := model.unsupported_extension
			why = fmt.tprintf("%s: %s", o3d.GLTF_ERROR_TEXT[err], ext) if ext != "" else o3d.GLTF_ERROR_TEXT[err]
			o3d.model_destroy(&model)
			return MEDIA_KINDS[.Model].undecodable, why, false
		}
	}
	if old, exists := &v.models[name]; exists {
		o3d.model_destroy(old)
		old^ = model
	} else {
		v.models[strings.clone(name)] = model
	}
	return "", "", true
}

// Makes the meshes of node `n` that the tables lack; returns the geometry
// types it made meshes of.
@(private = "file")
view3d_make_geometry :: proc(m: ^Media, n: View3d) -> (made: bit_set[o3d.Primitive], made_outlines: bit_set[Outline_Kind]) {
	v := &m.view3d
	context.allocator = v.allocator
	for mesh in n.meshes {
		if o := mesh.outline; o.kind != .None {
			key := outline_key(o)
			sync.shared_lock(&v.lock)
			_, known := v.outlines[key]
			sync.shared_unlock(&v.lock)
			if known {
				continue
			}
			if o.kind == .Exact {
				path := outline_path(o.asset, true)
				sync.guard(&v.lock)
				if key in v.outlines {
					continue
				}
				rule := o3d.Fill_Rule.Even_Odd if o.asset.fill_rule == .Even_Odd else o3d.Fill_Rule.Nonzero
				g := o3d.exact_shape_geometry(&v.geometries, &path, rule)
				v.outlines[key] = {geometry = g, caps = g, sides = g}
				made_outlines += {o.kind}
				continue
			}
			shapes := outline_shapes(o.asset, true)
			sync.guard(&v.lock)
			if key in v.outlines {
				continue
			}
			if o.kind == .Shape {
				g := o3d.shape_geometry(&v.geometries, shapes)
				v.outlines[key] = {geometry = g, caps = g, sides = g}
			} else {
				v.outlines[key] = o3d.extrude_geometry(&v.geometries, shapes, o.options)
			}
			made_outlines += {o.kind}
			continue
		}
		if mesh.geometry.kind == .None {
			continue
		}
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

@(private = "file")
outline_key :: proc "contextless" (o: Outline_Geometry) -> Outline_Key {
	return {o.asset.key, o.kind, o.options if o.kind == .Extrude else {}}
}

// Makes the textures of the media images node `n` names that the tables
// lack, decoding them for frame `frame`, with the environment maps of its
// environment and of a blurred background: the heavy part of a first use,
// which a render's look-ahead does early (`prefetch_frame_images`). A name
// the media lacks is left to `view3d_scene` to report.
view3d_make_textures :: proc(m: ^Media, n: View3d, frame: int) {
	context.allocator = m.view3d.allocator
	for name in view3d_image_names(n) {
		view3d_texture_make(m, name, frame, false)
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
	if clip, is_video := m.videos.by_name[name]; is_video && !environment {
		// a video: its frames bound on the GPU each render (view3d_videos)
		sync.guard(&v.lock)
		if _, added := v.textures_of[name]; !added {
			info := m.videos.infos[clip]
			v.textures_of[strings.clone(name)] = o3d.texture_add_external(&v.textures, info.width, info.height)
		}
		return
	}
	sync.shared_lock(&v.lock)
	id, added := v.textures_of[name]
	_, _, prefiltered := o3d.texture_environment(&v.textures, id)
	sync.shared_unlock(&v.lock)
	if added && (prefiltered || !environment) {
		return
	}
	if strings.equal_fold(file_ext(name), ".hdr") {
		// Radiance HDR: linear light past 1, straight to a float texture
		img, known := m.images[name]
		if !known {
			return
		}
		data, err := os.read_entire_file(img.path, context.temp_allocator)
		if err != nil {
			return
		}
		sync.guard(&v.lock)
		if id, added = v.textures_of[name]; !added {
			made: bool
			if id, made = o3d.texture_decode(&v.textures, data); !made {
				return
			}
			v.textures_of[strings.clone(name)] = id
		}
		if environment {
			o3d.environment_prefilter(&v.textures, id)
		}
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
		for part in pose.parts {
			if over, ok := part.material.?; ok {
				if sh, has_sh := over.shader.?; has_sh {
					view3d_shader_make(m, sh)
				}
			}
		}
	}
}

@(private = "file")
view3d_shader_make :: proc(m: ^Media, sh: Shader_Material) {
	v := &m.view3d
	sync.shared_lock(&v.lock)
	_, _, known := o3d.shader_find(&v.shaders, sh.vertex_shader, sh.fragment_shader, sh.glsl3)
	sync.shared_unlock(&v.lock)
	if known {
		return
	}
	sync.guard(&v.lock)
	o3d.shader(&v.shaders, sh.vertex_shader, sh.fragment_shader, sh.glsl3)
}

// ---- drawing ------------------------------------------------------------------------------

// A 3D render the GPU's thread runs before the frame that shows it is drawn:
// `scene` into canvas image `image` (`width x height` pixels).
View3d_Job :: struct {
	image:         vg.Image_Id,
	width, height: u32,
	scene:         o3d.Scene,
	// The video maps' frames, each bound to its texture for this render.
	videos:        [dynamic]Video_Binding,
	// Set by `view3d_gpu_prepare` for the canvas row that records it
	// (`view3d_job_run`): the GPU and its o3d job, the tables; what the
	// record said.
	gpu:           ^View3d_Gpu,
	slot:          int,
	media:         ^View3d_Media,
	prepared:      bool,
	err:           o3d.Error,
	// The image its depth goes to (a shader's depth input reads it; invalid:
	// none), and the distance written where nothing is drawn.
	depth_image:   vg.Image_Id,
	far:           f32,
	// Rendered on the CPU at its row (`view3d_job_run` with no GPU): the
	// renderer's software 3D renderer and task pool.
	software:      ^o3d.Software,
	pool:          ^thread.Pool,
}

// A 3D layer's depth image while a shader's group input is drawn: the
// first layer drawn in it leaves its depth here.
Depth_Capture :: struct {
	image:         vg.Image_Id,
	width, height: u32,
}

Video_Binding :: struct {
	texture: o3d.Texture_Id,
	image:   vg.Image_Id,
}

// The jobs of a frame, the first `count` of `list`; the jobs and their
// scenes' arrays are reused frame after frame. Each job keeps its address
// (the frame's canvas rows point at them).
View3d_Jobs :: struct {
	list:  [dynamic]^View3d_Job,
	count: int,
}

view3d_jobs_destroy :: proc(j: ^View3d_Jobs) {
	for job in j.list {
		o3d.scene_destroy(&job.scene)
		delete(job.videos)
		free(job)
	}
	delete(j.list)
	j^ = {}
}

@(private = "file")
view3d_jobs_next :: proc(j: ^View3d_Jobs) -> ^View3d_Job {
	if j.count == len(j.list) {
		append(&j.list, new(View3d_Job))
	}
	j.count += 1
	return j.list[j.count - 1]
}

// A renderer's 3D state: the CPU renderer, the frame's GPU jobs, and per
// scene the geometry types drawn on earlier frames and on the frame being
// drawn (`geometry_growth`).
View3d_State :: struct {
	jobs:     View3d_Jobs,
	drawn:    [dynamic]Drawn_Geometry,
	// Where this renderer poses models (sized on first use), and the part
	// tables a model's `nodes` / `materials` fill for its draw.
	pose:     o3d.Model_Pose,
	parts:    o3d.Model_Parts,
}

@(private)
Drawn_Geometry :: struct {
	scene:   int,
	frame:   int,
	earlier: bit_set[o3d.Primitive],
	now:     bit_set[o3d.Primitive],
	// The same for outline geometry (ShapeGeometry, ExtrudeGeometry).
	earlier_outlines, now_outlines: bit_set[Outline_Kind],
	// The types made new on this frame and on the renderer's previous
	// frame of the scene: growth is a type made again frame after frame (a
	// parameter animated), not a fixed shape that first shows up later.
	made, made_last:                   bit_set[o3d.Primitive],
	made_outlines, made_last_outlines: bit_set[Outline_Kind],
}

@(private)
view3d_state_destroy :: proc(s: ^View3d_State) {
	o3d.model_pose_destroy(&s.pose)
	o3d.model_parts_destroy(&s.parts)
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
	made, made_outlines := view3d_make_geometry(r.media, n)
	check_geometry_growth(r, n, made, made_outlines)
	view3d_make_textures(r.media, n, r.ctx.frame.index)
	view3d_make_shaders(r.media, n)
	v := &r.media.view3d
	s := &r.view3d
	job := view3d_jobs_next(&s.jobs)
	job.image, job.width, job.height = image, pw, ph
	job.depth_image, job.far = {}, n.camera.far
	// a shader's depth input reads this layer's depth, from this render
	if d := r.depth_capture; d != nil && !vg.image_id_valid(d.image) {
		job.depth_image = frame_image(r, pw, ph, .RGBA16F)
		d.image, d.width, d.height = job.depth_image, pw, ph
	}
	view3d_videos(r, n, job)
	// each label's nodes drawn into its panel image, bound to its texture
	labels := make([]View3d_Label_Sprite, len(n.labels), context.temp_allocator)
	for l, i in n.labels {
		lw := u32(clamp(math.ceil(l.w * sx), 1, 4096))
		lh := u32(clamp(math.ceil(l.h * sy), 1, 4096))
		img := draw_content(r, l.content, l.w, l.h, lw, lh)
		if !vg.image_id_valid(img) {
			continue
		}
		labels[i] = {view3d_label_texture(v, i), {f32(lw), f32(lh)}}
		append(&job.videos, Video_Binding{labels[i].texture, img})
	}
	sync.shared_lock(&v.lock)
	view3d_scene(r, n, &job.scene, {int(pw), int(ph)}, labels)
	job.scene.depth = vg.image_id_valid(job.depth_image)
	sync.shared_unlock(&v.lock)
	if r.gpu3d == nil {
		// the CPU draws it at its row too, reading the images made before
		// it, with what draws the renderer's frames
		d := renderer_cpu(r)
		job.software, job.pool, job.media = &d.software, d.pool, v
	}
	// rendered at this point of the canvas's rows: after the images it
	// samples (clips' frames, labels) were made, before the layer shows it
	vg.run_external(c, view3d_job_run, job)
	fill_layer(r, image, {n.x, n.y, n.w, n.h}, n.opacity)
}

// The frames the video maps of node `n` show on its clock (from its start,
// looping), each an image of the renderer's bound to its texture for the
// job's render (the GPU's or the CPU's).
@(private = "file")
view3d_videos :: proc(r: ^Renderer, n: View3d, job: ^View3d_Job) {
	clear(&job.videos)
	add :: proc(r: ^Renderer, n: View3d, job: ^View3d_Job, name: string) {
		v := r.ctx.videos
		clip, is_video := v.by_name[name]
		if name == "" || !is_video || v.handles[clip] < 0 {
			return
		}
		texture := r.media.view3d.textures_of[name]
		for b in job.videos {
			if b.texture == texture {
				return
			}
		}
		t, _ := video_clip_time(v.infos[clip], {index = n.clock_index, fps = n.clock_fps}, 0, 0, 1, true)
		stream := 0
		for s in n.video_streams {
			if s.name == name {
				stream = s.stream
			}
		}
		if slot, ok := video_clip_image(r, clip, stream, t); ok {
			append(&job.videos, Video_Binding{texture, r.video_images.image[slot]})
		}
	}
	for name in view3d_image_names(n) {
		add(r, n, job, name)
	}
}

// Fills `scene` with node `n` from the media's 3D tables (holding its
// meshes, textures and shaders; the caller holds their lock shared),
// reporting the media it names that is missing or does not decode and any
// ShaderMaterial problems.
@(private = "file")
view3d_scene :: proc(r: ^Renderer, n: View3d, scene: ^o3d.Scene, size: [2]int, labels: []View3d_Label_Sprite = nil) {
	v := &r.media.view3d
	o3d.scene_clear(scene)
	scene.camera = n.camera
	// the view's clock, for what rides a physics body
	now := f32(n.clock_index) / f32(max(n.clock_fps, 1))
	append(&scene.lights, ..n.lights)
	// Meshes attached to a model's part draw after the models.
	attached := make([dynamic]int, context.temp_allocator)
	for mesh, i in n.meshes {
		if mesh.attach.model > 0 {
			append(&attached, i)
			continue
		}
		view3d_mesh(r, scene, mesh, attach_frame(1, mesh.attach, mesh.group, now) * o3d.compose(mesh.position, mesh.rotation, mesh.scale))
	}
	// Where attached meshes and models ride: their part's world, read right
	// after the model it belongs to is posed.
	mesh_on := make([]o3d.Mat4, len(n.meshes), context.temp_allocator)
	model_on := make([]o3d.Mat4, len(n.models), context.temp_allocator)
	emitter_on := make([]o3d.Mat4, len(n.particles), context.temp_allocator)
	label_on := make([]o3d.Mat4, len(n.labels), context.temp_allocator)
	for &m in label_on {
		m = 1
	}
	for &m in mesh_on {
		m = 1
	}
	for &m in model_on {
		m = 1
	}
	for &m in emitter_on {
		m = 1
	}
	for pose, mi in n.models {
		if a := pose.attach.model; a > 0 && a > mi {
			report(&r.ctx, .Error, {code = .Attach_Target, name = pose.src, n = i64(a)})
		}
		model, found := &v.models[pose.src]
		if !found {
			report(&r.ctx, .Error, {code = .Missing_Model, name = pose.src})
			continue
		}
		for w in model.warnings {
			report(&r.ctx, .Warning, {code = .Model_Warning, name = pose.src, a = w})
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
		for mw in pose.morphs {
			if mw.name != "" {
				if o3d.gltf_morph_target(model, mw.name) < 0 {
					report(&r.ctx, .Error, {code = .Missing_Morph_Target, name = pose.src, a = mw.name})
				}
			} else if mw.index < 0 || mw.index >= o3d.gltf_morph_count(model) {
				report(&r.ctx, .Error, {code = .Missing_Morph_Target, name = pose.src, a = fmt.tprint(mw.index + 1)})
			}
		}
		parts: ^o3d.Model_Parts
		if len(pose.parts) > 0 {
			parts = &r.view3d.parts
			o3d.model_parts_init(parts, model)
			for part in pose.parts {
				switch part.of {
				case .Node:
					id := o3d.model_node(model, part.name)
					if id == 0 {
						report(&r.ctx, .Error, {code = .Missing_Model_Part, name = pose.src, a = "node", b = part.name})
						continue
					}
					parts.nodes[id - 1] = part.state
					parts.transforms[id - 1] = part.transform
				case .Material:
					id := o3d.model_material(model, part.name)
					if id == 0 {
						report(&r.ctx, .Error, {code = .Missing_Model_Part, name = pose.src, a = "material", b = part.name})
						continue
					}
					state := part.state
					if over, ok := part.material.?; ok {
						parts.replacements[id - 1] = view3d_material(r, scene, over.material, over.maps, over.shader)
						state.replace = true
					}
					parts.materials[id - 1] = state
				}
			}
		}
		// a whole-model material: under each part's own and the outline
		whole: o3d.Material
		override: ^o3d.Material
		if over, ok := pose.material.?; ok {
			whole = view3d_material(r, scene, over.material, over.maps, over.shader)
			override = &whole
		}
		o3d.gltf_draw(scene, model, attach_frame(model_on[mi], pose.attach, pose.group, now) * o3d.compose(pose.position, pose.rotation, pose.scale), anim, pose.time, pose.loop, pose.flags, &r.view3d.pose, override, morphs = pose.morphs, outline_width = pose.outline_width, outline_color = pose.outline_color, parts = parts)
		for mesh, k in n.meshes {
			if mesh.attach.model == mi + 1 {
				mesh_on[k] = view3d_attach_world(r, model, pose.src, mesh.attach.node)
			}
		}
		for other, k in n.models[mi + 1:] {
			if other.attach.model == mi + 1 {
				model_on[mi + 1 + k] = view3d_attach_world(r, model, pose.src, other.attach.node)
			}
		}
		for e, k in n.particles {
			if e.attach.model == mi + 1 {
				emitter_on[k] = view3d_attach_world(r, model, pose.src, e.attach.node)
			}
		}
		for l, k in n.labels {
			if l.attach.model == mi + 1 {
				label_on[k] = view3d_attach_world(r, model, pose.src, l.attach.node)
			}
		}
	}
	for e, i in n.particles {
		if e.attach.model > len(n.models) {
			report(&r.ctx, .Error, {code = .Attach_Target, name = "particles", n = i64(e.attach.model)})
		}
		view3d_particles(r, scene, e, attach_frame(emitter_on[i], e.attach, e.group, e.time))
	}
	for l, i in n.labels {
		if i >= len(labels) || labels[i].texture == 0 {
			continue
		}
		if l.attach.model > len(n.models) {
			report(&r.ctx, .Error, {code = .Attach_Target, name = "label", n = i64(l.attach.model)})
		}
		at := attach_frame(label_on[i], l.attach, l.group, now) * o3d.Vec4{l.at.x, l.at.y, l.at.z, 1}
		sprite := [1]o3d.Particle{{position = at.xyz, size = labels[i].pixels, color = {1, 1, 1, 1}, offset = {0, 0.5}}}
		material := o3d.MATERIAL_DEFAULT
		material.flags += {.Basic, .Transparent, .No_Size_Attenuation, .Premultiplied_Color_Map}
		material.color_map = labels[i].texture
		material.depth_offset = l.depth_offset
		if l.flare {
			// its place along the line from the point through the centre, in
			// its own sizes (pixels down, offsets up); over everything (the
			// near plane), the probe still at the point
			px, _, _ := o3d.camera_project(n.camera, size.x, size.y, at.xyz)
			d := (o3d.Vec2{f32(size.x), f32(size.y)} * 0.5 - px) * 2 * l.distance
			sprite[0].offset = {d.x / sprite[0].size.x, -d.y / sprite[0].size.y}
			material.flags += {.Additive}
			material.flags -= {.Transparent}
			material.depth_offset = 1e6
			material.occlusion_radius = l.occlusion_radius
		}
		append(&scene.draws, o3d.Draw{o3d.scene_particles(scene, sprite[:]), 1, material})
	}
	for i in attached {
		mesh := n.meshes[i]
		if mesh.attach.model > len(n.models) {
			report(&r.ctx, .Error, {code = .Attach_Target, name = "mesh", n = i64(mesh.attach.model)})
		}
		view3d_mesh(r, scene, mesh, attach_frame(mesh_on[i], mesh.attach, mesh.group, now) * o3d.compose(mesh.position, mesh.rotation, mesh.scale))
	}
	scene.environment = view3d_texture(r, n.environment)
	scene.environment_intensity = n.environment_intensity
	if col, is_color := view3d_background_color(r, n.background); is_color {
		scene.background_color = col
	} else {
		scene.background = view3d_texture(r, n.background)
	}
	scene.background_intensity = n.background_intensity
	scene.background_blurriness = n.background_blurriness
	scene.tone_mapping = n.tone_mapping
	scene.tone_mapping_exposure = n.tone_mapping_exposure
	scene.fog = n.fog
}

// Draws `mesh` at `transform` (its own position, rotation and scale, on
// what it is attached to).
@(private = "file")
view3d_mesh :: proc(r: ^Renderer, scene: ^o3d.Scene, mesh: Mesh, transform: o3d.Mat4) {
	v := &r.media.view3d
	material := view3d_material(r, scene, mesh.material, mesh.maps, mesh.shader)
	if len(mesh.colors) > 0 {
		material.flags += {.Vertex_Colors}
	}
	geo_id: o3d.Geometry_Id
	switch mesh.path_kind {
	case .None:
		if mesh.outline.kind != .None {
			ex := v.outlines[outline_key(mesh.outline)]
			geo_id = ex.geometry
			if ex.folded > 0 {
				report(&r.ctx, .Warning, {code = .Extrude_Folded, w = f32(ex.folded)})
			}
			if side, ok := mesh.side_material.?; ok {
				// Caps in the material, walls and bevels in the side one.
				geo_id = ex.caps
				side_mat := view3d_material(r, scene, side, {}, nil)
				append(&scene.draws, o3d.Draw{ex.sides, transform, side_mat})
				if len(mesh.instances) > 0 {
					o3d.scene_set_draw_instances(scene, len(scene.draws) - 1, o3d.scene_instances(scene, mesh.instances))
				}
			}
		} else {
			geo_id = v.geometries.keys[mesh.geometry]
		}
	case .Polyline:
		geo_id = o3d.scene_polyline(scene, mesh.points, mesh.path_closed, mesh.colors)
	case .Line_Segments:
		geo_id = o3d.scene_line_segments(scene, mesh.points, mesh.colors)
	case .Points:
		geo_id = o3d.scene_points(scene, mesh.points, mesh.colors)
	case .Tube:
		geo_id = o3d.scene_tube(scene, mesh.points, mesh.tube_radius, mesh.tube_segments, mesh.path_closed)
	}
	di := len(scene.draws)
	append(&scene.draws, o3d.Draw{geo_id, transform, material})
	if len(mesh.instances) > 0 {
		o3d.scene_set_draw_instances(scene, di, o3d.scene_instances(scene, mesh.instances))
	}
}

// A label's sprite this frame: the texture its panel image is bound to and
// the panel's size in the layer's pixels.
View3d_Label_Sprite :: struct {
	texture: o3d.Texture_Id,
	pixels:  [2]f32,
}

// The external texture the `i`th label of a layer is bound to, made the
// first time a layer has that many.
@(private = "file")
view3d_label_texture :: proc(v: ^View3d_Media, i: int) -> o3d.Texture_Id {
	sync.guard(&v.lock)
	for len(v.label_textures) <= i {
		append(&v.label_textures, o3d.texture_add_external(&v.textures, 1, 1))
	}
	return v.label_textures[i]
}

// Emitter `e`'s particles alive at its time, placed by `world` (what it is
// in and attached to), into `scene`.
@(private = "file")
view3d_particles :: proc(r: ^Renderer, scene: ^o3d.Scene, e: Particle_Emitter, world: o3d.Mat4) {
	rows := particle_rows(e, world, particle_births(e))
	if len(rows) == 0 {
		return
	}
	material := e.material
	material.color_map = view3d_texture(r, e.sprite)
	append(&scene.draws, o3d.Draw{o3d.scene_particles(scene, rows), 1, material})
}

// A particle's number (what its draws are seeded by) and when it was born.
Particle_Birth :: struct {
	i:  int,
	at: f32,
}

// The births of emitter `e` alive at its time (temp memory): the steady ones
// at i / rate (younger than the lifetime, from `start`, before `stop`), then
// each burst's, numbered apart from them.
@(private)
particle_births :: proc(e: Particle_Emitter) -> []Particle_Birth {
	if e.lifetime <= 0 || e.time < 0 {
		return nil
	}
	BURST_NUMBERS :: 1 << 40
	births := make([dynamic]Particle_Birth, 0, 64, context.temp_allocator)
	if e.rate > 0 {
		first := max(int(math.floor((e.time - e.lifetime) * e.rate)) + 1, int(math.ceil(e.start * e.rate)), 0)
		last := int(math.floor(e.time * e.rate))
		if e.stop <= e.time {
			last = min(last, int(math.ceil(e.stop * e.rate)) - 1)
		}
		for i in first ..= last {
			append(&births, Particle_Birth{i, f32(i) / e.rate})
		}
	}
	for b, k in e.bursts {
		if b.t <= e.time && e.time - b.t < e.lifetime {
			for j in 0 ..< b.count {
				append(&births, Particle_Birth{BURST_NUMBERS + (k << 20) + j, b.t})
			}
		}
	}
	return births[:]
}

// The particles of `births` at the emitter's time (temp memory): riding
// `world`, or, left behind (`world_space` on a body), placed by the body as
// it was at each birth with its velocity added, in the view's world.
@(private)
particle_rows :: proc(e: Particle_Emitter, world: o3d.Mat4, births: []Particle_Birth) -> []o3d.Particle {
	// a number in [0, 1) for particle i's draw k (splitmix64)
	random :: proc "contextless" (seed: u64, i, k: int) -> f32 {
		z := seed + u64(i) * 0x9e3779b97f4a7c15 + u64(k) * 0xbf58476d1ce4e5b9
		z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
		z = (z ~ (z >> 27)) * 0x94d049bb133111eb
		z ~= z >> 31
		return f32(z >> 40) / f32(1 << 24)
	}
	behind := e.world_space && e.attach.track.sample != nil
	g := group_transform(e.group)
	rows := make([]o3d.Particle, len(births), context.temp_allocator)
	for &p, j in rows {
		b := births[j]
		age := e.time - b.at
		u := clamp(age / e.lifetime, 0, 1)
		off, dv: o3d.Vec3
		for k in 0 ..< 3 {
			off[k] = e.spread[k] * (2 * random(e.seed, b.i, k) - 1)
			dv[k] = e.velocity_spread[k] * (2 * random(e.seed, b.i, k + 3) - 1)
		}
		local, v := e.position + off, e.velocity + dv
		at: o3d.Vec3
		if behind {
			pose, velocity := e.attach.track.sample(e.attach.track.data, e.attach.track.body, b.at)
			born := g * pose
			from := (born * o3d.Vec4{local.x, local.y, local.z, 1}).xyz
			moving := (born * o3d.Vec4{v.x, v.y, v.z, 0}).xyz + (g * o3d.Vec4{velocity.x, velocity.y, velocity.z, 0}).xyz
			at = from + moving * age + e.gravity * (0.5 * age * age)
		} else {
			q := local + v * age + e.gravity * (0.5 * age * age)
			at = (world * o3d.Vec4{q.x, q.y, q.z, 1}).xyz
		}
		size := e.size[0] + (e.size[1] - e.size[0]) * u
		p = {
			position = at,
			size     = {size, size},
			color    = e.color[0] + (e.color[1] - e.color[0]) * u,
			rotation = random(e.seed, b.i, 6) * 2 * math.PI + e.spin * age,
		}
	}
	return rows
}

// The world of node `node` of `model` as just posed: what attaches to it
// rides on it (the identity, reported, when the model has no such node).
@(private = "file")
view3d_attach_world :: proc(r: ^Renderer, model: ^o3d.Model, src, node: string) -> o3d.Mat4 {
	id := o3d.model_node(model, node)
	if id == 0 {
		report(&r.ctx, .Error, {code = .Missing_Model_Part, name = src, a = "node", b = node})
		return 1
	}
	return o3d.model_node_world(model, id, &r.view3d.pose)
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
	id, errors, found := o3d.shader_find(&v.shaders, sh.vertex_shader, sh.fragment_shader, sh.glsl3)
	material.shader = id
	if !found {
		return material
	}
	entry := o3d.shader_get(&v.shaders, id)
	if entry == nil {
		view3d_report_shader_errors(r, errors)
		return material
	}
	material.uniforms = view3d_shader_uniforms(r, scene, entry, sh.uniforms)
	for m in sh.maps {
		if slot := o3d.shader_map(&v.shaders, id, m.name); slot >= 0 {
			material.shader_maps[slot] = view3d_texture(r, m.src)
		} else {
			report(&r.ctx, .Warning, {code = .Shader_Undeclared_Uniform, name = "ShaderMaterial", a = m.name})
		}
	}
	return material
}

@(private = "file")
view3d_report_shader_errors :: proc(r: ^Renderer, errors: []o3d.Shader_Error) {
	for e in errors {
		stage := "Vertex" if e.stage == .Vertex else "Fragment"
		if e.code == .Compile {
			// oksl's own: its position, code and operands
			report(&r.ctx, .Error, {code = .Shader_Compile, name = stage, shader = e.compile})
		} else {
			report(&r.ctx, .Error, {code = .Shader_Compile, name = stage, a = o3d.shader_error_message(e, context.temp_allocator)})
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

// A view's `background` that names no image of the media (nor a sky or a
// video) but a CSS colour: the colour every pixel starts as (three.js's
// scene.background = new Color()), so the view is opaque and what adds
// light (additive glows, bloom) lands on it rather than on nothing.
@(private = "file")
view3d_background_color :: proc(r: ^Renderer, name: string) -> (col: o3d.Vec4, ok: bool) {
	if name == "" || name in r.media.view3d.textures_of || name in r.media.images || name in r.media.videos.by_name {
		return {}, false
	}
	c := vg.css_color_parse(name) or_return
	return {c.r, c.g, c.b, c.a}, true
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
check_geometry_growth :: proc(r: ^Renderer, n: View3d, made: bit_set[o3d.Primitive], made_outlines: bit_set[Outline_Kind]) {
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
		d.earlier_outlines += d.now_outlines
		d.now_outlines = {}
		d.made_last, d.made = d.made, {}
		d.made_last_outlines, d.made_outlines = d.made_outlines, {}
		d.frame = frame
	}
	d.made += made
	d.made_outlines += made_outlines
	for kind in made & d.earlier & d.made_last {
		report(&r.ctx, .Warning, {code = .Geometry_Growth, name = GEOMETRY_TYPES[kind].name})
	}
	OUTLINE_TYPES := [Outline_Kind]string{.None = "", .Shape = "ShapeGeometry", .Exact = "ShapeGeometry", .Extrude = "ExtrudeGeometry"}
	for kind in made_outlines & d.earlier_outlines & d.made_last_outlines {
		report(&r.ctx, .Warning, {code = .Geometry_Growth, name = OUTLINE_TYPES[kind]})
	}
	for mesh in n.meshes {
		if mesh.geometry.kind != .None {
			d.now += {mesh.geometry.kind}
		}
		if mesh.outline.kind != .None {
			d.now_outlines += {mesh.outline.kind}
		}
	}
}
