package onimite

import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import obase "deps:odawg/base"
import odevice "deps:odawg/device"
import orender "deps:odawg/render"
import osong "deps:odawg/song"

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
	// what the mix resolves the ducking to (odawg's defaults for what it leaves out)
	d := ducking_sidechain(duck)
	depth := f32(d.floor)
	attack := seconds_to_samples(f32(d.attack))
	hold := seconds_to_samples(f32(d.hold))
	release := seconds_to_samples(f32(d.release))
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
			fade_in, fade_out := track_edges(p)
			env := track_envelope(k, p.end - p.start, fade_in, fade_out, p.track.curve)
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
	// the render's nodes on a pool of three: the stream's samples on any pool
	pool: thread.Pool
	thread.pool_init(&pool, context.allocator, 3)
	thread.pool_start(&pool)
	defer {
		thread.pool_finish(&pool)
		thread.pool_destroy(&pool)
	}
	work: Pool_Work
	pool_work_init(&work, &pool)
	defer pool_work_destroy(&work)
	whole, stats := mix_render(&mx, 0, n, &work.work_pool)
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

// The preview's stream plays a song whose render is whole from that
// render (a clip over its 16-bit samples, no engine): the same sound as
// the song's engine in the mix, placed, faded and turned down the same.
@(test)
test_mix_stream_plays_song_render :: proc(t: ^testing.T) {
	m: Media
	media_init(&m)
	defer media_destroy(&m)
	v, err := json.parse_string(`{ name: "s", bpm: 120, sections: [ { name: "a", duration: "4m" } ],
		parts: { drums: { instrument: "MembraneSynth", play: [ { name: "a", notes: "C2 - C2 -", subdivision: "8n" } ] },
		         lead: { instrument: "PluckSynth", effects: [ { name: "FeedbackDelay", delay_time: "8n", feedback: 0.4, wet: 0.3 } ],
		                 play: [ { name: "a", notes: "A4 C5 E5 -", subdivision: "8n" } ] } } }`, .JSON5, true, context.temp_allocator)
	testing.expect(t, err == nil)
	sc, _ := media_song_put(&m, "s", v, value_key(v))
	testing.expect(t, sc.ok)
	energy := song_table(sc, .Energy, MIX_RATE, 30)
	song_table_build(sc, energy) // the render, whole
	testing.expect(t, song_render_whole(sc))
	n := sc.render.frames
	placed := []Placed_Track{{track = {src = "s", gain_db = -3, fade_in = 0.2, fade_out = 0.3}, song = sc, start = 2000, end = n - 4000, file_start = 1500}}
	mx: Mix
	mix_init(&mx, placed, {})
	defer mix_destroy(&mx)
	engine, _ := mix_render(&mx, 0, n)
	defer delete(engine)
	st: Mix_Stream
	mix_stream_init(&st, placed, {})
	defer mix_stream_destroy(&st)
	testing.expect_value(t, st.mix.tracks[0][1], 1) // one clip, not the song's tracks
	streamed := make([]f32, n * 2)
	defer delete(streamed)
	for from := 0; from < n; from += 1024 {
		count := min(1024, n - from)
		mix_block(&st, from, streamed[from * 2:][:count * 2])
		free_all(context.temp_allocator)
	}
	worst, peak: f32
	for x, i in engine {
		worst = max(worst, abs(x - streamed[i]))
		peak = max(peak, abs(x))
	}
	testing.expectf(t, peak > 0.05, "the song plays (peak %f)", peak)
	// the render is 16-bit: a step of 1/32768 at most, before the gain
	testing.expectf(t, worst < 1e-4, "largest difference from the engine %e", worst)
}

