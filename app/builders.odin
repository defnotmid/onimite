package onimite_app

import "base:runtime"
import "core:fmt"
import "core:sync"
import "core:thread"
import vg "deps:ovg"
import om "../onimite"
import enc "../encode"
import script "../script"

// Frame builders for `render`: frames are built as tasks on the app's pool,
// several at once, and the render loop takes them in frame order. Each
// builder owns a script state (the script loaded again: render procs are
// pure per frame; load-time data made with `shared` / `path_data` comes
// from the app's state instead of being made again), a renderer and two
// output slots (one being built, one handed over). A builder records the
// frame (ovg commands, vertices, image work). On the GPU the loop plays it with the builder's
// `Frame_Player`; on the CPU the builder plays it on its own software
// backend and converts it (to I420, or writes the PNG). Clip frames are
// asked for in frame order either way: the loop plays in order, and CPU
// builders take turns for that step (`Build_Run.turn`), since the decoders
// serve one position per clip.
//
// Builders start one at a time: the set grows by one, up to one per pool
// worker, whenever the loop would wait for its next frame from a builder
// that has built one before, so a render bound by the GPU or the encoder
// keeps few script states while one bound by building uses every core. A
// builder loads its script in its first task; waiting on that says nothing
// about building (and growing then would start another load). With no pool there is one builder, run on the loop's thread: the
// same rows and kernels, one frame after another.
//
// Multipass shaders keep feedback buffers from frame to frame, which every
// builder's renderer would have to catch up with on its own (feedback.odin).
// Once the loop takes a frame that has them (or the range starts on one),
// the set stops growing and hands every next frame to that frame's builder
// (the lead), so the buffers advance once per frame; frames already handed
// to the others are still taken, in order. On the CPU the lead runs on the
// loop's thread and shades its bands on the pool (a task waiting on the
// pool could end up running the frames it waits for).
//
// Media images decode on first use. With a pool, a scout (one more script
// state) builds every SCOUT_STEP-th frame up to SCOUT_AHEAD frames past the
// ones being built and decodes the images they show, so builders rarely
// wait for a decode; the pixels are the same either way. Images count as
// used by the frame that asked, and the render loop's evictions spare
// frames not yet played, the scout's included.
SCOUT_AHEAD :: 90
SCOUT_STEP :: 6

Builder :: struct {
	job:      om.Pool_Job,
	run:      ^Build_Run,
	// The CPU lead's pool for shader bands (see above).
	pool:     ^thread.Pool,
	script:   script.Script,
	renderer: om.Renderer,
	// CPU renders: the builder draws its records itself.
	software: vg.Software_Backend,
	player:   om.Frame_Player,
	// The frame being built and the slot it goes into.
	frame:    int,
	slot:     int,
	out:      [2]Built_Frame,
	ready:    bool,
	// Frames the loop has taken from it (the loop's own count).
	taken:    int,
	// Why setting up failed (strings of the builder's script).
	failure:  Failure,
}

Built_Frame :: struct {
	// GPU: the recorded frame; CPU: its number and diagnostics.
	record:     om.Frame_Record,
	// CPU to MP4: the frame as I420, `y_stride = width`.
	i420:       []u8,
	png_failed: bool,
}

// What every builder of one render shares (read-only while they run).
Build_Run :: struct {
	script_path:  string,
	script_args:  []string,
	script_props: []string,
	// Load-time data of the app's script state, which builders reuse
	// rather than make again (script/shared.odin).
	shared:       ^script.Shared,
	media:        ^om.Media,
	scale:        f32,
	software:     bool,
	// PNG output directory ("" for MP4).
	png_dir:      string,
	// CPU renders with video clips: frames past `start` whose clip frames
	// have been fetched; frame `start + turn` fetches next.
	start:        int,
	turn:         sync.Futex,
	video_turns:  bool,
}

Scout :: struct {
	job:      om.Pool_Job,
	run:      ^Build_Run,
	script:   script.Script,
	renderer: om.Renderer,
	ready:    bool,
	failed:   bool,
	frame:    int,
}

Builder_Set :: struct {
	pool:     ^thread.Pool,
	builders: []Builder,
	scout:    Scout,
	active:   int,
	// Builders in the order of the frames they build (a ring).
	order:    []int,
	head:     int,
	count:    int,
	// The next frame to hand out, and the end of the range.
	next:     int,
	end:      int,
	// Multipass shaders seen: only `lead` builds from now on.
	ordered:  bool,
	lead:     int,
}

