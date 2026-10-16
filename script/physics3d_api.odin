package onimite_script

import "core:c"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "deps:o3d"
import b3 "vendor:box3d"
import lua "vendor:lua/5.4"

// physics3d{...} -> sim: 3D rigid bodies simulated with Box3D once, at load,
// and returned as plain data in view3d{}'s vocabulary (metres, +Y up, Euler
// XYZ rotations in radians). Like physics{}, wrap it in `shared` so a
// render's frame builders simulate it once:
//
//     local sim = shared("drop3d", function()
//       return physics3d {
//         duration = 4, gravity = 9.81,              -- m/s² down (or { gx, gy, gz })
//         bodies = {
//           { static = true, box = { 10, 0.2, 10 }, position = { 0, -0.1, 0 } },
//           { name = "cube", box = { 1, 1, 1 }, position = { 0, 4, 0 }, rotation = { 0.3, 0.5, 0 }, bounce = 0.4 },
//           { name = "ball", sphere = 0.5, position = { 0.2, 6, 0.1 } },
//         },
//         joints = { { "rope", b = "ball", from = { 0, 8, 0 } } },
//         kicks = { { t = 2, body = "cube", velocity = { 3, 4, 0 } } },
//       }
//     end)
//     local pos, rot = physics3d_at(sim, "cube", f.seconds)
//
// Poses are stored as positions and unit quaternions (with hemisphere
// continuity so step-to-step NLERP takes the shortest arc without gimbal
// lock) and converted to `{ x, y, z }, { rx, ry, rz }` (Euler XYZ radians)
// when sampled by `physics3d_at` (or `physics_at`) and `physics3d_instances`.

@(private)
PHYSICS3D_TRACKS :: 0x7068_3364

// Deeper than this (metres) at a body's first step is an overlap, not a touch.
@(private = "file")
OVERLAP_3D :: 0.03

// Faster than these at the end (m/s, radians/s) is still moving.
@(private = "file")
MOVING_SPEED_3D :: 0.1
@(private = "file")
MOVING_SPIN_3D :: 0.15

// Default world bounds for `physics3d_offscreen` (metres).
@(private = "file")
DEFAULT_BOUNDS_MIN :: b3.Vec3{-50, -50, -50}
@(private = "file")
DEFAULT_BOUNDS_MAX :: b3.Vec3{50, 50, 50}

@(private = "file")
physics3d_lock: sync.Mutex

@(private = "file")
Physics3d_Flag :: enum u8 {
	Asleep,
	Leaves,
	Move,
	Enabled,
	Stopped,
	Seen,
}

@(private = "file")
Physics3d_Flags :: bit_set[Physics3d_Flag; u8]

@(private = "file")
Physics3d_Body :: struct {
	id:          b3.BodyId,
	kind:        Physics_Kind,
	flags:       Physics3d_Flags,
	first_step:  i32,
	start, stop: f32,
	settled:     f32,
	left_at:     f32,
	velocity:    b3.Vec3,
	spin:        b3.Vec3,
	label:       string,
}

@(private = "file")
Physics3d_Pose :: struct {
	p: b3.Vec3,
	q: b3.Quat,
}

@(private)
Physics3d_Tracks :: struct {
	magic:          u32,
	rate:           f32,
	duration:       f32,
	bodies:         int,
	samples:        int,
	// Body-major `[i * samples + k]` contiguous poses so sampling `k` and
	// `k + 1` touches one cache line.
	poses:          []Physics3d_Pose,
	// Precomputed body indices for `physics3d_instances(sim, t)` when `bodies`
	// is omitted (all non-static bodies, or all bodies if every body is static).
	default_bodies: []i32,
	moving:         []bool,
	labels:         []string,
}

@(private = "file")
Physics3d_Contact :: struct {
	t:      f32,
	a, b:   i32,
	point:  b3.Vec3,
	normal: b3.Vec3,
	speed:  f32,
}

@(private = "file")
Physics3d_Kick :: struct {
	t:        f32,
	body:     i32,
	done:     bool,
	velocity: b3.Vec3,
	spin:     b3.Vec3,
}