// A song's analysis tables, shared by every reader, are its render
// measured: a frame's energy and spectrum are those of the rendered
// samples at the frame (the same samples as a clip, measured by the same
// rows), whoever built the table and however.
@(test)
test_song_tables_are_render :: proc(t: ^testing.T) {
	m: Media
	media_init(&m)
	defer media_destroy(&m)
	v, err := json.parse_string(`{ name: "s", bpm: 120, sections: [ { name: "a", duration: "2m" } ],
		parts: { drums: { instrument: "MembraneSynth", play: [ { name: "a", notes: "C2 - C2 -", subdivision: "8n" } ] },
		         lead: { instrument: "PluckSynth", effects: [ { name: "FeedbackDelay", delay_time: "8n", feedback: 0.4, wet: 0.3 } ],
		                 play: [ { name: "a", notes: "A4 C5 E5 -", subdivision: "8n" } ] } } }`, .JSON5, true, context.temp_allocator)
	testing.expect(t, err == nil)
	sc, _ := media_song_put(&m, "s", v, value_key(v))
	testing.expect(t, sc.ok)
	frames := int(math.ceil((f64(sc.song.duration) + sc.tail) * MIX_RATE))
	whole := orender.output_from_song(&sc.song, {to = obase.Seconds(f64(frames) / MIX_RATE)}, context.temp_allocator)
	clip := Audio_Clip{samples = make([]f32, 2 * whole.frames), frames = whole.frames, source_rate = MIX_RATE, source_channels = 2}
	for i in 0 ..< whole.frames {
		clip.samples[2 * i], clip.samples[2 * i + 1] = whole.left[i], whole.right[i]
	}
	m.audio[strings.clone("whole")] = clip
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
	worst: f32
	a, b: [512]f32
	for f in 0 ..< 70 { // past the end: silence from both
		audio_spectrum(media_clip_table(&m, "whole", .Spectrum, 30, {f - 1, f + 1}, 1024, .Hann), f, 1, a[:])
		audio_spectrum(spectrum, f, 1, b[:])
		for k in 0 ..< 512 {
			worst = max(worst, abs(a[k] - b[k]))
		}
		x, y := audio_energy(media_clip_table(&m, "whole", .Energy, 30, {f - 2, f + 2}), f, 2), audio_energy(energy, f, 2)
		worst = max(worst, abs(x.rms - y.rms), abs(x.peak - y.peak), abs(x.low - y.low), abs(x.mid - y.mid), abs(x.high - y.high))
	}
	// the song's render is 16-bit: its quantization moves the quietest
	// bins by under a hundredth of a bar
	testing.expectf(t, worst < 1e-2, "largest difference from the render %e", worst)
}

@(private = "file")
write_test_wav :: proc(path: string, frames: int) {
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

// A song's sample files decode on the music's pool: what it plays is the same
// as decoded one at a time, file for file, with a render running beside the
// load on its own Pool_Work.
@(test)
test_song_load_on_the_pool_is_the_same_song :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_song_pool", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	for name, i in ([]string{"a.wav", "b.wav", "c.wav", "d.wav", "e.wav", "f.wav"}) {
		path, _ := filepath.join({dir, name}, context.temp_allocator)
		write_test_wav(path, 2400 + 1200 * i)
	}
	v, err := json.parse_string(`{ name: "s", bpm: 120, sets: { kit: { pads: { a: "a.wav", b: "b.wav", c: "c.wav", d: "d.wav", e: "e.wav", f: "f.wav" } } }, sections: [ { name: "a", duration: "2m" } ],
		parts: { drums: { instrument: { name: "Sampler", set: "kit" }, play: [ { name: "a", steps: { a: "x...............", b: "..x.............", c: "....x...........", d: "......x.........", e: "........x.......", f: "..........x....." } } ] } } }`, .JSON5, true, context.temp_allocator)
	testing.expect(t, err == nil)
	render :: proc(t: ^testing.T, dir: string, v: json.Value, pool: ^thread.Pool) -> []i16 {
		m: Media
		media_init(&m)
		defer media_destroy(&m)
		m.dir = strings.clone(dir)
		music_set_pool(&m, pool)
		sc, _ := media_song_put(&m, "s", v, value_key(v))
		testing.expect(t, sc.ok)
		song_render_build(sc)
		testing.expect(t, song_render_whole(sc))
		out := make([]i16, len(sc.render.samples), context.temp_allocator)
		copy(out, sc.render.samples)
		// a set's loaded sample count: none missed
		for st in m.music.bank.samples {
			testing.expect(t, st.frames > 0)
		}
		testing.expect_value(t, len(m.music.bank.samples), 6)
		music_set_pool(&m, nil)
		return out
	}
	serial := render(t, dir, v, nil)
	pool: thread.Pool
	thread.pool_init(&pool, context.allocator, 4)
	thread.pool_start(&pool)
	defer {
		thread.pool_finish(&pool)
		thread.pool_destroy(&pool)
	}
	pooled := render(t, dir, v, &pool)
	testing.expect_value(t, len(pooled), len(serial))
	same := len(pooled) == len(serial)
	loud := false
	for i in 0 ..< min(len(pooled), len(serial)) {
		same &&= pooled[i] == serial[i]
		loud ||= pooled[i] != 0
	}
	testing.expect(t, same)
	testing.expect(t, loud)
}

