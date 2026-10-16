package onimite_script

import "core:c"
import "core:math"
import "core:slice"
import "deps:o3d"
import om "../onimite"
import lua "vendor:lua/5.4"

// view3d{}: a 3D layer in three.js's vocabulary (onimite/view3d.odin).
// Every table takes its three.js counterpart's properties in snake case
// (`ground_color`, `cast_shadow`, `width_segments`), its `type` the
// three.js class ("BoxGeometry", "MeshStandardMaterial",
// "DirectionalLight", "PerspectiveCamera"), and is checked like any option
// table: a key nothing reads warns, nested tables included. A property
// only some types have is read only for those, so a misplaced one warns too.

// view3d{ x, y, w, h, opacity, camera = {...}, lights = {...}, meshes =
// {...}, models = {...}, environment, environment_intensity, background,
// background_intensity, background_blurriness, tone_mapping,
// tone_mapping_exposure, fog = {...} }; the box defaults to the whole
// video.
@(private)
l_view3d :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	ctx := render_ctx(L, s)
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	fields_begin(L, 1)
	v := om.View3d {
		x                     = get_num(L, 1, "x", 0),
		y                     = get_num(L, 1, "y", 0),
		w                     = get_num(L, 1, "w", get_num(L, 1, "width", f32(ctx.video.width))),
		h                     = get_num(L, 1, "h", get_num(L, 1, "height", f32(ctx.video.height))),
		opacity               = get_maybe(L, 1, "opacity"),
		camera                = o3d.CAMERA_DEFAULT,
		environment           = get_str(L, 1, "environment", ""),
		environment_intensity = get_num(L, 1, "environment_intensity", 1),
		background            = get_str(L, 1, "background", ""),
		background_intensity  = get_num(L, 1, "background_intensity", 1),
		background_blurriness = get_num(L, 1, "background_blurriness", 0),
		tone_mapping          = read_tone_mapping(L, 1),
		tone_mapping_exposure = get_num(L, 1, "tone_mapping_exposure", 1),
	}
	field(L, 1, "camera")
	if lua.istable(L, -1) {
		v.camera = read_camera(L, s, lua.absindex(L, -1))
	}
	lua.pop(L, 1)
	field(L, 1, "fog")
	if lua.istable(L, -1) {
		v.fog = read_fog(L, s, lua.absindex(L, -1))
	}
	lua.pop(L, 1)
	v.lights = read_list(L, s, 1, "lights", o3d.Light, read_light)
	v.meshes = read_list(L, s, 1, "meshes", om.Mesh, read_mesh)
	v.models = read_list(L, s, 1, "models", om.Model_Pose, read_model)
	om.view3d(ctx, s.frame, v)
	fields_end(L, s, 1, "view3d")
	return 0
}

@(private = "file")
read_tone_mapping :: proc(L: ^lua.State, t: c.int) -> o3d.Tone_Mapping {
	tm := get_str(L, t, "tone_mapping", "none")
	switch tm {
	case "none", "NoToneMapping":
		return .None
	case "linear", "LinearToneMapping":
		return .Linear
	case "reinhard", "ReinhardToneMapping":
		return .Reinhard
	case "cineon", "CineonToneMapping":
		return .Cineon
	case "aces", "aces_filmic", "ACESFilmicToneMapping":
		return .ACES_Filmic
	case "agx", "AgXToneMapping":
		return .AgX
	case "neutral", "NeutralToneMapping":
		return .Neutral
	case:
		bad_string(L, "tone_mapping", tm, "none, linear, reinhard, cineon, aces_filmic, agx or neutral")
		return .None
	}
}

