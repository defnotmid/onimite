package onimite_script

import "core:c"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import "core:sync"
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
// tone_mapping_exposure, fog = {...}, bloom = {...} }; the box defaults to
// the whole video.
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
	items := View3d_Items {
		meshes    = make([dynamic]om.Mesh, context.temp_allocator),
		models    = make([dynamic]om.Model_Pose, context.temp_allocator),
		particles = make([dynamic]om.Particle_Emitter, context.temp_allocator),
		labels    = make([dynamic]om.View3d_Label, context.temp_allocator),
	}
	read_items(L, s, 1, &items)
	read_groups(L, s, 1, nil, {}, &items)
	resolve_attach_names(L, &items)
	v.meshes, v.models, v.particles, v.labels = items.meshes[:], items.models[:], items.particles[:], items.labels[:]
	bloom_filter, has_bloom := read_bloom_filter(L, 1)
	if has_bloom {
		om.group_begin(ctx, om.Group{filter = bloom_filter})
		if s.node_sources_on {
			node_source_record(s, L)
		}
	}
	om.view3d(ctx, s.frame, v)
	if has_bloom {
		om.group_end(ctx)
	}
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
	m.position, m.rotation, m.scale = read_pose_transform(L, t)
	m.attach = read_attach(L, s, t)
	m.instances = read_list(L, s, t, "instances", o3d.Instance, read_instance)
	m.material = o3d.MATERIAL_DEFAULT
	default_mat := "MeshStandardMaterial"
	switch m.path_kind {
	case .None, .Tube:
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
	if m.outline.kind == .Shape && m.material.mode == .Triangles && m.shader == nil && m.material.outline_width <= 0 {
		// Drawn from its curves unless the material draws its triangles.
		m.outline.kind = .Exact
	}
	if m.outline.kind == .Extrude {
		// The walls and bevels in a material of their own (three.js's
		// [caps, sides] material array); no texture maps or shader.
		field(L, t, "side_material")
		if lua.istable(L, -1) {
			side := o3d.MATERIAL_DEFAULT
			maps: [om.Texture_Map]string
			shader: Maybe(om.Shader_Material)
			read_material(L, s, lua.absindex(L, -1), default_mat, &side, &maps, &shader)
			if maps != {} || shader != nil {
				lua.L_error(L, "side_material takes colours and surface values only (no texture maps or shader)")
			}
			m.side_material = side
		}
		lua.pop(L, 1)
	}
	if get_bool(L, t, "cast_shadow", false) {
		m.material.flags += {.Cast_Shadow}
	}
	if get_bool(L, t, "receive_shadow", false) {
		m.material.flags += {.Receive_Shadow}
	}
	if side, ok := &m.side_material.?; ok {
		side.flags += m.material.flags & {.Cast_Shadow, .Receive_Shadow}
	}
	return m, true
}

@(private = "file")
read_instance :: proc(L: ^lua.State, s: ^Script, t: c.int) -> (inst: o3d.Instance, ok: bool) {
	outer := fields_push(L, t)
	defer fields_pop(L, s, t, "instance", outer)
	pos, rot, scl := read_pose_transform(L, t)
	inst.transform = o3d.compose(pos, rot, scl)
	if has_field(L, t, "color") {
		inst.color = read_color3(L, t, "color", {1, 1, 1})
		inst.has_color = true
	}
	return inst, true
}

