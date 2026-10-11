package onimite

import "core:math"
import "core:slice"

// Loudness and level checks of a mix (interleaved stereo at MIX_RATE), as
// fframes' `audio analyze` reports them: ITU-R BS.1770-4 integrated loudness
// and EBU Tech 3342 loudness range, true peak, clipping and silences.

Audio_Report :: struct {
	integrated_lufs:  f32, // -inf for silence
	loudness_range:   f32, // LU
	max_momentary:    f32, // LUFS, 400 ms
	max_short_term:   f32, // LUFS, 3 s
	sample_peak_db:   f32,
	true_peak_db:     f32, // dBTP, 4x oversampled
	clipped_samples:  int,
	silent_ranges:    [dynamic][2]f32, // seconds, >= 0.5 s below -60 dBFS
	// Short-term loudness every 100 ms (for curves), LUFS.
	short_term_curve: [dynamic]f32,
	// Momentary (400 ms) loudness every 100 ms, the first block ending at
	// 0.4 s, LUFS.
	momentary_curve:  [dynamic]f32,
}

SILENCE_DBFS :: -60
SILENCE_MIN_SECONDS :: 0.5

audio_report_destroy :: proc(r: ^Audio_Report) {
	delete(r.silent_ranges)
	delete(r.short_term_curve)
	delete(r.momentary_curve)
	r^ = {}
}

analyze_audio :: proc(x: []f32, allocator := context.allocator) -> (r: Audio_Report) {
	r.silent_ranges = make([dynamic][2]f32, allocator)
	r.short_term_curve = make([dynamic]f32, allocator)
	r.momentary_curve = make([dynamic]f32, allocator)
	n := len(x) / 2
	if n == 0 {
		r.integrated_lufs = math.inf_f32(-1)
		return
	}

	// K-weighted mean square per 100 ms step, then summed into blocks.
	weighted := k_weight(x)
	STEP :: MIX_RATE / 10
	steps := n / STEP
	energy := make([]f64, steps, context.temp_allocator)
	for s in 0 ..< steps {
		sum: f64
		for i in s * STEP ..< (s + 1) * STEP {
			l, rr := f64(weighted[i * 2]), f64(weighted[i * 2 + 1])
			sum += l * l + rr * rr
		}
		energy[s] = sum / STEP
	}
	block_loudness :: proc(energy: []f64, first, count: int) -> (f64, f64) {
		sum: f64
		for e in energy[first:][:count] {
			sum += e
		}
		ms := sum / f64(count)
		return ms, -0.691 + 10 * math.log10(max(ms, 1e-20))
	}

	// Integrated: 400 ms blocks every 100 ms, gated at -70 LUFS absolute and
	// 10 LU below the ungated mean.
	r.max_momentary = math.inf_f32(-1)
	Block :: struct {
		ms, lufs: f64,
	}
	blocks := make([dynamic]Block, context.temp_allocator)
	for s := 0; s + 4 <= steps; s += 1 {
		ms, l := block_loudness(energy, s, 4)
		append(&blocks, Block{ms, l})
		append(&r.momentary_curve, f32(l))
		r.max_momentary = max(r.max_momentary, f32(l))
	}
	r.integrated_lufs = gated_loudness(blocks[:])

	// Loudness range: 3 s blocks, -70 absolute and -20 relative gates,
	// P95 - P10.
	r.max_short_term = math.inf_f32(-1)
	short := make([dynamic]Block, context.temp_allocator)
	for s := 0; s < steps; s += 1 {
		count := min(30, s + 1)
		ms, l := block_loudness(energy, s + 1 - count, count)
		append(&r.short_term_curve, f32(l))
		if s + 1 >= 30 {
			append(&short, Block{ms, l})
			r.max_short_term = max(r.max_short_term, f32(l))
		}
	}
	{
		abs_gated := make([dynamic]f64, context.temp_allocator)
		sum: f64
		for b in short {
			if b.lufs > -70 {
				append(&abs_gated, b.lufs)
				sum += b.ms
			}
		}
		if len(abs_gated) > 0 {
			rel := -0.691 + 10 * math.log10(sum / f64(len(abs_gated))) - 20
			kept := make([dynamic]f64, context.temp_allocator)
			for l in abs_gated {
				if l > rel {
					append(&kept, l)
				}
			}
			if len(kept) > 1 {
				slice.sort(kept[:])
				p := proc(v: []f64, q: f64) -> f64 {
					return v[clamp(int(math.round(q * f64(len(v) - 1))), 0, len(v) - 1)]
				}
				r.loudness_range = f32(p(kept[:], 0.95) - p(kept[:], 0.10))
			}
		}
	}

	// Peaks and clipping.
	peak: f32
	for s in x {
		peak = max(peak, abs(s))
		if abs(s) >= 1 {
			r.clipped_samples += 1
		}
	}
	r.sample_peak_db = 20 * math.log10(max(peak, 1e-9))
	r.true_peak_db = 20 * math.log10(max(true_peak(x), 1e-9))

	// Silences: 50 ms windows below SILENCE_DBFS, merged, at least 0.5 s.
	WIN :: MIX_RATE / 20
	threshold := math.pow(f64(10), SILENCE_DBFS / 10.0)
	run_start := -1
	windows := n / WIN
	for w in 0 ..= windows {
		quiet := false
		if w < windows {
			sum: f64
			for i in w * WIN ..< (w + 1) * WIN {
				sum += f64(x[i * 2]) * f64(x[i * 2]) + f64(x[i * 2 + 1]) * f64(x[i * 2 + 1])
			}
			quiet = sum / f64(2 * WIN) < threshold
		}
		if quiet && run_start < 0 {
			run_start = w
		} else if !quiet && run_start >= 0 {
			a := f32(run_start * WIN) / MIX_RATE
			b := f32(w * WIN) / MIX_RATE
			if b - a >= SILENCE_MIN_SECONDS {
				append(&r.silent_ranges, [2]f32{a, b})
			}
			run_start = -1
		}
	}
	return
}

