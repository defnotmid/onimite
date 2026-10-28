package onimite

import "core:math"

import vg "deps:ovg"

Vec2 :: vg.Vec2
Color :: vg.Color

Seconds :: distinct f32
Frames :: distinct int

// `nil` means "auto": a video lasts as long as its scenes.
Duration :: union {
	Seconds,
	Frames,
	// Media lengths and sums (`{ audio = "vo.wav" }`); see time_terms.odin.
	Duration_Terms,
}

// Seconds a scene extends into its neighbours, on top of its own duration
// (a cross-fade window). With `previous = 0.5` the scene starts 0.5 s before
// the previous one ends.
Overlap :: struct {
	previous, next: f32,
}

Render_Proc :: #type proc(f: Frame, ctx: ^Context)

Scene :: struct {
	// How the CLI addresses the scene (`Intro@1.5s`).
	name:     string,
	// Where the scene lands on the video, seconds (`start` in scripts): its
	// previous overlap reaches back from here, and without a `duration` it
	// lasts until the next scene's start. nil: right after the previous one.
	start:    Maybe(f32),
	duration: Duration,
	overlap:  Overlap,
	render:   Render_Proc,
	// The cue the scene's first frame lands on (`cue` in scripts): everything
	// on the same cue should meet there.
	cue:      string,
	// Where the script defines it ("scenes/race.lua:42"), for tools that
	// point an agent at the code.
	source:   string,
	// What `preview --present` does at the scene's end (`hold` in scripts).
	// Renders play straight through.
	hold:     Hold,
	// Free for the video's own state.
	user:     rawptr,
}

// A presentation waits at each scene's end for the presenter's click
// (where its next overlap would begin), the scene still running on (Alive:
// what has arrived stays, what moves keeps moving), playing again from its
// start (Loop) or still (Freeze); a Flow scene plays straight into the next.
Hold :: enum u8 {
	Alive,
	Loop,
	Freeze,
	Flow,
}

Video :: struct {
	width, height: int,
	fps:           int,
	// Painted under every frame.
	background:    Color,
	// `nil` (auto) is the length of the scenes.
	duration:      Duration,
	scenes:        []Scene,
	// Draws a frame. With `nil`, frames are the background plus the active
	// scenes (`render_scenes`).
	render:        Render_Proc,
	// Sound: every track of the video, its own (timed from the video start)
	// and its scenes' (`Audio_Track.scene`, timed from the scene's first
	// frame), in that order.
	audio:         []Audio_Track,
	// Buses tracks are mixed through (Audio_Track.bus): a gain per group of
	// tracks, e.g. every sound effect at once.
	buses:         []Bus,
	// The master bus: its gain before the limiter (fframes'
	// audio_mix.master_gain_db) and the limiter's ceiling, or none.
	mix:           Mix_Options,
	// Motion blur: how long the shutter is open, in degrees of a frame (180:
	// half the frame's time, centred on its moment); 0, the default, is
	// none. 3D views blur what moves in them over the shutter (motion.odin).
	shutter:       f32,
	user:          rawptr,
}

// The clock passed to render procs. Inside a scene `index` is relative to
// the scene's first frame; `global_index` always counts from the video start.
Frame :: struct {
	index:        int,
	global_index: int,
	fps:          int,
	// The scene being rendered, or nil at video level.
	scene:        ^Scene_Info,
	// Seconds from the frame's moment to the moment this build shows: 0, or
	// the shutter's opening (< 0) when the frame is built a second time for
	// its motion (motion.odin). Times read from the clock add it; `index`
	// stays the frame's.
	shift:        f64,
}

frame_seconds :: #force_inline proc "contextless" (f: Frame) -> f32 {
	return f32(f.index) / f32(f.fps) + f32(f.shift)
}

// The frame on screen at `seconds` (frame k shows [k, k + 1) / fps), which
// is also how many whole frames fit in `seconds`. A thousandth of a frame
// of slack absorbs float error (`1.16 * 25` is 28.99...; an f32 time is
// off by up to 6e-8 of itself).
frame_at :: #force_inline proc "contextless" (seconds: f64, fps: int) -> int {
	return int(math.floor(seconds * f64(fps) + 1e-3))
}

