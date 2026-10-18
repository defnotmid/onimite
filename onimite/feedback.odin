package onimite

import "core:math"

import vg "deps:ovg"
import "deps:oksl"

// Feedback buffers of multipass shaders. Each instance (a program and its
// occurrence in the frame, `Shader.instance`) owns a pair of RGBA16F images
// per feedback pass (`Shader_Library.feedback`: every pass but the output,
// and the output too when a pass reads it), sized to the shader's
// resolution (its box in its own units, so the buffers do not depend on the
// output scale), and runs those passes in the graph's order, each rendering
// into one image of its pair while the other holds the last frame's
// output; the output pass (`draw_shader`) reads them last. A pass reads
// this frame's output of an earlier pass, and the last frame's of any.
//
// Frame N of a pass depends on frames 0..N-1 (N is the shader's iFrame),
// so it must not depend on how N was reached:
//
// - An instance starts over (previous outputs read transparent black) when
//   its iFrame is 0, when it was not in the frame before, or when its size
//   changes. Everything else follows from the frames: iFrame, iTime and
//   iTimeDelta come from the timeline.
// - Drawing frames in order needs nothing more. A renderer asked for frame
//   T whose state is not at T - 1 (a range render's first frame, `frame`,
//   a seek) catches up first (`feedback_catch_up`): each instance that is
//   behind runs its feedback passes alone for the frames since its iFrame 0,
//   or since its own state or a checkpoint inside that span, building the
//   frames but drawing nothing else. Recording renderers record those
//   frames as extra records their players play before the frame
//   (`Frame_Record.sims`); direct ones flush each.
// - The preview keeps checkpoints (`feedback_checkpoints`): copies of every
//   instance's buffers each `every` frames, in a byte-budgeted cache (least
//   recently used go first, like the media's image cache), so a seek runs
//   at most `every - 1` frames of feedback passes.
//
// This assumes iFrame counts video frames (scenes do; a frame made up in
// the script may not).

// Frame number meaning "no state".
@(private)
NO_FRAME :: min(int) / 2

// Feedback instances: parallel arrays. `passes` have an image pair each
// (by pass index); `current` is the image of each pair holding the outputs
// of global frame `frame`, and the other one the frame before's when
// `has_last`.
Feedback :: struct {
	key:         [dynamic]u64,
	frame:       [dynamic]int,
	width:       [dynamic]u32,
	height:      [dynamic]u32,
	passes:      [dynamic]Pass_Set,
	images:      [dynamic][oksl.PASS_MAX][2]vg.Image_Id,
	current:     [dynamic]u8,
	has_last:    [dynamic]bool,
	// The last frame drawn whole (every instance in it ran; NO_FRAME before
	// any and after catching up), and whether it had feedback passes.
	drawn:       int,
	drew:        bool,
	// Thumbnails: catch up at most this many frames, from cold buffers,
	// instead of exactly (0).
	warmup:      int,
	// Freed buffer images kept for reuse (parallel arrays, by size), with
	// the frame they were freed at.
	spare:       [dynamic]vg.Image_Id,
	spare_size:  [dynamic][2]u32,
	spare_since: [dynamic]int,
	// While catching up: the instances that run and the frame each starts
	// at (parallel arrays).
	sim_keys:    [dynamic]u64,
	sim_from:    [dynamic]int,
	checkpoints: Feedback_Checkpoints,
	// Copies images (checkpoints): `half4 main(float2 p)` returning the
	// channel's texel.
	copy:        ^oksl.Module,
	copy_prog:   vg.Program_Id,
	copy_cpu:    ^Shader_Cpu,
}

// Copies of instances' buffers at frames `every` apart (parallel arrays).
Feedback_Checkpoints :: struct {
	// 0: none kept.
	every:    int,
	budget:   int,
	bytes:    int,
	tick:     u64,
	frame:    [dynamic]int,
	key:      [dynamic]u64,
	width:    [dynamic]u32,
	height:   [dynamic]u32,
	passes:   [dynamic]Pass_Set,
	images:   [dynamic][oksl.PASS_MAX]vg.Image_Id,
	last_use: [dynamic]u64,
}

// A shader's feedback passes' outputs of this frame and of the last (none
// on the instance's first frame), by pass index, and their size.
Feedback_Outputs :: struct {
	this, last: [oksl.PASS_MAX]vg.Image_Id,
	size:       [3]f32,
}