@(private)
l_physics3d :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))

	fields_begin(L, 1)
	duration := get_num(L, 1, "duration", 0)
	rate := get_num(L, 1, "rate", 60)
	hit_speed := get_num(L, 1, "hit_speed", 1)
	gravity := b3.Vec3{0, -9.81, 0}
	switch field(L, 1, "gravity") {
	case c.int(lua.Type.NUMBER):
		gravity = {0, -f32(lua.tonumber(L, -1)), 0}
	case c.int(lua.Type.TABLE):
		gravity = read_vec3_at(L, -1)
	}
	lua.pop(L, 1)

	bounds := b3.AABB{lowerBound = DEFAULT_BOUNDS_MIN, upperBound = DEFAULT_BOUNDS_MAX}
	has_bounds := true
	switch field(L, 1, "bounds") {
	case c.int(lua.Type.BOOLEAN):
		has_bounds = bool(lua.toboolean(L, -1))
	case c.int(lua.Type.TABLE):
		bt := lua.absindex(L, -1)
		outer := fields_push(L, bt)
		bounds.lowerBound = read_vec3(L, bt, "min", DEFAULT_BOUNDS_MIN)
		bounds.upperBound = read_vec3(L, bt, "max", DEFAULT_BOUNDS_MAX)
		if field(L, bt, "x") == c.int(lua.Type.TABLE) {
			pair := read_pair(L, -1)
			bounds.lowerBound.x, bounds.upperBound.x = pair[0], pair[1]
		}
		lua.pop(L, 1)
		if field(L, bt, "y") == c.int(lua.Type.TABLE) {
			pair := read_pair(L, -1)
			bounds.lowerBound.y, bounds.upperBound.y = pair[0], pair[1]
		}
		lua.pop(L, 1)
		if field(L, bt, "z") == c.int(lua.Type.TABLE) {
			pair := read_pair(L, -1)
			bounds.lowerBound.z, bounds.upperBound.z = pair[0], pair[1]
		}
		lua.pop(L, 1)
		fields_pop(L, s, bt, "physics3d.bounds", outer)
	}
	lua.pop(L, 1)

	if field(L, 1, "bodies") != c.int(lua.Type.TABLE) {
		lua.L_error(L, "physics3d: give bodies = { {...}, ... }")
	}
	bodies_at := lua.gettop(L)
	field(L, 1, "joints")
	joints_at := lua.gettop(L)
	field(L, 1, "kicks")
	kicks_at := lua.gettop(L)
	fields_end(L, s, 1, "physics3d")

	if !(duration > 0) || duration > 600 {
		lua.L_error(L, "physics3d: duration must be seconds in (0, 600], got %f", f64(duration))
	}
	if !(rate >= 1) || rate > 1000 {
		lua.L_error(L, "physics3d: rate must be steps a second in [1, 1000], got %f", f64(rate))
	}

	sync.lock(&physics3d_lock)
	world_def := b3.DefaultWorldDef()
	world_def.gravity = gravity
	world_def.hitEventThreshold = hit_speed
	world_def.workerCount = 1
	world := b3.CreateWorld(world_def)
	sync.unlock(&physics3d_lock)
	meshes := make([dynamic]^b3.MeshData, context.temp_allocator)
	defer {
		sync.guard(&physics3d_lock)
		b3.DestroyWorld(world)
		for m in meshes {
			b3.DestroyMesh(m)
		}
	}
	ground := b3.CreateBody(world, b3.DefaultBodyDef())

	n := int(lua.rawlen(L, bodies_at))
	bodies := make([]Physics3d_Body, n, context.temp_allocator)
	movers := make([dynamic]i32, 0, n, context.temp_allocator)
	names := make(map[string]int, context.temp_allocator)
	layers := make(map[string]u64, context.temp_allocator)
	layers[""] = 1
	for &body, i in bodies {
		lua.rawgeti(L, bodies_at, lua.Integer(i + 1))
		if !lua.istable(L, -1) {
			lua.L_error(L, "physics3d: bodies[%d] is not a table", i32(i + 1))
		}
		body = read_body3d(L, s, world, &layers, &meshes, lua.gettop(L), i)
		if .Move in body.flags {
			append(&movers, i32(i))
		}
		if body.label[0] != '#' {
			if body.label in names {
				lua.L_error(L, "physics3d: two bodies are named %s", strings.clone_to_cstring(body.label, context.temp_allocator))
			}
			names[body.label] = i
		}
		lua.pop(L, 1)
	}
	if lua.istable(L, joints_at) {
		for j in 0 ..< int(lua.rawlen(L, joints_at)) {
			lua.rawgeti(L, joints_at, lua.Integer(j + 1))
			if !lua.istable(L, -1) {
				lua.L_error(L, "physics3d: joints[%d] is not a table", i32(j + 1))
			}
			read_joint3d(L, s, world, ground, bodies, names, lua.gettop(L), j)
			lua.pop(L, 1)
		}
	}
	kicks := make([dynamic]Physics3d_Kick, context.temp_allocator)
	if lua.istable(L, kicks_at) {
		for j in 0 ..< int(lua.rawlen(L, kicks_at)) {
			lua.rawgeti(L, kicks_at, lua.Integer(j + 1))
			t := lua.gettop(L)
			if !lua.istable(L, t) {
				lua.L_error(L, "physics3d: kicks[%d] is not a table", i32(j + 1))
			}
			fields_begin(L, t)
			field(L, t, "body")
			vel := b3.Vec3{get_num(L, t, "vx", 0), get_num(L, t, "vy", 0), get_num(L, t, "vz", 0)}
			vel = read_vec3(L, t, "velocity", vel)
			spin := read_vec3(L, t, "spin", {})
			k := Physics3d_Kick {
				t        = get_num(L, t, "t", 0),
				body     = i32(body3d_ref(L, -1, bodies, names, "kicks", j)),
				velocity = vel,
				spin     = spin,
			}
			if k.body < 0 {
				lua.L_error(L, "physics3d: kicks[%d] needs a body", i32(j + 1))
			}
			append(&kicks, k)
			fields_end(L, s, t, fmt.tprintf("physics3d.kicks[%d]", j + 1))
			lua.settop(L, t - 1)
		}
	}

	steps := int(math.ceil(duration * rate))
	samples := steps + 1
	tracks := make_tracks3d(s.shared, bodies, samples, rate, duration)
	contacts := make([dynamic]Physics3d_Contact, context.temp_allocator)
	contact_data := make([dynamic]b3.ContactData, context.temp_allocator)

	record3d :: proc(bodies: []Physics3d_Body, tr: ^Physics3d_Tracks, samples, k: int) {
		for body, i in bodies {
			at := i * samples + k
			p := b3.ToVec3(b3.Body_GetPosition(body.id))
			q := b3.Body_GetRotation(body.id)
			if k > 0 && b3.DotQuat(tr.poses[at - 1].q, q) < 0 {
				q = -q
			}
			tr.poses[at] = {p = p, q = q}
		}
	}
	record3d(bodies, tracks, samples, 0)
	dt := 1 / rate
	for k in 1 ..= steps {
		was := f32(k - 1) * dt
		t := f32(k) * dt
		for &body in bodies {
			if body.flags & {.Enabled, .Stopped} == {} && body.start <= was + 1e-6 {
				b3.Body_Enable(body.id)
				b3.Body_SetLinearVelocity(body.id, body.velocity)
				b3.Body_SetAngularVelocity(body.id, body.spin)
				if .Asleep in body.flags {
					b3.Body_SetAwake(body.id, false)
				}
				body.flags += {.Enabled}
				body.first_step = i32(k)
			}
			if .Enabled in body.flags && body.stop <= was + 1e-6 {
				b3.Body_Disable(body.id)
				body.flags = (body.flags - {.Enabled}) + {.Stopped}
			}
		}
		for &kick in kicks {
			body := &bodies[kick.body]
			if !kick.done && kick.t <= was + 1e-6 && .Enabled in body.flags {
				kick.done = true
				b3.Body_SetLinearVelocity(body.id, b3.Body_GetLinearVelocity(body.id) + kick.velocity)
				b3.Body_SetAngularVelocity(body.id, b3.Body_GetAngularVelocity(body.id) + kick.spin)
				b3.Body_SetAwake(body.id, true)
			}
		}
		for mi in movers {
			body := &bodies[mi]
			if .Enabled in body.flags {
				p, q := call_move3d(L, bodies_at, int(mi), t)
				b3.Body_SetTargetTransform(body.id, {p = b3.ToPos(p), q = q}, dt, true)
			}
		}

		b3.World_Step(world, dt, PHYSICS_SUBSTEPS)

		events := b3.World_GetContactEvents(world)
		for e in events.hitEvents[:events.hitCount] {
			append(&contacts, Physics3d_Contact {
				t      = t,
				a      = i32(uintptr(b3.Shape_GetUserData(e.shapeIdA))),
				b      = i32(uintptr(b3.Shape_GetUserData(e.shapeIdB))),
				point  = b3.ToVec3(e.point),
				normal = e.normal,
				speed  = e.approachSpeed,
			})
		}
		record3d(bodies, tracks, samples, k)
		for &body, i in bodies {
			if body.kind != .Dynamic || .Enabled not_in body.flags {
				continue
			}
			if b3.Body_IsAwake(body.id) {
				body.settled = -1
			} else if body.settled < 0 {
				body.settled = t
			}
			if int(body.first_step) == k {
				check_overlap3d(L, s, bodies, i, &contact_data)
			}
			if has_bounds && .Leaves not_in body.flags {
				box := b3.Body_ComputeAABB(body.id)
				if b3.AABB_Overlaps(bounds, box) {
					body.flags += {.Seen}
					body.left_at = -1
				} else if .Seen in body.flags && body.left_at < 0 {
					body.left_at = t
				}
			}
		}
	}
	for body in bodies {
		if .Seen in body.flags && body.left_at >= 0 {
			report_warning(L, s, {code = .Physics3d_Offscreen, a = body.label, x = body.left_at})
		}
	}

	lua.createtable(L, 0, 5)
	set_num(L, "duration", duration)
	set_num(L, "rate", rate)
	lua.createtable(L, 0, c.int(len(names)))
	for name, i in names {
		lua.pushinteger(L, lua.Integer(i + 1))
		lua.setfield(L, -2, strings.clone_to_cstring(name, context.temp_allocator))
	}
	lua.setfield(L, -2, "names")
	lua.createtable(L, c.int(n), 0)
	for body, i in bodies {
		lua.createtable(L, 0, 6)
		if body.label[0] != '#' {
			lua.pushstring(L, strings.clone_to_cstring(body.label, context.temp_allocator))
			lua.setfield(L, -2, "name")
		}
		if body.kind == .Static {
			set_num(L, "settled", 0)
		} else if body.settled >= 0 {
			set_num(L, "settled", body.settled)
		}
		if body.kind == .Dynamic && .Enabled in body.flags {
			v := b3.Body_GetLinearVelocity(body.id)
			w := b3.Body_GetAngularVelocity(body.id)
			if linalg.length(v) > MOVING_SPEED_3D || linalg.length(w) > MOVING_SPIN_3D {
				tracks.moving[i] = true
				lua.pushboolean(L, true)
				lua.setfield(L, -2, "moving")
			}
		}
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	lua.setfield(L, -2, "bodies")
	lua.createtable(L, c.int(len(contacts)), 0)
	for ct, i in contacts {
		lua.createtable(L, 0, 8)
		set_num(L, "t", ct.t)
		set_int(L, "a", int(ct.a))
		set_int(L, "b", int(ct.b))
		set_num(L, "x", ct.point.x)
		set_num(L, "y", ct.point.y)
		set_num(L, "z", ct.point.z)
		push_vec3(L, ct.point)
		lua.setfield(L, -2, "position")
		push_vec3(L, ct.normal)
		lua.setfield(L, -2, "normal")
		set_num(L, "speed", ct.speed)
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	lua.setfield(L, -2, "contacts")
	lua.pushlightuserdata(L, tracks)
	lua.setfield(L, -2, "tracks")
	append(&s.physics, Physics_Sim{tracks, strings.clone(caller_where(L))})
	return 1
}

@(private)
physics3d_bodies_append :: proc(out: ^[dynamic]Physics_Body_Info, sim: Physics_Sim, k: int) {
	tr := (^Physics3d_Tracks)(sim.tracks)
	if tr.samples == 0 {
		return
	}
	for i in 0 ..< tr.bodies {
		first := tr.poses[i * tr.samples]
		last := tr.poses[i * tr.samples + tr.samples - 1]
		append(out, Physics_Body_Info {
			label    = tr.labels[i],
			sim      = k,
			at       = sim.at,
			duration = tr.duration,
			rate     = tr.rate,
			start    = first.p,
			stop     = last.p,
			moving   = tr.moving[i],
			is_3d    = true,
		})
	}
}

@(private = "file")
make_tracks3d :: proc(sh: ^Shared, bodies: []Physics3d_Body, samples: int, rate, duration: f32) -> ^Physics3d_Tracks {
	sync.guard(&sh.lock)
	alloc := virtual.arena_allocator(&sh.arena)
	n := len(bodies)
	non_static := 0
	for b in bodies {
		if b.kind != .Static {
			non_static += 1
		}
	}
	def_count := n if non_static == 0 else non_static
	tr := new(Physics3d_Tracks, alloc)
	tr^ = {
		magic          = PHYSICS3D_TRACKS,
		rate           = rate,
		duration       = duration,
		bodies         = n,
		samples        = samples,
		poses          = make([]Physics3d_Pose, n * samples, alloc),
		default_bodies = make([]i32, def_count, alloc),
		moving         = make([]bool, n, alloc),
		labels         = make([]string, n, alloc),
	}
	di := 0
	for b, i in bodies {
		tr.labels[i] = strings.clone(b.label, alloc)
		if non_static == 0 || b.kind != .Static {
			tr.default_bodies[di] = i32(i)
			di += 1
		}
	}
	return tr
}

// Samples body `i` of `tr` at `t` seconds -> position `{x, y, z}`, Euler XYZ
// rotation `{rx, ry, rz}` (radians).
@(private = "file")
sample_track3d :: proc(L: ^lua.State, s: ^Script, tr: ^Physics3d_Tracks, i: int, t: f32) -> (pos, rot: b3.Vec3) {
	row := i * tr.samples
	last := tr.samples - 1
	u := max(t * tr.rate, 0)
	k := int(u)
	q: b3.Quat
	if k >= last {
		if tr.moving[i] && u > f32(last) + 1e-3 {
			report_warning(L, s, {code = .Physics_Unsettled, a = tr.labels[i], x = tr.duration})
		}
		pose := tr.poses[row + last]
		pos, q = pose.p, pose.q
	} else {
		w := u - f32(k)
		s0 := tr.poses[row + k]
		s1 := tr.poses[row + k + 1]
		pos = linalg.lerp(s0.p, s1.p, w)
		q = b3.NLerp(s0.q, s1.q, w)
	}
	rot = quat_to_euler_xyz(q)
	return
}

// physics3d_at(sim, body, t) -> position, rotation (`{x, y, z}, {rx, ry, rz}`):
// body (an index or a name) of a physics3d{} result at t seconds on its clock.
@(private)
l_physics3d_at :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	lua.getfield(L, 1, "tracks")
	tr := (^Physics3d_Tracks)(lua.touserdata(L, -1))
	if tr == nil || tr.magic != PHYSICS3D_TRACKS {
		lua.L_error(L, "physics3d_at: give the table physics3d{} returned")
	}
	i := resolve_track3d_body(L, tr, 1, 2, "physics3d_at")
	t := f32(lua.L_checknumber(L, 3))
	pos, rot := sample_track3d(L, s, tr, i, t)
	push_vec3(L, pos)
	push_vec3(L, rot)
	return 2
}