@(private)
gated_loudness :: proc(blocks: []$B) -> f32 {
	sum: f64
	count := 0
	for b in blocks {
		if b.lufs > -70 {
			sum += b.ms
			count += 1
		}
	}
	if count == 0 {
		return math.inf_f32(-1)
	}
	rel := -0.691 + 10 * math.log10(sum / f64(count)) - 10
	sum, count = 0, 0
	for b in blocks {
		if b.lufs > -70 && b.lufs > rel {
			sum += b.ms
			count += 1
		}
	}
	if count == 0 {
		return math.inf_f32(-1)
	}
	return f32(-0.691 + 10 * math.log10(sum / f64(count)))
}

// BS.1770 K-weighting at 48 kHz: high shelf, then RLB high-pass.
@(private)
k_weight :: proc(x: []f32) -> []f32 {
	out := make([]f32, len(x), context.temp_allocator)
	Biquad :: struct {
		b0, b1, b2, a1, a2: f64,
	}
	shelf := Biquad{1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585}
	hp := Biquad{1, -2, 1, -1.99004745483398, 0.99007225036621}
	for ch in 0 ..< 2 {
		s1, s2, h1, h2: f64 // direct form II transposed states
		for i := ch; i < len(x); i += 2 {
			v := f64(x[i])
			y := shelf.b0 * v + s1
			s1 = shelf.b1 * v - shelf.a1 * y + s2
			s2 = shelf.b2 * v - shelf.a2 * y
			z := hp.b0 * y + h1
			h1 = hp.b1 * y - hp.a1 * z + h2
			h2 = hp.b2 * y - hp.a2 * z
			out[i] = f32(z)
		}
	}
	return out
}

// Peak of the signal reconstructed at 4x the sample rate (windowed-sinc
// interpolation between samples).
@(private)
true_peak :: proc(x: []f32) -> f32 {
	TAPS :: 8
	n := len(x) / 2
	peak: f32
	// Kernel for the three in-between phases.
	kernel: [3][2 * TAPS]f32
	for ph in 0 ..< 3 {
		frac := f64(ph + 1) / 4
		for k in 0 ..< 2 * TAPS {
			t := f64(k - TAPS + 1) - frac
			kernel[ph][k] = f32(lanczos(t, TAPS))
		}
	}
	for ch in 0 ..< 2 {
		for i in 0 ..< n {
			peak = max(peak, abs(x[i * 2 + ch]))
			if i + TAPS >= n || i < TAPS - 1 {
				continue
			}
			for ph in 0 ..< 3 {
				sum: f32
				for k in 0 ..< 2 * TAPS {
					sum += x[(i - TAPS + 1 + k) * 2 + ch] * kernel[ph][k]
				}
				peak = max(peak, abs(sum))
			}
		}
	}
	return peak
}