// Fog (`near`, `far`) or FogExp2 (`density`).
@(private = "file")
read_fog :: proc(L: ^lua.State, s: ^Script, t: c.int) -> (fog: o3d.Fog) {
	outer := fields_push(L, t)
	defer fields_pop(L, s, t, "fog", outer)
	switch kind := get_str(L, t, "type", "Fog"); kind {
	case "Fog":
		fog.kind = .Linear
		fog.color = read_color3(L, t, "color", {1, 1, 1})
		fog.near = get_num(L, t, "near", 1)
		fog.far = get_num(L, t, "far", 1000)
	case "FogExp2":
		fog.kind = .Exp2
		fog.color = read_color3(L, t, "color", {1, 1, 1})
		fog.density = get_num(L, t, "density", 0.00025)
	case:
		field_log = outer
		bad_string(L, "fog type", kind, "Fog or FogExp2")
	}
	return
}

// The tables of list `key` read by `read` (temp memory); entries it
// rejects are left out.
@(private = "file")
read_list :: proc(L: ^lua.State, s: ^Script, t: c.int, key: cstring, $T: typeid, read: proc(L: ^lua.State, s: ^Script, at: c.int) -> (T, bool)) -> []T {
	field(L, t, key)
	defer lua.pop(L, 1)
	if !lua.istable(L, -1) {
		return nil
	}
	n := int(lua.rawlen(L, -1))
	out := make([dynamic]T, 0, n, context.temp_allocator)
	for i in 1 ..= n {
		lua.rawgeti(L, -1, lua.Integer(i))
		if lua.istable(L, -1) {
			if item, ok := read(L, s, lua.absindex(L, -1)); ok {
				append(&out, item)
			}
		}
		lua.pop(L, 1)
	}
	return out[:]
}

// PerspectiveCamera (`fov`) or OrthographicCamera (`height`: the view's
// height in world units, its width following the box's aspect).
@(private = "file")
read_camera :: proc(L: ^lua.State, s: ^Script, t: c.int) -> (cam: o3d.Camera) {
	outer := fields_push(L, t)
	defer fields_pop(L, s, t, "camera", outer)
	cam = o3d.CAMERA_DEFAULT
	switch kind := get_str(L, t, "type", "PerspectiveCamera"); kind {
	case "PerspectiveCamera":
		cam.fov = get_num(L, t, "fov", cam.fov)
	case "OrthographicCamera":
		cam.orthographic = true
		cam.height = get_num(L, t, "height", 2)
	case:
		bad_string(L, "camera type", kind, "PerspectiveCamera or OrthographicCamera")
	}
	cam.position = read_vec3(L, t, "position", cam.position)
	cam.target = read_vec3(L, t, "target", cam.target)
	cam.up = read_vec3(L, t, "up", cam.up)
	cam.near = get_num(L, t, "near", cam.near)
	cam.far = get_num(L, t, "far", cam.far)
	return
}

// What a light type reads besides its type.
@(private = "file")
Light_Field :: enum u8 {
	Color,
	Ground_Color,
	Intensity,
	Position,
	Target,
	Distance,
	Decay,
	Angle,
	Penumbra,
	Cast_Shadow,
	Shadow,
}

@(private = "file", rodata)
LIGHT_TYPES := [o3d.Light_Kind]struct {
	name:   string,
	fields: bit_set[Light_Field],
} {
	.Ambient     = {"AmbientLight", {.Color, .Intensity}},
	.Hemisphere  = {"HemisphereLight", {.Color, .Ground_Color, .Intensity}},
	.Directional = {"DirectionalLight", {.Color, .Intensity, .Position, .Target, .Cast_Shadow, .Shadow}},
	.Point       = {"PointLight", {.Color, .Intensity, .Position, .Distance, .Decay}},
	.Spot        = {"SpotLight", {.Color, .Intensity, .Position, .Target, .Distance, .Decay, .Angle, .Penumbra, .Cast_Shadow, .Shadow}},
}