// A geometry type and its parameters (`om.GEOMETRY_TYPES`), or per-frame
// geometry from points (`LineGeometry`, `LineSegmentsGeometry`,
// `PointsGeometry`, `TubeGeometry`).
@(private = "file")
read_geometry :: proc(L: ^lua.State, s: ^Script, t: c.int, m: ^om.Mesh) -> (ok: bool) {
	outer := fields_push(L, t)
	name := get_str(L, t, "type", "")
	switch name {
	case "TubeGeometry":
		defer fields_pop(L, s, t, "geometry", outer)
		m.path_kind = .Tube
		m.path_closed = get_bool(L, t, "closed", false)
		m.tube_radius = get_num(L, t, "radius", 0.08)
		m.tube_segments = max(int(get_num(L, t, "radial_segments", 12)), 3)
		m.points = read_points(L, t, "points")
		return true
	case "LineGeometry":
		defer fields_pop(L, s, t, "geometry", outer)
		m.path_kind = .Polyline
		m.path_closed = get_bool(L, t, "closed", false)
		m.points = read_points(L, t, "points")
		m.colors = read_point_colors(L, t, len(m.points))
		return true
	case "LineSegmentsGeometry":
		defer fields_pop(L, s, t, "geometry", outer)
		m.path_kind = .Line_Segments
		m.points = read_points(L, t, "points")
		m.colors = read_point_colors(L, t, len(m.points))
		return true
	case "PointsGeometry":
		defer fields_pop(L, s, t, "geometry", outer)
		m.path_kind = .Points
		m.points = read_points(L, t, "points")
		m.colors = read_point_colors(L, t, len(m.points))
		return true
	case "ShapeGeometry", "ExtrudeGeometry":
		// An outline (outline{}, path_data, morph_at) in 3D: 1 unit per
		// outline unit, y flipped (it reads upright), extruded along +z
		// from 0 to `depth` (a bevel adds `bevel_thickness` both ways).
		defer fields_pop(L, s, t, "geometry", outer)
		if field(L, t, "shape") != c.int(lua.Type.LIGHTUSERDATA) {
			lua.pop(L, 1)
			lua.L_error(L, "%s", fmt.ctprintf("%s needs shape = an outline (outline{}, path_data() or morph_at())", name))
		}
		m.outline.asset = (^om.Path_Asset)(lua.touserdata(L, -1))
		lua.pop(L, 1)
		m.outline.kind = .Shape
		if name == "ExtrudeGeometry" {
			d := o3d.EXTRUDE_DEFAULT
			m.outline.kind = .Extrude
			m.outline.options = {
				depth           = get_num(L, t, "depth", d.depth),
				steps           = max(int(get_num(L, t, "steps", f32(d.steps))), 1),
				bevel_enabled   = get_bool(L, t, "bevel_enabled", d.bevel_enabled),
				bevel_thickness = get_num(L, t, "bevel_thickness", d.bevel_thickness),
				bevel_size      = get_num(L, t, "bevel_size", d.bevel_size),
				bevel_offset    = get_num(L, t, "bevel_offset", d.bevel_offset),
				bevel_segments  = max(int(get_num(L, t, "bevel_segments", f32(d.bevel_segments))), 0),
				crease_angle    = get_num(L, t, "crease_angle", d.crease_angle),
			}
		}
		return true
	}
	for gt, k in om.GEOMETRY_TYPES {
		if k != .None && gt.name == name {
			m.geometry.kind = k
		}
	}
	if m.geometry.kind == .None {
		field_log = outer
		bad_string(L, "geometry type", name, "BoxGeometry, SphereGeometry, PlaneGeometry, CylinderGeometry, TorusGeometry, CapsuleGeometry, TubeGeometry, ShapeGeometry, ExtrudeGeometry, LineGeometry, LineSegmentsGeometry or PointsGeometry")
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

// A path geometry's `colors`: one per point (sRGB and opacity; any colour
// form, `"#rrggbbaa"` and `rgba()` with their alpha), three.js's vertex
// colours; nil when not given.
@(private = "file")
read_point_colors :: proc(L: ^lua.State, t: c.int, count: int) -> []o3d.Vec4 {
	field(L, t, "colors")
	defer lua.pop(L, 1)
	if !lua.istable(L, -1) {
		return nil
	}
	if n := int(lua.rawlen(L, -1)); n != count {
		lua.L_error(L, "%s", fmt.ctprintf("colors has %d colours for %d points: give one per point", n, count))
	}
	colors := make([]o3d.Vec4, count, context.temp_allocator)
	for &col, i in colors {
		lua.rawgeti(L, -1, lua.Integer(i + 1))
		if lua.type(L, -1) == .NUMBER {
			h := u32(lua.tointeger(L, -1))
			col = {f32(h >> 16 & 255) / 255, f32(h >> 8 & 255) / 255, f32(h & 255) / 255, 1}
		} else {
			v := read_color_value(L, -1)
			col = {v.r, v.g, v.b, v.a}
		}
		lua.pop(L, 1)
	}
	return colors
}

// MeshStandardMaterial, MeshPhysicalMaterial (the standard one with a clear
// coat, sheen and transmission), MeshBasicMaterial (unlit: its colour, opacity and
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
	case "MeshStandardMaterial", "MeshPhysicalMaterial":
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
	case "ShadowMaterial":
		// only the shadows it receives: black at `opacity` where lit less
		m.flags += {.Shadow_Only}
		m.color = {}
	case:
		bad_string(L, "material type", kind, "MeshStandardMaterial, MeshPhysicalMaterial, MeshBasicMaterial, MeshToonMaterial, ShadowMaterial, LineBasicMaterial, PointsMaterial or ShaderMaterial")
	}
	if get_bool(L, t, "transparent", false) {
		m.flags += {.Transparent}
	}
	// three.js's blending: "additive" adds colour x opacity to what is
	// behind, drawn with the transparent ones, depth tested, not written
	switch blending := get_str(L, t, "blending", "normal"); blending {
	case "normal":
	case "additive":
		m.flags += {.Additive}
	case:
		bad_string(L, "material blending", blending, "normal or additive")
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
			maps := make([dynamic]om.Shader_Map, context.temp_allocator)
			for key in sorted_keys(L, ut) {
				push_key(L, ut, key)
				// an image of the media by name: the sampler2D's texture
				if lua.type(L, -1) == .STRING {
					str := string(lua.tostring(L, -1))
					if kind, ok := om.media_kind_of(str); ok && kind == .Image {
						append(&maps, om.Shader_Map{key, strings.clone(str, context.temp_allocator)})
						lua.pop(L, 1)
						continue
					}
				}
				values := make([dynamic]f32, context.temp_allocator)
				read_shader_floats(L, -1, &values)
				append(&uniforms, o3d.Uniform{name = key, value = values[:]})
				lua.pop(L, 1)
			}
			sh.uniforms = uniforms[:]
			sh.maps = maps[:]
		}
		lua.pop(L, 1)
		shader^ = sh
		return
	}
	m.color = read_color3(L, t, "color", m.color)
	m.opacity = get_num(L, t, "opacity", m.opacity)
	if kind == "ShadowMaterial" {
		return
	}
	if kind == "LineBasicMaterial" {
		m.size = get_num(L, t, "linewidth", m.size)
		if !get_bool(L, t, "size_attenuation", true) {
			m.flags += {.No_Size_Attenuation}
		}
		return
	}
	maps[.Color] = get_str(L, t, om.TEXTURE_MAPS[.Color], "")
	maps[.Alpha] = get_str(L, t, om.TEXTURE_MAPS[.Alpha], "")
	if cutoff := get_num(L, t, "alpha_test", 0); cutoff > 0 {
		m.alpha_cutoff = cutoff
		m.flags += {.Alpha_Mask}
	}
	// how its maps land: by the mesh's uvs, or projected along three axes
	// and blended by the normal (triplanar: meshes without uvs), in the
	// mesh's own space (moving with it) or the world's
	switch proj := get_str(L, t, "projection", "uv"); proj {
	case "uv":
	case "object":
		m.projection = .Object
	case "world":
		m.projection = .World
	case:
		bad_string(L, "material projection", proj, "uv, object or world")
	}
	m.projection_scale = get_num(L, t, "projection_scale", 1)
	m.projection_sharpness = get_num(L, t, "projection_sharpness", 4)
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
	for k in om.Texture_Map.Normal ..= om.Texture_Map.AO {
		maps[k] = get_str(L, t, om.TEXTURE_MAPS[k], "")
	}
	if kind != "MeshPhysicalMaterial" {
		return
	}
	// three.js's defaults; o3d's zero values are its own (ior 0: 1.5,
	// black sheen: none, attenuation_distance 0: no absorption)
	m.ior = get_num(L, t, "ior", 1.5)
	m.clearcoat = get_num(L, t, "clearcoat", 0)
	m.clearcoat_roughness = get_num(L, t, "clearcoat_roughness", 0)
	// three.js scales the linear sheen colour by `sheen`; o3d keeps it sRGB
	sheen := get_num(L, t, "sheen", 0)
	sc := read_color3(L, t, "sheen_color", {1, 1, 1})
	m.sheen_color = o3d.linear_to_srgb_vec3(sheen * o3d.Vec3{o3d.srgb_to_linear(sc.x), o3d.srgb_to_linear(sc.y), o3d.srgb_to_linear(sc.z)})
	m.sheen_roughness = get_num(L, t, "sheen_roughness", 1)
	m.transmission = get_num(L, t, "transmission", 0)
	m.thickness = get_num(L, t, "thickness", 0)
	m.attenuation_color = read_color3(L, t, "attenuation_color", {1, 1, 1})
	m.attenuation_distance = get_num(L, t, "attenuation_distance", 0)
	for k in om.Texture_Map.Clearcoat ..= om.Texture_Map.Thickness {
		maps[k] = get_str(L, t, om.TEXTURE_MAPS[k], "")
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
		bad_string(L, "model src", "", "a .glb, .gltf, .3mf, .obj, .usdz or .usdc file of the media")
		return
	}
	defer fields_pop(L, s, t, "model", outer)
	p.position, p.rotation, p.scale = read_pose_transform(L, t)
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
	p.attach = read_attach(L, s, t)
	p.name = strings.clone(get_str(L, t, "name", ""), context.temp_allocator)
	parts := make([dynamic]om.Model_Part, context.temp_allocator)
	read_parts(L, s, t, "nodes", .Node, &parts)
	read_parts(L, s, t, "materials", .Material, &parts)
	p.parts = parts[:]
	return p, true
}

