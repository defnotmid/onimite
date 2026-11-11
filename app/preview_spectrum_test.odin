package onimite_app

import "core:math"
import "core:sync"
import "core:testing"
import om "../onimite"
import orender "deps:odawg/render"
import sdl "vendor:sdl3"

// The time growing moves no button and not the analyzer: only the space
// between them gives way.
@(test)
test_controls_hold_still_as_the_time_changes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	tp: Test_Preview
	testing.expect(t, test_preview_make(&tp))
	defer test_preview_destroy(&tp)
	pv := &tp.app.preview
	keys := [?]string{"###play", "###loop", "###bookmark", "###mute", "###volume", "###reload", "###spectrum"}
	// each box's rect: its min and max
	rects: [2][len(keys)][2][2]f32
	widths: [2]f32
	ats := [2]int{5, 100}
	for at, i in ats {
		pv.frame = at
		test_frame(&tp)
		time := test_box(&tp.s, "###time")
		testing.expect(t, time != nil)
		if time == nil do return
		widths[i] = time.rect.max.x - time.rect.min.x
		for key, k in keys {
			b := test_box(&tp.s, key)
			testing.expectf(t, b != nil, "%s is built", key)
			if b != nil do rects[i][k] = {b.rect.min, b.rect.max}
		}
	}
	testing.expectf(t, widths[1] > widths[0], "the time is wider at frame 100: %v", widths)
	for key, k in keys {
		testing.expectf(t, rects[0][k] == rects[1][k], "%s holds still: %v, then %v", key, rects[0][k], rects[1][k])
	}
}

// The feeder analyses what it mixes, before the volume and while muted: the
// row heard during a 1 kHz tone peaks in the 1 kHz band; after a seek the
// rows start again from the first step after it, a generation later.
@(test)
test_analyzer_follows_the_mix :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	spec := sdl.AudioSpec{format = .F32, channels = 2, freq = om.MIX_RATE}
	stream := sdl.CreateAudioStream(&spec, &spec)
	testing.expect(t, stream != nil)
	if stream == nil do return
	defer sdl.DestroyAudioStream(stream)
	a: Audio_Shared
	audio_analyzer_init(&a)
	defer audio_shared_destroy(&a)
	frames := om.MIX_RATE
	samples := make([]f32, frames * 2)
	defer delete(samples)
	for i in 0 ..< frames {
		x := 0.5 * math.sin(2 * math.PI * 1000 * f32(i) / om.MIX_RATE)
		samples[i * 2], samples[i * 2 + 1] = x, x
	}
	clip := om.Audio_Clip{samples = samples, frames = frames}
	placed := [1]om.Placed_Track{{track = {src = "tone"}, clip = &clip, end = frames}}
	audio_set_tracks(&a, placed[:], i64(frames), {no_limiter = true})
	audio_set_gain(&a, 1)
	audio_set_state(&a, true, true, false)

	BLOCK :: 2048
	out := make([]f32, BLOCK * 2)
	defer delete(out)
	step :: proc(a: ^Audio_Shared, stream: ^sdl.AudioStream, out: []f32) -> (silent: bool) {
		audio_step(a, stream, len(out) / 2)
		got := sdl.GetAudioStreamData(stream, raw_data(out), i32(len(out) * size_of(f32)))
		silent = true
		for x in out[:int(max(got, 0)) / size_of(f32)] do silent &&= x == 0
		return
	}
	loudest :: proc(row: []f32) -> f32 {
		best := 0
		for level, b in row do if level > row[best] do best = b
		return orender.BAND_HZ[best]
	}
	testing.expect(t, spectrum_row(&a, 0) == nil, "nothing made yet")
	for _ in 0 ..< 8 {
		testing.expect(t, step(&a, stream, out), "muted, it is heard as silence")
	}
	// 16384 samples hold the windows (BANDS_FFT) of steps 0 to 8
	testing.expect_value(t, sync.atomic_load(&a.analyzed_next), i64((8 * BLOCK - orender.BANDS_FFT) / ANALYZER_STEP + 1))
	row := spectrum_row(&a, 8 * BLOCK)
	testing.expect(t, row != nil)
	if row != nil do testing.expect_value(t, loudest(row), 1000)

	gen := sync.atomic_load(&a.analyzed_gen)
	audio_seek(&a, 24000)
	for _ in 0 ..< 6 do step(&a, stream, out)
	testing.expect(t, sync.atomic_load(&a.analyzed_gen) != gen)
	testing.expect_value(t, sync.atomic_load(&a.analyzed_from), i64((24000 + ANALYZER_STEP - 1) / ANALYZER_STEP))
	row = spectrum_row(&a, 24000 + 6 * BLOCK)
	testing.expect(t, row != nil)
	if row != nil do testing.expect_value(t, loudest(row), 1000)
	testing.expect(t, spectrum_row(&a, 24000) == nil, "nothing from before the seek")
}

// A bar jumps to its band's level and falls back at SPECTRUM_FALL, a quieter
// row no faster; its peak mark holds, then falls, never under the bar.
@(test)
test_analyzer_bars_jump_and_fall :: proc(t: ^testing.T) {
	sp: Spectrum
	loud, quiet: [om.BAND_COUNT]f32
	for &v in loud do v = SPECTRUM_TOP_DB
	for &v in quiet do v = (SPECTRUM_TOP_DB + SPECTRUM_FLOOR_DB) / 2
	spectrum_settle(&sp, loud[:], 0.02)
	testing.expect_value(t, sp.levels[0], 1)
	testing.expect_value(t, sp.peaks[0], 1)
	spectrum_settle(&sp, quiet[:], 0.1)
	testing.expect(t, abs(sp.levels[0] - (1 - SPECTRUM_FALL * 0.1)) < 1e-5, "falls at its rate, not to the quieter level at once")
	testing.expect_value(t, sp.peaks[0], 1)
	// 0.4 s after the peak: the bar lower still, the mark held
	for _ in 0 ..< 3 do spectrum_settle(&sp, nil, 0.1)
	testing.expect(t, abs(sp.levels[0] - (1 - SPECTRUM_FALL * 0.4)) < 1e-5)
	testing.expect_value(t, sp.peaks[0], 1)
	// a second later: the bar down, the mark falling
	for _ in 0 ..< 10 do spectrum_settle(&sp, nil, 0.1)
	testing.expect_value(t, sp.levels[0], 0)
	testing.expect(t, sp.peaks[0] < 1 && sp.peaks[0] >= sp.levels[0], "the mark falls once held")
}
