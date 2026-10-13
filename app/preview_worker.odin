package onimite_app

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import om "../onimite"
import enc "../encode"
import script "../script"
import vg "deps:ovg"
import vgsdl "deps:ovg/sdlgpu"
import sdl "vendor:sdl3"

// The preview's render worker: one thread owning the Lua state, the media,
// the onimite renderer and the ovg canvas (SDL_GPU on the window's
// device). It renders the latest requested frame into one of three
// offscreen textures and publishes it; the UI thread samples the newest
// published texture and never waits on Lua or a fence.
//
// The UI and the worker share only the mailbox below: the request (latest
// wins, so scrubbing drops stale frames) and what was published. Script and
// media (re)loads run on the worker too; the swap to a new script happens
// between two renders.
//
// When no request is waiting the worker does idle work in small steps, so a
// new request waits at most one step: waveform pyramids, the Watch's rows,
// the media table, then timeline thumbnails (only while the UI is not playing or scrubbing,
// or while frames leave slack), see worker_idle.

SLOT_COUNT :: 3
// Timeline thumbnails: rendered this high, at most this many cached.
THUMB_HEIGHT :: 160
THUMB_MAX :: 192
// Thumbnails render during playback only when playhead frames take less.
IDLE_SLACK_MS :: 4.0
// Attempts at a thumbnail whose video clip frames were still decoding
// (each after a short wait a request ends).
THUMB_TRIES :: 12
// While paused, thumbnails wait this long after the last request, so a key
// pressed during a pause rarely finds a thumbnail in the way.
THUMB_QUIET :: 150 * time.Millisecond
// Media image thumbnails filled per idle step, per pool thread (each may
// decode its image).
MEDIA_THUMBS_PER_STEP :: 1

// What a load is doing, for the window's loading state.
Load_Phase :: enum u8 {
	Script,
	Media,
	Timeline,
}

// What the UI asks for.
Render_Request :: struct {
	frame:        int,
	scale:        f32,
	// Bumped by Script_Reload; the worker reloads when it differs from the
	// generation it loaded.
	reload:       u64,
	reload_media: bool,
	// When the UI asked (for the request-to-publish latency).
	asked:        time.Tick,
}


// A finished timeline thumbnail: the frame and its texture (owned by the
// worker; never written again while published).
Preview_Thumb :: struct {
	frame:   int,
	texture: ^sdl.GPUTexture,
}

// Shared between the UI and the worker; every field is read and written
// with `mutex` held, and holds are short (copies only).
Mailbox :: struct {
	mutex:            sync.Mutex,
	cond:             sync.Cond,
	quit:             bool,
	// The request and a counter the UI bumps on every change.
	request:          Render_Request,
	request_seq:      u64,
	// The slot the UI is sampling; the worker never renders into it.
	displayed_slot:   int,
	// Asked by the UI without a render: the UI is playing or scrubbing (idle
	// work holds back), the thumbnail frames the timeline shows (nearest
	// first), the thumbnail generation it has taken, and the bookmark to
	// write.
	busy:             bool,
	thumb_wanted:     [dynamic]int,
	thumb_wanted_seq: u64,
	thumb_ack:        u64,
	bookmark:         int,
	bookmark_seq:     u64,

	// Published by the worker.
	published_seq:    u64,
	slot:             int, // index of the newest finished frame's texture (-1: none yet)
	slot_texture:     ^sdl.GPUTexture,
	slot_frame:       int,
	slot_size:        [2]u32,
	render_ms:        f64,
	latency_ms:       f64, // request (or the end of a load) to publish of the newest frame
	rendering:        bool, // a frame is being rendered (requested frame not on screen yet)
	loading:          bool, // the script or media is (re)loading
	load_phase:       Load_Phase,
	load_files:       int, // files in the media directory being loaded
	load_began:       time.Tick,
	timeline_seq:     u64, // bumped with every load that changes the timeline
	timeline:         Preview_Timeline, // owned
	// The bookmark file's frame, read on the script's first load (-1: none).
	bookmark_loaded:  int,
	// Why the last load failed (owned; `.None` after a good one), bumping
	// `reload_seq`.
	reload_failure:   script.Failure,
	reload_seq:       u64,
	device_name:      string, // owned
	watch_seq:        u64,
	watch:            Watch_Table,
	waves_seq:        u64,
	waves:            Wave_Table,
	media_seq:        u64,
	media:            Media_Table,
	thumbs_seq:       u64,
	thumb_gen:        u64, // bumped by every load; thumbnails of older generations are gone
	thumb_size:       [2]u32,
	thumbs:           [dynamic]Preview_Thumb, // sorted by frame
	// Set by a pool job when a clip it built lands (the worker drains it).
	clips_landed:     bool,
}

mailbox_destroy :: proc(mb: ^Mailbox) {
	preview_timeline_destroy(&mb.timeline)
	script.failure_destroy(&mb.reload_failure)
	delete(mb.device_name)
	delete(mb.thumb_wanted)
	watch_table_destroy(&mb.watch)
	wave_table_destroy(&mb.waves)
	media_table_destroy(&mb.media)
	delete(mb.thumbs)
}

@(private)
Slot :: struct {
	texture: ^sdl.GPUTexture,
	size:    [2]u32,
}

// A cached thumbnail on the worker. `exact` is false when a video clip
// frame in it was still decoding.
@(private)
Thumb_Entry :: struct {
	frame:   int,
	texture: ^sdl.GPUTexture,
	exact:   bool,
	tries:   int,
	// Drawn without sound still being built: drawn again when it lands.
	audio:   bool,
}

