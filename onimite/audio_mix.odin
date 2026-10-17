package onimite

import "core:math"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:sync"
import odevice "deps:odawg/device"
import orender "deps:odawg/render"
import osong "deps:odawg/song"

// The mix: every track placed on the video timeline, as one odawg song
// (odawg's song/mix.odin) that odawg's engine streams: a clip is a Player
// playing its samples (gain, balance, offset, fades, mono, ducking under
// the voice tracks), a song or sound its own tracks moved to where it
// starts, let through its track's window. Then `master_gain_db` and the
// master limiter (fframes' defaults: -1 dB ceiling). The render is that
// stream cut into time segments on every core; the preview plays the same
// stream.

Mix_Options :: struct {
	master_gain_db: f32,
	// Limiter ceiling; 0 means -1 dBFS.
	ceiling_db:     f32,
	no_limiter:     bool,
}

// A track resolved to sample positions on the video timeline.
Placed_Track :: struct {
	track:      Audio_Track,
	// What it plays: a decoded clip, or a song (`song{}`, `sound{}`).
	clip:       ^Audio_Clip,
	song:       ^Song_Clip,
	// `[start, end)` in mix samples (per channel) from the video start.
	start, end: int,
	// First clip sample played (a song: its sample at `start`).
	file_start: int,
	// The name of the scene that places it, or "" for the video's own.
	scene:      string,
	// Left out of the mix but still a voice for ducking (one track heard
	// alone, as it sounds in the mix).
	muted:      bool,
	// A song's part heard alone ("bass" for `--track score/bass`; "" all).
	part:       string,
	// Its bus's kind (`None` on no bus).
	kind:       Bus_Kind,
}

Mix_Stats :: struct {
	// Samples beyond full scale before the limiter.
	clipped_before_limiter: int,
	peak_before_limiter:    f32,
	// Deepest gain reduction the limiter applied.
	max_reduction_db:       f32,
}

seconds_to_samples :: #force_inline proc "contextless" (s: f32) -> int {
	return int(math.round(f64(s) * MIX_RATE))
}

// Where track `tr`'s clock starts on timeline `t`, in mix samples: its
// scene's first frame, or the video start.
track_origin :: proc(tr: Audio_Track, t: Timeline, fps: int) -> int {
	if scene, in_scene := tr.scene.?; in_scene {
		return frames_to_samples(t.scenes[scene].start_frame, fps)
	}
	return 0
}

// Where track `tr` starts and (`has_stop`) stops on timeline `t`, in mix
// samples from the video start; false when a time term names a clip the
// media lacks (a load diagnostic).
track_times :: proc(tr: Audio_Track, t: Timeline, fps: int, m: ^Media) -> (start, stop: int, has_stop, ok: bool) {
	start_s, stop_s := f64(tr.start), f64(tr.stop)
	if len(tr.start_terms) > 0 {
		start_s, _ = terms_seconds(tr.start_terms, fps, m) or_return
	}
	has_stop = tr.stop > tr.start
	if len(tr.stop_terms) > 0 {
		stop_s, _ = terms_seconds(tr.stop_terms, fps, m) or_return
		has_stop = true
	}
	origin := track_origin(tr, t, fps)
	start = origin + int(math.round(start_s * MIX_RATE))
	stop = origin + int(math.round(stop_s * MIX_RATE))
	return start, stop, has_stop, true
}

// A context's tracks placed on its timeline (`placed_audio`): placed once,
// and again only when the media's clips change (the tracks point at them).
// The preview's worker keeps its own (`placed_audio_update`).
Placed_Audio :: struct {
	tracks: [dynamic]Placed_Track,
	// Indices into `tracks` by start time (stable): show's `track/N` is
	// `tracks[order[N]]`.
	order:  [dynamic]int,
	// `Media.audio_gen + 1` when placed (0: not placed).
	gen:    u64,
}

placed_audio_destroy :: proc(p: ^Placed_Audio) {
	delete(p.tracks)
	delete(p.order)
	p^ = {}
}

// The video's tracks placed on the context's timeline.
placed_audio :: proc(ctx: ^Context) -> ^Placed_Audio {
	p := &ctx.placed
	if p.gen != ctx.media.audio_gen + 1 {
		placed_audio_update(p, ctx.video, ctx.timeline^, ctx.media)
	}
	return p
}