// The preview's checkpoint interval and budget.
FEEDBACK_CHECKPOINT_EVERY :: 60
FEEDBACK_CHECKPOINT_BUDGET :: 512 << 20

// Spare buffer images unused this many frames are freed.
@(private = "file")
SPARE_FRAMES :: 120

@(private = "file")
COPY_SKSL :: "uniform shader src;\nhalf4 main(float2 p) { return src.eval(p); }\n"

// Keeps checkpoints of the buffers every `every` frames within `budget`
// bytes (0: none).
feedback_checkpoints :: proc(r: ^Renderer, every: int, budget: int = FEEDBACK_CHECKPOINT_BUDGET) {
	cp := &r.shader_state.feedback.checkpoints
	cp.every, cp.budget = every, budget
	checkpoint_evict(r, 0)
}

feedback_destroy :: proc(fb: ^Feedback, c: ^vg.Canvas) {
	for pairs, i in fb.images {
		for pi in fb.passes[i] {
			vg.delete_image(c, pairs[pi][0])
			vg.delete_image(c, pairs[pi][1])
		}
	}
	for id in fb.spare {
		vg.delete_image(c, id)
	}
	cp := &fb.checkpoints
	for ids, i in cp.images {
		for pi in cp.passes[i] {
			vg.delete_image(c, ids[pi])
		}
	}
	if vg.program_id_valid(fb.copy_prog) {
		vg.delete_program(c, fb.copy_prog)
	}
	oksl.destroy(fb.copy)
	free(fb.copy_cpu)
	delete(fb.key)
	delete(fb.frame)
	delete(fb.width)
	delete(fb.height)
	delete(fb.passes)
	delete(fb.images)
	delete(fb.current)
	delete(fb.has_last)
	delete(fb.spare)
	delete(fb.spare_size)
	delete(fb.spare_since)
	delete(fb.sim_keys)
	delete(fb.sim_from)
	delete(cp.frame)
	delete(cp.key)
	delete(cp.width)
	delete(cp.height)
	delete(cp.passes)
	delete(cp.images)
	delete(cp.last_use)
	fb^ = {}
}

// Whether frame `index` has shaders whose passes read a last frame (built
// on `r`, nothing drawn; what building reported is dropped).
frame_has_feedback :: proc(r: ^Renderer, index: int) -> bool {
	build_frame(r, index)
	diagnostics_clear(&r.ctx)
	for node in r.ctx.tree.nodes {
		if n, is_shader := node.kind.(Shader); is_shader && r.ctx.shaders.stateful[n.program] {
			return true
		}
	}
	return false
}

// ---- drawing ----------------------------------------------------------------------

// Runs shader `n`'s feedback passes for this frame, unless they ran
// already, and returns their outputs (none for a program without them);
// false when they can not run.
@(private)
feedback_passes :: proc(r: ^Renderer, n: Shader, g: ^oksl.Pass_Graph, sim: bool) -> (outputs: Feedback_Outputs, ok: bool) {
	passes := r.ctx.shaders.feedback[n.program]
	if passes == {} {
		return {}, true
	}
	fb := &r.shader_state.feedback
	frame := r.ctx.frame.global_index
	bw := u32(clamp(math.round(n.w), 1, 8192))
	bh := u32(clamp(math.round(n.h), 1, 8192))
	i := feedback_instance(r, n.instance, passes, bw, bh)
	if i < 0 {
		return {}, false
	}
	if !sim {
		fb.drew = true
	}
	if fb.frame[i] == frame {
		return feedback_outputs(fb, i), true
	}
	fb.has_last[i] = n.frame > 0 && fb.frame[i] == frame - 1
	fb.current[i] = 1 - fb.current[i]
	fb.frame[i] = NO_FRAME
	outputs = feedback_outputs(fb, i)
	for pi in 0 ..< len(g.passes) {
		if pi not_in passes {
			continue
		}
		prog := shader_program(r, n.program, pi, g.passes[pi].module) or_return
		// Inputs are drawn at the buffer's resolution, like the buffer.
		shader_run_pass(r, n, g, pi, prog, outputs.this[pi], outputs, f32(bw) / n.w, f32(bh) / n.h) or_return
	}
	fb.frame[i] = frame
	if r.ctx.shaders.stateful[n.program] {
		checkpoint_capture(r, i, frame)
	}
	return outputs, true
}