// The first frame starting at or after `seconds`: a scene placed on a cue
// never starts before it, so its own clock is never negative.
first_frame_from :: #force_inline proc "contextless" (seconds: f64, fps: int) -> int {
	return int(math.ceil(seconds * f64(fps) - 1e-3))
}

duration_frames :: proc(d: Duration, fps: int, m: ^Media = nil) -> (frames: int, ok: bool) {
	switch v in d {
	case Seconds:
		return frame_at(f64(v), fps), true
	case Frames:
		return int(v), true
	case Duration_Terms:
		frames, _, ok = terms_frames(([]Time_Term)(v), fps, m)
		return
	}
	return 0, false
}

// A named group of tracks with its own gain (`buses = { sfx = { gain_db = -4 } }`).
Bus :: struct {
	name:    string,
	gain_db: f32,
	kind:    Bus_Kind,
}

// What a bus's sounds are, which decides how onimite treats them: the beat
// is measured from `Music`, `Sfx` is checked against it, `Voice` is speech
// (it ducks the music, is never beat-checked); `Other` gets no role.
// `None` is a track on no bus.
Bus_Kind :: enum u8 {
	None,
	Music,
	Sfx,
	Voice,
	Other,
}

// A scene placed on the video timeline (overlaps included).
Scene_Info :: struct {
	index:       int,
	scene:       ^Scene,
	// `[start_frame, end_frame)` in video frames.
	start_frame: int,
	end_frame:   int,
	// The scene's own duration, without overlaps.
	duration:    int,
	is_last:     bool,
}

scene_info_frames :: #force_inline proc "contextless" (s: Scene_Info) -> int {
	return s.end_frame - s.start_frame
}

// Scene placement and total length of a video. Port of fframes'
// `ResolvedScenesTimeline`.
Timeline :: struct {
	scenes:          []Scene_Info,
	duration_frames: int,
}

// Durations taken from media lengths need `m`.
resolve_timeline :: proc(v: ^Video, m: ^Media = nil, allocator := context.allocator) -> (t: Timeline, err: Error) {
	t.scenes = make([]Scene_Info, len(v.scenes), allocator)
	end := 0
	for &s, i in v.scenes {
		// A scene with a start lands there; the others follow the previous one.
		if at, has := s.start.?; has {
			end = first_frame_from(f64(at), v.fps)
		}
		d, ok := duration_frames(s.duration, v.fps, m)
		if !ok && s.duration == nil {
			// No duration: until the next scene's start, or the video's end.
			if i + 1 < len(v.scenes) {
				if next_at, has := v.scenes[i + 1].start.?; has {
					d, ok = first_frame_from(f64(next_at), v.fps) - end, true
				}
			} else if vd, has := duration_frames(v.duration, v.fps, m); has && s.start != nil {
				d, ok = vd - end, true
			}
		}
		if !ok || d < 0 {
			delete(t.scenes, allocator)
			return {}, .Scene_Without_Duration
		}
		prev := frame_at(f64(s.overlap.previous), v.fps)
		next := frame_at(f64(s.overlap.next), v.fps)
		start := max(end - prev, 0)
		t.scenes[i] = {
			index       = i,
			scene       = &s,
			start_frame = start,
			end_frame   = end + d + next,
			duration    = d,
			is_last     = i == len(v.scenes) - 1,
		}
		end = max(end + d - next, 0)
	}
	if d, ok := duration_frames(v.duration, v.fps, m); ok {
		t.duration_frames = d
	} else if len(v.scenes) > 0 {
		t.duration_frames = end
	} else {
		delete(t.scenes, allocator)
		return {}, .Video_Without_Duration
	}
	return t, nil
}

timeline_destroy :: proc(t: ^Timeline, allocator := context.allocator) {
	delete(t.scenes, allocator)
	t^ = {}
}

// Index of the first scene named `name` (case-insensitive), or -1.
find_scene :: proc(t: Timeline, name: string) -> int {
	for s, i in t.scenes {
		if equal_fold(s.scene.name, name) {
			return i
		}
	}
	return -1
}

@(private)
equal_fold :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		x, y := a[i], b[i]
		if 'A' <= x && x <= 'Z' {x += 32}
		if 'A' <= y && y <= 'Z' {y += 32}
		if x != y {
			return false
		}
	}
	return true
}
