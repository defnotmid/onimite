package onimite

import "core:math"
import "core:slice"

// The mix: every track placed on the video timeline, summed linearly with
// gain, balance, fades and ducking, then a peak limiter on the master bus
// (fframes' defaults: -1 dBFS ceiling).

Mix_Options :: struct {
	master_gain_db: f32,
	// Limiter ceiling; 0 means -1 dBFS.
	ceiling_db:     f32,
	no_limiter:     bool,
}

// A track resolved to sample positions on the video timeline.
Placed_Track :: struct {
	track:      Audio_Track,
	clip:       ^Audio_Clip,
	// `[start, end)` in mix samples (per channel) from the video start.
	start, end: int,
	// First clip sample played.
	file_start: int,
	// The owning scene, or "" for video tracks.
	scene:      string,
	// Left out of the mix but still a voice for ducking (one track heard
	// alone, as it sounds in the mix).
	muted:      bool,
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

// Where track `tr` of a part that starts `origin` mix samples into the
// video starts and (`has_stop`) stops, in mix samples; false when a time
// term names a clip the media lacks (a load diagnostic).
track_times :: proc(tr: Audio_Track, origin, fps: int, m: ^Media) -> (start, stop: int, has_stop, ok: bool) {
	start_s, stop_s := f64(tr.start), f64(tr.stop)
	if len(tr.start_terms) > 0 {
		start_s, _ = terms_seconds(tr.start_terms, fps, m) or_return
	}
	has_stop = tr.stop > tr.start
	if len(tr.stop_terms) > 0 {
		stop_s, _ = terms_seconds(tr.stop_terms, fps, m) or_return
		has_stop = true
	}
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

// Places the video's and scenes' tracks on timeline `t` into `p`. Tracks
// whose sound the media lacks are left out (the load reports them).
placed_audio_update :: proc(p: ^Placed_Audio, v: ^Video, t: Timeline, m: ^Media) {
	clear(&p.tracks)
	total := frames_to_samples(t.duration_frames, v.fps)
	place :: proc(placed: ^[dynamic]Placed_Track, m: ^Media, tr: Audio_Track, origin: int, scene: string, total: int, fps: int) {
		clip, has := &m.audio[tr.src]
		if !has {
			return
		}
		start, stop, has_stop, ok := track_times(tr, origin, fps, m)
		if !ok {
			return
		}
		file_start := seconds_to_samples(tr.offset)
		end := start + max(clip.frames - file_start, 0)
		if has_stop {
			end = min(end, stop)
		}
		end = min(end, total)
		if end <= start || start >= total {
			return
		}
		append(placed, Placed_Track{track = tr, clip = clip, start = start, end = end, file_start = file_start, scene = scene})
	}
	for tr in v.audio {
		place(&p.tracks, m, tr, 0, "", total, v.fps)
	}
	for info in t.scenes {
		origin := frames_to_samples(info.start_frame, v.fps)
		for tr in info.scene.audio {
			place(&p.tracks, m, tr, origin, info.scene.name, total, v.fps)
		}
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

// Mixes `[from, to)` (mix samples) of the placed tracks into interleaved
// stereo, the whole range at once.
mix_tracks :: proc(placed: []Placed_Track, from, to: int, opts: Mix_Options = {}, allocator := context.allocator) -> (out: []f32, stats: Mix_Stats) {
	n := max(to - from, 0)
	out = make([]f32, n * 2, allocator)
	if n == 0 {
		return
	}
	mix_sum(placed, from, to, out)
	stats = master(out, n, opts, nil)
	return
}

// A mix made block by block (the preview's audio callback): the limiter's
// envelope carries from one block to the next, and each block looks ahead
// of its end, so consecutive blocks sound like one mix of the whole.
Mix_Stream :: struct {
	env:  f32,
	// Where the next block is expected; a block elsewhere (a seek) starts
	// the limiter afresh.
	next: int,
}

// Mixes the `len(out) / 2` samples from `from` into `out` (interleaved
// stereo), continuing `st`. Scratch comes from the temp allocator.
mix_block :: proc(placed: []Placed_Track, from: int, out: []f32, opts: Mix_Options, st: ^Mix_Stream) {
	n := len(out) / 2
	if n == 0 {
		return
	}
	if from != st.next || st.env <= 0 {
		st.env = 1
	}
	look := 0 if opts.no_limiter else LIMIT_LOOK
	buf := make([]f32, (n + look) * 2, context.temp_allocator)
	mix_sum(placed, from, from + n + look, buf)
	master(buf, n, opts, &st.env)
	copy(out, buf[:n * 2])
	st.next = from + n
}

// Adds every unmuted track's samples in `[from, to)` to `out`.
@(private = "file")
mix_sum :: proc(placed: []Placed_Track, from, to: int, out: []f32) {
	duck_cache := make(map[Ducking][]f32, context.temp_allocator)
	for &p in placed {
		lo := max(p.start, from)
		hi := min(p.end, to)
		if hi <= lo || p.muted {
			continue
		}
		tr := p.track
		gain := math.pow(10, tr.gain_db / 20)
		gl := min(1, 1 - tr.pan) * gain
		gr := min(1, 1 + tr.pan) * gain
		fade_in := seconds_to_samples(tr.fade_in)
		fade_out := seconds_to_samples(tr.fade_out)
		duck: []f32
		if tr.ducked {
			d := ducking_resolved(tr.duck)
			cached, ok := duck_cache[d]
			if !ok {
				cached = duck_envelope(placed, d, from, to)
				duck_cache[d] = cached
			}
			duck = cached
		}
		length := p.end - p.start
		mono := tr.mono && p.clip.source_channels >= 2
		for s in lo ..< hi {
			k := s - p.start
			src := p.file_start + k
			if src < 0 || src >= p.clip.frames {
				continue
			}
			env := track_envelope(k, length, fade_in, fade_out, tr.curve)
			if duck != nil {
				env *= duck[s - from]
			}
			o := (s - from) * 2
			l, r := p.clip.samples[src * 2], p.clip.samples[src * 2 + 1]
			if mono {
				l = l * 0.70710678 + r * 0.70710678
				r = l
			}
			out[o] += l * gl * env
			out[o + 1] += r * gr * env
		}
	}
}

// The master bus over the first `n` samples of `x` (which may hold look-ahead
// past them): gain, then the limiter, continuing `env` when given.
@(private = "file")
master :: proc(x: []f32, n: int, opts: Mix_Options, env: ^f32) -> (stats: Mix_Stats) {
	gain := math.pow(10, opts.master_gain_db / 20)
	for &v in x {
		v *= gain
	}
	for v in x[:n * 2] {
		stats.peak_before_limiter = max(stats.peak_before_limiter, abs(v))
		if abs(v) > 1 {
			stats.clipped_before_limiter += 1
		}
	}
	if !opts.no_limiter {
		ceiling_db := opts.ceiling_db if opts.ceiling_db != 0 else -1
		start: f32 = 1
		e := env if env != nil else &start
		stats.max_reduction_db = limit(x, n, math.pow(10, ceiling_db / 20), e)
	}
	return
}

// The shortest fade a track starts and ends with (no click): 3 ms.
DECLICK :: MIX_RATE * 3 / 1000

// A track's fade gain (0 to 1) `k` samples into its `length` samples: its
// fade in times its fade out (lengths in samples), each at least DECLICK.
// The mix, `audio at` and the preview's waveforms all use it.
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

// The ducking gain at every sample of `[from, to)`: 1 away from voice,
// `depth` under it, ramping over `attack` before and `release` after (with
// `hold`). Voice regions closer than `merge_gap` merge.
duck_envelope :: proc(placed: []Placed_Track, d: Ducking, from, to: int) -> []f32 {
	n := to - from
	weight := make([]f32, n, context.temp_allocator)
	Region :: struct {
		a, b: int,
	}
	regions := make([dynamic]Region, context.temp_allocator)
	for p in placed {
		if p.track.voice {
			append(&regions, Region{p.start, p.end})
		}
	}
	// Sort by start (few regions: insertion sort), then merge.
	for i in 1 ..< len(regions) {
		for j := i; j > 0 && regions[j].a < regions[j - 1].a; j -= 1 {
			regions[j], regions[j - 1] = regions[j - 1], regions[j]
		}
	}
	gap := seconds_to_samples(d.merge_gap)
	merged := make([dynamic]Region, context.temp_allocator)
	for r in regions {
		if len(merged) > 0 && r.a - merged[len(merged) - 1].b < gap {
			last := &merged[len(merged) - 1]
			last.b = max(last.b, r.b)
		} else {
			append(&merged, r)
		}
	}
	attack := seconds_to_samples(d.attack)
	hold := seconds_to_samples(d.hold)
	release := seconds_to_samples(d.release)
	for r in merged {
		lo := max(r.a - attack, from)
		hi := min(r.b + hold + release, to)
		for s in lo ..< hi {
			w: f32 = 1
			switch {
			case s < r.a:
				w = f32(s - (r.a - attack)) / f32(max(attack, 1))
			case s >= r.b + hold:
				w = 1 - f32(s - (r.b + hold)) / f32(max(release, 1))
			}
			weight[s - from] = max(weight[s - from], w)
		}
	}
	depth := math.pow(10, d.depth_db / 20)
	for &w in weight {
		w = 1 + (depth - 1) * w
	}
	return weight
}

// The limiter's look-ahead (and attack) in samples.
LIMIT_LOOK :: MIX_RATE * 5 / 1000

// Look-ahead peak limiter (5 ms look-ahead and attack, 80 ms release) that
// keeps |sample| <= ceiling over the first `n` samples of `x`; the samples
// after them are look-ahead only. `env` is the gain envelope going in and
// coming out. Returns the deepest reduction in dB.
@(private)
limit :: proc(x: []f32, n: int, ceiling: f32, env: ^f32) -> f32 {
	total := len(x) / 2
	look := LIMIT_LOOK
	need := make([]f32, total, context.temp_allocator)
	for i in 0 ..< total {
		peak := max(abs(x[i * 2]), abs(x[i * 2 + 1]))
		need[i] = ceiling / peak if peak > ceiling else 1
	}
	// Sliding minimum of `need` over the next `look` samples (monotonic deque).
	window := make([]f32, total, context.temp_allocator)
	deque := make([]int, total + 1, context.temp_allocator)
	head, tail := 0, 0
	for i := total - 1; i >= 0; i -= 1 {
		for tail > head && need[deque[tail - 1]] >= need[i] {
			tail -= 1
		}
		deque[tail] = i
		tail += 1
		for deque[head] > i + look {
			head += 1
		}
		window[i] = need[deque[head]]
	}
	attack := 1 - math.exp(-1 / f32(look))
	release := 1 - math.exp(-1 / f32(0.08 * MIX_RATE))
	e := env^
	deepest: f32 = 1
	for i in 0 ..< n {
		t := window[i]
		e += (t - e) * (attack if t < e else release)
		g := min(e, need[i])
		deepest = min(deepest, g)
		x[i * 2] = clamp(x[i * 2] * g, -ceiling, ceiling)
		x[i * 2 + 1] = clamp(x[i * 2 + 1] * g, -ceiling, ceiling)
	}
	env^ = e
	return 20 * math.log10(deepest)
}
