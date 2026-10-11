package onimite

import "core:math"
import "core:slice"
import "core:strings"
import "core:sync"

// Onsets: where sounds start (hits, notes, words), and the steady beat they
// imply, so a script or an agent that can't listen can place cues on the
// music. Spectral flux on log magnitudes (1024-sample frames every 256
// samples, about 5 ms), adaptive-threshold peak picking, then each onset is
// moved to the attack in the time domain (1 ms steps). The beat is the
// autocorrelation peak of the flux between 60 and 200 BPM (favouring
// 120), its phase the one the strongest onsets agree on.

Onset :: struct {
	time:     f32, // seconds from the start of the samples
	// 0..1: the rise in level at the attack (RMS over 20 ms after it minus
	// before it), relative to the largest rise.
	strength: f32,
}

Onset_Report :: struct {
	onsets: [dynamic]Onset,
	// 0 when there is no steady beat.
	bpm:    f32,
	// Where the first beat falls (seconds, 0 <= offset < 60 / bpm).
	offset: f32,
}

onset_report_destroy :: proc(r: ^Onset_Report) {
	delete(r.onsets)
	r^ = {}
}

@(private = "file")
ONSET_SIZE :: 1024
@(private = "file")
ONSET_HOP :: 256
// Envelope frames per second.
@(private = "file")
ONSET_RATE :: f32(MIX_RATE) / ONSET_HOP

// Onsets of interleaved stereo `x` at MIX_RATE.
audio_onsets :: proc(x: []f32, allocator := context.allocator) -> (r: Onset_Report) {
	r.onsets = make([dynamic]Onset, allocator)
	n := len(x) / 2
	if n < ONSET_SIZE {
		return
	}
	frames := (n - ONSET_SIZE) / ONSET_HOP + 1
	env := make([]f32, frames, context.temp_allocator)
	spectral_flux(x, env)

	peak := slice.max(env)
	if peak <= 0 {
		return
	}
	// A peak: the largest within ±3 frames (16 ms), above the local mean
	// (±16 frames) by a margin, and not a ripple of a much louder one.
	WIDE :: 16
	sum: f32
	for i in 0 ..< min(WIDE, frames) {
		sum += env[i]
	}
	last := -100
	for i in 0 ..< frames {
		if i + WIDE < frames {sum += env[i + WIDE]}
		if i - WIDE - 1 >= 0 {sum -= env[i - WIDE - 1]}
		lo, hi := max(i - WIDE, 0), min(i + WIDE, frames - 1)
		mean := sum / f32(hi - lo + 1)
		v := env[i]
		if v < 0.06 * peak || v < mean * 1.4 + 0.02 * peak {
			continue
		}
		is_max := true
		for k in max(i - 3, 0) ..= min(i + 3, frames - 1) {
			if env[k] > v || (env[k] == v && k < i) {
				is_max = false
				break
			}
		}
		if !is_max || i - last < 6 { // 30 ms apart at least
			continue
		}
		last = i
		at := attack_time(x, i)
		append(&r.onsets, Onset{at, level_rise(x, at)})
	}
	strongest: f32
	for o in r.onsets {
		strongest = max(strongest, o.strength)
	}
	// Relative strengths; a rise under 2% of the largest is no onset (a
	// spectral change inside a held sound).
	kept := 0
	for o in r.onsets {
		v := o.strength / strongest if strongest > 0 else 0
		if v >= 0.02 {
			r.onsets[kept] = {o.time, v}
			kept += 1
		}
	}
	resize(&r.onsets, kept)
	r.bpm, r.offset = estimate_beat(env, r.onsets[:])
	return
}

// Positive log-magnitude change per frame, summed over frequencies. Before
// the samples is silence: a sound from the first sample is an onset there.
@(private = "file")
spectral_flux :: proc(x: []f32, env: []f32) {
	window: [ONSET_SIZE]f32
	for k in 0 ..< ONSET_SIZE {
		window[k] = 0.5 * (1 - math.cos(2 * math.PI * f32(k) / ONSET_SIZE))
	}
	prev, cur: [ONSET_SIZE / 2]f32
	re, im: [ONSET_SIZE]f32
	for i in 0 ..< len(env) {
		src := x[i * ONSET_HOP * 2:][:ONSET_SIZE * 2]
		for k in 0 ..< ONSET_SIZE {
			re[k] = (src[k * 2] + src[k * 2 + 1]) * 0.5 * window[k]
			im[k] = 0
		}
		fft(re[:], im[:])
		flux: f32
		for k in 1 ..< ONSET_SIZE / 2 {
			mag := math.sqrt(re[k] * re[k] + im[k] * im[k])
			cur[k] = math.ln(1 + 100 * mag)
			flux += max(cur[k] - prev[k], 0)
		}
		env[i] = flux
		prev = cur
	}
}

// The attack of the onset flux frame `i` found: in 1 ms blocks around the
// frame, the block after which the energy rises the most.
@(private = "file")
attack_time :: proc(x: []f32, i: int) -> f32 {
	BLOCK :: MIX_RATE / 1000
	n := len(x) / 2
	from := max(i * ONSET_HOP, 0)
	to := min(i * ONSET_HOP + ONSET_SIZE, n)
	blocks := (to - from) / BLOCK
	if blocks < 3 {
		return f32(from + ONSET_SIZE / 2) / MIX_RATE
	}
	energy :: proc(x: []f32, a, b: int) -> f32 {
		e: f32
		for s in a ..< b {
			l, r := x[s * 2], x[s * 2 + 1]
			e += l * l + r * r
		}
		return e
	}
	best, best_rise := from + ONSET_SIZE / 2, f32(0)
	prev := energy(x, max(from - 4 * BLOCK, 0), from) / 4 // 4 ms before
	for b in 0 ..< blocks {
		a := from + b * BLOCK
		e := energy(x, a, a + BLOCK)
		rise := math.ln((e + 1e-9) / (prev + 1e-9))
		if rise > best_rise {
			best, best_rise = a, rise
		}
		prev = prev * 0.5 + e * 0.5
	}
	return f32(best) / MIX_RATE
}

