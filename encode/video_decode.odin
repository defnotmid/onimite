package onimite_encode

import "core:mem"
import "core:reflect"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import movie "deps:odecs/codec/movie"
import om "../onimite"

// Video clip decoding for onimite' `Video_Source`: one background thread per
// clip owns an odecs `movie.Reader` and fills a small ring of frames ahead
// of the requested time, as the decoder's planes (GPU renders convert them
// on the GPU; software ones with `to_rgba`). Requests take frames from the ring without
// decoding on the caller's thread; a request outside what the ring can
// reach soon restarts the thread at the new time (the latest request wins,
// checked between frames).

CLIP_RING_SLOTS :: 6
// A request this far past the newest decoded frame seeks instead of
// decoding forward to it.
SEEK_AHEAD_SECONDS :: 1.0
// A blocked request with no progress this long restarts decoding at its time.
BLOCK_RESEEK :: 2 * time.Second

Video_Decoders :: struct {
	mutex:   sync.Mutex,
	// Stable pointers: workers are shared with their threads.
	workers: [dynamic]^Clip_Worker,
	// Decode with odecs' native codecs rather than Vulkan Video. Backward
	// seeks cost ~5 ms native against 27-40 ms on Vulkan, so interactive
	// previews set it; exports keep hardware decoding. Read when a clip's
	// thread starts.
	native:  bool,
}

Clip_Slot_State :: enum u8 {
	Empty,
	Ready,
	Leased,
}

// One clip. Fields under "shared" are guarded by `mutex`; the reader and
// buffers it decodes into belong to the thread.
Clip_Worker :: struct {
	// The opener's allocator; the decode thread allocates with it too, so
	// whoever frees (the opener, at destroy) frees what the thread made.
	allocator:  mem.Allocator,
	path:       string,
	owner:      ^Video_Decoders,
	info:       movie.Video_Info,
	format:     om.Video_Format,
	frame_dur:  f64,
	reader:     movie.Reader,
	thread:     ^thread.Thread,

	// shared
	mutex:      sync.Mutex,
	work:       sync.Cond, // wakes the thread
	ready:      sync.Cond, // wakes waiting requests
	target:     f64,
	generation: u64,
	stop:       bool,
	eos:        bool, // decoded to the end since the last seek
	// A seek is asked for or decoding and hasn't landed a frame yet, and
	// the time it seeks to. Requests just after it wait for it rather than
	// restart it: a seek off a keyframe takes longer than a preview frame,
	// and restarting it on every request would never land one.
	seeking:    bool,
	seek_to:    f64,
	failed:     bool,
	failure:    om.Video_Failure,
	// The ring: parallel arrays.
	state:      [CLIP_RING_SLOTS]Clip_Slot_State,
	time:       [CLIP_RING_SLOTS]f64, // the frame shows over [time, end)
	seconds:    [CLIP_RING_SLOTS]f64, // its own timestamp
	end:        [CLIP_RING_SLOTS]f64,
	// The end is the next frame's time (or the clip's end), not a guess.
	final:      [CLIP_RING_SLOTS]bool,
	index:      [CLIP_RING_SLOTS]int,
	// Each slot's planes (Y', Cb, Cr, alpha) in its own buffer, made on
	// its first frame.
	buffers:    [CLIP_RING_SLOTS][]u8,
	planes:     [CLIP_RING_SLOTS][4][]u8,
	leased:     int, // slot lent to the caller, or -1
}

video_decoders_init :: proc(d: ^Video_Decoders, native := false) {
	d.workers = make([dynamic]^Clip_Worker)
	d.native = native
}

// Stops every decode thread and frees the clips.
video_decoders_destroy :: proc(d: ^Video_Decoders) {
	for w in d.workers {
		if w.thread != nil {
			sync.mutex_lock(&w.mutex)
			w.stop = true
			sync.cond_broadcast(&w.work)
			sync.mutex_unlock(&w.mutex)
			thread.join(w.thread)
			thread.destroy(w.thread)
		}
		movie.close_reader(&w.reader)
		for b in w.buffers {
			delete(b)
		}
		delete(w.path)
		free(w)
	}
	delete(d.workers)
	d^ = {}
}

// The `Video_Source` for onimite' media.
video_source :: proc(d: ^Video_Decoders) -> om.Video_Source {
	return {data = d, open = vs_open, request = vs_request, release = vs_release, prefetch = vs_prefetch, to_rgba = vs_to_rgba}
}

