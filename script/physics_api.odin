package onimite_script

import "core:c"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import b2 "vendor:box2d"
import lua "vendor:lua/5.4"

// physics{...} -> sim: rigid bodies simulated with Box2D once, at load, and
// returned as plain data. Frames build out of order and on several threads,
// so nothing steps per frame: the whole range is simulated in fixed steps
// on one thread, and `render` samples the tracks with `physics_at`.
// Wrap it in `shared` so a render's frame builders simulate it once:
//
//     local sim = shared("drop", function()
//       return physics {
//         duration = 4, gravity = 2000,              -- px/s² down (or { gx, gy })
//         bodies = {
//           { static = true, box = { 1920, 40 }, x = 960, y = 1040 },
//           { name = "tile", box = { 80, 110 }, x = 400, y = -100, angle = 8, start = 0.3, bounce = 0.3 },
//           { name = "ball", circle = 40, x = 900, y = 300 },
//           { kinematic = true, box = { 400, 20 }, move = function(t) return 200 + 300 * t, 600, 0 end },
//         },
//         joints = { { "rope", b = "ball", from = { 900, 0 } } },   -- a = nil: the world
//         kicks = { { t = 2, body = "tile", vx = 400, vy = -300 } },
//       }
//     end)
//     local x, y, angle = physics_at(sim, "tile", f.seconds)
//
// sim = { duration, rate, names = { name = index }, bodies = { { name,
// settled = seconds | nil, moving = true | nil }, ... }, contacts = { { t, a,
// b, x, y, speed }, ... }, tracks = handle }: contacts in time order with the
// two body indices, the point and the approach speed (px/s, at least
// `hit_speed`). The tracks (a pose per body per step, `rate` a second from
// 0) are one flat block in the render's `Shared` arena, like path assets:
// `shared` hands the frame builders the handle, not a copy, and
// `physics_at` reads it. Lengths are pixels, angles degrees (unwrapped: a
// rolling wheel keeps counting); Box2D sees lengths at PHYSICS_SCALE pixels
// a metre.
//
// The simulation checks itself as it runs (load warnings at the physics{}
// line): a body that starts inside another (`physics_overlap`), one that
// leaves the canvas for good (`physics_offscreen`, unless `leaves = true`);
// `physics_at` reports frames sampled past the end while a body still
// moves (`physics_unsettled`).

@(private)
PHYSICS_SCALE :: 100

@(private)
PHYSICS_SUBSTEPS :: 4

// Deeper than this (px) at a body's first step is an overlap, not a touch.
@(private = "file")
OVERLAP_PX :: 3

// Faster than these at the end (px/s, degrees/s) is still moving.
@(private = "file")
MOVING_SPEED, MOVING_SPIN :: 10, 10

// Box2D keeps its worlds in one process-wide table that creating and
// destroying a world change unguarded; frame builders load at once.
@(private = "file")
physics_lock: sync.Mutex

@(private = "file")
Physics_Kind :: enum u8 {
	Dynamic,
	Static,
	Kinematic,
}

@(private = "file")
Physics_Body :: struct {
	id:          b2.BodyId,
	// Its name in warnings and `show`: `name`, else "#i", its 1-based index
	// in `bodies` (temp).
	label:       string,
	kind:        Physics_Kind,
	start, stop: f32,
	asleep:      bool,
	// It may leave the canvas (no `physics_offscreen`).
	leaves:      bool,
	// A kinematic body's `move` function: its pose each step.
	move:        bool,
	enabled:     bool,
	stopped:     bool,
	// Its launch velocity (metres/s and radians/s), given when it starts.
	velocity:    [2]f32,
	spin:        f32,
	// When it last fell asleep and stayed so; -1 while awake.
	settled:     f32,
	// The step it started on, for the overlap check after it.
	first_step:  int,
	// Seen on the canvas, and when it last went off it (-1: on it).
	seen:        bool,
	left_at:     f32,
}

