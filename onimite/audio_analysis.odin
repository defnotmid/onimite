package onimite

import "core:math"
import oanalyze "deps:odawg/analyze"

// Loudness and level checks of a mix (interleaved stereo at MIX_RATE), as
// fframes' `audio analyze` reports them: ITU-R BS.1770-4 integrated loudness
// and EBU Tech 3342 loudness range, true peak, the loudness curves,
// clipping and silences, all measured by odawg's analyze; this is the
// report onimite's commands print.

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
	if len(x) < 2 {
		r.integrated_lufs = math.inf_f32(-1)
		return
	}
	l, rr := channels_from_interleaved(x)
	lu := oanalyze.loudness_from_samples(l, rr, MIX_RATE, context.temp_allocator)
	r.integrated_lufs = f32(lu.integrated)
	r.loudness_range = f32(lu.range)
	r.sample_peak_db = f32(lu.sample_peak)
	r.true_peak_db = f32(lu.true_peak)
	r.max_momentary = math.inf_f32(-1)
	for v in lu.momentary {
		append(&r.momentary_curve, v)
		r.max_momentary = max(r.max_momentary, v)
	}
	// short-term values from 3 s on are whole 3 s blocks
	r.max_short_term = math.inf_f32(-1)
	for v, i in lu.short_term {
		append(&r.short_term_curve, v)
		if i >= 29 {
			r.max_short_term = max(r.max_short_term, v)
		}
	}
	r.clipped_samples = oanalyze.clipped_from_samples(l, rr)
	for span in oanalyze.silences_from_samples(l, rr, MIX_RATE, SILENCE_DBFS, SILENCE_MIN_SECONDS, context.temp_allocator) {
		append(&r.silent_ranges, [2]f32{f32(span[0]), f32(span[1])})
	}
	return
}
