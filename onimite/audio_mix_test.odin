package onimite

import "core:encoding/endian"
import "core:encoding/json"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import orender "deps:odawg/render"

// A clip of constant level placed with gain, balance, an offset, fades and
// ducking under a voice track (no limiter) plays as onimite's own mix did:
// every sample is the clip times gain, balance, the track envelope and the
// ducking envelope (fframes' duck_under_voice, computed here on its own).
@(test)
test_mix_envelopes :: proc(t: ^testing.T) {
	n := MIX_RATE
	music := make([]f32, n * 2)
	defer delete(music)
	for i in 0 ..< n {
		music[i * 2], music[i * 2 + 1] = 0.5, 0.25
	}
	voice := make([]f32, n * 2)
	defer delete(voice)
	music_clip := Audio_Clip{samples = music, frames = n, source_channels = 2}
	voice_clip := Audio_Clip{samples = voice, frames = n, source_channels = 1}
	duck := Ducking{depth_db = -9, attack = 0.05, hold = 0.02, release = 0.1}
	placed := []Placed_Track {
		{track = {gain_db = -6, pan = 0.3, fade_in = 0.1, fade_out = 0.2, curve = .Equal_Power, ducked = true, duck = duck}, clip = &music_clip, start = 2400, end = 40000, file_start = 100},
		{track = {voice = true}, clip = &voice_clip, start = 12000, end = 20000},
	}
	out, _ := mix_tracks(placed, 0, n, {no_limiter = true})
	defer delete(out)
	d := ducking_resolved(duck)
	depth := math.pow(10, d.depth_db / 20)
	attack := seconds_to_samples(d.attack)
	hold := seconds_to_samples(d.hold)
	release := seconds_to_samples(d.release)
	ducking :: proc(s, a, b, attack, hold, release: int, depth: f32) -> f32 {
		w: f32
		switch {
		case s < a - attack || s >= b + hold + release:
			w = 0
		case s < a:
			w = f32(s - (a - attack)) / f32(attack)
		case s >= b + hold:
			w = 1 - f32(s - (b + hold)) / f32(release)
		case:
			w = 1
		}
		return 1 + (depth - 1) * w
	}
	p := placed[0]
	gain := math.pow(f32(10), -6.0 / 20)
	gl, gr := min(1, 1 - p.track.pan) * gain, min(1, 1 + p.track.pan) * gain
	worst: f32
	for s in 0 ..< n {
		want_l, want_r: f32
		if s >= p.start && s < p.end {
			k := s - p.start
			env := track_envelope(k, p.end - p.start, seconds_to_samples(p.track.fade_in), seconds_to_samples(p.track.fade_out), p.track.curve)
			env *= ducking(s, 12000, 20000, attack, hold, release, depth)
			want_l, want_r = 0.5 * gl * env, 0.25 * gr * env
		}
		worst = max(worst, abs(out[s * 2] - want_l), abs(out[s * 2 + 1] - want_r))
	}
	testing.expectf(t, worst < 1e-5, "largest difference from the envelopes %e", worst)
}

// The preview's stream, block by block from the start, plays the render's
// samples (the limiter working, the render cut into short segments on
// several threads), and the limiter holds the ceiling.
@(test)
test_mix_stream_is_render :: proc(t: ^testing.T) {
	n := MIX_RATE / 2
	samples := make([]f32, n * 2)
	defer delete(samples)
	for i in 0 ..< n {
		v := f32(math.sin(f64(i) * 0.05)) * 1.6 // loud: the limiter works
		samples[i * 2], samples[i * 2 + 1] = v, v * 0.5
	}
	clip := Audio_Clip{samples = samples, frames = n, source_channels = 2}
	placed := []Placed_Track{{track = {fade_in = 0.05, gain_db = 2}, clip = &clip, start = 100, end = n - 1000}}
	opts := Mix_Options{master_gain_db = 2}
	mx: Mix
	mix_init(&mx, placed, opts)
	defer mix_destroy(&mx)
	whole, stats := mix_render(&mx, 0, n, threads = 3, segment = 0.05)
	defer delete(whole)
	testing.expect(t, stats.max_reduction_db < -1, "the limiter works")
	st: Mix_Stream
	mix_stream_init(&st, placed, opts)
	defer mix_stream_destroy(&st)
	streamed := make([]f32, n * 2)
	defer delete(streamed)
	for from := 0; from < n; from += 1000 {
		count := min(1000, n - from)
		mix_block(&st, from, streamed[from * 2:][:count * 2])
		free_all(context.temp_allocator)
	}
	worst: f32
	for v, i in whole {
		worst = max(worst, abs(v - streamed[i]))
	}
	testing.expectf(t, worst < 1e-6, "largest difference %e", worst)
	ceiling := math.pow(f32(10), -1.0 / 20)
	peak: f32
	for v in whole {
		peak = max(peak, abs(v))
	}
	testing.expectf(t, peak <= ceiling + 1e-4, "peak %f over the ceiling", peak)
}