// `attach = { model = i or "name", node = "Name" }`: rides on that node of
// the view's model number `i` (1-based: the top-level models, then the
// groups' in order) or the model of that `name`, as it is posed.
@(private = "file")
read_attach :: proc(L: ^lua.State, s: ^Script, t: c.int) -> (a: om.Attach) {
	field(L, t, "attach")
	defer lua.pop(L, 1)
	if !lua.istable(L, -1) {
		return
	}
	at := lua.absindex(L, -1)
	outer := fields_push(L, at)
	defer fields_pop(L, s, at, "attach", outer)
	// a physics3d body: { sim = physics3d{...}, body = name or number }
	if field(L, at, "sim") == c.int(lua.Type.TABLE) {
		sim := lua.gettop(L)
		lua.getfield(L, sim, "tracks")
		tr := (^Physics3d_Tracks)(lua.touserdata(L, -1))
		lua.pop(L, 1)
		if tr == nil || tr.magic != PHYSICS3D_TRACKS {
			lua.L_error(L, "attach.sim takes the table physics3d{} returned")
		}
		field(L, at, "body")
		a.track = {sample = track3d_sample, data = tr, body = track3d_body(L, tr, sim, lua.gettop(L), "attach")}
		lua.pop(L, 2)
		return
	}
	lua.pop(L, 1)
	field(L, at, "model")
	if lua.type(L, -1) == .STRING {
		a.model_name = strings.clone(string(lua.tostring(L, -1)), context.temp_allocator)
		a.model = -1 // numbered once the view's models are all read
	} else {
		a.model = int(lua.tointeger(L, -1))
	}
	lua.pop(L, 1)
	a.node = strings.clone(get_str(L, at, "node", ""), context.temp_allocator)
	if a.model == 0 || a.node == "" {
		lua.L_error(L, "attach takes { model = <its number in models, from 1, or its name>, node = <a node's name in that model> } or { sim = <a physics3d{} result>, body = <a body's name or number> }")
	}
	return
}