// Instance `i`'s outputs of its frame and of the frame before.
@(private = "file")
feedback_outputs :: proc(fb: ^Feedback, i: int) -> (o: Feedback_Outputs) {
	cur := fb.current[i]
	for pi in fb.passes[i] {
		o.this[pi] = fb.images[i][pi][cur]
		if fb.has_last[i] {
			o.last[pi] = fb.images[i][pi][1 - cur]
		}
	}
	o.size = {f32(fb.width[i]), f32(fb.height[i]), 1}
	return o
}

// The instance `key` with buffers of `w x h` for `passes`, made or resized
// (which starts it over) as needed; -1 if its images can not be made.
@(private = "file")
feedback_instance :: proc(r: ^Renderer, key: u64, passes: Pass_Set, w, h: u32) -> int {
	fb := &r.shader_state.feedback
	i := -1
	for k, j in fb.key {
		if k == key {
			i = j
			break
		}
	}
	if i >= 0 && fb.width[i] == w && fb.height[i] == h && fb.passes[i] == passes {
		return i
	}
	if i >= 0 {
		feedback_release(r, i)
	} else {
		i = len(fb.key)
		append(&fb.key, key)
		append(&fb.frame, NO_FRAME)
		append(&fb.width, 0)
		append(&fb.height, 0)
		append(&fb.passes, Pass_Set{})
		append(&fb.images, [oksl.PASS_MAX][2]vg.Image_Id{})
		append(&fb.current, 0)
		append(&fb.has_last, false)
	}
	fb.frame[i] = NO_FRAME
	fb.width[i], fb.height[i] = w, h
	fb.current[i] = 0
	fb.has_last[i] = false
	for pi in passes {
		for k in 0 ..< 2 {
			id := feedback_image(r, w, h)
			if !vg.image_id_valid(id) {
				feedback_remove(r, i)
				return -1
			}
			fb.images[i][pi][k] = id
			// Made pairs are released with the instance.
			fb.passes[i] += {pi}
		}
	}
	return i
}

// A `w x h` RGBA16F image: a spare one of that size, else a new one.
@(private = "file")
feedback_image :: proc(r: ^Renderer, w, h: u32) -> vg.Image_Id {
	fb := &r.shader_state.feedback
	for size, k in fb.spare_size {
		if size == {w, h} {
			id := fb.spare[k]
			unordered_remove(&fb.spare, k)
			unordered_remove(&fb.spare_size, k)
			unordered_remove(&fb.spare_since, k)
			return id
		}
	}
	id, err := vg.create_image_empty(&r.canvas, w, h, .RGBA16F, {})
	if err != nil {
		report(&r.ctx, .Error, {code = .Shader_Buffer, n = i64(w), m = i64(h), gpu = err})
		return {}
	}
	return id
}

// Moves instance `i`'s images to the spares.
@(private = "file")
feedback_release :: proc(r: ^Renderer, i: int) {
	fb := &r.shader_state.feedback
	for pi in fb.passes[i] {
		for k in 0 ..< 2 {
			if vg.image_id_valid(fb.images[i][pi][k]) {
				append(&fb.spare, fb.images[i][pi][k])
				append(&fb.spare_size, [2]u32{fb.width[i], fb.height[i]})
				append(&fb.spare_since, r.ctx.frame.global_index)
			}
		}
	}
	fb.passes[i] = {}
	fb.images[i] = {}
}

@(private = "file")
feedback_remove :: proc(r: ^Renderer, i: int) {
	fb := &r.shader_state.feedback
	feedback_release(r, i)
	unordered_remove(&fb.key, i)
	unordered_remove(&fb.frame, i)
	unordered_remove(&fb.width, i)
	unordered_remove(&fb.height, i)
	unordered_remove(&fb.passes, i)
	unordered_remove(&fb.images, i)
	unordered_remove(&fb.current, i)
	unordered_remove(&fb.has_last, i)
}

// After a frame drawn whole: instances it did not have are over (they start
// again if they come back), and spares unused for a while go.
@(private)
feedback_end_frame :: proc(r: ^Renderer) {
	fb := &r.shader_state.feedback
	frame := r.ctx.frame.global_index
	fb.drawn = frame
	for i := len(fb.key) - 1; i >= 0; i -= 1 {
		// One frame of slack: the frame before can be drawn again as is.
		if fb.frame[i] != frame && fb.frame[i] != frame - 1 {
			feedback_remove(r, i)
		}
	}
	for k := len(fb.spare) - 1; k >= 0; k -= 1 {
		if abs(frame - fb.spare_since[k]) > SPARE_FRAMES {
			vg.delete_image(&r.canvas, fb.spare[k])
			unordered_remove(&fb.spare, k)
			unordered_remove(&fb.spare_size, k)
			unordered_remove(&fb.spare_since, k)
		}
	}
}