// physics3d_instances(sim, t [, bodies]) -> { { position = {x, y, z}, rotation = {rx, ry, rz} }, ... }:
// poses of `bodies` (a list of names/indices; omitted: all non-static bodies,
// or all bodies if every body is static) ready for a view3d mesh's `instances`.
@(private)
l_physics3d_instances :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	lua.getfield(L, 1, "tracks")
	tr := (^Physics3d_Tracks)(lua.touserdata(L, -1))
	if tr == nil || tr.magic != PHYSICS3D_TRACKS {
		lua.L_error(L, "physics3d_instances: give the table physics3d{} returned")
	}
	lua.pop(L, 1)
	t := f32(lua.L_checknumber(L, 2))
	if lua.istable(L, 3) {
		count := int(lua.rawlen(L, 3))
		lua.createtable(L, c.int(count), 0)
		out := lua.gettop(L)
		for k in 1 ..= count {
			lua.rawgeti(L, 3, lua.Integer(k))
			i := resolve_track3d_body(L, tr, 1, lua.gettop(L), "physics3d_instances")
			lua.pop(L, 1)
			pos, rot := sample_track3d(L, s, tr, i, t)
			push_instance_pose(L, pos, rot)
			lua.rawseti(L, out, lua.Integer(k))
		}
		return 1
	}
	lua.createtable(L, c.int(len(tr.default_bodies)), 0)
	out := lua.gettop(L)
	for bi, k in tr.default_bodies {
		pos, rot := sample_track3d(L, s, tr, int(bi), t)
		push_instance_pose(L, pos, rot)
		lua.rawseti(L, out, lua.Integer(k + 1))
	}
	return 1
}

@(private = "file")
resolve_track3d_body :: proc(L: ^lua.State, tr: ^Physics3d_Tracks, sim_idx, body_idx: c.int, fn: cstring) -> int {
	i := -1
	if lua.type(L, body_idx) == .STRING {
		lua.getfield(L, sim_idx, "names")
		if lua.istable(L, -1) {
			lua.pushvalue(L, body_idx)
			lua.rawget(L, -2)
			i = int(lua.tointeger(L, -1)) - 1
			lua.pop(L, 1)
		}
		lua.pop(L, 1)
	} else if lua.isinteger(L, body_idx) {
		i = int(lua.tointeger(L, body_idx)) - 1
	}
	if i < 0 || i >= tr.bodies {
		lua.L_error(L, "%s: no body %s", fn, lua.L_tostring(L, body_idx))
	}
	return i
}

