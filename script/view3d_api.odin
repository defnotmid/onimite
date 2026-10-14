package onimite_script

import "core:c"
import "core:math"
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
// background_intensity, background_blurriness }; the box defaults to the
// whole video.
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
	}
	field(L, 1, "camera")
	if lua.istable(L, -1) {
		v.camera = read_camera(L, s, lua.absindex(L, -1))
	}
	lua.pop(L, 1)
	v.lights = read_list(L, s, 1, "lights", o3d.Light, read_light)
	v.meshes = read_list(L, s, 1, "meshes", om.Mesh, read_mesh)
	v.models = read_list(L, s, 1, "models", om.Model_Pose, read_model)
	om.view3d(ctx, s.frame, v)
	fields_end(L, s, 1, "view3d")
	return 0
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
}

// A light with three.js's defaults (white, intensity 1, a directional
// light from above toward the origin, a point light's decay 2).
@(private = "file")
read_light :: proc(L: ^lua.State, s: ^Script, t: c.int) -> (l: o3d.Light, ok: bool) {
	outer := fields_push(L, t)
	name := get_str(L, t, "type", "")
	kind, known := light_kind(name)
	if !known {
		// Its other keys are not to blame.
		field_log = outer
		bad_string(L, "light type", name, "AmbientLight, HemisphereLight, DirectionalLight or PointLight")
		return
	}
	defer fields_pop(L, s, t, "light", outer)
	reads := LIGHT_TYPES[kind].fields
	l = {kind = kind, color = {1, 1, 1}, intensity = 1, position = {0, 1, 0}, decay = 2}
	if .Color in reads {l.color = read_color3(L, t, "color", l.color)}
	if .Ground_Color in reads {l.ground = read_color3(L, t, "ground_color", l.ground)}
	if .Intensity in reads {l.intensity = get_num(L, t, "intensity", l.intensity)}
	if .Position in reads {l.position = read_vec3(L, t, "position", l.position)}
	if .Target in reads {l.target = read_vec3(L, t, "target", l.target)}
	if .Distance in reads {l.distance = get_num(L, t, "distance", l.distance)}
	if .Decay in reads {l.decay = get_num(L, t, "decay", l.decay)}
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

// A mesh: `geometry`, `material` (MeshStandardMaterial's defaults when
// left out), position, rotation (radians), scale (a number scales all
// three) and three.js's shadow flags.
@(private = "file")
read_mesh :: proc(L: ^lua.State, s: ^Script, t: c.int) -> (m: om.Mesh, ok: bool) {
	outer := fields_push(L, t)
	field(L, t, "geometry")
	if lua.istable(L, -1) {
		m.geometry, ok = read_geometry(L, s, lua.absindex(L, -1))
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
	m.material = o3d.MATERIAL_DEFAULT
	field(L, t, "material")
	if lua.istable(L, -1) {
		read_material(L, s, lua.absindex(L, -1), &m)
	}
	lua.pop(L, 1)
	if get_bool(L, t, "cast_shadow", false) {
		m.material.flags += {.Cast_Shadow}
	}
	if get_bool(L, t, "receive_shadow", false) {
		m.material.flags += {.Receive_Shadow}
	}
	return m, true
}

// A geometry type and its parameters (`om.GEOMETRY_TYPES`).
@(private = "file")
read_geometry :: proc(L: ^lua.State, s: ^Script, t: c.int) -> (key: o3d.Geometry_Key, ok: bool) {
	outer := fields_push(L, t)
	name := get_str(L, t, "type", "")
	for gt, k in om.GEOMETRY_TYPES {
		if k != .None && gt.name == name {
			key.kind = k
		}
	}
	if key.kind == .None {
		field_log = outer
		bad_string(L, "geometry type", name, "BoxGeometry, SphereGeometry, PlaneGeometry, CylinderGeometry or TorusGeometry")
		return
	}
	defer fields_pop(L, s, t, "geometry", outer)
	for p, i in om.GEOMETRY_TYPES[key.kind].params {
		if p.name == nil {
			break
		}
		switch p.kind {
		case .Size:
			key.params[i] = get_num(L, t, p.name, p.default)
		case .Count:
			key.params[i] = max(math.floor(get_num(L, t, p.name, p.default)), p.least)
		case .Flag:
			key.params[i] = 1 if get_bool(L, t, p.name, p.default != 0) else 0
		}
	}
	return key, true
}

// MeshStandardMaterial, or MeshBasicMaterial (unlit: its colour, opacity
// and `map`). Texture maps are media images by name.
@(private = "file")
read_material :: proc(L: ^lua.State, s: ^Script, t: c.int, mesh: ^om.Mesh) {
	outer := fields_push(L, t)
	defer fields_pop(L, s, t, "material", outer)
	m := &mesh.material
	switch kind := get_str(L, t, "type", "MeshStandardMaterial"); kind {
	case "MeshStandardMaterial":
	case "MeshBasicMaterial":
		m.flags += {.Basic}
	case:
		bad_string(L, "material type", kind, "MeshStandardMaterial or MeshBasicMaterial")
	}
	m.color = read_color3(L, t, "color", m.color)
	m.opacity = get_num(L, t, "opacity", m.opacity)
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
	mesh.maps[.Color] = get_str(L, t, om.TEXTURE_MAPS[.Color], "")
	if .Basic in m.flags {
		return
	}
	m.metalness = get_num(L, t, "metalness", m.metalness)
	m.roughness = get_num(L, t, "roughness", m.roughness)
	m.emissive = read_color3(L, t, "emissive", m.emissive)
	m.emissive_intensity = get_num(L, t, "emissive_intensity", m.emissive_intensity)
	if get_bool(L, t, "flat_shading", false) {
		m.flags += {.Flat_Shading}
	}
	for k in om.Texture_Map {
		if k != .Color {
			mesh.maps[k] = get_str(L, t, om.TEXTURE_MAPS[k], "")
		}
	}
}

// A glTF model of the media (`src`), placed by position, rotation and
// scale, posed at `time` seconds (default the frame's) of `animation` (a
// name or an index; none: its rest pose), looping unless `loop = false`.
@(private = "file")
read_model :: proc(L: ^lua.State, s: ^Script, t: c.int) -> (p: om.Model_Pose, ok: bool) {
	outer := fields_push(L, t)
	p.src = get_str(L, t, "src", "")
	if p.src == "" {
		field_log = outer
		bad_string(L, "model src", "", "a .glb or .gltf file of the media")
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
	if get_bool(L, t, "cast_shadow", false) {
		p.flags += {.Cast_Shadow}
	}
	if get_bool(L, t, "receive_shadow", false) {
		p.flags += {.Receive_Shadow}
	}
	return p, true
}

// `key` as a vector {x, y, z} (three.js's Vector3), else `def`; with
// `splat`, a number is all three (`scale = 2`).
@(private = "file")
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