@(private = "file")
vs_open :: proc(data: rawptr, path: string) -> (clip: int, info: om.Video_Info, why: om.Video_Failure, err: om.Error) {
	d := (^Video_Decoders)(data)
	w := new(Clip_Worker)
	w.allocator = context.allocator
	w.path = strings.clone(path)
	w.owner = d
	w.leased = -1
	cfg := movie.Reader_Config {
		preference          = .Native if d.native else .Automatic,
		// ovg composites premultiplied, and SkSL children `.eval` it.
		premultiplied_alpha = true,
		format              = .Planar,
	}
	if e := movie.open_reader(&w.reader, path, cfg); e != .None {
		why = decode_failure(e, w.reader.error_detail)
		movie.close_reader(&w.reader)
		delete(w.path)
		free(w)
		return -1, {}, why, why.code
	}
	if w.reader.video_index < 0 {
		movie.close_reader(&w.reader)
		delete(w.path)
		free(w)
		return -1, {}, {code = .No_Video_Track}, .No_Video_Track
	}
	v := w.reader.video
	w.info = v
	w.format = clip_format(&w.reader, path, cfg)
	fps := f64(v.fps_num) / f64(max(v.fps_den, 1)) if v.fps_num > 0 else 30
	w.frame_dur = 1 / fps
	sync.mutex_lock(&d.mutex)
	clip = len(d.workers)
	append(&d.workers, w)
	sync.mutex_unlock(&d.mutex)
	return clip, {v.width, v.height, v.duration, fps, v.frame_count, v.rotation, w.format}, {}, nil
}

// How the clip's planes read. The header says it all except, for VP9, the
// bit depth and, with alpha, whether colour is premultiplied by it: then the
// first frame is decoded to see, and the reader opened again.
@(private = "file")
clip_format :: proc(r: ^movie.Reader, path: string, cfg: movie.Reader_Config) -> om.Video_Format {
	v := r.video
	f := om.Video_Format {
		bit_depth     = v.bit_depth,
		monochrome    = v.chroma == .Monochrome,
		alpha         = v.has_alpha,
		matrix_coeffs = v.color.matrix_coeffs,
		transfer      = v.color.transfer,
		primaries     = v.color.primaries,
		full_range    = v.color.full_range,
	}
	#partial switch v.chroma {
	case .YUV420:
		f.shift_x, f.shift_y = 1, 1
	case .YUV422:
		f.shift_x = 1
	}
	if v.bit_depth == 0 || v.has_alpha {
		if frame, err := movie.next_frame(r); err == .None {
			p := frame.planar
			f.bit_depth = p.bit_depth
			f.alpha = len(p.alpha) > 0
			f.alpha_premultiplied = p.alpha_premultiplied
		}
		movie.close_reader(r)
		_ = movie.open_reader(r, path, cfg)
	}
	f.bit_depth = max(f.bit_depth, 8)
	f.wide = f.bit_depth > 8
	return f
}

// The CPU conversion (software renders): odecs' own, from the planes.
@(private = "file")
vs_to_rgba :: proc(data: rawptr, frame: om.Video_Frame, out: []u8) {
	f := frame.format
	bytes := 2 if f.wide else 1
	p := movie.Planar {
		width               = frame.width,
		height              = frame.height,
		bit_depth           = f.bit_depth,
		storage_bits        = 8 * bytes,
		color               = {primaries = f.primaries, transfer = f.transfer, matrix_coeffs = f.matrix_coeffs, full_range = f.full_range},
		alpha_premultiplied = f.alpha_premultiplied,
		chroma              = .Monochrome if f.monochrome else .YUV444 if f.shift_x == 0 else .YUV422 if f.shift_y == 0 else .YUV420,
	}
	for i in 0 ..< 3 {
		p.planes[i] = frame.planes[i]
		w, _ := om.video_plane_size(f, frame.width, frame.height, i)
		p.strides[i] = w * bytes
	}
	p.alpha = frame.planes[3]
	p.alpha_stride = frame.width * bytes
	movie.planar_to_rgba(p, out, premultiplied = true)
}

// odecs' error as the core's failure: its name and detail (static strings).
@(private = "file")
decode_failure :: proc(e: movie.Error, detail: string) -> om.Video_Failure {
	return {code = .Video_Decode, cause = reflect.enum_string(e), detail = detail}
}

@(private = "file")
worker_of :: proc(d: ^Video_Decoders, clip: int) -> ^Clip_Worker {
	sync.mutex_lock(&d.mutex)
	defer sync.mutex_unlock(&d.mutex)
	if clip < 0 || clip >= len(d.workers) {
		return nil
	}
	return d.workers[clip]
}