// Numbers the attachments that named their model, and checks that an
// emitter whose particles are left behind (world_space) is on a body,
// its own or its group's.
@(private = "file")
resolve_attach_names :: proc(L: ^lua.State, items: ^View3d_Items) {
	models := items.models[:]
	number :: proc(L: ^lua.State, a: ^om.Attach, models: []om.Model_Pose) {
		if a.model != -1 {
			return
		}
		for m, i in models {
			if m.name == a.model_name {
				a.model = i + 1
				return
			}
		}
		lua.L_error(L, "attach: no model named %s in this view3d", strings.clone_to_cstring(a.model_name, context.temp_allocator))
	}
	for &m in items.meshes {
		number(L, &m.attach, models)
	}
	for &m in models {
		number(L, &m.attach, models)
	}
	for &e in items.particles {
		number(L, &e.attach, models)
		// on its own or its group's body
		if e.world_space && e.attach.track.sample == nil {
			lua.L_error(L, "particles: world_space = true needs attach = { sim = <a physics3d{} result>, body = ... } (its own or its group's): only a body's past poses are known")
		}
	}
	for &l in items.labels {
		number(L, &l.attach, models)
	}
}

// What a view3d and its groups draw, in read order.
@(private = "file")
View3d_Items :: struct {
	meshes:    [dynamic]om.Mesh,
	models:    [dynamic]om.Model_Pose,
	particles: [dynamic]om.Particle_Emitter,
	labels:    [dynamic]om.View3d_Label,
}

@(private = "file")
read_items :: proc(L: ^lua.State, s: ^Script, t: c.int, items: ^View3d_Items) {
	append(&items.meshes, ..read_list(L, s, t, "meshes", om.Mesh, read_mesh))
	append(&items.models, ..read_list(L, s, t, "models", om.Model_Pose, read_model))
	append(&items.particles, ..read_list(L, s, t, "particles", om.Particle_Emitter, read_particles))
	append(&items.labels, ..read_list(L, s, t, "labels", om.View3d_Label, read_label))
	read_lensflares(L, s, t, &items.labels)
}

// A label: `draw` lays out its nodes in a `w x h` panel (its own units
// from the top left), shown with the panel's bottom centre on the 3D point
// `at`, hidden where the scene is nearer; `depth_offset` (world units)
// pulls it toward the camera; `attach` as a mesh's.
@(private = "file")
read_label :: proc(L: ^lua.State, s: ^Script, t: c.int) -> (l: om.View3d_Label, ok: bool) {
	outer := fields_push(L, t)
	defer fields_pop(L, s, t, "label", outer)
	l.at = read_vec3(L, t, "at", {})
	l.w = get_num(L, t, "w", 200)
	l.h = get_num(L, t, "h", 60)
	l.depth_offset = get_num(L, t, "depth_offset", 0)
	l.attach = read_attach(L, s, t)
	l.content = read_panel(L, s, t, "a label takes draw = function() ... end: its nodes, laid out in its w x h panel")
	return l, l.w > 0 && l.h > 0
}

// A panel's `draw` function, run into a content group: its nodes.
@(private = "file")
read_panel :: proc(L: ^lua.State, s: ^Script, t: c.int, missing: cstring) -> i32 {
	field(L, t, "draw")
	if !lua.isfunction(L, -1) {
		lua.pop(L, 1)
		lua.L_error(L, missing)
	}
	ctx := render_ctx(L, s)
	content := om.shader_content_begin(ctx)
	status := lua.pcall(L, 0, 0, 0)
	om.group_end(ctx)
	if status != 0 {
		lua.error(L)
	}
	return content
}

// view3d's `lensflares` (three.js's Lensflare): each `{ position,
// occlusion_radius, attach, elements = { { size, distance, draw }, ... } }`
// adds its elements as panels: `size` pixels square, `distance` along the
// line from the point through the centre, all faded by how much of the
// point the scene hides.
@(private = "file")
read_lensflares :: proc(L: ^lua.State, s: ^Script, t: c.int, labels: ^[dynamic]om.View3d_Label) {
	field(L, t, "lensflares")
	defer lua.pop(L, 1)
	if !lua.istable(L, -1) {
		return
	}
	list := lua.absindex(L, -1)
	for i in 1 ..= int(lua.rawlen(L, list)) {
		lua.rawgeti(L, list, lua.Integer(i))
		if lua.istable(L, -1) {
			ft := lua.absindex(L, -1)
			outer := fields_push(L, ft)
			at := read_vec3(L, ft, "position", {})
			radius := get_num(L, ft, "occlusion_radius", 8)
			attach := read_attach(L, s, ft)
			field(L, ft, "elements")
			fields_pop(L, s, ft, "lensflare", outer)
			if lua.istable(L, -1) {
				et := lua.absindex(L, -1)
				for k in 1 ..= int(lua.rawlen(L, et)) {
					lua.rawgeti(L, et, lua.Integer(k))
					if lua.istable(L, -1) {
						el := lua.absindex(L, -1)
						eo := fields_push(L, el)
						size := get_num(L, el, "size", 100)
						l := om.View3d_Label {
							at               = at,
							w                = size,
							h                = size,
							attach           = attach,
							flare            = true,
							distance         = get_num(L, el, "distance", 0),
							occlusion_radius = radius,
						}
						l.content = read_panel(L, s, el, "a lens flare element takes draw = function() ... end: its nodes, laid out in its size x size panel")
						fields_pop(L, s, el, "lensflare element", eo)
						if size > 0 {
							append(labels, l)
						}
					}
					lua.pop(L, 1)
				}
			}
			lua.pop(L, 1)
		}
		lua.pop(L, 1)
	}
}