// ---- catching up ------------------------------------------------------------------

// Brings the instances of built frame `index` that are behind up to
// `index - 1` (see the top of the file) and builds `index` again. A
// recording renderer records the frames run into `rec.sims`; a direct one
// flushes each.
@(private)
feedback_catch_up :: proc(r: ^Renderer, index: int, rec: ^Frame_Record = nil) {
	fb := &r.shader_state.feedback
	if fb.drawn == index - 1 || fb.drawn == index {
		return
	}
	lib := &r.ctx.shaders
	// Restores may copy on the CPU before anything is drawn.
	r.shader_state.pool = r.pool
	clear(&fb.sim_keys)
	clear(&fb.sim_from)
	start := index
	for node in r.ctx.tree.nodes {
		n, is_shader := node.kind.(Shader)
		if !is_shader || !lib.stateful[n.program] || n.frame <= 0 {
			continue
		}
		i := -1
		for k, j in fb.key {
			if k == n.instance {
				i = j
			}
		}
		if i >= 0 && (fb.frame[i] == index - 1 || fb.frame[i] == index) {
			continue
		}
		// Since its iFrame 0, or its own state or a checkpoint inside that
		// span: every state a renderer reaches is the one drawing in order
		// reaches.
		from := max(index - n.frame, 0)
		if fb.warmup > 0 {
			from = max(from, index - fb.warmup)
		}
		if i >= 0 && fb.frame[i] >= from && fb.frame[i] < index {
			from = fb.frame[i] + 1
		} else if c := checkpoint_find(fb, n.instance, from, index - 1); c >= 0 && checkpoint_restore(r, c, lib.feedback[n.program]) {
			from = fb.checkpoints.frame[c] + 1
		}
		append(&fb.sim_keys, n.instance)
		append(&fb.sim_from, from)
		start = min(start, from)
	}
	for g in start ..< index {
		build_frame(r, g)
		diagnostics_clear(&r.ctx)
		draw_sim(r)
		if r.recording {
			if rec.sim_count == len(rec.sims) {
				append(&rec.sims, Frame_Record{})
			}
			sim := &rec.sims[rec.sim_count]
			rec.sim_count += 1
			vg.canvas_take(&r.canvas, &sim.canvas)
			sim.frame = g
			r.video_uploads, sim.video = sim.video, r.video_uploads
			clear(&r.video_uploads)
		} else {
			r.software.pool = r.pool
			vg.flush(&r.canvas)
		}
	}
	if start < index {
		fb.drawn = NO_FRAME
		build_frame(r, index)
	}
}

// The feedback passes of the instances catching up that start at or
// before the built frame.
@(private = "file")
draw_sim :: proc(r: ^Renderer) {
	fb := &r.shader_state.feedback
	lib := &r.ctx.shaders
	frame := r.ctx.frame.global_index
	c := &r.canvas
	vg.set_size(c, r.width, r.height)
	vg.reset(c)
	vg.layer_stack_begin(&r.layers, c, r.width, r.height)
	for node in r.ctx.tree.nodes {
		n, is_shader := node.kind.(Shader)
		if !is_shader || lib.feedback[n.program] == {} {
			continue
		}
		for k, j in fb.sim_keys {
			if k == n.instance && fb.sim_from[j] <= frame {
				draw_shader(r, n, sim = true)
			}
		}
	}
	vg.layer_stack_end(&r.layers, c)
}

// ---- checkpoints ------------------------------------------------------------------