// The simulated poses, made once per simulation in `Shared.arena` and never
// changed: body i's step k at [i * samples + k] (body-major, so a body's
// track is contiguous).
@(private = "file")
Physics_Tracks :: struct {
	// PHYSICS_TRACKS: what `physics_at` checks its handle by.
	magic:    u32,
	rate:     f32,
	duration: f32,
	bodies:   int,
	samples:  int,
	x, y:     []f32,
	angle:    []f32,
	// Still moving at the end, and its name in warnings, per body.
	moving:   []bool,
	labels:   []string,
}

@(private = "file")
PHYSICS_TRACKS :: 0x7068_7973

@(private = "file")
Physics_Contact :: struct {
	t:     f32,
	a, b:  i32,
	point: [2]f32,
	speed: f32,
}

@(private = "file")
Physics_Kick :: struct {
	t:        f32,
	body:     int,
	velocity: [2]f32,
	spin:     f32,
	done:     bool,
}

@(private)
l_physics :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))

	fields_begin(L, 1)
	duration := get_num(L, 1, "duration", 0)
	rate := get_num(L, 1, "rate", 60)
	hit_speed := get_num(L, 1, "hit_speed", 100)
	gravity := [2]f32{0, 2000}
	switch field(L, 1, "gravity") {
	case c.int(lua.Type.NUMBER):
		gravity.y = f32(lua.tonumber(L, -1))
	case c.int(lua.Type.TABLE):
		gravity = read_pair(L, -1)
	}
	lua.pop(L, 1)
	if field(L, 1, "bodies") != c.int(lua.Type.TABLE) {
		lua.L_error(L, "physics: give bodies = { {...}, ... }")
	}
	bodies_at := lua.gettop(L)
	field(L, 1, "joints")
	joints_at := lua.gettop(L)
	field(L, 1, "kicks")
	kicks_at := lua.gettop(L)
	fields_end(L, s, 1, "physics")
	if !(duration > 0) || duration > 600 {
		lua.L_error(L, "physics: duration must be seconds in (0, 600], got %f", f64(duration))
	}
	if !(rate >= 1) || rate > 1000 {
		lua.L_error(L, "physics: rate must be steps a second in [1, 1000], got %f", f64(rate))
	}

	sync.lock(&physics_lock)
	world_def := b2.DefaultWorldDef()
	world_def.gravity = gravity / PHYSICS_SCALE
	world_def.hitEventThreshold = hit_speed / PHYSICS_SCALE
	world := b2.CreateWorld(world_def)
	sync.unlock(&physics_lock)
	defer {
		sync.guard(&physics_lock)
		b2.DestroyWorld(world)
	}
	// What a joint without `a` or `b` holds on to.
	ground := b2.CreateBody(world, b2.DefaultBodyDef())

	n := int(lua.rawlen(L, bodies_at))
	bodies := make([]Physics_Body, n, context.temp_allocator)
	names := make(map[string]int, context.temp_allocator)
	// Collision layers by name, a bit each ("" is the default layer, bit 0).
	layers := make(map[string]u64, context.temp_allocator)
	layers[""] = 1
	for &body, i in bodies {
		lua.rawgeti(L, bodies_at, lua.Integer(i + 1))
		if !lua.istable(L, -1) {
			lua.L_error(L, "physics: bodies[%d] is not a table", i32(i + 1))
		}
		body = read_body(L, s, world, &layers, lua.gettop(L), i)
		if body.label[0] != '#' {
			if body.label in names {
				lua.L_error(L, "physics: two bodies are named %s", strings.clone_to_cstring(body.label, context.temp_allocator))
			}
			names[body.label] = i
		}
		lua.pop(L, 1)
	}
	if lua.istable(L, joints_at) {
		for j in 0 ..< int(lua.rawlen(L, joints_at)) {
			lua.rawgeti(L, joints_at, lua.Integer(j + 1))
			if !lua.istable(L, -1) {
				lua.L_error(L, "physics: joints[%d] is not a table", i32(j + 1))
			}
			read_joint(L, s, world, ground, bodies, names, lua.gettop(L), j)
			lua.pop(L, 1)
		}
	}
	kicks := make([dynamic]Physics_Kick, context.temp_allocator)
	if lua.istable(L, kicks_at) {
		for j in 0 ..< int(lua.rawlen(L, kicks_at)) {
			lua.rawgeti(L, kicks_at, lua.Integer(j + 1))
			t := lua.gettop(L)
			if !lua.istable(L, t) {
				lua.L_error(L, "physics: kicks[%d] is not a table", i32(j + 1))
			}
			fields_begin(L, t)
			field(L, t, "body")
			k := Physics_Kick {
				t        = get_num(L, t, "t", 0),
				body     = body_ref(L, -1, bodies, names, "kicks", j),
				velocity = {get_num(L, t, "vx", 0), get_num(L, t, "vy", 0)} / PHYSICS_SCALE,
				spin     = get_num(L, t, "spin", 0) * (math.PI / 180),
			}
			if k.body < 0 {
				lua.L_error(L, "physics: kicks[%d] needs a body", i32(j + 1))
			}
			append(&kicks, k)
			fields_end(L, s, t, fmt.tprintf("physics.kicks[%d]", j + 1))
			lua.settop(L, t - 1)
		}
	}

	canvas := [2]f32{f32(s.video.width), f32(s.video.height)}
	steps := int(math.ceil(duration * rate))
	samples := steps + 1
	tracks := make_tracks(s.shared, bodies, samples, rate, duration)
	xs, ys, angles := tracks.x, tracks.y, tracks.angle
	contacts := make([dynamic]Physics_Contact, context.temp_allocator)
	contact_data := make([dynamic]b2.ContactData, context.temp_allocator)
	record :: proc(bodies: []Physics_Body, xs, ys, angles: []f32, samples, k: int) {
		for body, i in bodies {
			at := i * samples + k
			p := b2.Body_GetPosition(body.id) * PHYSICS_SCALE
			a := b2.Rot_GetAngle(b2.Body_GetRotation(body.id)) * (180 / math.PI)
			if k > 0 {
				// Unwrapped: the nearest turn to the last sample.
				a -= 360 * math.round((a - angles[at - 1]) / 360)
			}
			xs[at], ys[at], angles[at] = p.x, p.y, a
		}
	}
	record(bodies, xs, ys, angles, samples, 0)
	dt := 1 / rate
	for k in 1 ..= steps {
		was := f32(k - 1) * dt
		t := f32(k) * dt
		for &body in bodies {
			if !body.enabled && !body.stopped && body.start <= was + 1e-6 {
				// Box2D drops the velocity of a body made disabled.
				b2.Body_Enable(body.id)
				b2.Body_SetLinearVelocity(body.id, body.velocity)
				b2.Body_SetAngularVelocity(body.id, body.spin)
				if body.asleep {
					b2.Body_SetAwake(body.id, false)
				}
				body.enabled = true
				body.first_step = k
			}
			if body.enabled && body.stop <= was + 1e-6 {
				b2.Body_Disable(body.id)
				body.enabled, body.stopped = false, true
			}
		}
		for &kick in kicks {
			body := &bodies[kick.body]
			if !kick.done && kick.t <= was + 1e-6 && body.enabled {
				kick.done = true
				b2.Body_SetLinearVelocity(body.id, b2.Body_GetLinearVelocity(body.id) + kick.velocity)
				b2.Body_SetAngularVelocity(body.id, b2.Body_GetAngularVelocity(body.id) + kick.spin)
				b2.Body_SetAwake(body.id, true)
			}
		}
		for &body, i in bodies {
			if body.move && body.enabled {
				// Velocities that put it on its next pose by the end of the step.
				p, a := call_move(L, bodies_at, i, t)
				b2.Body_SetLinearVelocity(body.id, (p - b2.Body_GetPosition(body.id)) / dt)
				da := a - b2.Rot_GetAngle(b2.Body_GetRotation(body.id))
				da -= 2 * math.PI * math.round(da / (2 * math.PI))
				b2.Body_SetAngularVelocity(body.id, da / dt)
			}
		}

		b2.World_Step(world, dt, PHYSICS_SUBSTEPS)

		events := b2.World_GetContactEvents(world)
		for e in events.hitEvents[:events.hitCount] {
			append(&contacts, Physics_Contact {
				t = t,
				a = i32(uintptr(b2.Shape_GetUserData(e.shapeIdA))),
				b = i32(uintptr(b2.Shape_GetUserData(e.shapeIdB))),
				point = e.point * PHYSICS_SCALE,
				speed = e.approachSpeed * PHYSICS_SCALE,
			})
		}
		record(bodies, xs, ys, angles, samples, k)
		for &body, i in bodies {
			if body.kind != .Dynamic || !body.enabled {
				continue
			}
			if b2.Body_IsAwake(body.id) {
				body.settled = -1
			} else if body.settled < 0 {
				body.settled = t
			}
			if body.first_step == k {
				check_overlap(L, s, bodies, i, &contact_data)
			}
			if canvas.x > 0 && !body.leaves {
				box := b2.Body_ComputeAABB(body.id)
				lo, hi := box.lowerBound * PHYSICS_SCALE, box.upperBound * PHYSICS_SCALE
				if hi.x > 0 && hi.y > 0 && lo.x < canvas.x && lo.y < canvas.y {
					body.seen, body.left_at = true, -1
				} else if body.seen && body.left_at < 0 {
					body.left_at = t
				}
			}
		}
	}
	for body in bodies {
		if body.seen && body.left_at >= 0 {
			report_warning(L, s, {code = .Physics_Offscreen, a = body.label, x = body.left_at})
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
		if body.kind == .Dynamic && body.enabled {
			v := b2.Body_GetLinearVelocity(body.id) * PHYSICS_SCALE
			w := abs(b2.Body_GetAngularVelocity(body.id)) * (180 / math.PI)
			if math.sqrt(v.x * v.x + v.y * v.y) > MOVING_SPEED || w > MOVING_SPIN {
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
		lua.createtable(L, 0, 6)
		set_num(L, "t", ct.t)
		set_int(L, "a", int(ct.a))
		set_int(L, "b", int(ct.b))
		set_num(L, "x", ct.point.x)
		set_num(L, "y", ct.point.y)
		set_num(L, "speed", ct.speed)
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	lua.setfield(L, -2, "contacts")
	lua.pushlightuserdata(L, tracks)
	lua.setfield(L, -2, "tracks")
	append(&s.physics, Physics_Sim{tracks, strings.clone(caller_where(L))})
	return 1
}

// A simulation this load ran: its tracks (in the shared arena) and the
// script line of its physics{} call (owned).
Physics_Sim :: struct {
	tracks: rawptr,
	at:     string,
}

// A simulated body as `onimite show` lists it: its simulation (in the
// order of the physics{} calls) and that call's line, where it is at the
// start and the end, and whether it still moves when the simulation ends.
Physics_Body_Info :: struct {
	label:    string,
	sim:      int,
	at:       string,
	duration: f32,
	rate:     f32,
	start:    [2]f32,
	stop:     [2]f32,
	// Its rotation at the end, radians.
	angle:    f32,
	moving:   bool,
}

// The bodies of every simulation this load ran (temp memory, strings
// borrowed).
physics_bodies :: proc(s: ^Script) -> []Physics_Body_Info {
	out := make([dynamic]Physics_Body_Info, context.temp_allocator)
	for sim, k in s.physics {
		tr := (^Physics_Tracks)(sim.tracks)
		if tr.samples == 0 {
			continue
		}
		for i in 0 ..< tr.bodies {
			first, last := i * tr.samples, i * tr.samples + tr.samples - 1
			append(&out, Physics_Body_Info{tr.labels[i], k, sim.at, tr.duration, tr.rate, {tr.x[first], tr.y[first]}, {tr.x[last], tr.y[last]}, tr.angle[last], tr.moving[i]})
		}
	}
	return out[:]
}

@(private)
physics_unload :: proc(s: ^Script) {
	for sim in s.physics {
		delete(sim.at)
	}
	delete(s.physics)
}

// The tracks of a simulation of `bodies`, in the shared arena (filled by
// the caller before anyone else can see them).
@(private = "file")
make_tracks :: proc(sh: ^Shared, bodies: []Physics_Body, samples: int, rate, duration: f32) -> ^Physics_Tracks {
	sync.guard(&sh.lock)
	alloc := virtual.arena_allocator(&sh.arena)
	n := len(bodies)
	tr := new(Physics_Tracks, alloc)
	tr^ = {
		magic    = PHYSICS_TRACKS,
		rate     = rate,
		duration = duration,
		bodies   = n,
		samples  = samples,
		x        = make([]f32, n * samples, alloc),
		y        = make([]f32, n * samples, alloc),
		angle    = make([]f32, n * samples, alloc),
		moving   = make([]bool, n, alloc),
		labels   = make([]string, n, alloc),
	}
	for b, i in bodies {
		tr.labels[i] = strings.clone(b.label, alloc)
	}
	return tr
}

// physics_at(sim, body, t) -> x, y, angle: body (an index or a name) of a
// physics{} result at t seconds on its clock, between steps linearly; the
// ends hold, and a frame past the end while the body still moved there is
// reported (`physics_unsettled`).
@(private)
l_physics_at :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	lua.getfield(L, 1, "tracks")
	tr := (^Physics_Tracks)(lua.touserdata(L, -1))
	if tr == nil || tr.magic != PHYSICS_TRACKS {
		lua.L_error(L, "physics_at: give the table physics{} returned")
	}
	i := -1
	if lua.type(L, 2) == .STRING {
		lua.getfield(L, 1, "names")
		if lua.istable(L, -1) {
			lua.pushvalue(L, 2)
			lua.rawget(L, -2)
			i = int(lua.tointeger(L, -1)) - 1
		}
	} else if lua.isinteger(L, 2) {
		i = int(lua.tointeger(L, 2)) - 1
	}
	if i < 0 || i >= tr.bodies {
		lua.L_error(L, "physics_at: no body %s", lua.L_tostring(L, 2))
	}
	t := f32(lua.L_checknumber(L, 3))
	row := i * tr.samples
	last := tr.samples - 1
	u := max(t * tr.rate, 0)
	k := int(u)
	x, y, a: f32
	if k >= last {
		if tr.moving[i] && u > f32(last) + 1e-3 {
			report_warning(L, s, {code = .Physics_Unsettled, a = tr.labels[i], x = tr.duration})
		}
		x, y, a = tr.x[row + last], tr.y[row + last], tr.angle[row + last]
	} else {
		w := u - f32(k)
		at := row + k
		x = tr.x[at] + (tr.x[at + 1] - tr.x[at]) * w
		y = tr.y[at] + (tr.y[at + 1] - tr.y[at]) * w
		a = tr.angle[at] + (tr.angle[at + 1] - tr.angle[at]) * w
	}
	lua.pushnumber(L, lua.Number(x))
	lua.pushnumber(L, lua.Number(y))
	lua.pushnumber(L, lua.Number(a))
	return 3
}

// One `bodies` entry made into a (disabled until its start) body with its shape.
@(private = "file")
read_body :: proc(L: ^lua.State, s: ^Script, world: b2.WorldId, layers: ^map[string]u64, t: c.int, i: int) -> (body: Physics_Body) {
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
	body.asleep = get_flag(L, t, "asleep")
	body.leaves = get_flag(L, t, "leaves")
	body.settled = -1
	def := b2.DefaultBodyDef()
	types := [Physics_Kind]b2.BodyType{.Dynamic = .dynamicBody, .Static = .staticBody, .Kinematic = .kinematicBody}
	def.type = types[body.kind]
	position := [2]f32{get_num(L, t, "x", 0), get_num(L, t, "y", 0)} / PHYSICS_SCALE
	angle := get_num(L, t, "angle", 0) * (math.PI / 180)
	if field(L, t, "move") == c.int(lua.Type.FUNCTION) {
		if body.kind != .Kinematic {
			lua.L_error(L, "physics: bodies[%d].move needs kinematic = true", i32(i + 1))
		}
		body.move = true
		lua.pop(L, 1)
		position, angle = call_move(L, t, -1, 0)
	} else {
		lua.pop(L, 1)
	}
	body.velocity = {get_num(L, t, "vx", 0), get_num(L, t, "vy", 0)} / PHYSICS_SCALE
	body.spin = get_num(L, t, "spin", 0) * (math.PI / 180)
	def.position = position
	def.rotation = b2.MakeRot(angle)
	def.linearVelocity = body.velocity
	def.angularVelocity = body.spin
	def.gravityScale = get_num(L, t, "gravity_scale", 1)
	def.linearDamping = get_num(L, t, "damping", 0)
	def.angularDamping = get_num(L, t, "spin_damping", 0)
	def.isBullet = get_flag(L, t, "bullet")
	def.isAwake = !body.asleep
	def.isEnabled = body.start <= 0
	body.enabled = def.isEnabled
	body.first_step = 1 if body.enabled else 0
	body.id = b2.CreateBody(world, def)

	shape := b2.DefaultShapeDef()
	shape.userData = rawptr(uintptr(i + 1))
	shape.enableHitEvents = true
	shape.density = get_num(L, t, "density", 1)
	shape.material.friction = get_num(L, t, "friction", 0.6)
	shape.material.restitution = get_num(L, t, "bounce", 0)
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
	switch {
	case field(L, t, "box") == c.int(lua.Type.TABLE):
		size := read_pair(L, -1) / (2 * PHYSICS_SCALE)
		if !(size.x > 0 && size.y > 0) {
			lua.L_error(L, "physics: bodies[%d].box needs a positive { w, h }", i32(i + 1))
		}
		box := b2.MakeBox(size.x, size.y)
		_ = b2.CreatePolygonShape(body.id, shape, &box)
	case field(L, t, "circle") == c.int(lua.Type.NUMBER):
		r := f32(lua.tonumber(L, -1)) / PHYSICS_SCALE
		if !(r > 0) {
			lua.L_error(L, "physics: bodies[%d].circle needs a positive radius", i32(i + 1))
		}
		circle := b2.Circle{radius = r}
		_ = b2.CreateCircleShape(body.id, shape, &circle)
	case field(L, t, "polygon") == c.int(lua.Type.TABLE):
		points: [b2.MAX_POLYGON_VERTICES]b2.Vec2
		count := int(lua.rawlen(L, -1)) / 2
		if count < 3 || count > len(points) {
			lua.L_error(L, "physics: bodies[%d].polygon needs 3 to %d points { x1, y1, x2, y2, ... }", i32(i + 1), i32(len(points)))
		}
		for &p, j in points[:count] {
			lua.rawgeti(L, -1, lua.Integer(2 * j + 1))
			lua.rawgeti(L, -2, lua.Integer(2 * j + 2))
			p = {f32(lua.tonumber(L, -2)), f32(lua.tonumber(L, -1))} / PHYSICS_SCALE
			lua.pop(L, 2)
		}
		hull := b2.ComputeHull(points[:count])
		if hull.count == 0 {
			lua.L_error(L, "physics: bodies[%d].polygon has no area (points in a line or too close)", i32(i + 1))
		}
		polygon := b2.MakePolygon(hull, 0)
		_ = b2.CreatePolygonShape(body.id, shape, &polygon)
	case body.kind == .Dynamic:
		lua.L_error(L, "physics: bodies[%d] needs a shape: box = { w, h }, circle = r or polygon = { x1, y1, ... }", i32(i + 1))
	}
	// The shape fields read (a failed case leaves its value too).
	lua.settop(L, t)
	fields_end(L, s, t, fmt.tprintf("physics.bodies[%d]", i + 1))
	return
}

// One `joints` entry: { kind, a = body, b = body, ... }, anchors in canvas
// pixels; a missing `a` or `b` is the world.
@(private = "file")
read_joint :: proc(L: ^lua.State, s: ^Script, world: b2.WorldId, ground: b2.BodyId, bodies: []Physics_Body, names: map[string]int, t: c.int, j: int) {
	fields_begin(L, t)
	lua.rawgeti(L, t, 1)
	kind := string(lua.tostring(L, -1)) if lua.type(L, -1) == .STRING else ""
	lua.pop(L, 1)
	ids: [2]b2.BodyId
	for key, k in ([2]cstring{"a", "b"}) {
		field(L, t, key)
		r := body_ref(L, -1, bodies, names, "joints", j)
		lua.pop(L, 1)
		ids[k] = ground if r < 0 else bodies[r].id
	}
	if ids[0] == ids[1] {
		lua.L_error(L, "physics: joints[%d] needs two different bodies (a, b; a missing one is the world)", i32(j + 1))
	}
	// An anchor: `key` in pixels, else body k's centre.
	anchor :: proc(L: ^lua.State, t: c.int, key: cstring, id: b2.BodyId) -> b2.Vec2 {
		if field(L, t, key) == c.int(lua.Type.TABLE) {
			p := read_pair(L, -1) / PHYSICS_SCALE
			lua.pop(L, 1)
			return p
		}
		lua.pop(L, 1)
		return b2.Body_GetPosition(id)
	}
	collide := get_flag(L, t, "collide")
	switch kind {
	case "hinge":
		at := anchor(L, t, "at", ids[1])
		def := b2.DefaultRevoluteJointDef()
		def.bodyIdA, def.bodyIdB = ids[0], ids[1]
		def.localAnchorA = b2.Body_GetLocalPoint(ids[0], at)
		def.localAnchorB = b2.Body_GetLocalPoint(ids[1], at)
		def.referenceAngle = b2.Rot_GetAngle(b2.Body_GetRotation(ids[1])) - b2.Rot_GetAngle(b2.Body_GetRotation(ids[0]))
		def.collideConnected = collide
		if field(L, t, "limit") == c.int(lua.Type.TABLE) {
			lim := read_pair(L, -1) * (math.PI / 180)
			def.enableLimit, def.lowerAngle, def.upperAngle = true, lim[0], lim[1]
		}
		lua.pop(L, 1)
		if speed, ok := get_opt_num(L, t, "motor"); ok {
			def.enableMotor, def.motorSpeed = true, speed * (math.PI / 180)
			def.maxMotorTorque = get_num(L, t, "torque", 1000)
		}
		_ = b2.CreateRevoluteJoint(world, def)
	case "weld":
		at := anchor(L, t, "at", ids[1])
		def := b2.DefaultWeldJointDef()
		def.bodyIdA, def.bodyIdB = ids[0], ids[1]
		def.localAnchorA = b2.Body_GetLocalPoint(ids[0], at)
		def.localAnchorB = b2.Body_GetLocalPoint(ids[1], at)
		def.referenceAngle = b2.Rot_GetAngle(b2.Body_GetRotation(ids[1])) - b2.Rot_GetAngle(b2.Body_GetRotation(ids[0]))
		def.collideConnected = collide
		_ = b2.CreateWeldJoint(world, def)
	case "rod", "rope", "spring":
		from := anchor(L, t, "from", ids[0])
		to := anchor(L, t, "to", ids[1])
		d := to - from
		def := b2.DefaultDistanceJointDef()
		def.bodyIdA, def.bodyIdB = ids[0], ids[1]
		def.localAnchorA = b2.Body_GetLocalPoint(ids[0], from)
		def.localAnchorB = b2.Body_GetLocalPoint(ids[1], to)
		def.length = get_num(L, t, "length", math.sqrt(d.x * d.x + d.y * d.y) * PHYSICS_SCALE) / PHYSICS_SCALE
		def.collideConnected = collide
		switch kind {
		case "rope":
			// Slack up to its length: a free spring with a maximum.
			def.enableSpring, def.hertz = true, 0
			def.enableLimit, def.minLength, def.maxLength = true, 0, def.length
		case "spring":
			def.enableSpring = true
			def.hertz = get_num(L, t, "hertz", 4)
			def.dampingRatio = get_num(L, t, "damping", 0.5)
		}
		_ = b2.CreateDistanceJoint(world, def)
	case:
		lua.L_error(L, "physics: joints[%d] needs its kind first: { \"hinge\" | \"weld\" | \"rod\" | \"rope\" | \"spring\", a = ..., b = ... }", i32(j + 1))
	}
	fields_end(L, s, t, fmt.tprintf("physics.joints[%d]", j + 1))
}

// A body reference at `idx` (an index from 1 or a name) as an index from 0;
// -1 when it is nil.
@(private = "file")
body_ref :: proc(L: ^lua.State, idx: c.int, bodies: []Physics_Body, names: map[string]int, list: cstring, j: int) -> int {
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
	lua.L_error(L, "physics: %s[%d] names no body: %s", list, i32(j + 1), lua.L_tostring(L, idx))
	return -1
}

// A kinematic body's pose at `t`: `bodies[i + 1].move(t)` (i < 0: the
// table at `at` itself) -> x, y, angle, in Box2D units.
@(private = "file")
call_move :: proc(L: ^lua.State, at: c.int, i: int, t: f32) -> (p: b2.Vec2, angle: f32) {
	top := lua.gettop(L)
	defer lua.settop(L, top)
	if i >= 0 {
		lua.rawgeti(L, at, lua.Integer(i + 1))
	} else {
		lua.pushvalue(L, at)
	}
	lua.getfield(L, -1, "move")
	lua.pushnumber(L, lua.Number(t))
	lua.call(L, 1, 3)
	p = {f32(lua.tonumber(L, -3)), f32(lua.tonumber(L, -2))} / PHYSICS_SCALE
	angle = f32(lua.tonumber(L, -1)) * (math.PI / 180)
	return
}

// Warns when body i starts deeper than OVERLAP_PX inside another.
@(private = "file")
check_overlap :: proc(L: ^lua.State, s: ^Script, bodies: []Physics_Body, i: int, data: ^[dynamic]b2.ContactData) {
	resize(data, int(b2.Body_GetContactCapacity(bodies[i].id)))
	deepest, other := f32(-OVERLAP_PX), -1
	for &cd in b2.Body_GetContactData(bodies[i].id, data[:]) {
		for p in cd.manifold.points[:cd.manifold.pointCount] {
			if sep := p.separation * PHYSICS_SCALE; sep < deepest {
				a := int(uintptr(b2.Shape_GetUserData(cd.shapeIdA))) - 1
				b := int(uintptr(b2.Shape_GetUserData(cd.shapeIdB))) - 1
				deepest, other = sep, b if a == i else a
			}
		}
	}
	// A pair that starts together is one finding (the first body's).
	if other >= 0 && !(other < i && bodies[other].kind == .Dynamic && bodies[other].first_step == bodies[i].first_step) {
		report_warning(L, s, {code = .Physics_Overlap, a = bodies[i].label, b = bodies[other].label, w = -deepest, x = max(bodies[i].start, 0)})
	}
}

// The bit of collision layer `name`, given on first use (64 at most).
@(private = "file")
layer_bit :: proc(L: ^lua.State, layers: ^map[string]u64, name: string) -> u64 {
	if bit, ok := layers[name]; ok {
		return bit
	}
	if len(layers) >= 64 {
		lua.L_error(L, "physics: more than 64 layers")
	}
	bit := u64(1) << uint(len(layers))
	layers[strings.clone(name, context.temp_allocator)] = bit
	return bit
}

@(private = "file")
get_flag :: proc(L: ^lua.State, t: c.int, key: cstring) -> bool {
	field(L, t, key)
	defer lua.pop(L, 1)
	return bool(lua.toboolean(L, -1))
}

// { a, b } at `idx` (missing entries read 0).
@(private = "file")
read_pair :: proc(L: ^lua.State, at: c.int) -> [2]f32 {
	idx := lua.absindex(L, at)
	lua.rawgeti(L, idx, 1)
	lua.rawgeti(L, idx, 2)
	defer lua.pop(L, 2)
	return {f32(lua.tonumber(L, -2)), f32(lua.tonumber(L, -1))}
}