// A particle emitter: `rate` a second, each living `lifetime` seconds
// (`time`: its clock, default the frame's), born within `spread` of
// `position`, moving at `velocity` give or take `velocity_spread` under
// `gravity`; `size` / `size_end`, `color` / `color_end` and `opacity` /
// `opacity_end` over its life, `spin` radians a second; the sprite `map`,
// `additive`, `softness` (world units) and `size_attenuation`.
@(private = "file")
read_particles :: proc(L: ^lua.State, s: ^Script, t: c.int) -> (e: om.Particle_Emitter, ok: bool) {
	outer := fields_push(L, t)
	defer fields_pop(L, s, t, "particles", outer)
	e.seed = u64(get_num(L, t, "seed", 1))
	e.rate = get_num(L, t, "rate", 0)
	e.lifetime = get_num(L, t, "lifetime", 1)
	e.time = get_num(L, t, "time", om.frame_seconds(s.frame))
	e.position = read_vec3(L, t, "position", {})
	e.spread = read_vec3(L, t, "spread", {}, splat = true)
	e.velocity = read_vec3(L, t, "velocity", {})
	e.velocity_spread = read_vec3(L, t, "velocity_spread", {}, splat = true)
	e.gravity = read_vec3(L, t, "gravity", {})
	size := get_num(L, t, "size", 0.1)
	e.size = {size, get_num(L, t, "size_end", size)}
	c0 := read_color3(L, t, "color", {1, 1, 1})
	c1 := read_color3(L, t, "color_end", c0)
	o0 := get_num(L, t, "opacity", 1)
	o1 := get_num(L, t, "opacity_end", o0)
	e.color = {{c0.x, c0.y, c0.z, o0}, {c1.x, c1.y, c1.z, o1}}
	e.spin = get_num(L, t, "spin", 0)
	e.start = get_num(L, t, "start", 0)
	e.stop = get_num(L, t, "stop", max(f32))
	if field(L, t, "bursts") == c.int(lua.Type.TABLE) {
		bt := lua.gettop(L)
		bursts := make([]om.Particle_Burst, int(lua.rawlen(L, bt)), context.temp_allocator)
		for &b, k in bursts {
			lua.rawgeti(L, bt, lua.Integer(k + 1))
			if lua.istable(L, -1) {
				one := lua.gettop(L)
				bo := fields_push(L, one)
				b = {t = get_num(L, one, "t", 0), count = max(int(get_num(L, one, "count", 0)), 0)}
				fields_pop(L, s, one, "particles.bursts", bo)
			}
			lua.pop(L, 1)
		}
		e.bursts = bursts
	}
	lua.pop(L, 1)
	e.world_space = get_bool(L, t, "world_space", false)
	e.material = o3d.MATERIAL_DEFAULT
	e.material.flags += {.Basic, .Additive} if get_bool(L, t, "additive", false) else {.Basic, .Transparent}
	if !get_bool(L, t, "size_attenuation", true) {
		e.material.flags += {.No_Size_Attenuation}
	}
	e.material.softness = get_num(L, t, "softness", 0)
	e.sprite = strings.clone(get_str(L, t, "map", ""), context.temp_allocator)
	e.attach = read_attach(L, s, t)
	return e, e.rate > 0 || len(e.bursts) > 0
}

// view3d's `groups`: each `{ position, rotation, scale, attach, meshes,
// models, groups }` places what is in it by its transform (on its parent
// group's); a group's `attach` holds for what in it has none of its own.
@(private = "file")
read_groups :: proc(L: ^lua.State, s: ^Script, t: c.int, parent: Maybe(o3d.Mat4), parent_attach: om.Attach, items: ^View3d_Items) {
	field(L, t, "groups")
	defer lua.pop(L, 1)
	if !lua.istable(L, -1) {
		return
	}
	list := lua.absindex(L, -1)
	for i in 1 ..= int(lua.rawlen(L, list)) {
		lua.rawgeti(L, list, lua.Integer(i))
		if !lua.istable(L, -1) {
			lua.pop(L, 1)
			continue
		}
		gt := lua.absindex(L, -1)
		outer := fields_push(L, gt)
		pos, rot, scl := read_pose_transform(L, gt)
		g := om.group_transform(parent) * o3d.compose(pos, rot, scl)
		attach := read_attach(L, s, gt)
		if om.attach_none(attach) {
			attach = parent_attach
		}
		first_mesh, first_model, first_emitter, first_label := len(items.meshes), len(items.models), len(items.particles), len(items.labels)
		read_items(L, s, gt, items)
		for &m in items.meshes[first_mesh:] {
			m.group = g
			if om.attach_none(m.attach) {
				m.attach = attach
			}
		}
		for &m in items.models[first_model:] {
			m.group = g
			if om.attach_none(m.attach) {
				m.attach = attach
			}
		}
		for &m in items.particles[first_emitter:] {
			m.group = g
			if om.attach_none(m.attach) {
				m.attach = attach
			}
		}
		for &m in items.labels[first_label:] {
			m.group = g
			if om.attach_none(m.attach) {
				m.attach = attach
			}
		}
		read_groups(L, s, gt, g, attach, items)
		fields_pop(L, s, gt, "group", outer)
		lua.pop(L, 1)
	}
}