// The ready slot showing time `t`, or -1. With `exact`, only a frame whose
// end is known (the next frame is decoded): until then a guessed end could
// claim a time the next frame shows, depending on how far decoding got.
// Call with the mutex held.
@(private = "file")
slot_at :: proc(w: ^Clip_Worker, t: f64, exact := false) -> int {
	last := -1
	for s in 0 ..< CLIP_RING_SLOTS {
		if w.state[s] == .Empty {
			continue
		}
		if t >= w.time[s] && t < w.end[s] && (w.final[s] || !exact) {
			return s
		}
		if last < 0 || w.time[s] > w.time[last] {
			last = s
		}
	}
	// The clip's final frame stays on screen through its end.
	if w.eos && last >= 0 && t >= w.time[last] {
		return last
	}
	return -1
}

// Restarts decoding at `t`. Call with the mutex held.
@(private = "file")
seek_locked :: proc(w: ^Clip_Worker, t: f64) {
	w.generation += 1
	w.seeking = true
	w.seek_to = t
}

// Moves the thread's target to `t`, restarting it if the ring can't reach
// `t` soon. Starts the thread on first use. Call with the mutex held.
@(private = "file")
retarget :: proc(w: ^Clip_Worker, t: f64) {
	w.target = t
	if slot_at(w, t) < 0 {
		lo, hi := max(f64), min(f64)
		any := false
		for s in 0 ..< CLIP_RING_SLOTS {
			if w.state[s] != .Empty {
				lo = min(lo, w.time[s])
				hi = max(hi, w.end[s])
				any = true
			}
		}
		far := !any || t < lo || t > hi + SEEK_AHEAD_SECONDS || w.eos
		coming := w.seeking && t >= w.seek_to && t <= w.seek_to + SEEK_AHEAD_SECONDS
		if far && !coming {
			seek_locked(w, t)
		}
	}
	if w.thread == nil {
		w.thread = thread.create_and_start_with_poly_data(w, worker_run)
	}
	sync.cond_broadcast(&w.work)
}

@(private = "file")
vs_prefetch :: proc(data: rawptr, clip: int, seconds: f64) {
	w := worker_of((^Video_Decoders)(data), clip)
	if w == nil {
		return
	}
	sync.mutex_lock(&w.mutex)
	retarget(w, seconds)
	sync.mutex_unlock(&w.mutex)
}

@(private = "file")
vs_request :: proc(data: rawptr, clip: int, seconds: f64, wait: om.Video_Wait) -> (f: om.Video_Frame) {
	w := worker_of((^Video_Decoders)(data), clip)
	if w == nil {
		return
	}
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)
	release_locked(w)
	retarget(w, seconds)
	s := slot_at(w, seconds, wait == .Block)
	exact := s >= 0
	if s < 0 && wait == .Block {
		for s < 0 && !w.failed {
			if !sync.cond_wait_with_timeout(&w.ready, &w.mutex, BLOCK_RESEEK) {
				// No frame for this time arrived: restart decoding at it rather
				// than wait on a ring that can't reach it.
				seek_locked(w, seconds)
				sync.cond_broadcast(&w.work)
			}
			s = slot_at(w, seconds, true)
		}
		exact = s >= 0
	} else if s < 0 {
		// The nearest decoded frame: the latest at or before `seconds`, else
		// the earliest after it.
		for k in 0 ..< CLIP_RING_SLOTS {
			if w.state[k] == .Empty {continue}
			if s < 0 {
				s = k
				continue
			}
			before, best_before := w.time[k] <= seconds, w.time[s] <= seconds
			switch {
			case before && !best_before:
				s = k
			case before && best_before && w.time[k] > w.time[s]:
				s = k
			case !before && !best_before && w.time[k] < w.time[s]:
				s = k
			}
		}
	}
	if s < 0 {
		return
	}
	w.state[s] = .Leased
	w.leased = s
	return {w.planes[s], w.format, w.info.width, w.info.height, w.index[s], w.seconds[s], exact, true}
}

@(private = "file")
release_locked :: proc(w: ^Clip_Worker) {
	if w.leased >= 0 {
		w.state[w.leased] = .Ready
		w.leased = -1
		// A freed slot may be what the thread waits for.
		sync.cond_broadcast(&w.work)
	}
}

@(private = "file")
vs_release :: proc(data: rawptr, clip: int) {
	w := worker_of((^Video_Decoders)(data), clip)
	if w == nil {
		return
	}
	sync.mutex_lock(&w.mutex)
	release_locked(w)
	sync.mutex_unlock(&w.mutex)
}