// A song's analysis tables, shared by every reader, are its render
// measured: a frame's energy and spectrum are those of the rendered
// samples at the frame, whoever built the table and however.
@(test)
test_song_tables_are_render :: proc(t: ^testing.T) {
	m: Media
	media_init(&m)
	defer media_destroy(&m)
	v, err := json.parse_string(`{ name: "s", bpm: 120, sections: [ { name: "a", duration: "2m" } ],
		parts: { drums: { instrument: "DrumKit", play: [ { name: "a", steps: { kick: "x...x...x...x...", hat: "..x...x...x...x." } } ] },
		         lead: { instrument: "pluck", effects: [ { name: "FeedbackDelay", delay_time: "8n", feedback: 0.4, wet: 0.3 } ],
		                 play: [ { name: "a", notes: "A4 C5 E5 -", subdivision: "8n" } ] } } }`, .JSON5, true, context.temp_allocator)
	testing.expect(t, err == nil)
	sc, _ := media_song_put(&m, "s", v, value_key(v))
	testing.expect(t, sc.ok)
	frames := int(math.ceil((sc.song.duration + sc.tail) * MIX_RATE))
	whole := orender.output_from_song(&sc.song, {to = f64(frames) / MIX_RATE}, context.temp_allocator)
	clip := Audio_Clip{samples = make([]f32, 2 * whole.frames, context.temp_allocator), frames = whole.frames, source_rate = MIX_RATE, source_channels = 2}
	for i in 0 ..< whole.frames {
		clip.samples[2 * i], clip.samples[2 * i + 1] = whole.left[i], whole.right[i]
	}
	spectrum := song_table(sc, .Spectrum, MIX_RATE, 30, 1024, .Hann)
	energy := song_table(sc, .Energy, MIX_RATE, 30)
	testing.expect(t, song_table(sc, .Energy, MIX_RATE, 30) == energy) // one per kind and step
	song_table_build(sc, spectrum)
	// the other in the background, as the preview builds it (queued, then
	// drained)
	for !song_table_later(sc, energy) {
		music_drain(&m)
		time.sleep(time.Millisecond)
	}
	testing.expect(t, music_landed(&m) > 0)
	p := Spectrum_Params{sample_size = 1024, smooth = 1, window = .Hann}
	worst: f32
	a, b: [512]f32
	for f in 0 ..< 70 { // past the end: silence from both
		audio_spectrum(&clip, f, 30, p, a[:])
		audio_spectrum(nil, f, 30, p, b[:], spectrum)
		for k in 0 ..< 512 {
			worst = max(worst, abs(a[k] - b[k]))
		}
		x, y := audio_energy(&clip, f, 30, 2), audio_energy(nil, f, 30, 2, energy)
		worst = max(worst, abs(x.rms - y.rms), abs(x.peak - y.peak), abs(x.low - y.low), abs(x.mid - y.mid), abs(x.high - y.high))
	}
	// the song's render is 16-bit: its quantization moves the quietest
	// bins by under a hundredth of a bar
	testing.expectf(t, worst < 1e-2, "largest difference from the render %e", worst)
}