// Copies instance `i`'s outputs of `frame` if checkpoints are kept there.
@(private = "file")
checkpoint_capture :: proc(r: ^Renderer, i: int, frame: int) {
	fb := &r.shader_state.feedback
	cp := &fb.checkpoints
	if cp.every <= 0 || frame % cp.every != 0 || fb.warmup > 0 {
		return
	}
	key := fb.key[i]
	for f, k in cp.frame {
		if f == frame && cp.key[k] == key && cp.width[k] == fb.width[i] && cp.height[k] == fb.height[i] {
			return
		}
	}
	w, h := fb.width[i], fb.height[i]
	passes := fb.passes[i]
	ids: [oksl.PASS_MAX]vg.Image_Id
	for pi in passes {
		id, err := vg.create_image_empty(&r.canvas, w, h, .RGBA16F, {})
		if err != nil || !feedback_copy(r, id, fb.images[i][pi][fb.current[i]], w, h) {
			for d in ids {
				if vg.image_id_valid(d) {
					vg.delete_image(&r.canvas, d)
				}
			}
			if err == nil {
				vg.delete_image(&r.canvas, id)
			}
			return
		}
		ids[pi] = id
	}
	cp.tick += 1
	append(&cp.frame, frame)
	append(&cp.key, key)
	append(&cp.width, w)
	append(&cp.height, h)
	append(&cp.passes, passes)
	append(&cp.images, ids)
	append(&cp.last_use, cp.tick)
	cp.bytes += card(passes) * int(w * h) * 8
	checkpoint_evict(r, 1)
}

// Frees the least recently used checkpoints until the rest fit the budget,
// keeping at least `keep` (the newest).
@(private = "file")
checkpoint_evict :: proc(r: ^Renderer, keep: int) {
	cp := &r.shader_state.feedback.checkpoints
	for cp.bytes > cp.budget && len(cp.frame) > keep {
		oldest := 0
		for t, k in cp.last_use {
			if t < cp.last_use[oldest] {
				oldest = k
			}
		}
		for pi in cp.passes[oldest] {
			vg.delete_image(&r.canvas, cp.images[oldest][pi])
		}
		cp.bytes -= card(cp.passes[oldest]) * int(cp.width[oldest] * cp.height[oldest]) * 8
		ordered_remove(&cp.frame, oldest)
		ordered_remove(&cp.key, oldest)
		ordered_remove(&cp.width, oldest)
		ordered_remove(&cp.height, oldest)
		ordered_remove(&cp.passes, oldest)
		ordered_remove(&cp.images, oldest)
		ordered_remove(&cp.last_use, oldest)
	}
}

// The latest checkpoint of instance `key` in frames `from ..= to`, or -1.
@(private = "file")
checkpoint_find :: proc(fb: ^Feedback, key: u64, from, to: int) -> int {
	cp := &fb.checkpoints
	best := -1
	for f, k in cp.frame {
		if cp.key[k] == key && f >= from && f <= to && (best < 0 || f > cp.frame[best]) {
			best = k
		}
	}
	return best
}

// Puts checkpoint `c` back as its instance's state (buffers for `passes`).
@(private = "file")
checkpoint_restore :: proc(r: ^Renderer, c: int, passes: Pass_Set) -> bool {
	fb := &r.shader_state.feedback
	cp := &fb.checkpoints
	if cp.passes[c] != passes {
		return false
	}
	w, h := cp.width[c], cp.height[c]
	i := feedback_instance(r, cp.key[c], passes, w, h)
	if i < 0 {
		return false
	}
	for pi in passes {
		if !feedback_copy(r, fb.images[i][pi][0], cp.images[c][pi], w, h) {
			fb.frame[i] = NO_FRAME
			return false
		}
	}
	cp.tick += 1
	cp.last_use[c] = cp.tick
	fb.current[i] = 0
	fb.frame[i] = cp.frame[c]
	return true
}

// Copies `src` into `dst` (both `w x h` RGBA16F) with the copy program.
@(private = "file")
feedback_copy :: proc(r: ^Renderer, dst, src: vg.Image_Id, w, h: u32) -> bool {
	fb := &r.shader_state.feedback
	if fb.copy == nil {
		m, _, ok := oksl.compile(COPY_SKSL)
		fb.copy = m
		if !ok {
			return false
		}
		prog, err := shader_register(r, m, &fb.copy_cpu)
		if err != nil {
			return false
		}
		fb.copy_prog = prog
	}
	if !vg.program_id_valid(fb.copy_prog) {
		return false
	}
	block := make([]u8, fb.copy.block_size, context.temp_allocator)
	size := [3]f32{f32(w), f32(h), 1}
	oksl.write_input(fb.copy, block, .Resolution, size[:])
	oksl.write_input(fb.copy, block, .Channel_Resolution, size[:], 0)
	return vg.run_program(&r.canvas, fb.copy_prog, dst, block, {src}) == nil
}