@(private = "file")
push_instance_pose :: proc(L: ^lua.State, pos, rot: b3.Vec3) {
	lua.createtable(L, 0, 2)
	push_vec3(L, pos)
	lua.setfield(L, -2, "position")
	push_vec3(L, rot)
	lua.setfield(L, -2, "rotation")
}

@(private = "file")
read_body3d :: proc(L: ^lua.State, s: ^Script, world: b3.WorldId, layers: ^map[string]u64, meshes: ^[dynamic]^b3.MeshData, t: c.int, i: int) -> (body: Physics3d_Body) {
	fields_begin(L, t)
	body.label = fmt.tprintf("#%d", i + 1)
	if name := get_str(L, t, "name", ""); name != "" {
		body.label = strings.clone(name, context.temp_allocator)
	}
	switch {
	case get_flag(L, t, "static"):
		body.kind = .Static
	case get_flag(L, t, "kinematic"):
		body.kind = .Kinematic
	}
	body.start = get_num(L, t, "start", 0)
	body.stop = get_num(L, t, "stop", max(f32))
	if get_flag(L, t, "asleep") {
		body.flags += {.Asleep}
	}
	if get_flag(L, t, "leaves") {
		body.flags += {.Leaves}
	}
	body.settled = -1

	def := b3.DefaultBodyDef()
	types := [Physics_Kind]b3.BodyType{.Dynamic = .dynamicBody, .Static = .staticBody, .Kinematic = .kinematicBody}
	def.type = types[body.kind]

	position := b3.Vec3{get_num(L, t, "x", 0), get_num(L, t, "y", 0), get_num(L, t, "z", 0)}
	position = read_vec3(L, t, "position", position)
	rotation_euler := read_vec3(L, t, "rotation", {})
	rotation := euler_xyz_to_quat(rotation_euler)

	if field(L, t, "move") == c.int(lua.Type.FUNCTION) {
		if body.kind != .Kinematic {
			lua.L_error(L, "physics3d: bodies[%d].move needs kinematic = true", i32(i + 1))
		}
		body.flags += {.Move}
		def.enableSleep = false
		lua.pop(L, 1)
		position, rotation = call_move3d(L, t, -1, 0)
	} else {
		lua.pop(L, 1)
	}

	vel := b3.Vec3{get_num(L, t, "vx", 0), get_num(L, t, "vy", 0), get_num(L, t, "vz", 0)}
	body.velocity = read_vec3(L, t, "velocity", vel)
	body.spin = read_vec3(L, t, "spin", {})

	def.position = b3.ToPos(position)
	def.rotation = rotation
	def.linearVelocity = body.velocity
	def.angularVelocity = body.spin
	def.gravityScale = get_num(L, t, "gravity_scale", 1)
	def.linearDamping = get_num(L, t, "damping", 0)
	def.angularDamping = get_num(L, t, "spin_damping", 0)
	def.isBullet = get_flag(L, t, "bullet")
	def.isAwake = .Asleep not_in body.flags
	def.isEnabled = body.start <= 0
	def.motionLocks = read_motion_locks(L, t)
	if def.isEnabled {
		body.flags += {.Enabled}
		body.first_step = 1
	}
	body.id = b3.CreateBody(world, def)

	shape := b3.DefaultShapeDef()
	shape.userData = rawptr(uintptr(i + 1))
	shape.enableHitEvents = true
	shape.density = get_num(L, t, "density", 1)
	shape.baseMaterial.friction = get_num(L, t, "friction", 0.6)
	shape.baseMaterial.restitution = get_num(L, t, "bounce", 0)
	shape.baseMaterial.rollingResistance = get_num(L, t, "rolling_resistance", 0)
	shape.filter.categoryBits = layer_bit(L, layers, get_str(L, t, "layer", ""))
	shape.filter.maskBits = max(u64)
	if field(L, t, "ignores") == c.int(lua.Type.TABLE) {
		for k in 1 ..= lua.rawlen(L, -1) {
			lua.rawgeti(L, -1, lua.Integer(k))
			shape.filter.maskBits &~= layer_bit(L, layers, string(lua.tostring(L, -1)) if lua.type(L, -1) == .STRING else "")
			lua.pop(L, 1)
		}
	}
	lua.pop(L, 1)
	scale := read_vec3(L, t, "scale", {1, 1, 1}, splat = true)

	has_shape := attach_shape3d(L, s, body.id, body.kind, shape, scale, meshes, t, i)
	if field(L, t, "shapes") == c.int(lua.Type.TABLE) {
		st := lua.absindex(L, -1)
		scount := int(lua.rawlen(L, st))
		for k in 1 ..= scount {
			lua.rawgeti(L, st, lua.Integer(k))
			if !lua.istable(L, -1) {
				lua.L_error(L, "physics3d: bodies[%d].shapes[%d] is not a table", i32(i + 1), i32(k))
			}
			ct := lua.absindex(L, -1)
			outer := fields_push(L, ct)
			cscale := read_vec3(L, ct, "scale", scale, splat = true)
			cpos := read_vec3(L, ct, "position", {})
			crot := euler_xyz_to_quat(read_vec3(L, ct, "rotation", {}))
			if !attach_shape3d(L, s, body.id, body.kind, shape, cscale, meshes, ct, i, b3.Transform{p = cpos, q = crot}) {
				lua.L_error(L, "physics3d: bodies[%d].shapes[%d] needs a shape", i32(i + 1), i32(k))
			}
			fields_pop(L, s, ct, fmt.tprintf("physics3d.bodies[%d].shapes[%d]", i + 1, k), outer)
			lua.pop(L, 1)
			has_shape = true
		}
	}
	lua.pop(L, 1)

	if !has_shape && body.kind == .Dynamic {
		lua.L_error(L, "physics3d: bodies[%d] needs a shape: box, sphere, capsule, cylinder, cone, hull or mesh", i32(i + 1))
	}
	lua.settop(L, t)
	fields_end(L, s, t, fmt.tprintf("physics3d.bodies[%d]", i + 1))
	return
}