// What a reload that took lets go: songs retired before it, and the sets only
// they named. A song this load retired may be read by its own script, so it
// and its sets stay; nothing goes while a render reads the bank; what's kept
// still plays.
@(test)
test_load_frees_retired_songs_and_their_sets :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_song_collect", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	kick, _ := filepath.join({dir, "kick.wav"}, context.temp_allocator)
	write_test_wav(kick, 4800)
	m: Media
	media_init(&m)
	defer media_destroy(&m)
	m.dir = strings.clone(dir)
	v, err := json.parse_string(`{ name: "s", bpm: 120, sets: { kit: { pads: { kick: "kick.wav" } } }, sections: [ { name: "a", duration: "1m" } ],
		parts: { drums: { instrument: { name: "Sampler", set: "kit" }, play: [ { name: "a", steps: { kick: "x...x...x...x..." } } ] } } }`, .JSON5, true, context.temp_allocator)
	testing.expect(t, err == nil)
	set_of :: proc(sc: ^Song_Clip) -> odevice.Set_Id {
		sets := make([dynamic]odevice.Set_Id, context.temp_allocator)
		osong.sets_of_song(&sc.song, &sets)
		return len(sets) == 1 ? sets[0] : 0
	}
	first, _ := media_song_put(&m, "s", v, value_key(v))
	testing.expect(t, first.ok)
	first_set := set_of(first)
	testing.expect(t, first_set != 0)
	write_test_wav(kick, 9600)
	second, _ := media_song_put(&m, "s", v, value_key(v))
	second_set := set_of(second)
	testing.expect(t, second_set != 0 && second_set != first_set)

	// The next load starts here, and replaces `second` itself.
	mark := music_retired_mark(&m)
	testing.expect_value(t, mark, 1)
	write_test_wav(kick, 14400)
	third, _ := media_song_put(&m, "s", v, value_key(v))
	third_set := set_of(third)
	testing.expect_value(t, len(m.music.retired), 2)
	bank := &m.music.bank

	// Nothing goes until a load says it took, or while a render runs.
	music_drain(&m)
	testing.expect_value(t, len(m.music.retired), 2)
	music_retire(&m, mark)
	m.music.running = true
	music_drain(&m)
	testing.expect_value(t, len(m.music.retired), 2)
	testing.expect(t, odevice.bank_set_row(bank, first_set) >= 0)
	m.music.running = false

	music_drain(&m)
	testing.expect_value(t, len(m.music.retired), 1)
	testing.expect(t, m.music.retired[0] == second)
	testing.expect(t, odevice.bank_set_row(bank, first_set) < 0)
	testing.expect(t, odevice.bank_set_row(bank, second_set) >= 0)
	testing.expect(t, odevice.bank_set_row(bank, third_set) >= 0)

	// The song left plays its file.
	song_render_build(third)
	testing.expect(t, song_render_whole(third))
	loud := false
	for s in third.render.samples {
		if s != 0 {
			loud = true
			break
		}
	}
	testing.expect(t, loud)
}

// A song the script no longer names goes with the load that drops it, as a
// replaced song does: out of the songs at once (nothing finds, lists or
// renders it), freed with its sets once the load after that takes.
@(test)
test_load_retires_songs_it_no_longer_names :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_song_named", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	kick, _ := filepath.join({dir, "kick.wav"}, context.temp_allocator)
	write_test_wav(kick, 4800)
	snare, _ := filepath.join({dir, "snare.wav"}, context.temp_allocator)
	write_test_wav(snare, 9600)
	m: Media
	media_init(&m)
	defer media_destroy(&m)
	m.dir = strings.clone(dir)
	spec :: proc(t: ^testing.T, name, file: string) -> json.Value {
		text := fmt.tprintf(`{{ name: "%s", bpm: 120, sets: {{ kit: {{ pads: {{ hit: "%s" }} }} }}, sections: [ {{ name: "a", duration: "1m" }} ],
			parts: {{ drums: {{ instrument: {{ name: "Sampler", set: "kit" }}, play: [ {{ name: "a", steps: {{ hit: "x...x...x...x..." }} }} ] }} }} }}`, name, file)
		v, err := json.parse_string(text, .JSON5, true, context.temp_allocator)
		testing.expect(t, err == nil)
		return v
	}
	set_of :: proc(sc: ^Song_Clip) -> odevice.Set_Id {
		sets := make([dynamic]odevice.Set_Id, context.temp_allocator)
		osong.sets_of_song(&sc.song, &sets)
		return len(sets) == 1 ? sets[0] : 0
	}
	va, vb := spec(t, "a", "kick.wav"), spec(t, "b", "snare.wav")

	// A first load names both.
	mark := music_retired_mark(&m)
	a, _ := media_song_put(&m, "a", va, value_key(va))
	b, _ := media_song_put(&m, "b", vb, value_key(vb))
	testing.expect(t, a.ok && b.ok)
	b_set, a_set := set_of(b), set_of(a)
	testing.expect(t, a_set != 0 && b_set != 0 && a_set != b_set)
	music_retire(&m, mark)
	testing.expect_value(t, len(m.music.songs), 2)
	testing.expect_value(t, len(m.music.retired), 0)

	// The next names `a` only (kept as it is): `b` leaves the songs.
	mark = music_retired_mark(&m)
	kept, fresh := media_song_put(&m, "a", va, value_key(va))
	testing.expect(t, kept == a && !fresh)
	music_retire(&m, mark)
	testing.expect_value(t, len(m.music.songs), 1)
	testing.expect(t, media_song(&m, "b") == nil)
	testing.expect(t, media_song(&m, "a") == a)
	testing.expect_value(t, len(m.music.retired), 1)
	testing.expect(t, len(m.music.retired) == 1 && m.music.retired[0] == b)
	// the script it replaced is gone, but `b` was retired after the mark
	music_drain(&m)
	testing.expect_value(t, len(m.music.retired), 1)
	bank := &m.music.bank
	testing.expect(t, odevice.bank_set_row(bank, b_set) >= 0)

	// The load after that frees it, with the set only it named.
	mark = music_retired_mark(&m)
	media_song_put(&m, "a", va, value_key(va))
	music_retire(&m, mark)
	music_drain(&m)
	testing.expect_value(t, len(m.music.retired), 0)
	testing.expect(t, odevice.bank_set_row(bank, b_set) < 0)
	testing.expect(t, odevice.bank_set_row(bank, a_set) >= 0)
	testing.expect(t, media_song(&m, "a") == a)
}