// Owned by the worker thread.
Render_Worker :: struct {
	mb:             ^Mailbox,
	audio:          ^Audio_Shared,
	device:         ^sdl.GPUDevice,
	software:       bool,
	// Bytes of decoded images the media keeps (--image-cache).
	image_budget:   int,
	script_path:    string,
	// Borrowed from the app's script; outlives the worker.
	script_args:    []string,
	script_props:   []string,
	media_dir:      string,
	// The app's video decode threads (thread-safe; shared by every media).
	video:          ^enc.Video_Decoders,
	// The app's task pool, borrowed for media decoding: while the preview
	// runs, only the worker's loads use it.
	pool:           ^thread.Pool,
	thread:         ^thread.Thread,

	// Heap allocated: a Script must keep its address while loaded.
	script:         ^script.Script,
	media:          ^om.Media,
	renderer:       om.Renderer,
	renderer_ok:    bool,
	gpu:            vgsdl.SDL_Backend,
	gpu_ok:         bool,
	slots:          [SLOT_COUNT]Slot,
	loaded:         u64, // reload generation of the script in use
	ever_loaded:    bool,
	handled_seq:    u64,
	last_slot:      int,
	last_request:   Render_Request,
	last_ms:        f64,
	request_tick:   time.Tick, // when the last request was taken
	// ONIMITE_CLIP_LOG: print the video clip frames each published frame shows.
	log_clips:      bool,
	bookmark_seq:   u64,

	// The loaded video's timeline (false: it does not resolve) and its
	// tracks placed on it, again as clips land.
	timeline:       om.Timeline,
	timeline_ok:    bool,
	placed:         om.Placed_Audio,
	// Idle work (worker_idle), all reset by a load.
	// Problems since the load, and the Watch's rows, made again when they
	// change (`watch_dirty`) or the frames reach more animate keys.
	findings:       Finding_Table,
	watch:          Watch_Table,
	watch_dirty:    bool,
	watch_keys:     int,
	// Why the last load failed (owned; "" after a good one).
	load_error:     string,
	waves:          Wave_Builder,
	media_table:    Media_Table,
	media_dirty:    bool,
	// The clips the script defers, built on the pool or (no pool) here, one
	// per idle step (nil: none or all drained), and earlier loads' builds
	// still finishing a clip.
	clips:          ^Clip_Builds,
	clips_retired:  [dynamic]^Clip_Builds,
	clips_began:    time.Tick,
	// The last frame drawn without sound still being built.
	frame_audio:    bool,
	// ONIMITE_DEBUG: the first frames after a load are timed.
	debug:          bool,
	loaded_at:      time.Tick,
	frames_since:   int,
	frames:         int, // the loaded video's length
	// Thumbnails: their own renderer and canvas at THUMB_HEIGHT, the cache
	// (sorted by frame), free textures, and textures of older generations
	// that become free once the UI has taken the current one.
	thumb:          om.Renderer,
	thumb_ok:       bool,
	thumb_gpu:      vgsdl.SDL_Backend,
	thumb_gpu_ok:   bool,
	thumbs:         [dynamic]Thumb_Entry,
	thumb_free:     [dynamic]^sdl.GPUTexture,
	thumb_retired:  [dynamic]^sdl.GPUTexture,
	thumb_gen:      u64,
	thumb_size:     [2]u32,
	thumb_wanted:   [dynamic]int,
	wanted_seq:     u64,
	// Thumbnails draw video clips from their own decoders (one reader per
	// clip, opened when the thumbnail renderer is made), so they never pull
	// the playhead's decoders to another time. `thumb_videos` is their clip
	// table, which the thumbnail renderer reads in place of the media's
	// (everything else comes from the worker's media); the clips are
	// reopened when the media is replaced.
	thumb_video:    enc.Video_Decoders,
	thumb_videos:   om.Video_Clips,
	thumb_clips_of: u64, // media_gen the thumbnail clips were opened for
	media_gen:      u64,
}

worker_start :: proc(w: ^Render_Worker) {
	w.loaded = max(u64) // forces the first load
	w.last_slot = -1
	w.thread = thread.create_and_start_with_poly_data(w, worker_main, context)
}

// Asks the worker to stop and waits for it; it releases everything it
// created on the device first.
worker_stop :: proc(w: ^Render_Worker) {
	if w.thread == nil {
		return
	}
	sync.mutex_lock(&w.mb.mutex)
	w.mb.quit = true
	sync.cond_signal(&w.mb.cond)
	sync.mutex_unlock(&w.mb.mutex)
	thread.join(w.thread)
	thread.destroy(w.thread)
	w.thread = nil
	delete(w.script_path)
	delete(w.media_dir)
}