@(private = "file")
attach_shape3d :: proc(L: ^lua.State, s: ^Script, body_id: b3.BodyId, kind: Physics_Kind, shape: b3.ShapeDef, scale: b3.Vec3, meshes: ^[dynamic]^b3.MeshData, t: c.int, i: int, local_xf := b3.Transform_identity) -> bool {
	top := lua.gettop(L)
	defer lua.settop(L, top)
	has_local := local_xf.p != {} || local_xf.q != b3.Quat_identity

	switch field(L, t, "box") {
	case c.int(lua.Type.NUMBER):
		half := f32(lua.tonumber(L, -1)) * 0.5
		if !(half > 0) {
			lua.L_error(L, "physics3d: bodies[%d].box needs a positive size", i32(i + 1))
		}
		h := half * scale
		box := b3.MakeTransformedBoxHull(h.x, h.y, h.z, local_xf) if has_local else b3.MakeBoxHull(h.x, h.y, h.z)
		_ = b3.CreateHullShape(body_id, shape, &box.base)
		return true
	case c.int(lua.Type.TABLE):
		size := read_vec3_at(L, -1) * scale * 0.5
		if !(size.x > 0 && size.y > 0 && size.z > 0) {
			lua.L_error(L, "physics3d: bodies[%d].box needs a positive { w, h, d }", i32(i + 1))
		}
		box := b3.MakeTransformedBoxHull(size.x, size.y, size.z, local_xf) if has_local else b3.MakeBoxHull(size.x, size.y, size.z)
		_ = b3.CreateHullShape(body_id, shape, &box.base)
		return true
	}
	lua.settop(L, top)

	if field(L, t, "sphere") == c.int(lua.Type.NUMBER) {
		r := f32(lua.tonumber(L, -1)) * max(scale.x, scale.y, scale.z)
		if !(r > 0) {
			lua.L_error(L, "physics3d: bodies[%d].sphere needs a positive radius", i32(i + 1))
		}
		sp := b3.Sphere{center = local_xf.p, radius = r}
		_ = b3.CreateSphereShape(body_id, shape, &sp)
		return true
	}
	lua.settop(L, top)

	if field(L, t, "capsule") == c.int(lua.Type.TABLE) {
		ct := lua.absindex(L, -1)
		outer := fields_push(L, ct)
		r := get_num(L, ct, "radius", 0)
		h := get_num(L, ct, "height", 0)
		if r == 0 && h == 0 && lua.rawlen(L, ct) >= 2 {
			pair := read_pair(L, ct)
			r, h = pair[0], pair[1]
		}
		c1 := b3.Vec3{0, -h * 0.5, 0}
		c2 := b3.Vec3{0, h * 0.5, 0}
		if has_field(L, ct, "from") || has_field(L, ct, "to") {
			c1 = read_vec3(L, ct, "from", c1)
			c2 = read_vec3(L, ct, "to", c2)
		}
		fields_pop(L, s, ct, fmt.tprintf("physics3d.bodies[%d].capsule", i + 1), outer)
		r *= max(scale.x, scale.z)
		if !(r > 0) {
			lua.L_error(L, "physics3d: bodies[%d].capsule needs a positive radius", i32(i + 1))
		}
		cap := b3.Capsule {
			center1 = b3.TransformPoint(local_xf, c1 * scale),
			center2 = b3.TransformPoint(local_xf, c2 * scale),
			radius  = r,
		}
		_ = b3.CreateCapsuleShape(body_id, shape, &cap)
		return true
	}
	lua.settop(L, top)

	if field(L, t, "cylinder") == c.int(lua.Type.TABLE) {
		ct := lua.absindex(L, -1)
		outer := fields_push(L, ct)
		r := get_num(L, ct, "radius", 0)
		h := get_num(L, ct, "height", 0)
		sides := c.int(clamp(int(get_num(L, ct, "segments", 16)), 6, 32))
		if r == 0 && h == 0 && lua.rawlen(L, ct) >= 2 {
			pair := read_pair(L, ct)
			r, h = pair[0], pair[1]
		}
		fields_pop(L, s, ct, fmt.tprintf("physics3d.bodies[%d].cylinder", i + 1), outer)
		if !(r > 0 && h > 0) {
			lua.L_error(L, "physics3d: bodies[%d].cylinder needs positive { radius, height }", i32(i + 1))
		}
		hull := b3.CreateCylinder(h, r, 0, sides)
		if hull == nil {
			lua.L_error(L, "physics3d: bodies[%d].cylinder could not build hull", i32(i + 1))
		}
		defer b3.DestroyHull(hull)
		_ = b3.CreateTransformedHullShape(body_id, shape, hull, local_xf, scale)
		return true
	}
	lua.settop(L, top)

	if field(L, t, "cone") == c.int(lua.Type.TABLE) {
		ct := lua.absindex(L, -1)
		outer := fields_push(L, ct)
		r1 := get_num(L, ct, "radius", get_num(L, ct, "radius_bottom", 0))
		r2 := get_num(L, ct, "radius_top", 0)
		h := get_num(L, ct, "height", 0)
		slices := c.int(clamp(int(get_num(L, ct, "segments", 16)), 6, 32))
		if r1 == 0 && h == 0 && lua.rawlen(L, ct) >= 2 {
			pair := read_pair(L, ct)
			r1, h = pair[0], pair[1]
		}
		fields_pop(L, s, ct, fmt.tprintf("physics3d.bodies[%d].cone", i + 1), outer)
		if !(r1 > 0 && r2 >= 0 && h > 0) {
			lua.L_error(L, "physics3d: bodies[%d].cone needs positive { radius, height }", i32(i + 1))
		}
		var_hull: ^b3.HullData
		if r2 > 0 {
			var_hull = b3.CreateCone(h, r1, r2, slices)
		} else {
			pts := make([dynamic]b3.Vec3, 0, int(slices) + 1, context.temp_allocator)
			append(&pts, b3.Vec3{0, h * 0.5, 0})
			for k in 0 ..< int(slices) {
				ang := 2 * math.PI * f32(k) / f32(slices)
				append(&pts, b3.Vec3{r1 * math.cos(ang), -h * 0.5, r1 * math.sin(ang)})
			}
			var_hull = build_hull3d(L, pts[:], i)
		}
		if var_hull == nil {
			lua.L_error(L, "physics3d: bodies[%d].cone could not build hull", i32(i + 1))
		}
		defer b3.DestroyHull(var_hull)
		_ = b3.CreateTransformedHullShape(body_id, shape, var_hull, local_xf, scale)
		return true
	}
	lua.settop(L, top)

	switch field(L, t, "hull") {
	case c.int(lua.Type.STRING):
		name := string(lua.tostring(L, -1))
		pts, _ := model_geometry(L, s, name, scale, i, "hull", false)
		hull := build_hull3d(L, pts, i)
		defer b3.DestroyHull(hull)
		_ = b3.CreateTransformedHullShape(body_id, shape, hull, local_xf, {1, 1, 1})
		return true
	case c.int(lua.Type.TABLE):
		pts := read_vec3_list(L, -1, scale)
		hull := build_hull3d(L, pts, i)
		defer b3.DestroyHull(hull)
		_ = b3.CreateTransformedHullShape(body_id, shape, hull, local_xf, {1, 1, 1})
		return true
	}
	lua.settop(L, top)

	switch field(L, t, "mesh") {
	case c.int(lua.Type.STRING):
		if kind != .Static {
			lua.L_error(L, "physics3d: bodies[%d].mesh requires static = true (use hull for dynamic bodies)", i32(i + 1))
		}
		name := string(lua.tostring(L, -1))
		verts, indices := model_geometry(L, s, name, {1, 1, 1}, i, "mesh", true)
		mdata := build_mesh3d(L, verts, indices, i)
		append(meshes, mdata)
		_ = b3.CreateMeshShape(body_id, shape, mdata, scale)
		return true
	case c.int(lua.Type.TABLE):
		if kind != .Static {
			lua.L_error(L, "physics3d: bodies[%d].mesh requires static = true (use hull for dynamic bodies)", i32(i + 1))
		}
		mt := lua.absindex(L, -1)
		outer := fields_push(L, mt)
		field(L, mt, "vertices")
		verts := read_vec3_list(L, -1, {1, 1, 1})
		lua.pop(L, 1)
		field(L, mt, "indices")
		indices := read_i32_list(L, -1)
		lua.pop(L, 1)
		fields_pop(L, s, mt, fmt.tprintf("physics3d.bodies[%d].mesh", i + 1), outer)
		mdata := build_mesh3d(L, verts, indices, i)
		append(meshes, mdata)
		_ = b3.CreateMeshShape(body_id, shape, mdata, scale)
		return true
	}
	lua.settop(L, top)
	return false
}