// A loaded song plays from a view of its own: the video's bank growing
// under it (another song's sets declared and loaded, as a reload does while
// a render runs on the background pool) moves nothing it reads, and it
// sounds the same after. Before, every song read the video's bank itself.
@(test)
test_song_plays_its_own_view :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_song_view", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	m: Media
	media_init(&m)
	defer media_destroy(&m)
	m.dir = strings.clone(dir)
	spec :: proc(t: ^testing.T, dir, name: string, frames: int) -> json.Value {
		file := fmt.tprintf("%s.wav", name)
		path, _ := filepath.join({dir, file}, context.temp_allocator)
		write_test_wav(path, frames)
		text := fmt.tprintf(`{{ name: "%s", bpm: 120, sets: {{ kit: {{ pads: {{ hit: "%s" }} }} }}, sections: [ {{ name: "a", duration: "1m" }} ],
			parts: {{ drums: {{ instrument: {{ name: "Sampler", set: "kit" }}, play: [ {{ name: "a", steps: {{ hit: "x...x...x...x..." }} }} ] }} }} }}`, name, file)
		v, err := json.parse_string(text, .JSON5, true, context.temp_allocator)
		testing.expect(t, err == nil)
		return v
	}
	va := spec(t, dir, "a", 4800)
	a, _ := media_song_put(&m, "a", va, value_key(va))
	testing.expect(t, a.ok && a.has_needs && song_clip_loading(a))
	song_clip_load(a)
	testing.expect(t, !song_clip_loading(a))
	bank := &m.music.bank
	testing.expect(t, len(a.song.bank.zones) > 0)
	testing.expect(t, raw_data(a.song.bank.zones) != raw_data(bank.zones))
	view_zones, view_samples := raw_data(a.song.bank.zones), raw_data(a.song.bank.samples)
	frames := int(math.ceil((f64(a.song.duration) + a.tail) * MIX_RATE))
	before := orender.output_from_song(&a.song, {to = obase.Seconds(f64(frames) / MIX_RATE)}, context.temp_allocator)

	// The video's bank grows past where its rows were: 40 more songs' sets.
	grown_from := raw_data(bank.zones)
	for i in 0 ..< 40 {
		name := fmt.tprintf("s%d", i)
		v := spec(t, dir, name, 2400 + i)
		sc, _ := media_song_put(&m, name, v, value_key(v))
		song_clip_load(sc)
	}
	testing.expect(t, raw_data(bank.zones) != grown_from, "the bank's rows moved")
	testing.expect(t, raw_data(a.song.bank.zones) == view_zones && raw_data(a.song.bank.samples) == view_samples)
	after := orender.output_from_song(&a.song, {to = obase.Seconds(f64(frames) / MIX_RATE)}, context.temp_allocator)
	same := after.frames == before.frames
	loud := false
	for i in 0 ..< min(after.frames, before.frames) {
		same &&= after.left[i] == before.left[i] && after.right[i] == before.right[i]
		loud ||= before.left[i] != 0
	}
	testing.expect(t, same && loud)

	// A mix of it plays its samples too, from the mix's own view.
	placed := []Placed_Track{{track = {src = "a"}, song = a, start = 0, end = frames}}
	mixed, _ := mix_tracks(placed, 0, frames, {no_limiter = true}, allocator = context.temp_allocator)
	heard := false
	for x in mixed {
		heard ||= x != 0
	}
	testing.expect(t, heard, "the mix plays the song's samples")
}

// A song is what it is made of: its spec and the files it reads. The same
// spec and files are the song already there; a sample file changed makes
// a new song.
@(test)
test_song_is_its_files :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_song_files", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	write_wav := write_test_wav
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