// Places the video's tracks on timeline `t` into `p`. Tracks whose sound
// the media lacks are left out (the load reports them). A song lasts to
// its end and its tail.
placed_audio_update :: proc(p: ^Placed_Audio, v: ^Video, t: Timeline, m: ^Media) {
	clear(&p.tracks)
	total := frames_to_samples(t.duration_frames, v.fps)
	for tr in v.audio {
		clip, has := &m.audio[tr.src]
		song: ^Song_Clip
		length := 0
		if has {
			length = clip.frames
		} else {
			clip = nil
			song = media_song(m, tr.src)
			if song == nil || !song.ok {
				continue
			}
			length = int(math.ceil((song.song.duration + song.tail) * MIX_RATE))
		}
		start, stop, has_stop, ok := track_times(tr, t, v.fps, m)
		if !ok {
			continue
		}
		file_start := seconds_to_samples(tr.offset)
		end := start + max(length - file_start, 0)
		if has_stop {
			end = min(end, stop)
		}
		end = min(end, total)
		if end <= start || start >= total {
			continue
		}
		scene := ""
		if i, in_scene := tr.scene.?; in_scene {
			scene = v.scenes[i].name
		}
		append(&p.tracks, Placed_Track{track = tr, clip = clip, song = song, start = start, end = end, file_start = file_start, scene = scene})
	}
	// A bus's gain adds to its tracks' (placed tracks carry the sum), and
	// its kind is theirs: a voice bus's tracks are voices (they duck).
	for &pt in p.tracks {
		for b in v.buses {
			if b.name == pt.track.bus && b.name != "" {
				pt.track.gain_db += b.gain_db
				pt.kind = b.kind
				pt.track.voice ||= b.kind == .Voice
			}
		}
	}
	resize(&p.order, len(p.tracks))
	for &o, i in p.order {
		o = i
	}
	context.user_ptr = raw_data(p.tracks)
	slice.stable_sort_by(p.order[:], proc(a, b: int) -> bool {
		t := ([^]Placed_Track)(context.user_ptr)
		return t[a].start < t[b].start
	})
	p.gen = m.audio_gen + 1
}

frames_to_samples :: #force_inline proc "contextless" (frames, fps: int) -> int {
	return int(i64(frames) * MIX_RATE / i64(max(fps, 1)))
}

// ---- the mix as an odawg song ---------------------------------------------------------

// The placed tracks as one song: `song` streams the mix; `bank` holds what
// its Players and Samplers play: the video's sample sets first (a view of
// its bank, at the indices its songs were composed with: rows copied, no
// audio), then a set per clip (lent by the media, not copied). `tracks[i]`
// is placed track i's tracks in the song (first, count). All in `arena`.
Mix :: struct {
	arena:  virtual.Arena,
	song:   osong.Song,
	bank:   odevice.Bank,
	tracks: [][2]i32,
}

// The master limiter's release (fframes' 80 ms).
LIMITER_RELEASE :: 0.08