@(private = "file")
build_hull3d :: proc(L: ^lua.State, pts: []b3.Vec3, i: int) -> ^b3.HullData {
	if len(pts) < 4 {
		lua.L_error(L, "physics3d: bodies[%d].hull needs at least 4 points", i32(i + 1))
	}
	// Box3D keeps a hull to 256 half-edges, and V vertices make up to 6V - 12
	// of them: 44 is the most that always fits.
	for max_v in ([?]c.int{44, 32, 16}) {
		if hull := b3.CreateHull(raw_data(pts), c.int(len(pts)), max_v); hull != nil {
			return hull
		}
	}
	lua.L_error(L, "physics3d: bodies[%d].hull has no volume (points coplanar or too close)", i32(i + 1))
	return nil
}

@(private = "file")
build_mesh3d :: proc(L: ^lua.State, verts: []b3.Vec3, indices: []i32, i: int) -> ^b3.MeshData {
	if len(verts) < 3 || len(indices) < 3 {
		lua.L_error(L, "physics3d: bodies[%d].mesh needs vertices and triangle indices", i32(i + 1))
	}
	def := b3.MeshDef {
		vertices      = raw_data(verts),
		vertexCount   = c.int(len(verts)),
		indices       = raw_data(indices),
		triangleCount = c.int(len(indices) / 3),
		weldVertices  = true,
		weldTolerance = 1e-4,
		identifyEdges = true,
	}
	mdata := b3.CreateMesh(def, nil, 0)
	if mdata == nil {
		lua.L_error(L, "physics3d: bodies[%d].mesh could not build collision mesh", i32(i + 1))
	}
	return mdata
}

// Extracts the rest-pose vertices (scaled by `scale`) and optional 0-based
// triangle indices of media model `name` into pre-sized temp slices.
@(private = "file")
model_geometry :: proc(L: ^lua.State, s: ^Script, name: string, scale: b3.Vec3, i: int, kind: cstring, need_indices: bool) -> (verts: []b3.Vec3, indices: []i32) {
	if s.media == nil {
		lua.L_error(L, "physics3d: bodies[%d].%s %s needs the media", i32(i + 1), kind, strings.clone_to_cstring(name, context.temp_allocator))
	}
	v := &s.media.view3d
	sync.shared_lock(&v.lock)
	defer sync.shared_unlock(&v.lock)
	model, found := &v.models[name]
	if !found {
		lua.L_error(L, "physics3d: bodies[%d].%s: no model %s in the media", i32(i + 1), kind, strings.clone_to_cstring(name, context.temp_allocator))
	}
	nn := len(model.nodes)
	worlds := make([]o3d.Mat4, nn, context.temp_allocator)
	total_v, total_i := 0, 0
	for ni in 0 ..< nn {
		parent := model.nodes[ni].parent
		local := model.nodes[ni].local
		worlds[ni] = (worlds[parent] * local) if parent >= 0 else local
		mi := model.nodes[ni].mesh
		if mi < 0 || int(mi) >= len(model.meshes) {
			continue
		}
		mm := model.meshes[mi]
		for prim in model.primitives[mm.first_primitive:][:mm.primitive_count] {
			if prim.geometry == 0 || int(prim.geometry) > len(v.geometries.list) {
				continue
			}
			geo := v.geometries.list[prim.geometry - 1]
			if geo.mode != .Triangles {
				continue
			}
			total_v += int(geo.vertex_count)
			if need_indices {
				total_i += int(geo.index_count)
			}
		}
	}
	verts = make([]b3.Vec3, total_v, context.temp_allocator)
	if need_indices {
		indices = make([]i32, total_i, context.temp_allocator)
	}
	vi, ii := 0, 0
	for ni in 0 ..< nn {
		mi := model.nodes[ni].mesh
		if mi < 0 || int(mi) >= len(model.meshes) {
			continue
		}
		w := worlds[ni]
		mm := model.meshes[mi]
		for prim in model.primitives[mm.first_primitive:][:mm.primitive_count] {
			if prim.geometry == 0 || int(prim.geometry) > len(v.geometries.list) {
				continue
			}
			geo := v.geometries.list[prim.geometry - 1]
			if geo.mode != .Triangles {
				continue
			}
			base := i32(vi)
			for vert in v.geometries.vertices[geo.first_vertex:][:geo.vertex_count] {
				p := (w * o3d.Vec4{vert.position.x, vert.position.y, vert.position.z, 1}).xyz
				verts[vi] = p * scale
				vi += 1
			}
			if need_indices {
				for idx in v.geometries.indices[geo.first_index:][:geo.index_count] {
					indices[ii] = base + i32(idx)
					ii += 1
				}
			}
		}
	}
	return verts, indices
}