// ---- the decode thread ----------------------------------------------------------

@(private = "file")
worker_run :: proc(w: ^Clip_Worker) {
	context.allocator = w.allocator
	// The backend is chosen at the first decode, so this still applies.
	if w.owner.native {
		w.reader.config.preference = .Native
		w.reader.preference = .Native
	}
	seen_gen: u64 = max(u64)
	for {
		sync.mutex_lock(&w.mutex)
		// Work: a seek, or a free slot to prefetch into.
		slot := -1
		for !w.stop {
			if w.generation != seen_gen {
				break
			}
			if !w.eos && !w.failed {
				slot = free_slot(w)
				if slot >= 0 {
					break
				}
			}
			sync.cond_wait(&w.work, &w.mutex)
		}
		if w.stop {
			sync.mutex_unlock(&w.mutex)
			return
		}
		seek := w.generation != seen_gen
		gen := w.generation
		target := w.target
		if seek {
			// Everything decoded so far is from the old position.
			for k in 0 ..< CLIP_RING_SLOTS {
				if w.state[k] == .Ready {
					w.state[k] = .Empty
				}
			}
			w.eos = false
			w.seek_to = target
			slot = free_slot(w)
			seen_gen = gen
		}
		sync.mutex_unlock(&w.mutex)
		if slot < 0 {
			continue
		}

		// Decode without the lock.
		frame: movie.Frame
		err: movie.Error
		if seek {
			frame, err = movie.frame_at(&w.reader, target)
		} else {
			frame, err = movie.next_frame(&w.reader)
		}
		if err == .None {
			slot_fill(w, slot, frame.planar)
		}

		sync.mutex_lock(&w.mutex)
		switch {
		case err == .End_Of_Stream:
			w.eos = true
			w.seeking = false
			// The newest frame lasts to the end of the clip.
			newest := -1
			for k in 0 ..< CLIP_RING_SLOTS {
				if w.state[k] != .Empty && (newest < 0 || w.time[k] > w.time[newest]) {
					newest = k
				}
			}
			if newest >= 0 {
				w.end[newest] = max(w.end[newest], w.info.duration)
				w.final[newest] = true
			}
		case err != .None:
			w.failed = true
			w.seeking = false
			w.failure = decode_failure(err, w.reader.error_detail)
		case w.generation != gen:
		// A newer request moved on; drop this frame.
		case:
			// The previous frame ends where this one starts.
			for k in 0 ..< CLIP_RING_SLOTS {
				if w.state[k] != .Empty && w.index[k] == frame.index - 1 {
					w.end[k] = frame.time
					w.final[k] = true
				}
			}
			w.seeking = false
			w.state[slot] = .Ready
			w.final[slot] = false
			w.time[slot] = frame.time
			if seek {
				// The frame a seek lands on is the one on screen at the target,
				// even when the target precedes its timestamp (before the first
				// frame, or rounding to the nearest tick).
				w.time[slot] = min(frame.time, target)
			}
			w.end[slot] = frame.time + w.frame_dur
			w.index[slot] = frame.index
			w.seconds[slot] = frame.time
		}
		sync.cond_broadcast(&w.ready)
		sync.mutex_unlock(&w.mutex)
	}
}

// A slot to decode into: empty, or ready but already behind the target.
// Call with the mutex held.
@(private = "file")
free_slot :: proc(w: ^Clip_Worker) -> int {
	for k in 0 ..< CLIP_RING_SLOTS {
		if w.state[k] == .Empty {
			return k
		}
	}
	oldest := -1
	for k in 0 ..< CLIP_RING_SLOTS {
		if w.state[k] == .Ready && w.end[k] <= w.target && (oldest < 0 || w.time[k] < w.time[oldest]) {
			oldest = k
		}
	}
	return oldest
}

// Copies a frame's planes into slot `slot` (its buffer made on its first
// frame: every frame of a clip has the same size).
@(private = "file")
slot_fill :: proc(w: ^Clip_Worker, slot: int, p: movie.Planar) {
	sources := [4][]u8{p.planes[0], p.planes[1], p.planes[2], p.alpha}
	size := 0
	for s in sources {
		size += len(s)
	}
	if len(w.buffers[slot]) != size {
		delete(w.buffers[slot])
		w.buffers[slot] = make([]u8, size)
	}
	at := 0
	for s, i in sources {
		w.planes[slot][i] = w.buffers[slot][at:][:len(s)]
		copy(w.planes[slot][i], s)
		at += len(s)
	}
}