// Builds the mix of `placed`; `samples = false` leaves the samples out (a
// mix asked only where things are and how loud they are set: `audio at`).
// `load = false` takes the songs' sample sets as the bank has them now
// (the preview: what isn't loaded yet joins when it lands) instead of
// loading them first.
mix_init :: proc(mx: ^Mix, placed: []Placed_Track, opts: Mix_Options, samples := true, load := true) {
	_ = virtual.arena_init_growing(&mx.arena)
	context.allocator = virtual.arena_allocator(&mx.arena)
	osong.mix_init(&mx.song)
	mx.song.bank = &mx.bank
	mx.tracks = make([][2]i32, len(placed))
	// the sample sets the songs play, loaded and viewed as the video's bank
	// has them
	if samples {
		for p in placed {
			if p.song != nil && load {
				song_clip_load(p.song)
			}
		}
		for p in placed {
			if p.song != nil && p.song.song.bank != nil {
				sync.guard(&p.song.music.bank_lock)
				odevice.bank_view(&mx.bank, p.song.song.bank)
				break
			}
		}
	}
	sets := make(map[^Audio_Clip]i32, len(placed), context.temp_allocator)
	for p, i in placed {
		tr := p.track
		first := i32(len(mx.song.tracks))
		if p.song != nil {
			// song time 0 on the video, let through the track's span
			at := f64(p.start - p.file_start) / MIX_RATE
			window := osong.Window{f64(p.start) / MIX_RATE, f64(p.end) / MIX_RATE, f64(tr.fade_in), f64(tr.fade_out), odevice.Curve(tr.curve)}
			duck := tr.ducked ? sidechain_from_ducking(tr.duck) : osong.Sidechain{}
			osong.append_song(&mx.song, &p.song.song, at, tr.src, f64(tr.gain_db), window, duck)
			heard := strings.concatenate({tr.src, "/", p.part}, context.temp_allocator)
			for &t in mx.song.tracks[first:] {
				t.variant = strings.clone(t.variant)
				t.muted = p.muted || (p.part != "" && mx.song.parts[t.part] != heard)
			}
		} else {
			set: i32 = -1
			if samples {
				known: bool
				if set, known = sets[p.clip]; !known {
					set = odevice.bank_borrow(&mx.bank, tr.src, p.clip.samples[:p.clip.frames * 2])
					sets[p.clip] = set
				}
			}
			d := ducking_resolved(tr.duck)
			c := osong.Clip {
				name     = tr.src,
				set      = set,
				start    = f64(p.start) / MIX_RATE,
				stop     = f64(p.end) / MIX_RATE,
				offset   = f64(p.file_start) / MIX_RATE,
				gain_db  = f64(tr.gain_db),
				pan      = f64(tr.pan),
				fade_in  = f64(tr.fade_in),
				fade_out = f64(tr.fade_out),
				curve    = odevice.Curve(tr.curve),
				// a mono file plays as is
				mono     = tr.mono && p.clip.source_channels >= 2,
				voice    = tr.voice,
				ducked   = tr.ducked,
			}
			c.duck = {f64(d.depth_db), f64(d.attack), f64(d.hold), f64(d.release), f64(d.merge_gap)}
			ti := osong.append_clip(&mx.song, c)
			mx.song.tracks[ti].muted = p.muted
		}
		mx.tracks[i] = {first, i32(len(mx.song.tracks)) - first}
	}
	// a song that makes room under a bus ("voice"): that bus's spans
	for p in placed {
		if p.song == nil || p.song.song.room_from == "" {
			continue
		}
		for q in placed {
			if q.track.bus == p.song.song.room_from {
				append(&mx.song.room, [2]f64{f64(q.start) / MIX_RATE, f64(q.end) / MIX_RATE})
			}
		}
	}
	mx.song.master_gain_db = f64(opts.master_gain_db)
	if !opts.no_limiter {
		p := odevice.params_from_kind(.Limiter)
		p[.Threshold] = opts.ceiling_db if opts.ceiling_db != 0 else -1
		p[.Release] = LIMITER_RELEASE
		append(&mx.song.devices, odevice.Device_Kind.Limiter)
		append(&mx.song.params, p)
		append(&mx.song.chain, i32(len(mx.song.devices) - 1))
		mx.song.master = {i32(len(mx.song.chain) - 1), 1}
	}
	osong.mix_end(&mx.song)
}

mix_destroy :: proc(mx: ^Mix) {
	virtual.arena_destroy(&mx.arena)
	mx^ = {}
}

// A ducked song track's sidechain: under the voice tracks' spans, with the
// track's ducking (onimite's defaults for what it leaves out).
@(private = "file")
sidechain_from_ducking :: proc(duck: Ducking) -> osong.Sidechain {
	d := ducking_resolved(duck)
	return {mode = .Spans, depth = f64(d.depth_db), attack = f64(d.attack), hold = f64(d.hold), release = f64(d.release), merge = f64(d.merge_gap)}
}

// The master as odawg measures it, in onimite's terms.
@(private = "file")
mix_stats :: proc(s: orender.Master_Stats) -> Mix_Stats {
	return {clipped_before_limiter = s.clipped_before, peak_before_limiter = s.peak_before, max_reduction_db = s.reduction_db}
}

// Renders `[from, to)` (mix samples) of the mix into interleaved stereo:
// odawg's export (the stream cut into time segments on every core, each
// from an exact seek, the master over them in order), each segment
// interleaved into `out` as it comes: the samples streaming from `from`
// gives, however it is cut.
mix_render :: proc(mx: ^Mix, from, to: int, threads := 0, segment: f64 = 0, allocator := context.allocator) -> (out: []f32, stats: Mix_Stats) {
	n := max(to - from, 0)
	out = make([]f32, n * 2, allocator)
	if n == 0 {
		return
	}
	got := orender.export_song(&mx.song, {from = f64(from) / MIX_RATE, to = f64(to) / MIX_RATE, threads = threads, segment = segment}, {&out, proc(data: rawptr, at: i64, l, r: []f32, stems: [][2][]f32) {
		out := (^[]f32)(data)^
		for i in 0 ..< len(l) {
			k := 2 * (int(at) + i)
			if k + 1 < len(out) {
				out[k], out[k + 1] = l[i], r[i]
			}
		}
	}})
	if mx.song.master.count > 0 || mx.song.master_gain_db != 0 {
		stats = mix_stats(got)
	}
	return
}