// A song is what it is made of: its spec and the files it reads. The same
// spec and files are the song already there; a sample file changed makes
// a new song.
@(test)
test_song_is_its_files :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_song_files", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	write_wav :: proc(path: string, frames: int) {
		data := make([]u8, 44 + 2 * frames, context.temp_allocator)
		copy(data, "RIFF")
		endian.unchecked_put_u32le(data[4:], u32(36 + 2 * frames))
		copy(data[8:], "WAVEfmt ")
		endian.unchecked_put_u32le(data[16:], 16)
		endian.unchecked_put_u16le(data[20:], 1)
		endian.unchecked_put_u16le(data[22:], 1)
		endian.unchecked_put_u32le(data[24:], MIX_RATE)
		endian.unchecked_put_u32le(data[28:], 2 * MIX_RATE)
		endian.unchecked_put_u16le(data[32:], 2)
		endian.unchecked_put_u16le(data[34:], 16)
		copy(data[36:], "data")
		endian.unchecked_put_u32le(data[40:], u32(2 * frames))
		for i in 0 ..< frames {
			endian.unchecked_put_u16le(data[44 + 2 * i:], u16(i16(math.sin(f64(i) * 0.05) * 20000)))
		}
		_ = os.write_entire_file(path, data)
	}
	kick, _ := filepath.join({dir, "kick.wav"}, context.temp_allocator)
	write_wav(kick, 4800)
	m: Media
	media_init(&m)
	defer media_destroy(&m)
	m.dir = strings.clone(dir)
	v, err := json.parse_string(`{ name: "s", bpm: 120, sets: { kit: { pads: { kick: "kick.wav" } } }, sections: [ { name: "a", duration: "1m" } ],
		parts: { drums: { instrument: { name: "Sampler", set: "kit" }, play: [ { name: "a", steps: { kick: "x...x...x...x..." } } ] } } }`, .JSON5, true, context.temp_allocator)
	testing.expect(t, err == nil)
	first, fresh := media_song_put(&m, "s", v, value_key(v))
	testing.expect(t, fresh && first.ok)
	again, fresh_again := media_song_put(&m, "s", v, value_key(v))
	testing.expect(t, !fresh_again && again == first) // the same spec and files: the same song
	write_wav(kick, 9600) // the sample changed
	changed, fresh_changed := media_song_put(&m, "s", v, value_key(v))
	testing.expect(t, fresh_changed && changed != first)
}

// A scene's crossfade track fades in over its overlap with the scene
// before and out over its overlap with the scene after (equal power, on
// top of its own fades); a scene with no neighbour overlapping keeps its
// own fades and curve.
@(test)
test_crossfade_placement :: proc(t: ^testing.T) {
	samples := make([]f32, MIX_RATE * 20)
	defer delete(samples)
	m: Media
	m.audio = make(map[string]Audio_Clip)
	defer delete(m.audio)
	m.audio["a"] = Audio_Clip{samples = samples, frames = MIX_RATE * 10, source_channels = 2}
	scenes := []Scene {
		{name = "A", duration = Seconds(3)},
		{name = "B", duration = Seconds(3), overlap = {previous = 0.5}},
		{name = "C", duration = Seconds(2), overlap = {previous = 0.4}},
		{name = "D", duration = Seconds(1)},
	}
	audio := []Audio_Track {
		{src = "a", scene = 0, crossfade = true},
		{src = "a", scene = 1, crossfade = true, fade_in = 0.1},
		{src = "a", scene = 2, crossfade = true},
		{src = "a", scene = 3, crossfade = true, fade_out = 0.2},
	}
	v := Video{width = 64, height = 64, fps = 30, scenes = scenes, audio = audio}
	tl, err := resolve_timeline(&v, &m)
	testing.expect_value(t, err, nil)
	defer delete(tl.scenes)
	p: Placed_Audio
	defer placed_audio_destroy(&p)
	placed_audio_update(&p, &v, tl, &m)
	testing.expect_value(t, len(p.tracks), 4)
	want := [4][2]f32{{0, 0.5}, {0.6, 0.4}, {0.4, 0}, {0, 0.2}}
	for tr, i in p.tracks {
		testing.expectf(t, abs(tr.track.fade_in - want[i][0]) < 1e-4 && abs(tr.track.fade_out - want[i][1]) < 1e-4,
			"scene %d fades %.3f/%.3f, want %.3f/%.3f", i, tr.track.fade_in, tr.track.fade_out, want[i][0], want[i][1])
		testing.expect_value(t, tr.track.curve, Fade_Curve.Linear if i == 3 else .Equal_Power)
	}
}