@(private = "file")
worker_main :: proc(w: ^Render_Worker) {
	defer worker_release(w)
	for {
		sync.mutex_lock(&w.mb.mutex)
		for !w.mb.quit && w.mb.request_seq == w.handled_seq && w.mb.bookmark_seq == w.bookmark_seq {
			ready, retry := worker_idle_ready(w)
			if ready {
				break
			}
			if retry > 0 {
				sync.cond_wait_with_timeout(&w.mb.cond, &w.mb.mutex, retry)
			} else {
				sync.cond_wait(&w.mb.cond, &w.mb.mutex)
			}
		}
		if w.mb.quit {
			sync.mutex_unlock(&w.mb.mutex)
			return
		}
		if w.mb.bookmark_seq != w.bookmark_seq {
			w.bookmark_seq = w.mb.bookmark_seq
			frame := w.mb.bookmark
			sync.mutex_unlock(&w.mb.mutex)
			bookmark_write(w.script_path, frame)
			free_all(context.temp_allocator)
			continue
		}
		if w.mb.request_seq == w.handled_seq {
			busy := w.mb.busy
			sync.mutex_unlock(&w.mb.mutex)
			worker_idle(w, busy)
			free_all(context.temp_allocator)
			continue
		}
		req := w.mb.request
		w.handled_seq = w.mb.request_seq
		w.request_tick = time.tick_now()
		if req.reload != w.loaded {
			w.mb.loading = true
		} else {
			w.mb.rendering = true
		}
		sync.mutex_unlock(&w.mb.mutex)

		if req.reload != w.loaded {
			worker_load(w, req.reload_media || !w.ever_loaded)
			w.loaded = req.reload
			// The latency is the frame's, not the load's (shown separately).
			req.asked = time.tick_now()
			// Render after a load even when the frame didn't change.
			sync.mutex_lock(&w.mb.mutex)
			w.mb.loading = false
			w.mb.rendering = true
			sync.mutex_unlock(&w.mb.mutex)
		}
		worker_render(w, req)
		free_all(context.temp_allocator)
		worker_settle(w, req)
		worker_clips(w)
	}
}

// Hands the placed tracks to the audio thread, which mixes them as it
// plays.
@(private = "file")
worker_publish_audio :: proc(w: ^Render_Worker) {
	v := &w.script.video
	audio_set_tracks(w.audio, w.placed.tracks[:], i64(om.frames_to_samples(w.frames, v.fps)), v.mix)
}

// Places the tracks again (clips landed) and publishes them.
@(private = "file")
worker_place_audio :: proc(w: ^Render_Worker) {
	if !w.timeline_ok {
		return
	}
	om.placed_audio_update(&w.placed, &w.script.video, w.timeline, w.media)
	worker_lanes(w)
	w.media_dirty = true
	w.watch_dirty = true
	worker_publish_audio(w)
}

// The timeline's lanes and items for the placed tracks.
@(private = "file")
worker_lanes :: proc(w: ^Render_Worker) {
	wave_builder_lanes(&w.waves, w.placed.tracks[:], w.placed.order[:], &w.script.video, len(w.timeline.scenes), w.script.cues[:])
}

// Called by a clip job when a clip lands.
@(private = "file")
worker_wake :: proc(data: rawptr) {
	w := (^Render_Worker)(data)
	sync.mutex_lock(&w.mb.mutex)
	w.mb.clips_landed = true
	sync.cond_signal(&w.mb.cond)
	sync.mutex_unlock(&w.mb.mutex)
}

// Starts building the clips `s` defers, nearest the frame `from` first (by
// the first track that plays each), the builds of an earlier load going on
// only to finish the clip they are on.
@(private = "file")
worker_clips_start :: proc(w: ^Render_Worker, s: ^script.Script, tl: om.Timeline, from: int) {
	worker_clips_retire(w)
	names := script.audio_pending_names(s)
	if len(names) == 0 {
		return
	}
	v := &s.video
	at := om.frames_to_samples(from, v.fps)
	// The sample a clip first plays at, from `at` on (earlier ones last):
	// where placement starts its tracks (`track_times`; they are not placed
	// while their clip is not built).
	need := make([]int, len(names), context.temp_allocator)
	for &n in need {
		n = max(int)
	}
	for tr in v.audio {
		start, _, _, ok := om.track_times(tr, tl, v.fps, w.media)
		if !ok {
			continue
		}
		key := start - at if start >= at else max(int) / 2 + start
		for name, i in names {
			if name == tr.src {
				need[i] = min(need[i], key)
			}
		}
	}
	order := make([]int, len(names), context.temp_allocator)
	for &o, i in order {
		o = i
	}
	for i in 1 ..< len(order) {
		for j := i; j > 0 && need[order[j]] < need[order[j - 1]]; j -= 1 {
			order[j], order[j - 1] = order[j - 1], order[j]
		}
	}
	sorted := make([]string, len(names), context.temp_allocator)
	for o, i in order {
		sorted[i] = names[o]
	}
	// Frames never build them: they draw without and again once they land.
	s.audio_later = true
	b := clip_builds_make(sorted, w.pool, nil, w.script_path, w.media_dir, w.script_args, w.script_props, w.video)
	b.wake, b.wake_data = worker_wake, w
	w.clips_began = time.tick_now()
	clip_builds_start(b)
	w.clips = b
}

// Whether the worker builds clips itself (no pool) and has some left.
@(private = "file")
clips_built_here :: proc(w: ^Render_Worker) -> bool {
	return w.clips != nil && w.clips.pool == nil
}

// Cancels the current builds (a job finishes the clip it is on) and frees
// the ones no job runs any more.
@(private = "file")
worker_clips_retire :: proc(w: ^Render_Worker) {
	if w.clips != nil {
		sync.atomic_store(&w.clips.cancel, true)
		append(&w.clips_retired, w.clips)
		w.clips = nil
	}
	worker_clips_free(w)
}

// Frees the retired builds no job runs any more.
@(private = "file")
worker_clips_free :: proc(w: ^Render_Worker) {
	for i := 0; i < len(w.clips_retired); {
		if b := w.clips_retired[i]; clip_builds_idle(b) {
			clip_builds_destroy(b)
			unordered_remove(&w.clips_retired, i)
		} else {
			i += 1
		}
	}
}