// One `joints` entry: { kind, a = body, b = body, ... }, anchors and axes in
// world units; a missing `a` or `b` is the world.
@(private = "file")
read_joint3d :: proc(L: ^lua.State, s: ^Script, world: b3.WorldId, ground: b3.BodyId, bodies: []Physics3d_Body, names: map[string]int, t: c.int, j: int) {
	fields_begin(L, t)
	lua.rawgeti(L, t, 1)
	kind := string(lua.tostring(L, -1)) if lua.type(L, -1) == .STRING else ""
	lua.pop(L, 1)
	ids: [2]b3.BodyId
	for key, k in ([2]cstring{"a", "b"}) {
		field(L, t, key)
		r := body3d_ref(L, -1, bodies, names, "joints", j)
		lua.pop(L, 1)
		ids[k] = ground if r < 0 else bodies[r].id
	}
	if ids[0] == ids[1] {
		lua.L_error(L, "physics3d: joints[%d] needs two different bodies (a, b; a missing one is the world)", i32(j + 1))
	}
	anchor :: proc(L: ^lua.State, t: c.int, key: cstring, id: b3.BodyId) -> b3.Vec3 {
		if field(L, t, key) == c.int(lua.Type.TABLE) {
			p := read_vec3_at(L, -1)
			lua.pop(L, 1)
			return p
		}
		lua.pop(L, 1)
		return b3.ToVec3(b3.Body_GetPosition(id))
	}
	frame_at :: proc(id: b3.BodyId, world_pt: b3.Vec3, world_axis, local_ref: b3.Vec3) -> b3.Transform {
		axis := b3.Normalize(world_axis)
		if axis == {} {
			axis = local_ref
		}
		wq := b3.ComputeQuatBetweenUnitVectors(local_ref, axis)
		bq := b3.Body_GetRotation(id)
		return {
			p = b3.Body_GetLocalPoint(id, b3.ToPos(world_pt)),
			q = b3.InvMulQuat(bq, wq),
		}
	}
	collide := get_flag(L, t, "collide")
	switch kind {
	case "hinge":
		at := anchor(L, t, "at", ids[1])
		axis := read_vec3(L, t, "axis", {0, 0, 1})
		def := b3.DefaultRevoluteJointDef()
		def.bodyIdA, def.bodyIdB = ids[0], ids[1]
		def.localFrameA = frame_at(ids[0], at, axis, {0, 0, 1})
		def.localFrameB = frame_at(ids[1], at, axis, {0, 0, 1})
		def.collideConnected = collide
		if field(L, t, "limit") == c.int(lua.Type.TABLE) {
			lim := read_pair(L, -1)
			def.enableLimit, def.lowerAngle, def.upperAngle = true, lim[0], lim[1]
		}
		lua.pop(L, 1)
		if hertz, ok := get_opt_num(L, t, "hertz"); ok {
			def.enableSpring, def.hertz = true, hertz
			def.dampingRatio = get_num(L, t, "damping", 0.5)
		}
		if speed, ok := get_opt_num(L, t, "motor"); ok {
			def.enableMotor, def.motorSpeed = true, speed
			def.maxMotorTorque = get_num(L, t, "torque", 1000)
		}
		_ = b3.CreateRevoluteJoint(world, def)
	case "ball", "spherical":
		at := anchor(L, t, "at", ids[1])
		axis := read_vec3(L, t, "axis", {0, 0, 1})
		def := b3.DefaultSphericalJointDef()
		def.bodyIdA, def.bodyIdB = ids[0], ids[1]
		def.localFrameA = frame_at(ids[0], at, axis, {0, 0, 1})
		def.localFrameB = frame_at(ids[1], at, axis, {0, 0, 1})
		def.collideConnected = collide
		if cone, ok := get_opt_num(L, t, "cone"); ok {
			def.enableConeLimit, def.coneAngle = true, cone
		}
		if field(L, t, "twist") == c.int(lua.Type.TABLE) {
			lim := read_pair(L, -1)
			def.enableTwistLimit, def.lowerTwistAngle, def.upperTwistAngle = true, lim[0], lim[1]
		}
		lua.pop(L, 1)
		if hertz, ok := get_opt_num(L, t, "hertz"); ok {
			def.enableSpring, def.hertz = true, hertz
			def.dampingRatio = get_num(L, t, "damping", 0.5)
		}
		if field(L, t, "motor") == c.int(lua.Type.TABLE) {
			def.enableMotor = true
			def.motorVelocity = read_vec3_at(L, -1)
			def.maxMotorTorque = get_num(L, t, "torque", 1000)
		}
		lua.pop(L, 1)
		_ = b3.CreateSphericalJoint(world, def)
	case "slider", "prismatic":
		at := anchor(L, t, "at", ids[1])
		axis := read_vec3(L, t, "axis", {1, 0, 0})
		def := b3.DefaultPrismaticJointDef()
		def.bodyIdA, def.bodyIdB = ids[0], ids[1]
		def.localFrameA = frame_at(ids[0], at, axis, {1, 0, 0})
		def.localFrameB = frame_at(ids[1], at, axis, {1, 0, 0})
		def.collideConnected = collide
		if field(L, t, "limit") == c.int(lua.Type.TABLE) {
			lim := read_pair(L, -1)
			def.enableLimit, def.lowerTranslation, def.upperTranslation = true, lim[0], lim[1]
		}
		lua.pop(L, 1)
		if hertz, ok := get_opt_num(L, t, "hertz"); ok {
			def.enableSpring, def.hertz = true, hertz
			def.dampingRatio = get_num(L, t, "damping", 0.5)
		}
		if speed, ok := get_opt_num(L, t, "motor"); ok {
			def.enableMotor, def.motorSpeed = true, speed
			def.maxMotorForce = get_num(L, t, "force", 1000)
		}
		_ = b3.CreatePrismaticJoint(world, def)
	case "weld":
		at := anchor(L, t, "at", ids[1])
		def := b3.DefaultWeldJointDef()
		def.bodyIdA, def.bodyIdB = ids[0], ids[1]
		def.localFrameA = frame_at(ids[0], at, {0, 0, 1}, {0, 0, 1})
		def.localFrameB = frame_at(ids[1], at, {0, 0, 1}, {0, 0, 1})
		def.linearHertz = get_num(L, t, "hertz", 0)
		def.linearDampingRatio = get_num(L, t, "damping", 1)
		def.angularHertz = get_num(L, t, "angular_hertz", def.linearHertz)
		def.angularDampingRatio = get_num(L, t, "angular_damping", def.linearDampingRatio)
		def.collideConnected = collide
		_ = b3.CreateWeldJoint(world, def)
	case "rod", "rope", "spring":
		from := anchor(L, t, "from", ids[0])
		to := anchor(L, t, "to", ids[1])
		def := b3.DefaultDistanceJointDef()
		def.bodyIdA, def.bodyIdB = ids[0], ids[1]
		def.localFrameA = {p = b3.Body_GetLocalPoint(ids[0], b3.ToPos(from)), q = b3.Quat_identity}
		def.localFrameB = {p = b3.Body_GetLocalPoint(ids[1], b3.ToPos(to)), q = b3.Quat_identity}
		def.length = get_num(L, t, "length", linalg.length(to - from))
		def.collideConnected = collide
		switch kind {
		case "rope":
			def.enableSpring, def.hertz = true, 0
			def.enableLimit, def.minLength, def.maxLength = true, 0, def.length
		case "spring":
			def.enableSpring = true
			def.hertz = get_num(L, t, "hertz", 4)
			def.dampingRatio = get_num(L, t, "damping", 0.5)
		}
		_ = b3.CreateDistanceJoint(world, def)
	case:
		lua.L_error(L, "physics3d: joints[%d] needs its kind first: { \"hinge\" | \"ball\" | \"slider\" | \"weld\" | \"rod\" | \"rope\" | \"spring\", a = ..., b = ... }", i32(j + 1))
	}
	fields_end(L, s, t, fmt.tprintf("physics3d.joints[%d]", j + 1))
}

@(private = "file")
body3d_ref :: proc(L: ^lua.State, idx: c.int, bodies: []Physics3d_Body, names: map[string]int, list: cstring, j: int) -> int {
	#partial switch lua.type(L, idx) {
	case .NIL:
		return -1
	case .NUMBER:
		i := int(lua.tointeger(L, idx))
		if i >= 1 && i <= len(bodies) {
			return i - 1
		}
	case .STRING:
		if i, ok := names[string(lua.tostring(L, idx))]; ok {
			return i
		}
	}
	lua.L_error(L, "physics3d: %s[%d] names no body: %s", list, i32(j + 1), lua.L_tostring(L, idx))
	return -1
}

// Kinematic `move(t)` callback: accepts `{x, y, z}, {rx, ry, rz}` or
// `x, y, z [, rx, ry, rz]`.
@(private = "file")
call_move3d :: proc(L: ^lua.State, at: c.int, i: int, t: f32) -> (p: b3.Vec3, q: b3.Quat) {
	top := lua.gettop(L)
	defer lua.settop(L, top)
	if i >= 0 {
		lua.rawgeti(L, at, lua.Integer(i + 1))
	} else {
		lua.pushvalue(L, at)
	}
	lua.getfield(L, -1, "move")
	lua.pushnumber(L, lua.Number(t))
	lua.call(L, 1, 6)
	res := top + 2
	if lua.istable(L, res) {
		p = read_vec3_at(L, res)
		euler: b3.Vec3
		if lua.istable(L, res + 1) {
			euler = read_vec3_at(L, res + 1)
		}
		q = euler_xyz_to_quat(euler)
		return
	}
	p = {f32(lua.tonumber(L, res)), f32(lua.tonumber(L, res + 1)), f32(lua.tonumber(L, res + 2))}
	euler := b3.Vec3{f32(lua.tonumber(L, res + 3)), f32(lua.tonumber(L, res + 4)), f32(lua.tonumber(L, res + 5))}
	q = euler_xyz_to_quat(euler)
	return
}