// A model's `nodes` or `materials`: by name in the model's file, each
// `{ hidden, cast_shadow, receive_shadow }`, a node's own `position`,
// `rotation` (radians) and `scale` replaced, a material's `material` drawn
// in its place.
@(private = "file")
read_parts :: proc(L: ^lua.State, s: ^Script, t: c.int, key: cstring, of: type_of(om.Model_Part{}.of), parts: ^[dynamic]om.Model_Part) {
	field(L, t, key)
	defer lua.pop(L, 1)
	if !lua.istable(L, -1) {
		return
	}
	pt := lua.absindex(L, -1)
	for name in sorted_keys(L, pt) {
		push_key(L, pt, name)
		if !lua.istable(L, -1) {
			lua.L_error(L, "model %s.%s takes a table", key, strings.clone_to_cstring(name, context.temp_allocator))
		}
		at := lua.absindex(L, -1)
		outer := fields_push(L, at)
		part := om.Model_Part{of = of, name = name}
		part.state.hidden = get_bool(L, at, "hidden", false)
		for flag in ([2]struct{key: cstring, flag: o3d.Material_Flag}{{"cast_shadow", .Cast_Shadow}, {"receive_shadow", .Receive_Shadow}}) {
			field(L, at, flag.key)
			if !lua.isnil(L, -1) {
				if lua.toboolean(L, -1) {
					part.state.add += {flag.flag}
				} else {
					part.state.remove += {flag.flag}
				}
			}
			lua.pop(L, 1)
		}
		if of == .Node {
			x := &part.transform
			if has_field(L, at, "position") {
				x.set += {.Translation}
				x.translation = read_vec3(L, at, "position", {})
			}
			if has_field(L, at, "rotation") {
				x.set += {.Rotation}
				e := read_vec3(L, at, "rotation", {})
				// Euler XYZ as o3d.compose: R = Rx * Ry * Rz
				qx := quaternion(w = math.cos(e.x / 2), x = math.sin(e.x / 2), y = 0, z = 0)
				qy := quaternion(w = math.cos(e.y / 2), x = 0, y = math.sin(e.y / 2), z = 0)
				qz := quaternion(w = math.cos(e.z / 2), x = 0, y = 0, z = math.sin(e.z / 2))
				x.rotation = qx * qy * qz
			}
			if has_field(L, at, "scale") {
				x.set += {.Scale}
				x.scale = read_vec3(L, at, "scale", {1, 1, 1}, splat = true)
			}
		} else {
			field(L, at, "material")
			if lua.istable(L, -1) {
				over := om.Model_Material{material = o3d.MATERIAL_DEFAULT}
				read_material(L, s, lua.absindex(L, -1), "MeshStandardMaterial", &over.material, &over.maps, &over.shader)
				part.material = over
			}
			lua.pop(L, 1)
		}
		fields_pop(L, s, at, "model part", outer)
		append(parts, part)
		lua.pop(L, 1)
	}
}

// Reads `position`, `rotation` and `scale`, with optional `from` / `to`
// (places at the midpoint and rotates local +Y from `from` to `to`, scaling
// local Y by the distance when `stretch = true`) or `look_at` (rotates
// local +Z toward `look_at`).
@(private = "file")
read_pose_transform :: proc(L: ^lua.State, t: c.int) -> (pos, rot, scl: o3d.Vec3) {
	pos = read_vec3(L, t, "position", {})
	rot = read_vec3(L, t, "rotation", {})
	scl = read_vec3(L, t, "scale", {1, 1, 1}, splat = true)
	if has_field(L, t, "from") && has_field(L, t, "to") {
		p_from := read_vec3(L, t, "from", {})
		p_to := read_vec3(L, t, "to", {0, 1, 0})
		up := read_vec3(L, t, "up", {0, 1, 0})
		mid, euler, dist := orient_along_y(p_from, p_to, up)
		if !has_field(L, t, "position") {
			pos = mid
		}
		if !has_field(L, t, "rotation") {
			rot = euler
		}
		if get_bool(L, t, "stretch", false) {
			scl.y *= dist
		}
	} else if has_field(L, t, "look_at") {
		target := read_vec3(L, t, "look_at", {})
		up := read_vec3(L, t, "up", {0, 1, 0})
		rot = orient_along_z(pos, target, up)
	}
	return
}

// Euler XYZ angles `(rx, ry, rz)` for `o3d.compose` from orthonormal basis
// columns `(col0, col1, col2)`.
@(private)
basis_to_euler_xyz :: proc(col0, col1, col2: o3d.Vec3) -> o3d.Vec3 {
	ry := math.asin(clamp(col2.x, -1, 1))
	rx, rz: f32
	if abs(col2.x) < 0.999999 {
		rx = math.atan2(-col2.y, col2.z)
		rz = math.atan2(-col1.x, col0.x)
	} else {
		rx = math.atan2(col1.z, col1.y)
		rz = 0
	}
	return {rx, ry, rz}
}