// Up to one builder per pool worker (the loop's thread plays and encodes),
// one with no pool; never more than frames. `ordered`: the first frame has
// multipass shaders, so one builder builds them all.
builder_set_init :: proc(s: ^Builder_Set, run: ^Build_Run, pool: ^thread.Pool, start, end: int, ordered := false) {
	n := clamp(om.pool_count(pool) if pool != nil else 1, 1, max(end - start, 1))
	s^ = {pool = pool, builders = make([]Builder, n), order = make([]int, n), next = start, end = end}
	run.start = start
	run.video_turns = run.software && len(run.media.videos.names) > 0
	for &b in s.builders {
		b.run = run
		b.job.procedure = builder_task
	}
	s.scout = {run = run, frame = start}
	s.scout.job.procedure = scout_task
	if ordered {
		builder_set_lead(s, 0)
		s.active = 1
		builder_set_spawn(s, 0)
		return
	}
	builder_set_grow(s)
}

// From now on only builder `k` builds.
@(private = "file")
builder_set_lead :: proc(s: ^Builder_Set, k: int) {
	s.ordered, s.lead = true, k
	if s.builders[k].run.software {
		s.builders[k].pool = s.pool
	}
}

builder_set_destroy :: proc(s: ^Builder_Set) {
	om.pool_join(&s.scout.job)
	if s.scout.ready {
		om.renderer_destroy(&s.scout.renderer)
	}
	script.unload(&s.scout.script)
	for &b in s.builders {
		om.pool_join(&b.job)
		if b.ready {
			om.renderer_destroy(&b.renderer)
			if b.run.software {
				om.frame_player_destroy(&b.player)
				vg.software_backend_destroy(&b.software)
			}
		}
		script.unload(&b.script)
		for &o in b.out {
			om.frame_record_destroy(&o.record)
			delete(o.i420)
		}
	}
	delete(s.builders)
	delete(s.order)
	s^ = {}
}

// Starts another builder on the next frame, if one is left.
@(private = "file")
builder_set_grow :: proc(s: ^Builder_Set) {
	if s.ordered || s.active == len(s.builders) || s.next >= s.end {
		return
	}
	s.active += 1
	builder_set_spawn(s, s.active - 1)
}

@(private = "file")
builder_set_spawn :: proc(s: ^Builder_Set, k: int) {
	if s.next >= s.end {
		return
	}
	b := &s.builders[k]
	b.frame = s.next
	s.next += 1
	s.order[(s.head + s.count) % len(s.order)] = k
	s.count += 1
	// The CPU lead builds right here, on the loop's thread.
	om.pool_spawn(nil if b.pool != nil else s.pool, &b.job, runtime.heap_allocator())
}

// The next frame in order: waits for it, gives its builder the next frame
// to build (adding a builder when this had to wait) and returns the frame's
// slot and its builder's index. The slot stays valid until that builder's
// next take. A builder that failed to set up returns its code (its
// `failure` says why).
builder_set_take :: proc(s: ^Builder_Set) -> (out: ^Built_Frame, k: int, err: Error) {
	assert(s.count > 0)
	k = s.order[s.head]
	s.head = (s.head + 1) % len(s.order)
	s.count -= 1
	b := &s.builders[k]
	if b.taken > 0 && om.pool_job_running(&b.job) {
		builder_set_grow(s)
	}
	om.pool_join(&b.job)
	b.taken += 1
	if b.failure.code != .None {
		return nil, k, b.failure.code
	}
	out = &b.out[b.slot]
	b.slot = 1 - b.slot
	if !s.ordered && out.record.feedback {
		builder_set_lead(s, k)
	}
	if !s.ordered || k == s.lead {
		builder_set_spawn(s, k)
	}
	scout_poke(s)
	return out, k, nil
}

// Sends the scout to its next frame if it is idle and not far enough ahead.
@(private = "file")
scout_poke :: proc(s: ^Builder_Set) {
	sc := &s.scout
	if s.pool == nil || sc.failed || om.pool_job_running(&sc.job) {
		return
	}
	om.pool_join(&sc.job)
	sc.frame = max(sc.frame + SCOUT_STEP, s.next)
	if sc.frame < min(s.next + SCOUT_AHEAD, s.end) {
		om.pool_spawn(s.pool, &sc.job, runtime.heap_allocator())
	} else {
		sc.frame -= SCOUT_STEP
	}
}