// Warns when body i starts deeper than OVERLAP_3D inside another.
@(private = "file")
check_overlap3d :: proc(L: ^lua.State, s: ^Script, bodies: []Physics3d_Body, i: int, data: ^[dynamic]b3.ContactData) {
	cap := int(b3.Body_GetContactCapacity(bodies[i].id))
	if cap <= 0 {
		return
	}
	resize(data, cap)
	count := int(b3.Body_GetContactData(bodies[i].id, raw_data(data^), c.int(cap)))
	deepest, other := f32(-OVERLAP_3D), -1
	for &cd in data[:count] {
		for &m in cd.manifolds[:cd.manifoldCount] {
			for p in m.points[:m.pointCount] {
				if p.separation < deepest {
					a := int(uintptr(b3.Shape_GetUserData(cd.shapeIdA))) - 1
					b := int(uintptr(b3.Shape_GetUserData(cd.shapeIdB))) - 1
					deepest, other = p.separation, b if a == i else a
				}
			}
		}
	}
	if other >= 0 && !(other < i && bodies[other].kind == .Dynamic && bodies[other].first_step == bodies[i].first_step) {
		report_warning(L, s, {code = .Physics3d_Overlap, a = bodies[i].label, b = bodies[other].label, w = -deepest * 100, x = max(bodies[i].start, 0)})
	}
}

@(private = "file")
read_motion_locks :: proc(L: ^lua.State, t: c.int) -> (locks: b3.MotionLocks) {
	// `true` locks all three axes, `{ x, y, z }` each one.
	axes :: proc(L: ^lua.State, t: c.int, key: cstring) -> (v: [3]bool) {
		field(L, t, key)
		defer lua.pop(L, 1)
		if lua.type(L, -1) == .BOOLEAN {
			b := bool(lua.toboolean(L, -1))
			return {b, b, b}
		}
		if lua.istable(L, -1) {
			for k in 0 ..< 3 {
				lua.rawgeti(L, -1, lua.Integer(k + 1))
				v[k] = bool(lua.toboolean(L, -1))
				lua.pop(L, 1)
			}
		}
		return
	}
	p := axes(L, t, "lock_position")
	r := axes(L, t, "lock_rotation")
	locks.linearX, locks.linearY, locks.linearZ = p[0], p[1], p[2]
	locks.angularX, locks.angularY, locks.angularZ = r[0], r[1], r[2]
	return
}

// Euler XYZ (radians, matching `o3d.compose`) -> unit quaternion.
@(private)
euler_xyz_to_quat :: proc "contextless" (rot: b3.Vec3) -> b3.Quat {
	cx, sx := math.cos(rot.x * 0.5), math.sin(rot.x * 0.5)
	cy, sy := math.cos(rot.y * 0.5), math.sin(rot.y * 0.5)
	cz, sz := math.cos(rot.z * 0.5), math.sin(rot.z * 0.5)
	return quaternion(
		x = sx * cy * cz + cx * sy * sz,
		y = cx * sy * cz - sx * cy * sz,
		z = cx * cy * sz + sx * sy * cz,
		w = cx * cy * cz - sx * sy * sz,
	)
}

// Unit quaternion -> Euler XYZ (radians, matching `o3d.compose`: R = Rx * Ry * Rz).
@(private)
quat_to_euler_xyz :: proc "contextless" (q: b3.Quat) -> b3.Vec3 {
	xx, yy, zz := q.x * q.x, q.y * q.y, q.z * q.z
	xy, xz, yz := q.x * q.y, q.x * q.z, q.y * q.z
	xw, yw, zw := q.x * q.w, q.y * q.w, q.z * q.w

	r00 := 1 - 2 * (yy + zz)
	r01 := 2 * (xy - zw)
	r02 := 2 * (xz + yw)
	r11 := 1 - 2 * (xx + zz)
	r12 := 2 * (yz - xw)
	r21 := 2 * (yz + xw)
	r22 := 1 - 2 * (xx + yy)

	ry := math.asin(clamp(r02, -1, 1))
	rx, rz: f32
	if abs(r02) < 0.9999999 {
		rx = math.atan2(-r12, r22)
		rz = math.atan2(-r01, r00)
	} else {
		rx = math.atan2(r21, r11)
		rz = 0
	}
	return {rx, ry, rz}
}

@(private = "file")
read_vec3_at :: proc(L: ^lua.State, at: c.int) -> (v: b3.Vec3) {
	idx := lua.absindex(L, at)
	for k in 0 ..< 3 {
		lua.rawgeti(L, idx, lua.Integer(k + 1))
		v[k] = f32(lua.tonumber(L, -1))
		lua.pop(L, 1)
	}
	return
}

@(private = "file")
read_vec3_list :: proc(L: ^lua.State, at: c.int, scale: b3.Vec3) -> []b3.Vec3 {
	if !lua.istable(L, at) {
		return nil
	}
	idx := lua.absindex(L, at)
	n := int(lua.rawlen(L, idx))
	if n == 0 {
		return nil
	}
	lua.rawgeti(L, idx, 1)
	first_is_num := lua.type(L, -1) == .NUMBER
	lua.pop(L, 1)
	if first_is_num {
		count := n / 3
		pts := make([]b3.Vec3, count, context.temp_allocator)
		for k in 0 ..< count {
			for c in 0 ..< 3 {
				lua.rawgeti(L, idx, lua.Integer(k * 3 + c + 1))
				pts[k][c] = f32(lua.tonumber(L, -1)) * scale[c]
				lua.pop(L, 1)
			}
		}
		return pts
	}
	pts := make([dynamic]b3.Vec3, 0, n, context.temp_allocator)
	for k in 1 ..= n {
		lua.rawgeti(L, idx, lua.Integer(k))
		if lua.istable(L, -1) {
			append(&pts, read_vec3_at(L, -1) * scale)
		}
		lua.pop(L, 1)
	}
	return pts[:]
}

@(private = "file")
read_i32_list :: proc(L: ^lua.State, at: c.int) -> []i32 {
	if !lua.istable(L, at) {
		return nil
	}
	idx := lua.absindex(L, at)
	n := int(lua.rawlen(L, idx))
	if n == 0 {
		return nil
	}
	out := make([]i32, n, context.temp_allocator)
	min_idx := i32(max(i32))
	for k in 0 ..< n {
		lua.rawgeti(L, idx, lua.Integer(k + 1))
		v := i32(lua.tointeger(L, -1))
		out[k] = v
		min_idx = min(min_idx, v)
		lua.pop(L, 1)
	}
	// Accept 1-based Lua triangle indices as well as 0-based indices.
	if min_idx == 1 {
		for &v in out {
			v -= 1
		}
	}
	return out
}

@(private = "file")
push_vec3 :: proc(L: ^lua.State, v: b3.Vec3) {
	lua.createtable(L, 3, 0)
	for k in 0 ..< 3 {
		lua.pushnumber(L, lua.Number(v[k]))
		lua.rawseti(L, -2, lua.Integer(k + 1))
	}
}