// A light with three.js's defaults (white, intensity 1, a directional or
// spot light from above toward the origin, a point or spot light's decay 2,
// a spot light's angle PI / 3).
@(private = "file")
read_light :: proc(L: ^lua.State, s: ^Script, t: c.int) -> (l: o3d.Light, ok: bool) {
	outer := fields_push(L, t)
	name := get_str(L, t, "type", "")
	kind, known := light_kind(name)
	if !known {
		// Its other keys are not to blame.
		field_log = outer
		bad_string(L, "light type", name, "AmbientLight, HemisphereLight, DirectionalLight, PointLight or SpotLight")
		return
	}
	defer fields_pop(L, s, t, "light", outer)
	reads := LIGHT_TYPES[kind].fields
	l = {kind = kind, color = {1, 1, 1}, intensity = 1, position = {0, 1, 0}, decay = 2, angle = math.PI / 3}
	if .Color in reads {l.color = read_color3(L, t, "color", l.color)}
	if .Ground_Color in reads {l.ground = read_color3(L, t, "ground_color", l.ground)}
	if .Intensity in reads {l.intensity = get_num(L, t, "intensity", l.intensity)}
	if .Position in reads {l.position = read_vec3(L, t, "position", l.position)}
	if .Target in reads {l.target = read_vec3(L, t, "target", l.target)}
	if .Distance in reads {l.distance = get_num(L, t, "distance", l.distance)}
	if .Decay in reads {l.decay = get_num(L, t, "decay", l.decay)}
	if .Angle in reads {l.angle = get_num(L, t, "angle", l.angle)}
	if .Penumbra in reads {l.penumbra = get_num(L, t, "penumbra", l.penumbra)}
	if .Cast_Shadow in reads {l.cast_shadow = get_bool(L, t, "cast_shadow", false)}
	if .Shadow in reads {
		field(L, t, "shadow")
		if lua.istable(L, -1) {
			st := lua.absindex(L, -1)
			inner := fields_push(L, st)
			l.shadow = {
				map_size    = int(get_num(L, st, "map_size", 0)),
				height      = get_num(L, st, "height", 0),
				near        = get_num(L, st, "near", 0),
				far         = get_num(L, st, "far", 0),
				bias        = get_num(L, st, "bias", 0),
				normal_bias = get_num(L, st, "normal_bias", 0),
			}
			fields_pop(L, s, st, "shadow", inner)
		}
		lua.pop(L, 1)
	}
	return l, true
}

@(private = "file")
light_kind :: proc(name: string) -> (o3d.Light_Kind, bool) {
	for lt, k in LIGHT_TYPES {
		if lt.name == name {
			return k, true
		}
	}
	return {}, false
}

// A mesh: `geometry`, `material` (MeshStandardMaterial's defaults for
// surface meshes, LineBasicMaterial for LineGeometry/LineSegmentsGeometry,
// PointsMaterial for PointsGeometry), optional `instances`, position,
// rotation (radians), scale (a number scales all three) and three.js's
// shadow flags.
@(private = "file")
read_mesh :: proc(L: ^lua.State, s: ^Script, t: c.int) -> (m: om.Mesh, ok: bool) {
	outer := fields_push(L, t)
	field(L, t, "geometry")
	if lua.istable(L, -1) {
		ok = read_geometry(L, s, lua.absindex(L, -1), &m)
	} else {
		bad_string(L, "mesh geometry", "nil", `a table such as { type = "BoxGeometry", width = 1, height = 1, depth = 1 }`)
	}
	lua.pop(L, 1)
	if !ok {
		// Left out: its other keys are not to blame.
		field_log = outer
		return
	}
	defer fields_pop(L, s, t, "mesh", outer)
	m.position = read_vec3(L, t, "position", {})
	m.rotation = read_vec3(L, t, "rotation", {})
	m.scale = read_vec3(L, t, "scale", {1, 1, 1}, splat = true)
	m.instances = read_list(L, s, t, "instances", o3d.Instance, read_instance)
	m.material = o3d.MATERIAL_DEFAULT
	default_mat := "MeshStandardMaterial"
	switch m.path_kind {
	case .None:
	case .Polyline, .Line_Segments:
		default_mat = "LineBasicMaterial"
		m.material.mode = .Lines
		m.material.flags += {.Basic}
	case .Points:
		default_mat = "PointsMaterial"
		m.material.mode = .Points
		m.material.flags += {.Basic}
	}
	field(L, t, "material")
	if lua.istable(L, -1) {
		m.material = o3d.MATERIAL_DEFAULT
		read_material(L, s, lua.absindex(L, -1), default_mat, &m.material, &m.maps, &m.shader)
	}
	lua.pop(L, 1)
	if m.path_kind == .Polyline || m.path_kind == .Line_Segments {
		m.material.mode = .Lines
	} else if m.path_kind == .Points {
		m.material.mode = .Points
	}
	if get_bool(L, t, "cast_shadow", false) {
		m.material.flags += {.Cast_Shadow}
	}
	if get_bool(L, t, "receive_shadow", false) {
		m.material.flags += {.Receive_Shadow}
	}
	return m, true
}