// The clips built since the last call join the media and the tracks are
// placed and published again (without a pool, the next clip is built here
// first). Returns whether anything changed.
@(private = "file")
worker_clips :: proc(w: ^Render_Worker) -> bool {
	sync.mutex_lock(&w.mb.mutex)
	w.mb.clips_landed = false
	sync.mutex_unlock(&w.mb.mutex)
	worker_clips_free(w)
	if w.script == nil {
		return false
	}
	landed := 0
	if w.clips != nil {
		clip_builds_step(w.clips)
		n, f := clip_builds_drain(w.clips, w.media, w.script)
		if f.code != .None {
			worker_build_failed(w, f)
		}
		landed = n
		if clip_builds_finished(w.clips) {
			if w.debug {
				fmt.eprintfln("preview worker: %d clips built in %.1f ms", len(w.clips.slots), time.duration_milliseconds(time.tick_since(w.clips_began)))
			}
			worker_clips_retire(w)
		}
	}
	if landed > 0 {
		worker_place_audio(w)
		// What was drawn without these clips is drawn again.
		for &t in w.thumbs {
			if t.audio {
				t.tries = 0
			}
		}
		if w.frame_audio && w.renderer_ok {
			if w.debug {
				fmt.eprintfln("preview worker: frame %d drawn again, its sound landed", w.last_request.frame)
			}
			worker_render(w, w.last_request)
		}
	}
	return landed > 0
}

// A clip the script builds failed: a script error among the problems (the
// clip stays silent), as a command would fail with it.
@(private = "file")
worker_build_failed :: proc(w: ^Render_Worker, f: script.Failure) {
	message := script.error_message(f, context.temp_allocator)
	warn("%s", message)
	finding_add(&w.findings, nil, LOAD_FRAME, {severity = .Error, code = .Script_Error, a = message})
	w.watch_dirty = true
}

// Clip frames still decoding were drawn from the nearest decoded frame: draw
// again shortly unless the UI asks for something else.
@(private = "file")
worker_settle :: proc(w: ^Render_Worker, req: Render_Request) {
	for w.renderer_ok && w.renderer.video_images.pending > 0 {
		sync.mutex_lock(&w.mb.mutex)
		newer := w.mb.quit || w.mb.request_seq != w.handled_seq
		if !newer {
			sync.cond_wait_with_timeout(&w.mb.cond, &w.mb.mutex, 4 * time.Millisecond)
			newer = w.mb.quit || w.mb.request_seq != w.handled_seq
		}
		if !newer {
			w.mb.rendering = true
		}
		sync.mutex_unlock(&w.mb.mutex)
		if newer {
			break
		}
		worker_render(w, req)
		free_all(context.temp_allocator)
	}
}

// Whether there is idle work to do now (called with the mailbox locked),
// else how long until thumbnails may start (0: until signalled). Takes the
// UI's newest thumbnail list, and frees retired thumbnail textures once the
// UI has taken the current generation.
@(private = "file")
worker_idle_ready :: proc(w: ^Render_Worker) -> (ready: bool, retry: time.Duration) {
	if w.script == nil {
		return
	}
	if w.mb.thumb_wanted_seq != w.wanted_seq {
		w.wanted_seq = w.mb.thumb_wanted_seq
		table_copy(&w.thumb_wanted, w.mb.thumb_wanted[:])
	}
	if w.mb.thumb_ack == w.thumb_gen && len(w.thumb_retired) > 0 {
		append(&w.thumb_free, ..w.thumb_retired[:])
		clear(&w.thumb_retired)
	}
	if w.mb.clips_landed || clips_built_here(w) || wave_builder_pending(&w.waves) || watch_pending(w) || media_pending(w) {
		return true, 0
	}
	if thumb_next(w) < 0 {
		return
	}
	return thumbs_allowed(w, w.mb.busy)
}

@(private = "file")
watch_pending :: proc(w: ^Render_Worker) -> bool {
	return w.watch_dirty || (w.script != nil && len(w.script.key_anchors) != w.watch_keys)
}

// The Watch's rows from the load, published. The sync findings wait for
// the script's sounds (a cue's hit needs its track built).
@(private = "file")
worker_watch :: proc(w: ^Render_Worker) {
	w.watch_dirty = false
	src := Watch_Sources{fps = 1, findings = &w.findings, media = w.media, load_error = w.load_error}
	if s := w.script; s != nil {
		w.watch_keys = len(s.key_anchors)
		src.fps, src.cues, src.placed = s.video.fps, s.cues[:], w.placed.tracks[:]
		if w.timeline_ok {
			src.timeline = &w.timeline
			if w.clips == nil {
				src.sync = sync_check(w.media, src.placed, src.fps, video_anchors(s, w.media, w.timeline.scenes[:], src.placed, src.fps))
			}
		}
	}
	watch_table_build(&w.watch, src)
	sync.mutex_lock(&w.mb.mutex)
	watch_table_copy(&w.mb.watch, &w.watch)
	w.mb.watch_seq += 1
	sync.mutex_unlock(&w.mb.mutex)
}

@(private = "file")
media_pending :: proc(w: ^Render_Worker) -> bool {
	t := &w.media_table
	return w.media_dirty || (t.thumbs_ready < len(t.rows) && t.rows[t.thumbs_ready].kind == .Image)
}