// Mixes `[from, to)` (mix samples) of the placed tracks into interleaved
// stereo, the whole range at once.
mix_tracks :: proc(placed: []Placed_Track, from, to: int, opts: Mix_Options = {}, allocator := context.allocator) -> (out: []f32, stats: Mix_Stats) {
	mx: Mix
	mix_init(&mx, placed, opts)
	defer mix_destroy(&mx)
	return mix_render(&mx, from, to, allocator = allocator)
}

// The mix played block by block (the preview's audio callback): one
// engine streaming it, put where a block asks when the position jumps (a
// seek: notes sounding there are picked up, effects start afresh), so
// consecutive blocks are the render's samples.
Mix_Stream :: struct {
	mix:    Mix,
	engine: orender.Engine,
	// Where the next block is expected.
	next:   int,
	ready:  bool,
}

mix_stream_init :: proc(st: ^Mix_Stream, placed: []Placed_Track, opts: Mix_Options, load := true) {
	mix_init(&st.mix, placed, opts, load = load)
	st.ready = orender.engine_init(&st.engine, &st.mix.song)
	st.next = 0
}

mix_stream_destroy :: proc(st: ^Mix_Stream) {
	if st.ready {
		orender.engine_destroy(&st.engine)
	}
	mix_destroy(&st.mix)
	st^ = {}
}

// Mixes the `len(out) / 2` samples from `from` into `out` (interleaved
// stereo), continuing `st`. Scratch comes from the temp allocator.
mix_block :: proc(st: ^Mix_Stream, from: int, out: []f32) {
	n := len(out) / 2
	if n == 0 || !st.ready {
		return
	}
	if from != st.next {
		orender.engine_seek(&st.engine, i64(from), false)
	}
	buf := make([]f32, 2 * n, context.temp_allocator)
	l, r := buf[:n], buf[n:]
	orender.engine_process(&st.engine, l, r)
	for i in 0 ..< n {
		out[i * 2], out[i * 2 + 1] = l[i], r[i]
	}
	st.next = from + n
}

// The ducking gain (0..1) of placed track `i` at mix sample `at`: how far
// the voice tracks dip it there (1: not ducked).
mix_duck_gain :: proc(mx: ^Mix, i: int, at: int) -> f32 {
	span := mx.tracks[i]
	if span[1] == 0 {
		return 1
	}
	t := mx.song.tracks[span[0]]
	l, r := [1]f32{1}, [1]f32{1}
	for sc in mx.song.sidechains[t.sidechains.first:t.sidechains.first + t.sidechains.count] {
		if sc.mode == .Spans {
			orender.SIDECHAIN_TABLE[.Spans](&mx.song, sc, i64(at), l[:], r[:])
		}
	}
	return l[0]
}

// The shortest fade a track starts and ends with (no click): 3 ms, as
// odawg's Player and a song's window play it.
DECLICK :: MIX_RATE * 3 / 1000

// A track's fade gain (0 to 1) `k` samples into its `length` samples: its
// fade in times its fade out (lengths in samples), each at least DECLICK:
// what the mix plays, for `audio at` and the preview's waveforms.
track_envelope :: #force_inline proc "contextless" (k, length, fade_in, fade_out: int, curve: Fade_Curve) -> f32 {
	return fade_gain(k, max(fade_in, DECLICK), curve) * fade_gain(length - 1 - k, max(fade_out, DECLICK), curve)
}

// The loudest track_envelope over samples `[k0, k1)` of the track (a
// waveform's bucket or pixel): at the sample nearest its full level, which
// the fade in rises to and the fade out falls from.
track_envelope_peak :: proc "contextless" (k0, k1, length, fade_in, fade_out: int, curve: Fade_Curve) -> f32 {
	full := clamp(k0, max(fade_in, DECLICK), length - 1 - max(fade_out, DECLICK))
	return track_envelope(clamp(full, k0, max(k1 - 1, k0)), length, fade_in, fade_out, curve)
}

// Gain (0 to 1) `k` samples into a fade of `length` samples.
@(private = "file")
fade_gain :: #force_inline proc "contextless" (k, length: int, curve: Fade_Curve) -> f32 {
	if length <= 0 || k >= length {
		return 1
	}
	t := f32(max(k, 0)) / f32(length)
	if curve == .Equal_Power {
		return math.sin(t * math.PI / 2)
	}
	return t
}