@(private = "file")
read_instance :: proc(L: ^lua.State, s: ^Script, t: c.int) -> (inst: o3d.Instance, ok: bool) {
	outer := fields_push(L, t)
	defer fields_pop(L, s, t, "instance", outer)
	pos := read_vec3(L, t, "position", {})
	rot := read_vec3(L, t, "rotation", {})
	scl := read_vec3(L, t, "scale", {1, 1, 1}, splat = true)
	inst.transform = o3d.compose(pos, rot, scl)
	if has_field(L, t, "color") {
		inst.color = read_color3(L, t, "color", {1, 1, 1})
		inst.has_color = true
	}
	return inst, true
}

// A geometry type and its parameters (`om.GEOMETRY_TYPES`), or per-frame
// line/point positions (`LineGeometry`, `LineSegmentsGeometry`,
// `PointsGeometry`).
@(private = "file")
read_geometry :: proc(L: ^lua.State, s: ^Script, t: c.int, m: ^om.Mesh) -> (ok: bool) {
	outer := fields_push(L, t)
	name := get_str(L, t, "type", "")
	switch name {
	case "LineGeometry":
		defer fields_pop(L, s, t, "geometry", outer)
		m.path_kind = .Polyline
		m.path_closed = get_bool(L, t, "closed", false)
		m.points = read_points(L, t, "points")
		return true
	case "LineSegmentsGeometry":
		defer fields_pop(L, s, t, "geometry", outer)
		m.path_kind = .Line_Segments
		m.points = read_points(L, t, "points")
		return true
	case "PointsGeometry":
		defer fields_pop(L, s, t, "geometry", outer)
		m.path_kind = .Points
		m.points = read_points(L, t, "points")
		return true
	}
	for gt, k in om.GEOMETRY_TYPES {
		if k != .None && gt.name == name {
			m.geometry.kind = k
		}
	}
	if m.geometry.kind == .None {
		field_log = outer
		bad_string(L, "geometry type", name, "BoxGeometry, SphereGeometry, PlaneGeometry, CylinderGeometry, TorusGeometry, LineGeometry, LineSegmentsGeometry or PointsGeometry")
		return false
	}
	defer fields_pop(L, s, t, "geometry", outer)
	for p, i in om.GEOMETRY_TYPES[m.geometry.kind].params {
		if p.name == nil {
			break
		}
		switch p.kind {
		case .Size:
			m.geometry.params[i] = get_num(L, t, p.name, p.default)
		case .Count:
			m.geometry.params[i] = max(math.floor(get_num(L, t, p.name, p.default)), p.least)
		case .Flag:
			m.geometry.params[i] = 1 if get_bool(L, t, p.name, p.default != 0) else 0
		}
	}
	return true
}