// Thumbnails render while frames leave slack (fast scripts, even playing),
// or once the UI has been quiet for THUMB_QUIET.
@(private = "file")
thumbs_allowed :: proc(w: ^Render_Worker, busy: bool) -> (ok: bool, retry: time.Duration) {
	if w.last_ms < IDLE_SLACK_MS {
		return true, 0
	}
	if busy {
		return false, 0
	}
	since := time.tick_since(w.request_tick)
	if since >= THUMB_QUIET {
		return true, 0
	}
	return false, THUMB_QUIET - since
}

// One step of idle work, in priority order.
@(private = "file")
worker_idle :: proc(w: ^Render_Worker, busy: bool) {
	if worker_clips(w) {
		return
	}
	if wave_builder_pending(&w.waves) {
		if wave_builder_step(&w.waves) {
			sync.mutex_lock(&w.mb.mutex)
			wave_table_copy(&w.mb.waves, &w.waves.table)
			w.mb.waves_seq += 1
			sync.mutex_unlock(&w.mb.mutex)
		}
		return
	}
	if watch_pending(w) {
		worker_watch(w)
		return
	}
	if media_pending(w) {
		// The rows first (published at once), then the image thumbnails a few
		// per step, published when all are done.
		publish := w.media_dirty
		if w.media_dirty {
			w.media_dirty = false
			media_table_build(&w.media_table, w.media)
		} else {
			publish = media_table_thumbs(&w.media_table, w.media, MEDIA_THUMBS_PER_STEP * om.pool_count(w.pool), w.pool)
			// Their decodes count against the image budget too.
			om.media_evict(w.media)
		}
		if publish {
			sync.mutex_lock(&w.mb.mutex)
			media_table_copy(&w.mb.media, &w.media_table)
			w.mb.media_seq += 1
			sync.mutex_unlock(&w.mb.mutex)
		}
		return
	}
	if ok, _ := thumbs_allowed(w, busy); !ok {
		return
	}
	if i := thumb_next(w); i >= 0 {
		thumb_render(w, w.thumb_wanted[i])
	}
}

// Loads the script (and the media when asked) into fresh instances and
// swaps them in on success; a failing edit keeps the last good script.
@(private = "file")
worker_load :: proc(w: ^Render_Worker, reload_media: bool) {
	began := time.tick_now()
	// The audio thread lets go of the samples a load may replace; the tracks
	// come back with the new script (or the last good one).
	audio_clear_tracks(w.audio)
	sync.mutex_lock(&w.mb.mutex)
	w.mb.load_phase = .Script
	w.mb.load_files = 0
	w.mb.load_began = began
	sync.mutex_unlock(&w.mb.mutex)
	// The media first: scripts measure text with its fonts at load.
	first_load := !w.ever_loaded
	media := w.media
	if reload_media || media == nil {
		media = new(om.Media)
		media_open(media, w.image_budget, w.video)
		if os.is_dir(w.media_dir) {
			files := 0
			if infos, err := os.read_all_directory_by_path(w.media_dir, context.temp_allocator); err == nil {
				files = len(infos)
			}
			sync.mutex_lock(&w.mb.mutex)
			w.mb.load_phase = .Media
			w.mb.load_files = files
			sync.mutex_unlock(&w.mb.mutex)
			om.media_load_dir(media, w.media_dir, w.pool)
		}
		sync.mutex_lock(&w.mb.mutex)
		w.mb.load_phase = .Script
		sync.mutex_unlock(&w.mb.mutex)
	}
	next := new(script.Script)
	// Lines an edit added are synthesized by the load.
	loaded := script.load(next, w.script_path, w.script_args, media, nil, w.script_props)
	if loaded != nil {
		// The Watch's problems and the video show it.
		delete(w.load_error)
		w.load_error = strings.clone(script.error_message(next.failure, context.temp_allocator))
		w.watch_dirty = true
		sync.mutex_lock(&w.mb.mutex)
		script.failure_destroy(&w.mb.reload_failure)
		w.mb.reload_failure = script.failure_clone(next.failure)
		w.mb.reload_seq += 1
		sync.mutex_unlock(&w.mb.mutex)
		warn("reload failed, keeping the last good script: %s", script.error_message(next.failure, context.temp_allocator))
		script.unload(next)
		free(next)
		if media != w.media {
			om.media_destroy(media)
			free(media)
		}
		if w.script != nil {
			worker_place_audio(w)
		} else {
			worker_watch(w) // no idle work without a script
		}
		return
	}
	warn_load(next, media)
	sync.mutex_lock(&w.mb.mutex)
	w.mb.load_phase = .Timeline
	sync.mutex_unlock(&w.mb.mutex)
	if w.renderer_ok {
		om.renderer_destroy(&w.renderer)
		w.renderer_ok = false
	}
	if w.thumb_ok {
		om.renderer_destroy(&w.thumb)
		w.thumb_ok = false
	}
	if w.script != nil {
		script.unload(w.script)
		free(w.script)
	}
	// The pyramids belong to the clips of the last load (a kept media's may
	// have been replaced).
	wave_builder_reset(&w.waves)
	if media != w.media {
		w.media_gen += 1
		if w.media != nil {
			om.media_destroy(w.media)
			free(w.media)
		}
	}
	w.script = next
	w.media = media
	w.ever_loaded = true
	// Clips the script makes (built on the pool below): a kept media's
	// copies are from the last version of the script.
	for name in script.audio_pending_names(next) {
		if clip, ok := om.media_take_audio(media, name); ok {
			om.audio_clip_destroy(&clip)
		}
	}

	// Everything derived from the last script goes: problems, thumbnails
	// (their textures retire until the UI takes the new generation).
	finding_table_clear(&w.findings)
	for d in load_diagnostics(next, media) {
		finding_add(&w.findings, nil, LOAD_FRAME, d)
	}
	delete(w.load_error)
	w.load_error = ""
	w.watch_dirty = true
	for t in w.thumbs {
		append(&w.thumb_retired, t.texture)
	}
	clear(&w.thumbs)
	w.thumb_gen += 1

	// The timeline for the UI, the mix for the audio thread, the lanes.
	om.timeline_destroy(&w.timeline)
	tl, err := om.resolve_timeline(&next.video, media)
	w.timeline, w.timeline_ok = tl, err == nil
	clear(&w.placed.tracks)
	clear(&w.placed.order)
	if err == nil {
		v := &next.video
		om.placed_audio_update(&w.placed, v, tl, media)
		w.frames = tl.duration_frames
		thumb_scale := min(f32(THUMB_HEIGHT) / f32(max(v.height, 1)), 1)
		w.thumb_size = {u32(f32(v.width) * thumb_scale + 0.5), u32(f32(v.height) * thumb_scale + 0.5)}
	}
	worker_lanes(w)
	w.media_dirty = true
	bookmark := bookmark_read(w.script_path) if first_load else -1
	if err == nil {
		// Sound plays at once from what is ready; the rest joins as it lands.
		worker_publish_audio(w)
		worker_clips_start(w, next, tl, bookmark if bookmark >= 0 else w.last_request.frame)
	}

	sync.mutex_lock(&w.mb.mutex)
	preview_timeline_build(&w.mb.timeline, &next.video, &w.timeline if err == nil else nil)
	w.mb.timeline_seq += 1
	if first_load {
		w.mb.bookmark_loaded = bookmark
	}
	if w.mb.reload_failure.code != .None {
		script.failure_destroy(&w.mb.reload_failure)
		w.mb.reload_seq += 1
	}
	wave_table_copy(&w.mb.waves, &w.waves.table)
	w.mb.waves_seq += 1
	clear(&w.mb.thumbs)
	w.mb.thumb_gen = w.thumb_gen
	w.mb.thumb_size = w.thumb_size
	w.mb.thumbs_seq += 1
	sync.mutex_unlock(&w.mb.mutex)
	w.loaded_at, w.frames_since = time.tick_now(), 0
	if w.debug {
		fmt.eprintfln("preview worker: loaded %s in %.1f ms", w.script_path, time.duration_milliseconds(time.tick_since(began)))
	}
}