// RMS over the 20 ms after `at` minus over the 20 ms before (0 for a fall).
@(private = "file")
level_rise :: proc(x: []f32, at: f32) -> f32 {
	W :: MIX_RATE / 50
	n := len(x) / 2
	s := int(at * MIX_RATE)
	rms :: proc(x: []f32, a, b: int) -> f32 {
		if b <= a {
			return 0
		}
		e: f32
		for k in a ..< b {
			e += x[k * 2] * x[k * 2] + x[k * 2 + 1] * x[k * 2 + 1]
		}
		return math.sqrt(e / f32(2 * (b - a)))
	}
	return max(rms(x, s, min(s + W, n)) - rms(x, max(s - W, 0), s), 0)
}

// The steady beat of the flux envelope: bpm (0 for none) and the phase of
// the first beat, snapped to the strongest onset near the grid.
@(private = "file")
estimate_beat :: proc(env: []f32, onsets: []Onset) -> (bpm, offset: f32) {
	n := len(env)
	lo := 56 // 200 BPM, in envelope frames
	hi := 188 // 60 BPM
	if n < hi * 4 || len(onsets) < 8 {
		return 0, 0
	}
	mean: f32
	for v in env {
		mean += v
	}
	mean /= f32(n)
	e := make([]f32, n, context.temp_allocator)
	for v, i in env {
		e[i] = max(v - mean, 0)
	}
	ac := make([]f32, hi + 2, context.temp_allocator)
	for l in 0 ..< len(ac) {
		s: f32
		for i in 0 ..< n - l {
			s += e[i] * e[i + l]
		}
		ac[l] = s
	}
	if ac[0] <= 0 {
		return 0, 0
	}
	best, best_score := 0, f32(0)
	for l in lo ..= hi {
		if ac[l] < ac[l - 1] || ac[l] < ac[l + 1] {
			continue
		}
		b := 60 * ONSET_RATE / f32(l)
		octaves := math.log2(b / 120)
		score := ac[l] * math.exp(-0.5 * octaves * octaves)
		if score > best_score {
			best, best_score = l, score
		}
	}
	if best == 0 || ac[best] < 0.1 * ac[0] {
		return 0, 0
	}
	// Parabolic peak for a fractional lag.
	y0, y1, y2 := ac[best - 1], ac[best], ac[best + 1]
	shift: f32
	if d := y0 - 2 * y1 + y2; d != 0 {
		shift = clamp(0.5 * (y0 - y2) / d, -0.5, 0.5)
	}
	lag := f32(best) + shift
	bpm = 60 * ONSET_RATE / lag
	period := lag / ONSET_RATE

	// The phase whose grid collects the most onset strength (10 ms steps),
	// then the strongest onset within 30 ms of it.
	PHASES :: 100
	best_phase, best_sum := f32(0), f32(-1)
	for p in 0 ..< PHASES {
		phase := period * f32(p) / PHASES
		s: f32
		for o in onsets {
			d := math.mod(o.time - phase + period * 1000, period)
			d = min(d, period - d)
			if d < 0.02 {
				s += o.strength
			}
		}
		if s > best_sum {
			best_phase, best_sum = phase, s
		}
	}
	offset = best_phase
	strongest := f32(0)
	for o in onsets {
		d := math.mod(o.time - best_phase + period * 1000, period)
		if (d < 0.03 || period - d < 0.03) && o.strength > strongest {
			strongest = o.strength
			offset = math.mod(o.time, period)
		}
	}
	return
}

// Onsets of media clips, computed once per clip and shared by everything
// that uses the media (every frame builder of a render). A clip replaced
// under the same name (a preview reload) is analysed again.
Onset_Cache :: struct {
	mutex:   sync.Mutex,
	entries: map[string]Onset_Cache_Entry,
}

@(private)
Onset_Cache_Entry :: struct {
	samples: rawptr, // the clip analysed
	report:  Onset_Report,
}

// The onsets of clip `name` (borrowed from the cache until the media is
// destroyed or the clip replaced); false when there is no such clip.
media_onsets :: proc(m: ^Media, name: string) -> (r: Onset_Report, ok: bool) {
	clip, has := m.audio[name]
	if !has {
		return {}, false
	}
	c := m.onsets
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	if e, seen := &c.entries[name]; seen {
		if e.samples == raw_data(clip.samples) {
			return e.report, true
		}
		onset_report_destroy(&e.report)
		e^ = {raw_data(clip.samples), audio_onsets(clip.samples, c.entries.allocator)}
		return e.report, true
	}
	e := Onset_Cache_Entry{raw_data(clip.samples), audio_onsets(clip.samples, c.entries.allocator)}
	c.entries[strings.clone(name, c.entries.allocator)] = e
	return e.report, true
}

@(private)
onset_cache_destroy :: proc(c: ^Onset_Cache) {
	for name, &e in c.entries {
		delete(name, c.entries.allocator)
		onset_report_destroy(&e.report)
	}
	delete(c.entries)
}