@(private = "file")
read_points :: proc(L: ^lua.State, t: c.int, key: cstring) -> []o3d.Vec3 {
	field(L, t, key)
	defer lua.pop(L, 1)
	if !lua.istable(L, -1) {
		return nil
	}
	n := int(lua.rawlen(L, -1))
	if n == 0 {
		return nil
	}
	lua.rawgeti(L, -1, 1)
	first_is_num := lua.type(L, -1) == .NUMBER
	lua.pop(L, 1)
	if first_is_num {
		count := n / 3
		pts := make([]o3d.Vec3, count, context.temp_allocator)
		for i in 0 ..< count {
			for c in 0 ..< 3 {
				lua.rawgeti(L, -1, lua.Integer(i * 3 + c + 1))
				pts[i][c] = f32(lua.tonumber(L, -1))
				lua.pop(L, 1)
			}
		}
		return pts
	}
	pts := make([dynamic]o3d.Vec3, 0, n, context.temp_allocator)
	for i in 1 ..= n {
		lua.rawgeti(L, -1, lua.Integer(i))
		if lua.istable(L, -1) {
			v: o3d.Vec3
			for c in 0 ..< 3 {
				lua.rawgeti(L, -1, lua.Integer(c + 1))
				v[c] = f32(lua.tonumber(L, -1))
				lua.pop(L, 1)
			}
			append(&pts, v)
		}
		lua.pop(L, 1)
	}
	return pts[:]
}

// MeshStandardMaterial, MeshBasicMaterial (unlit: its colour, opacity and
// `map`), MeshToonMaterial (banded light), LineBasicMaterial (`linewidth`, `size_attenuation`),
// PointsMaterial (`size`, `size_attenuation`, `map`) or ShaderMaterial
// (custom GLSL ES vertex and fragment shaders and per-frame uniforms).
// Texture maps are media images by name.
@(private = "file")
read_material :: proc(L: ^lua.State, s: ^Script, t: c.int, default_type: string, m: ^o3d.Material, maps: ^[om.Texture_Map]string, shader: ^Maybe(om.Shader_Material)) {
	outer := fields_push(L, t)
	defer fields_pop(L, s, t, "material", outer)
	kind := get_str(L, t, "type", default_type)
	switch kind {
	case "MeshStandardMaterial":
	case "MeshBasicMaterial":
		m.flags += {.Basic}
	case "MeshToonMaterial":
		m.flags += {.Toon}
	case "LineBasicMaterial":
		m.flags += {.Basic}
		m.mode = .Lines
	case "PointsMaterial":
		m.flags += {.Basic}
		m.mode = .Points
	case "ShaderMaterial":
	case:
		bad_string(L, "material type", kind, "MeshStandardMaterial, MeshBasicMaterial, MeshToonMaterial, LineBasicMaterial, PointsMaterial or ShaderMaterial")
	}
	if get_bool(L, t, "transparent", false) {
		m.flags += {.Transparent}
	}
	switch side := get_str(L, t, "side", "front"); side {
	case "front":
		m.side = .Front
	case "back":
		m.side = .Back
	case "double":
		m.side = .Double
	case:
		bad_string(L, "material side", side, "front, back or double")
	}
	if kind == "ShaderMaterial" {
		sh := om.Shader_Material {
			vertex_shader   = get_str(L, t, "vertex_shader", ""),
			fragment_shader = get_str(L, t, "fragment_shader", ""),
			glsl3           = get_bool(L, t, "glsl3", false),
		}
		field(L, t, "uniforms")
		if lua.istable(L, -1) {
			ut := lua.absindex(L, -1)
			uniforms := make([dynamic]o3d.Uniform, context.temp_allocator)
			for key in sorted_keys(L, ut) {
				push_key(L, ut, key)
				values := make([dynamic]f32, context.temp_allocator)
				read_shader_floats(L, -1, &values)
				append(&uniforms, o3d.Uniform{name = key, value = values[:]})
				lua.pop(L, 1)
			}
			sh.uniforms = uniforms[:]
		}
		lua.pop(L, 1)
		shader^ = sh
		return
	}
	m.color = read_color3(L, t, "color", m.color)
	m.opacity = get_num(L, t, "opacity", m.opacity)
	if kind == "LineBasicMaterial" {
		m.size = get_num(L, t, "linewidth", m.size)
		if !get_bool(L, t, "size_attenuation", true) {
			m.flags += {.No_Size_Attenuation}
		}
		return
	}
	maps[.Color] = get_str(L, t, om.TEXTURE_MAPS[.Color], "")
	if cutoff := get_num(L, t, "alpha_test", 0); cutoff > 0 {
		m.alpha_cutoff = cutoff
		m.flags += {.Alpha_Mask}
	}
	if kind == "PointsMaterial" {
		m.size = get_num(L, t, "size", m.size)
		if !get_bool(L, t, "size_attenuation", true) {
			m.flags += {.No_Size_Attenuation}
		}
		return
	}
	if get_bool(L, t, "wireframe", false) {
		m.mode = .Lines
	}
	if w := get_num(L, t, "wireframe_linewidth", 0); w > 0 {
		m.size = w
	}
	if !get_bool(L, t, "size_attenuation", true) {
		m.flags += {.No_Size_Attenuation}
	}
	m.outline_width = get_num(L, t, "outline_width", 0)
	m.outline_color = read_color3(L, t, "outline_color", {})
	if .Basic in m.flags {
		return
	}
	m.metalness = get_num(L, t, "metalness", m.metalness)
	m.roughness = get_num(L, t, "roughness", m.roughness)
	m.emissive = read_color3(L, t, "emissive", m.emissive)
	m.emissive_intensity = get_num(L, t, "emissive_intensity", m.emissive_intensity)
	m.ao_map_intensity = get_num(L, t, "ao_map_intensity", m.ao_map_intensity)
	if get_bool(L, t, "flat_shading", false) {
		m.flags += {.Flat_Shading}
	}
	for k in om.Texture_Map {
		if k != .Color {
			maps[k] = get_str(L, t, om.TEXTURE_MAPS[k], "")
		}
	}
}