// The GPU canvas backend for a renderer: `b` initialised on the window's
// device on first use (nil: draw on the CPU).
@(private = "file")
worker_backend :: proc(w: ^Render_Worker, b: ^vgsdl.SDL_Backend, ok: ^bool) -> Maybe(vg.Backend) {
	if !w.software && !ok^ {
		if err := vgsdl.init(b, w.device); err != nil {
			warn("no GPU canvas in the preview (%v), drawing on the CPU", err)
			w.software = true
		} else {
			ok^ = true
		}
	}
	if ok^ && !w.software {
		return vgsdl.backend(b)
	}
	return nil
}

@(private = "file")
worker_renderer :: proc(w: ^Render_Worker, scale: f32) -> ^om.Renderer {
	if w.script == nil {
		return nil
	}
	if w.renderer_ok && w.renderer.scale != scale {
		om.renderer_destroy(&w.renderer)
		w.renderer_ok = false
	}
	if !w.renderer_ok {
		backend := worker_backend(w, &w.gpu, &w.gpu_ok)
		if om.renderer_init(&w.renderer, &w.script.video, w.media, scale, backend) != nil {
			return nil
		}
		w.renderer.pool = w.pool
		// Seeks restore the nearest earlier checkpoint of feedback buffers.
		om.feedback_checkpoints(&w.renderer, om.FEEDBACK_CHECKPOINT_EVERY)
		w.renderer_ok = true
	}
	return &w.renderer
}

// Draws frame `frame` of `r` into `tex` (GPU canvas, or CPU pixels
// uploaded), never waiting on video decode threads: the nearest decoded
// clip frame now, the exact one on a later pass.
@(private = "file")
draw_into :: proc(w: ^Render_Worker, r: ^om.Renderer, gpu_ok: bool, frame: int, tex: ^sdl.GPUTexture) {
	r.video_images.wait = .Nearest
	r.video_images.pending = 0
	size := [2]u32{r.width, r.height}
	if w.software || !gpu_ok {
		pixels := om.render_frame(r, frame)
		upload_rgba(w.device, tex, size, pixels)
	} else {
		out := vgsdl.Output{texture = tex, format = .R8G8B8A8_UNORM, width = size.x, height = size.y}
		om.render_frame(r, frame, vgsdl.output(&out), readback = false)
	}
}

@(private = "file")
make_target :: proc(device: ^sdl.GPUDevice, size: [2]u32) -> ^sdl.GPUTexture {
	return sdl.CreateGPUTexture(
		device,
		{type = .D2, format = .R8G8B8A8_UNORM, usage = {.SAMPLER, .COLOR_TARGET}, width = size.x, height = size.y, layer_count_or_depth = 1, num_levels = 1, sample_count = ._1},
	)
}