@(private = "file")
scout_task :: proc(job: ^om.Pool_Job) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	sc := container_of(job, Scout, "job")
	run := sc.run
	if !sc.ready {
		if script.load(&sc.script, run.script_path, run.script_args, run.media, run.shared, run.script_props) != nil {
			sc.failed = true
			return
		}
		if om.renderer_init(&sc.renderer, &sc.script.video, run.media, run.scale, nil, recording = true) != nil {
			sc.failed = true
			return
		}
		sc.ready = true
	}
	om.prefetch_frame_images(&sc.renderer, sc.frame)
}

@(private = "file")
builder_task :: proc(job: ^om.Pool_Job) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	b := container_of(job, Builder, "job")
	run := b.run
	if !b.ready && !builder_setup(b) {
		// Later frames wait for this one's turn.
		builder_turn(run, b.frame)
		return
	}
	out := &b.out[b.slot]
	r := &b.renderer
	r.pool = b.pool
	om.record_frame(r, b.frame, &out.record)
	if !run.software {
		return
	}
	builder_turn(run, b.frame, &b.player, &out.record)
	om.play_frame_draw(&b.player, &out.record)
	pixels := b.software.pixels
	if run.png_dir != "" {
		path := fmt.tprintf("%s/%06d.png", run.png_dir, b.frame)
		out.png_failed = write_png(path, pixels, r.width, r.height) != nil
	} else {
		enc.rgba_to_i420(pixels, int(r.width), int(r.height), out.i420)
	}
}

// Applies a CPU record's image work and fetches its clip frames; with video
// clips, once every earlier frame has (frames are spawned in order, so the
// wait is for tasks already running).
@(private = "file")
builder_turn :: proc(run: ^Build_Run, frame: int, p: ^om.Frame_Player = nil, rec: ^om.Frame_Record = nil) {
	if !run.video_turns {
		if p != nil {
			om.play_frame_images(p, rec)
		}
		return
	}
	mine := u32(frame - run.start)
	for {
		turn := sync.atomic_load(&run.turn)
		if u32(turn) == mine {
			break
		}
		sync.futex_wait(&run.turn, u32(turn))
	}
	if p != nil {
		om.play_frame_images(p, rec)
	}
	sync.atomic_store(&run.turn, sync.Futex(mine + 1))
	sync.futex_broadcast(&run.turn)
}

// Loads the script and prepares the renderer (a builder's first task).
@(private = "file")
builder_setup :: proc(b: ^Builder) -> bool {
	if b.failure.code != .None {
		return false
	}
	run := b.run
	if script.load(&b.script, run.script_path, run.script_args, run.media, run.shared, run.script_props) != nil {
		b.failure = {code = .Script, script = b.script.failure}
		return false
	}
	if err := om.renderer_init(&b.renderer, &b.script.video, run.media, run.scale, nil, recording = true); err != nil {
		b.failure = {code = .Renderer, render = err}
		return false
	}
	b.renderer.plays_on_gpu = !run.software
	if run.software {
		vg.software_backend_init(&b.software)
		om.frame_player_init(&b.player, vg.software_backend(&b.software), run.media, nil)
		if run.png_dir == "" {
			for &o in b.out {
				o.i420 = make([]u8, enc.i420_size(int(b.renderer.width), int(b.renderer.height)))
			}
		}
	}
	b.ready = true
	return true
}

// ---- PNG writing ------------------------------------------------------------------

// A frame read back from the GPU, written as a PNG by a pool task.
Png_Job :: struct {
	job:    om.Pool_Job,
	pixels: []u8,
	width:  u32,
	height: u32,
	path:   string,
	failed: bool,
}

// Writes `pixels` (taken) to `path` (taken) on the pool, once the job's
// previous file is written.
png_job_start :: proc(j: ^Png_Job, pixels: []u8, w, h: u32, path: string, pool: ^thread.Pool) {
	om.pool_join(&j.job)
	j.job.procedure = png_task
	delete(j.pixels)
	delete(j.path)
	j.pixels, j.width, j.height, j.path = pixels, w, h, path
	om.pool_spawn(pool, &j.job, runtime.heap_allocator())
}

@(private = "file")
png_task :: proc(job: ^om.Pool_Job) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	j := container_of(job, Png_Job, "job")
	j.failed = write_png(j.path, j.pixels, j.width, j.height) != nil
}

png_jobs_destroy :: proc(jobs: []Png_Job) {
	for &j in jobs {
		om.pool_join(&j.job)
		delete(j.pixels)
		delete(j.path)
	}
}