// Numbers, booleans, colours (`"#rrggbb"`, `rgb(...)`, `0xff8800`: linear
// RGBA) and nested lists, flattened.
@(private = "file")
read_shader_floats :: proc(L: ^lua.State, at: c.int, out: ^[dynamic]f32) {
	idx := lua.absindex(L, at)
	#partial switch lua.type(L, idx) {
	case .NUMBER:
		append(out, f32(lua.tonumber(L, idx)))
	case .BOOLEAN:
		append(out, f32(1) if lua.toboolean(L, idx) else 0)
	case .STRING:
		col := read_color_value(L, idx)
		append(out, o3d.srgb_to_linear(col.r), o3d.srgb_to_linear(col.g), o3d.srgb_to_linear(col.b), col.a)
	case .TABLE:
		if has_field(L, idx, "r") {
			col := read_color_value(L, idx)
			append(out, o3d.srgb_to_linear(col.r), o3d.srgb_to_linear(col.g), o3d.srgb_to_linear(col.b), col.a)
			return
		}
		n := int(lua.rawlen(L, idx))
		for i in 1 ..= n {
			lua.rawgeti(L, idx, lua.Integer(i))
			read_shader_floats(L, -1, out)
			lua.pop(L, 1)
		}
	}
}

// A glTF model of the media (`src`), placed by position, rotation and
// scale, posed at `time` seconds (default the frame's) of `animation` (a
// name or an index; none: its rest pose), looping unless `loop = false`,
// with optional `morphs` weight overrides, shadow flags, `toon` shading,
// an `outline_width` / `outline_color` cartoon outline or a `material`
// override.
@(private = "file")
read_model :: proc(L: ^lua.State, s: ^Script, t: c.int) -> (p: om.Model_Pose, ok: bool) {
	outer := fields_push(L, t)
	p.src = get_str(L, t, "src", "")
	if p.src == "" {
		field_log = outer
		bad_string(L, "model src", "", "a .glb, .gltf, .3mf or .obj file of the media")
		return
	}
	defer fields_pop(L, s, t, "model", outer)
	p.position = read_vec3(L, t, "position", {})
	p.rotation = read_vec3(L, t, "rotation", {})
	p.scale = read_vec3(L, t, "scale", {1, 1, 1}, splat = true)
	p.animation_index = -1
	field(L, t, "animation")
	#partial switch lua.type(L, -1) {
	case .STRING:
		p.animation = string(lua.tostring(L, -1))
	case .NUMBER:
		p.animation_index = int(lua.tointeger(L, -1))
	}
	lua.pop(L, 1)
	p.time = get_num(L, t, "time", om.frame_seconds(s.frame))
	p.loop = get_bool(L, t, "loop", true)
	field(L, t, "morphs")
	if lua.istable(L, -1) {
		mt := lua.absindex(L, -1)
		morphs := make([dynamic]o3d.Morph_Weight, context.temp_allocator)
		indices := make([dynamic]int, context.temp_allocator)
		lua.pushnil(L)
		for lua.next(L, mt) != 0 {
			if lua.isinteger(L, -2) {
				append(&indices, int(lua.tointeger(L, -2)))
			}
			lua.pop(L, 1)
		}
		slice.sort(indices[:])
		for k in indices {
			lua.rawgeti(L, mt, lua.Integer(k))
			if lua.type(L, -1) == .NUMBER {
				append(&morphs, o3d.Morph_Weight{index = k - 1, weight = f32(lua.tonumber(L, -1))})
			}
			lua.pop(L, 1)
		}
		for key in sorted_keys(L, mt) {
			push_key(L, mt, key)
			if lua.type(L, -1) == .NUMBER {
				append(&morphs, o3d.Morph_Weight{name = key, weight = f32(lua.tonumber(L, -1))})
			}
			lua.pop(L, 1)
		}
		p.morphs = morphs[:]
	}
	lua.pop(L, 1)
	field(L, t, "material")
	if lua.istable(L, -1) {
		over := om.Model_Material{material = o3d.MATERIAL_DEFAULT}
		read_material(L, s, lua.absindex(L, -1), "MeshStandardMaterial", &over.material, &over.maps, &over.shader)
		p.material = over
	}
	lua.pop(L, 1)
	if get_bool(L, t, "cast_shadow", false) {
		p.flags += {.Cast_Shadow}
	}
	if get_bool(L, t, "receive_shadow", false) {
		p.flags += {.Receive_Shadow}
	}
	if get_bool(L, t, "toon", false) {
		p.flags += {.Toon}
	}
	p.outline_width = get_num(L, t, "outline_width", 0)
	p.outline_color = read_color3(L, t, "outline_color", {})
	return p, true
}