@(private = "file")
worker_render :: proc(w: ^Render_Worker, req: Render_Request) {
	r := worker_renderer(w, req.scale)
	if r == nil {
		sync.mutex_lock(&w.mb.mutex)
		w.mb.rendering = false
		sync.mutex_unlock(&w.mb.mutex)
		return
	}
	sync.mutex_lock(&w.mb.mutex)
	displayed := w.mb.displayed_slot
	sync.mutex_unlock(&w.mb.mutex)
	// A slot neither on screen nor the newest published one.
	slot := 0
	for i in 0 ..< SLOT_COUNT {
		if i != displayed && i != w.last_slot {
			slot = i
			break
		}
	}
	size := [2]u32{r.width, r.height}
	s := &w.slots[slot]
	if s.texture == nil || s.size != size {
		if s.texture != nil {
			sdl.ReleaseGPUTexture(w.device, s.texture)
		}
		s.texture = make_target(w.device, size)
		s.size = size
	}
	frame := clamp(req.frame, 0, max(r.timeline.duration_frames - 1, 0))
	began := time.tick_now()
	draw_into(w, r, w.gpu_ok, frame, s.texture)
	ms := time.duration_milliseconds(time.tick_since(began))
	w.last_request = req
	w.last_ms = ms
	w.frame_audio = r.ctx.audio_pending > 0
	if w.debug && w.frames_since < 12 {
		w.frames_since += 1
		fmt.eprintfln("preview worker: frame %d drawn in %.1f ms, %.0f ms after the load", frame, ms, time.duration_milliseconds(time.tick_since(w.loaded_at)))
	}
	if w.log_clips {
		vi := &r.video_images
		for clip, k in vi.clip {
			if vi.used_frame[k] == frame {
				fmt.eprintfln("clip-log frame %d clip %d.%d index %d%s", frame, clip, k, vi.shown[k], " (inexact)" if vi.pending > 0 else "")
			}
		}
	}
	// Problems accumulate per load; a frame without findings changes nothing.
	for d in r.ctx.diagnostics {
		w.watch_dirty |= finding_add(&w.findings, &r.timeline, frame, d)
	}
	om.diagnostics_clear(&r.ctx)

	sync.mutex_lock(&w.mb.mutex)
	w.mb.slot = slot
	w.mb.slot_texture = s.texture
	w.mb.slot_frame = frame
	w.mb.slot_size = size
	w.mb.render_ms = ms
	w.mb.latency_ms = time.duration_milliseconds(time.tick_since(req.asked))
	w.mb.rendering = false
	w.mb.published_seq += 1
	sync.mutex_unlock(&w.mb.mutex)
	w.last_slot = slot
}

// ---- thumbnails ---------------------------------------------------------------------------

@(private = "file")
thumb_find :: proc(w: ^Render_Worker, frame: int) -> (index: int, found: bool) {
	return slice.binary_search_by(w.thumbs[:], frame, proc(e: Thumb_Entry, f: int) -> slice.Ordering {
		return slice.cmp(e.frame, f)
	})
}

// The wanted thumbnail to render next (an index into thumb_wanted, -1 for
// none): the first one missing, else the first inexact one with tries left.
@(private = "file")
thumb_next :: proc(w: ^Render_Worker) -> int {
	if w.thumb_size.x == 0 {
		return -1
	}
	retry := -1
	for f, i in w.thumb_wanted {
		j, found := thumb_find(w, f)
		if !found {
			return i
		}
		if e := w.thumbs[j]; !e.exact && e.tries < THUMB_TRIES && retry < 0 {
			retry = i
		}
	}
	return retry
}

// (Re)opens the media's clips on the thumbnail decoders when the media was
// replaced.
@(private = "file")
thumb_clips_update :: proc(w: ^Render_Worker) {
	if w.thumb_clips_of == w.media_gen {
		return
	}
	thumb_clips_release(w)
	w.thumb_clips_of = w.media_gen
	src := &w.media.videos
	if len(src.names) == 0 {
		return
	}
	enc.video_decoders_init(&w.thumb_video, native = w.video != nil && w.video.native)
	w.thumb_videos.source = enc.video_source(&w.thumb_video)
	for name, i in src.names {
		om.video_clips_add(&w.thumb_videos, name, src.paths[i])
	}
}

// Closes the thumbnail decoders and frees their clip table.
@(private = "file")
thumb_clips_release :: proc(w: ^Render_Worker) {
	om.video_clips_destroy(&w.thumb_videos)
	w.thumb_videos = {}
	if w.thumb_video.workers != nil {
		enc.video_decoders_destroy(&w.thumb_video)
	}
}