// Midpoint, Euler XYZ rotation aligning local +Y from `from` to `to`, and
// distance between them.
@(private = "file")
orient_along_y :: proc(from, to, up: o3d.Vec3) -> (mid, euler: o3d.Vec3, dist: f32) {
	mid = (from + to) * 0.5
	d := to - from
	dist = linalg.length(d)
	if dist < 1e-6 {
		return mid, {}, 0
	}
	col1 := d / dist
	ref_up := up
	if linalg.length(ref_up) < 1e-5 {
		ref_up = {0, 1, 0}
	} else {
		ref_up = linalg.normalize(ref_up)
	}
	if abs(linalg.dot(col1, ref_up)) > 0.999 {
		ref_up = {1, 0, 0} if abs(col1.x) < 0.9 else {0, 0, 1}
	}
	col0 := linalg.normalize(linalg.cross(ref_up, col1))
	col2 := linalg.cross(col0, col1)
	euler = basis_to_euler_xyz(col0, col1, col2)
	return
}

// Euler XYZ rotation aligning local +Z from `pos` toward `target`.
@(private = "file")
orient_along_z :: proc(pos, target, up: o3d.Vec3) -> o3d.Vec3 {
	d := target - pos
	dist := linalg.length(d)
	if dist < 1e-6 {
		return {}
	}
	col2 := d / dist
	ref_up := up
	if linalg.length(ref_up) < 1e-5 {
		ref_up = {0, 1, 0}
	} else {
		ref_up = linalg.normalize(ref_up)
	}
	if abs(linalg.dot(col2, ref_up)) > 0.999 {
		ref_up = {0, 0, 1} if abs(col2.z) < 0.9 else {1, 0, 0}
	}
	col0 := linalg.normalize(linalg.cross(ref_up, col2))
	col1 := linalg.cross(col2, col0)
	return basis_to_euler_xyz(col0, col1, col2)
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

// The {x, y, z} list at stack index `at`.
@(private = "file")
read_vec3_at :: proc(L: ^lua.State, at: c.int) -> (v: o3d.Vec3) {
	for k in 0 ..< 3 {
		lua.rawgeti(L, at, lua.Integer(k + 1))
		v[k] = f32(lua.tonumber(L, -1))
		lua.pop(L, 1)
	}
	return
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

// sky{ name, sun, up, turbidity, rayleigh, mie_coefficient,
// mie_directional_g, size }: three.js's Sky (Preetham) baked at load into an
// equirectangular HDR image `size` across (1024) named `name` ("sky"), for
// a view3d's `environment` and `background`; returns the name.
@(private)
l_sky :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	fields_begin(L, 1)
	media := measure_media(L, s, "sky")
	name := strings.clone(get_str(L, 1, "name", "sky"), context.temp_allocator)
	sky := om.View3d_Sky {
		sky = {
			sun               = read_vec3(L, 1, "sun", o3d.SKY_DEFAULT.sun),
			up                = read_vec3(L, 1, "up", o3d.SKY_DEFAULT.up),
			turbidity         = get_num(L, 1, "turbidity", o3d.SKY_DEFAULT.turbidity),
			rayleigh          = get_num(L, 1, "rayleigh", o3d.SKY_DEFAULT.rayleigh),
			mie_coefficient   = get_num(L, 1, "mie_coefficient", o3d.SKY_DEFAULT.mie_coefficient),
			mie_directional_g = get_num(L, 1, "mie_directional_g", o3d.SKY_DEFAULT.mie_directional_g),
		},
		width = clamp(int(get_num(L, 1, "size", 1024)), 64, 4096),
	}
	fields_end(L, s, 1, "sky")
	if linalg.length(sky.sky.sun) == 0 || linalg.length(sky.sky.up) == 0 {
		lua.L_error(L, "sky: sun and up need a direction (not { 0, 0, 0 })")
	}
	if !om.view3d_sky(media, name, sky) {
		lua.L_error(L, "sky: %s is already a media file's name", strings.clone_to_cstring(name, context.temp_allocator))
	}
	lua.pushlstring(L, cstring(raw_data(name)), c.size_t(len(name)))
	return 1
}

// model_info(name): what a model of the media holds: its rest-pose box
// (`min`, `max`, `size`, `center`), the node and material names its
// `nodes` / `materials` take, each named node's pose and box (`parts`), its
// animations (`{ name, duration }`) and morph target names; nil when the
// media has no such model.
@(private)
l_model_info :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	media := measure_media(L, s, "model_info")
	name := string(lua.L_checkstring(L, 1))
	v := &media.view3d
	sync.shared_lock(&v.lock)
	defer sync.shared_unlock(&v.lock)
	model, found := &v.models[name]
	if !found {
		lua.pushnil(L)
		return 1
	}
	push_vec3 :: proc(L: ^lua.State, key: cstring, p: o3d.Vec3) {
		lua.createtable(L, 3, 0)
		for x, i in p {
			lua.pushnumber(L, lua.Number(x))
			lua.rawseti(L, -2, lua.Integer(i + 1))
		}
		lua.setfield(L, -2, key)
	}
	push_names :: proc(L: ^lua.State, key: cstring, names: []string) {
		lua.createtable(L, i32(len(names)), 0)
		seen := make(map[string]bool, len(names), context.temp_allocator)
		k := 0
		for n in names {
			if n == "" || seen[n] {
				continue
			}
			seen[n] = true
			k += 1
			lua.pushlstring(L, cstring(raw_data(n)), c.size_t(len(n)))
			lua.rawseti(L, -2, lua.Integer(k))
		}
		lua.setfield(L, -2, key)
	}
	lua.createtable(L, 0, 8)
	if lo, hi, ok := o3d.model_bounds(model, &v.geometries); ok {
		push_vec3(L, "min", lo)
		push_vec3(L, "max", hi)
		push_vec3(L, "size", hi - lo)
		push_vec3(L, "center", (lo + hi) / 2)
	}
	push_names(L, "nodes", model.nodes.name[:len(model.nodes)])
	// parts[name]: a node's own position, rotation (Euler XYZ, radians) and
	// scale in its parent, what `nodes = { name = {...} }` replaces, and the
	// rest-pose box of it and what is under it in the model's space
	n := len(model.nodes)
	boxes := make([][2]o3d.Vec3, n, context.temp_allocator)
	o3d.model_node_bounds(model, &v.geometries, boxes)
	lua.createtable(L, 0, i32(n))
	for i in 0 ..< n {
		name := model.nodes.name[i]
		if name == "" {
			continue
		}
		lua.pushlstring(L, cstring(raw_data(name)), c.size_t(len(name)))
		if lua.rawget(L, -2) != c.int(lua.Type.NIL) {
			lua.pop(L, 1) // a name used again: the first node's, as `nodes` takes
			continue
		}
		lua.pop(L, 1)
		lua.pushlstring(L, cstring(raw_data(name)), c.size_t(len(name)))
		lua.createtable(L, 0, 7)
		position, rotation, scale := euler_pose(model.nodes.local[i])
		push_vec3(L, "position", position)
		push_vec3(L, "rotation", rotation)
		push_vec3(L, "scale", scale)
		if lo, hi := boxes[i][0], boxes[i][1]; lo.x <= hi.x {
			push_vec3(L, "min", lo)
			push_vec3(L, "max", hi)
			push_vec3(L, "size", hi - lo)
			push_vec3(L, "center", (lo + hi) / 2)
		}
		lua.rawset(L, -3)
	}
	lua.setfield(L, -2, "parts")
	push_names(L, "materials", model.material_names[:])
	push_names(L, "morphs", model.target_names[:])
	lua.createtable(L, i32(len(model.animations)), 0)
	for a, i in model.animations {
		lua.createtable(L, 0, 2)
		lua.pushlstring(L, cstring(raw_data(a.name)), c.size_t(len(a.name)))
		lua.setfield(L, -2, "name")
		set_num(L, "duration", f32(a.duration))
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	lua.setfield(L, -2, "animations")
	return 1
}

// A transform's translation, Euler XYZ rotation (radians: three.js's
// Euler.setFromRotationMatrix, as o3d.compose builds it) and scale.
@(private = "file")
euler_pose :: proc(m: o3d.Mat4) -> (position, rotation, scale: o3d.Vec3) {
	position = {m[0, 3], m[1, 3], m[2, 3]}
	for j in 0 ..< 3 {
		scale[j] = linalg.length(o3d.Vec3{m[0, j], m[1, j], m[2, j]})
	}
	r :: proc(m: o3d.Mat4, s: o3d.Vec3, i, j: int) -> f32 {
		return m[i, j] / s[j] if s[j] != 0 else 0
	}
	rotation.y = math.asin(clamp(r(m, scale, 0, 2), -1, 1))
	if abs(r(m, scale, 0, 2)) < 0.9999999 {
		rotation.x = math.atan2(-r(m, scale, 1, 2), r(m, scale, 2, 2))
		rotation.z = math.atan2(-r(m, scale, 0, 1), r(m, scale, 0, 0))
	} else {
		rotation.x = math.atan2(r(m, scale, 2, 1), r(m, scale, 1, 1))
	}
	return
}

// view3d_project(camera, point, size): where `point` ({x, y, z}) shows in a
// view3d of `size` ({ width, height }; default the video's) seen by
// `camera` (as view3d's): `{ x, y }` from the view's top left, `depth` (0
// near .. 1 far) and `in_front` (false: behind the camera).
@(private)
l_view3d_project :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	lua.L_checktype(L, 2, i32(lua.Type.TABLE))
	cam := read_camera(L, s, 1)
	p := read_vec3_at(L, 2)
	w, h := s.video.width, s.video.height
	if lua.istable(L, 3) {
		w = int(get_num(L, 3, "width", f32(w)))
		h = int(get_num(L, 3, "height", f32(h)))
	}
	pixel, depth, in_front := o3d.camera_project(cam, w, h, p)
	lua.createtable(L, 0, 4)
	set_num(L, "x", pixel.x)
	set_num(L, "y", pixel.y)
	set_num(L, "depth", 1 - depth) // o3d's depth is reversed (1 near); scripts read 0 near .. 1 far
	lua.pushboolean(L, b32(in_front))
	lua.setfield(L, -2, "in_front")
	return 1
}