// `key` as a vector {x, y, z} (three.js's Vector3), else `def`; with
// `splat`, a number is all three (`scale = 2`).
@(private)
read_vec3 :: proc(L: ^lua.State, t: c.int, key: cstring, def: o3d.Vec3, splat := false) -> o3d.Vec3 {
	field(L, t, key)
	defer lua.pop(L, 1)
	if splat && lua.type(L, -1) == .NUMBER {
		k := f32(lua.tonumber(L, -1))
		return {k, k, k}
	}
	if !lua.istable(L, -1) {
		return def
	}
	v: o3d.Vec3
	for k in 0 ..< 3 {
		lua.rawgeti(L, -1, lua.Integer(k + 1))
		v[k] = f32(lua.tonumber(L, -1))
		lua.pop(L, 1)
	}
	return v
}

// `key` as an sRGB colour (three.js's Color): any CSS colour, `rgb()`, or
// a number as three.js writes them (0xff8800); else `def`.
@(private = "file")
read_color3 :: proc(L: ^lua.State, t: c.int, key: cstring, def: o3d.Vec3) -> o3d.Vec3 {
	field(L, t, key)
	defer lua.pop(L, 1)
	#partial switch lua.type(L, -1) {
	case .NUMBER:
		h := u32(lua.tointeger(L, -1))
		return {f32(h >> 16 & 255) / 255, f32(h >> 8 & 255) / 255, f32(h & 255) / 255}
	case .STRING, .TABLE:
		col := read_color_value(L, -1)
		return {col.r, col.g, col.b}
	}
	return def
}

@(private = "file")
get_bool :: proc(L: ^lua.State, t: c.int, key: cstring, def: bool) -> bool {
	field(L, t, key)
	defer lua.pop(L, 1)
	if lua.type(L, -1) == .BOOLEAN {
		return bool(lua.toboolean(L, -1))
	}
	return def
}