// Renders one thumbnail with the thumbnail renderer and publishes the
// cache. Its diagnostics are dropped: problems come from playhead frames.
@(private = "file")
thumb_render :: proc(w: ^Render_Worker, frame: int) {
	if !w.thumb_ok {
		thumb_clips_update(w)
		backend := worker_backend(w, &w.thumb_gpu, &w.thumb_gpu_ok)
		scale := f32(w.thumb_size.y) / f32(max(w.script.video.height, 1))
		if om.renderer_init(&w.thumb, &w.script.video, w.media, scale, backend) != nil {
			w.thumb_size = {}
			return
		}
		w.thumb.pool = w.pool
		w.thumb.ctx.videos = &w.thumb_videos
		// Thumbnails warm feedback buffers up for a second instead of
		// catching up exactly.
		w.thumb.shader_state.feedback.warmup = int(w.script.video.fps)
		w.thumb_ok = true
	}
	r := &w.thumb
	j, found := thumb_find(w, frame)
	if !found {
		tex: ^sdl.GPUTexture
		if n := len(w.thumb_free); n > 0 {
			tex = pop(&w.thumb_free)
		} else if len(w.thumbs) < THUMB_MAX {
			tex = make_target(w.device, {r.width, r.height})
		} else {
			// Full: take the entry farthest from every wanted frame.
			far, far_d := -1, -1
			for e, k in w.thumbs {
				d := max(int)
				for f in w.thumb_wanted {
					d = min(d, abs(e.frame - f))
				}
				if d > far_d {
					far, far_d = k, d
				}
			}
			if far_d <= 0 {
				return
			}
			tex = w.thumbs[far].texture
			ordered_remove(&w.thumbs, far)
			j, _ = thumb_find(w, frame)
		}
		if tex == nil {
			w.thumb_size = {} // no more thumbnails rather than retrying forever
			return
		}
		inject_at(&w.thumbs, j, Thumb_Entry{frame = frame, texture = tex})
	}
	e := &w.thumbs[j]
	draw_into(w, r, w.thumb_gpu_ok, clamp(frame, 0, max(r.timeline.duration_frames - 1, 0)), e.texture)
	om.diagnostics_clear(&r.ctx)
	e.audio = r.ctx.audio_pending > 0
	e.exact = r.video_images.pending == 0 && !e.audio
	e.tries += 1
	free_all(context.temp_allocator)
	sync.mutex_lock(&w.mb.mutex)
	resize(&w.mb.thumbs, len(w.thumbs))
	for t, k in w.thumbs {
		w.mb.thumbs[k] = {t.frame, t.texture}
	}
	w.mb.thumbs_seq += 1
	exact := e.exact
	sync.mutex_unlock(&w.mb.mutex)
	if !exact {
		// Give the decoders a moment before the retry; a request ends the wait.
		sync.mutex_lock(&w.mb.mutex)
		if w.mb.request_seq == w.handled_seq && !w.mb.quit {
			sync.cond_wait_with_timeout(&w.mb.cond, &w.mb.mutex, 8 * time.Millisecond)
		}
		sync.mutex_unlock(&w.mb.mutex)
	}
}

// CPU pixels into a texture through a transfer buffer (on this thread's own
// command buffer, waited on before returning).
@(private = "file")
upload_rgba :: proc(device: ^sdl.GPUDevice, tex: ^sdl.GPUTexture, size: [2]u32, pixels: []u8) {
	n := u32(len(pixels))
	tb := sdl.CreateGPUTransferBuffer(device, {usage = .UPLOAD, size = n})
	if tb == nil {
		return
	}
	defer sdl.ReleaseGPUTransferBuffer(device, tb)
	dst := sdl.MapGPUTransferBuffer(device, tb, false)
	if dst == nil {
		return
	}
	runtime.mem_copy_non_overlapping(dst, raw_data(pixels), int(n))
	sdl.UnmapGPUTransferBuffer(device, tb)
	cb := sdl.AcquireGPUCommandBuffer(device)
	pass := sdl.BeginGPUCopyPass(cb)
	sdl.UploadToGPUTexture(pass, {transfer_buffer = tb, pixels_per_row = size.x, rows_per_layer = size.y}, {texture = tex, w = size.x, h = size.y, d = 1}, false)
	sdl.EndGPUCopyPass(pass)
	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cb)
	if fence != nil {
		fences := [1]^sdl.GPUFence{fence}
		_ = sdl.WaitForGPUFences(device, true, &fences[0], 1)
		sdl.ReleaseGPUFence(device, fence)
	}
}

@(private = "file")
worker_release :: proc(w: ^Render_Worker) {
	audio_clear_tracks(w.audio)
	// Pool jobs still building wake this worker: wait for them (each ends
	// with the clip it is on).
	worker_clips_retire(w)
	for len(w.clips_retired) > 0 {
		time.sleep(time.Millisecond)
		worker_clips_retire(w)
	}
	delete(w.clips_retired)
	if w.renderer_ok {
		om.renderer_destroy(&w.renderer)
	}
	if w.thumb_ok {
		om.renderer_destroy(&w.thumb)
	}
	if w.gpu_ok {
		vgsdl.destroy(&w.gpu)
	}
	if w.thumb_gpu_ok {
		vgsdl.destroy(&w.thumb_gpu)
	}
	thumb_clips_release(w)
	for &s in w.slots {
		if s.texture != nil {
			sdl.ReleaseGPUTexture(w.device, s.texture)
			s.texture = nil
		}
	}
	for t in w.thumbs {
		sdl.ReleaseGPUTexture(w.device, t.texture)
	}
	for t in w.thumb_free {
		sdl.ReleaseGPUTexture(w.device, t)
	}
	for t in w.thumb_retired {
		sdl.ReleaseGPUTexture(w.device, t)
	}
	delete(w.thumbs)
	delete(w.thumb_free)
	delete(w.thumb_retired)
	delete(w.thumb_wanted)
	om.timeline_destroy(&w.timeline)
	om.placed_audio_destroy(&w.placed)
	finding_table_destroy(&w.findings)
	watch_table_destroy(&w.watch)
	delete(w.load_error)
	wave_builder_destroy(&w.waves)
	media_table_destroy(&w.media_table)
	if w.script != nil {
		script.unload(w.script)
		free(w.script)
	}
	if w.media != nil {
		om.media_destroy(w.media)
		free(w.media)
	}
}
