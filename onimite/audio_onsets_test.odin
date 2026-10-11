package onimite

import "core:math"
import "core:math/rand"
import "core:testing"

// Kicks on a 128 BPM grid from 0.31 s with quieter hats between them, over
// low noise: every kick is found within 3 ms, the hats are weaker, and the
// beat comes out at 128 BPM with its first beat on the first kick.
@(test)
test_audio_onsets :: proc(t: ^testing.T) {
	BPM :: 128
	FIRST :: 0.31
	period := f32(60) / BPM
	n := MIX_RATE * 12
	x := make([]f32, n * 2)
	defer delete(x)
	r := rand.create(7)
	for i in 0 ..< n {
		v := (rand.float32(rand.default_random_generator()) - 0.5) * 0.002
		x[i * 2], x[i * 2 + 1] = v, v
	}
	kicks := make([dynamic]f32, context.temp_allocator)
	for beat := f32(FIRST); beat < 11.5; beat += period {
		append(&kicks, beat)
		s0 := int(beat * MIX_RATE)
		for k in 0 ..< MIX_RATE / 4 {
			tt := f32(k) / MIX_RATE
			v := math.sin(2 * math.PI * (50 + 120 * math.exp(-tt * 30)) * tt) * math.exp(-tt * 9) * 0.8
			x[(s0 + k) * 2] += v
			x[(s0 + k) * 2 + 1] += v
		}
		h0 := int((beat + period / 2) * MIX_RATE)
		for k in 0 ..< MIX_RATE / 20 {
			v := (rand.float32(rand.default_random_generator()) - 0.5) * 0.25 * math.exp(-f32(k) / MIX_RATE * 60)
			x[(h0 + k) * 2] += v
			x[(h0 + k) * 2 + 1] += v
		}
	}
	_ = r
	rep := audio_onsets(x)
	defer onset_report_destroy(&rep)
	for kick in kicks {
		found := false
		for o in rep.onsets {
			if abs(o.time - kick) < 0.003 {
				found = true
				testing.expectf(t, o.strength > 0.5, "kick at %.3f: strength %.2f", kick, o.strength)
			}
		}
		testing.expectf(t, found, "no onset within 3 ms of the kick at %.3f", kick)
	}
	testing.expectf(t, abs(rep.bpm - BPM) < 0.5, "bpm %.2f", rep.bpm)
	testing.expectf(t, abs(rep.offset - FIRST) < 0.005, "offset %.3f", rep.offset)
}

// A mix made block by block (the preview's audio callback) matches the mix
// of the whole range, the limiter included.
@(test)
test_mix_blocks :: proc(t: ^testing.T) {
	n := MIX_RATE / 2
	samples := make([]f32, n * 2)
	defer delete(samples)
	for i in 0 ..< n {
		v := f32(math.sin(f64(i) * 0.05)) * 1.6 // loud: the limiter works
		samples[i * 2], samples[i * 2 + 1] = v, v
	}
	clip := Audio_Clip{samples = samples, frames = n, source_channels = 2}
	placed := []Placed_Track{{track = {fade_in = 0.05}, clip = &clip, start = 100, end = n - 1000}}
	whole, _ := mix_tracks(placed, 0, n, {master_gain_db = 2})
	defer delete(whole)
	streamed := make([]f32, n * 2)
	defer delete(streamed)
	st: Mix_Stream
	for from := 0; from < n; from += 1000 {
		count := min(1000, n - from)
		mix_block(placed, from, streamed[from * 2:][:count * 2], {master_gain_db = 2}, &st)
		free_all(context.temp_allocator)
	}
	worst: f32
	for v, i in whole {
		worst = max(worst, abs(v - streamed[i]))
	}
	testing.expectf(t, worst < 1e-5, "largest difference %e", worst)
}
