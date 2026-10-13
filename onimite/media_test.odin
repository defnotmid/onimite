package onimite

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:testing"
import stbi "vendor:stb/image"

@(test)
test_parse_subtitles :: proc(t: ^testing.T) {
	src := "WEBVTT\nKind: captions\n\nNOTE a comment\nspanning lines\n\n1\n00:00:00.500 --> 00:00:02.000 align:center\nHello there,\nsecond line\n\n00:02.000 --> 00:03.250\nShort form timing\n\nintro-end\n01:00:03.500 --> 01:00:05.000\nLast cue\n"
	s, ok := parse_subtitles(src)
	defer subtitles_destroy(&s)
	testing.expect(t, ok)
	testing.expect_value(t, len(s.starts), 3)
	testing.expect_value(t, s.starts[0], 500)
	testing.expect_value(t, s.stops[0], 2000)
	testing.expect_value(t, s.texts[0], "Hello there,\nsecond line")
	testing.expect_value(t, s.ids[0], "1")
	testing.expect_value(t, s.settings[0], "align:center")
	testing.expect_value(t, s.starts[1], 2000)
	testing.expect_value(t, s.stops[1], 3250)
	// Hours count (fframes' parser multiplied them by the minutes).
	testing.expect_value(t, s.starts[2], 3_603_500)
	testing.expect_value(t, s.ids[2], "intro-end")

	// The latest cue showing wins where two touch (fframes' reverse search).
	testing.expect_value(t, subtitle_cue_at(&s, 400), -1)
	testing.expect_value(t, subtitle_cue_at(&s, 1000), 0)
	testing.expect_value(t, subtitle_cue_at(&s, 2000), 1)
	testing.expect_value(t, subtitle_cue_at(&s, 3300), -1)

	_, bad := parse_subtitles("not a vtt")
	testing.expect(t, !bad)
	crlf, crlf_ok := parse_subtitles("WEBVTT\r\n\r\n00:01.000 --> 00:02.000\r\nA\r\nB\r\n")
	defer subtitles_destroy(&crlf)
	testing.expect(t, crlf_ok && len(crlf.texts) == 1 && crlf.texts[0] == "A\nB")
}

// A sine on the left channel only, at `rate`.
@(private = "file")
sine_clip :: proc(freq: f32, seconds: f32, rate: int) -> Audio_Clip {
	n := int(seconds * f32(rate))
	src := make([]f32, n * 2)
	defer delete(src)
	for i in 0 ..< n {
		src[i * 2] = math.sin(2 * math.PI * freq * f32(i) / f32(rate))
	}
	return clip_from_samples(src, rate, 2)
}

@(test)
test_audio_spectrum :: proc(t: ^testing.T) {
	// Analysed at MIX_RATE: bin 64 of a 1024-point FFT is 3000 Hz, whatever
	// the file's rate.
	clip := sine_clip(48000.0 * 64 / 1024, 2, 44100)
	defer audio_clip_destroy(&clip)
	testing.expect(t, clip.source_rate == 44100 && clip.source_channels == 2 && clip.frames == 96000)
	out := make([]f32, 512)
	defer delete(out)
	audio_spectrum(&clip, 10, 30, {sample_size = 1024}, out)
	peak := 0
	for v, i in out {
		if v > out[peak] {peak = i}
	}
	testing.expect_value(t, peak, 64)
	// An unwindowed full-scale sine on a bin, left only: N/2 of the
	// 0.707 * (L + R) mix.
	testing.expectf(t, abs(out[64] - 512 * 0.70710678) < 5, "sine bin %v", out[64])

	// The Hamming window on a constant: bin 0 is the window's sum.
	dc := make([]f32, 4800)
	defer delete(dc)
	for &v in dc {v = 1}
	mono := clip_from_samples(dc, 48000, 1)
	defer audio_clip_destroy(&mono)
	ham := make([]f32, 8)
	defer delete(ham)
	audio_spectrum(&mono, 1, 30, {sample_size = 16, window = .Hamming}, ham)
	want: f32
	for k in 0 ..< 16 {
		want += 2 * 0.70710678 * (0.54 - 0.46 * math.cos(2 * math.PI * f32(k) / 15))
	}
	testing.expectf(t, abs(ham[0] - want) < 1e-3 * want, "hamming dc %v, want %v", ham[0], want)

	// Deterministic, and smoothing is the mean of neighbouring frames.
	again := make([]f32, 512)
	defer delete(again)
	audio_spectrum(&clip, 10, 30, {sample_size = 1024}, again)
	testing.expect(t, slices_equal(out, again))
	smooth := make([]f32, 512)
	defer delete(smooth)
	audio_spectrum(&clip, 20, 30, {sample_size = 1024, smooth = 2, window = .Hann}, smooth)
	sum := make([]f32, 512)
	defer delete(sum)
	tmp := make([]f32, 512)
	defer delete(tmp)
	for f in 18 ..= 22 {
		audio_spectrum(&clip, f, 30, {sample_size = 1024, window = .Hann}, tmp)
		for v, i in tmp {sum[i] += v / 5}
	}
	for v, i in sum {
		testing.expect(t, abs(v - smooth[i]) <= 1e-4 * max(abs(v), 1))
	}
	// Past the end of the file the buffer is silent.
	audio_spectrum(&clip, 1000, 30, {sample_size = 1024}, out)
	testing.expect_value(t, out[64], 0)

	centered := make([]f32, 8)
	defer delete(centered)
	spectrum_centered({1, 2, 3, 4, 5, 6, 7, 8}, centered)
	testing.expect(t, slices_equal(centered, []f32{7, 5, 3, 1, 2, 4, 6, 8}))
}

@(private = "file")
slices_equal :: proc(a, b: []f32) -> bool {
	if len(a) != len(b) {return false}
	for v, i in a {
		if v != b[i] {return false}
	}
	return true
}

@(test)
test_time_terms :: proc(t: ^testing.T) {
	m: Media
	media_init(&m)
	defer media_destroy(&m)
	vo := sine_clip(440, 2.5, MIX_RATE)
	m.audio["vo.wav"] = vo // the media frees it (key is a literal: drop it before destroy)
	defer delete_key(&m.audio, "vo.wav")
	defer audio_clip_destroy(&vo)

	terms := []Time_Term{{.Seconds, 1, 2, ""}, {.Audio, 1, 0, "vo.wav"}}
	frames, _, ok := terms_frames(terms, 30, &m)
	testing.expect(t, ok)
	testing.expect_value(t, frames, 60 + 75)
	sub := []Time_Term{{.Audio, 1, 0, "vo.wav"}, {.Seconds, -1, 3, ""}}
	frames, _, ok = terms_frames(sub, 30, &m)
	testing.expect(t, ok && frames == 0) // saturating, as fframes
	secs, _, sok := terms_seconds([]Time_Term{{.Frames, 1, 45, ""}, {.Seconds, 1, 60, ""}}, 30, &m)
	testing.expect(t, sok && abs(secs - 61.5) < 1e-9)
	_, missing, found := terms_frames([]Time_Term{{.Video, 1, 0, "nope.mp4"}}, 30, &m)
	testing.expect(t, !found && missing == "nope.mp4")

	// A video lasting as long as its voice-over.
	v := Video{width = 16, height = 16, fps = 30, duration = Duration_Terms(terms[1:])}
	tl, err := resolve_timeline(&v, &m)
	defer timeline_destroy(&tl)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, tl.duration_frames, 75)
}

@(test)
test_image_eviction :: proc(t: ^testing.T) {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	dir := fmt.tprintf("%s/onimite_image_cache_test", tmp if tmp != "" else "/tmp")
	testing.expect(t, os.make_directory_all(dir) == nil)
	defer os.remove_all(dir)
	// Two 8x8 images (256 decoded bytes each): red, and half-transparent blue.
	red, blue: [8 * 8 * 4]u8
	for i := 0; i < len(red); i += 4 {
		red[i], red[i + 3] = 255, 255
		blue[i + 2], blue[i + 3] = 255, 128
	}
	stbi.write_png(fmt.ctprintf("%s/a.png", dir), 8, 8, 4, &red, 32)
	stbi.write_png(fmt.ctprintf("%s/b.png", dir), 8, 8, 4, &blue, 32)

	media: Media
	media_init(&media)
	defer media_destroy(&media)
	add_image_file(&media, "a.png", fmt.tprintf("%s/a.png", dir))
	add_image_file(&media, "b.png", fmt.tprintf("%s/b.png", dir))
	media.cache.budget = 300 // one image

	// a on frames 0 and 2, b on frame 1.
	@(static) scenes: [1]Scene
	scenes = [1]Scene{{name = "S", duration = Frames(3), render = proc(f: Frame, ctx: ^Context) {
		image(ctx, {src = "b.png" if f.index == 1 else "a.png", w = 8, h = 8})
	}}}
	v := Video{width = 8, height = 8, fps = 30, background = WHITE, scenes = scenes[:]}
	r: Renderer
	testing.expect_value(t, renderer_init(&r, &v, &media), Error.None)
	defer renderer_destroy(&r)

	first := slice.clone(render_frame(&r, 0), context.temp_allocator)
	a := media.images["a.png"]
	key := a.key
	render_frame(&r, 1)
	testing.expect_value(t, media.cache.bytes, 512)
	// Over budget: frame 2 starts by evicting a (the least recently used),
	// then decodes and uploads it again.
	again := render_frame(&r, 2)
	testing.expect_value(t, media.cache.evictions, 1)
	testing.expect(t, a.key != 0 && a.key != key)
	testing.expect(t, slice.equal(first, again))
	testing.expect_value(t, first[0], 255)
	testing.expect_value(t, media.cache.bytes, 512)

	// Images used by frames still in flight are spared; the others go, with
	// their texture keys.
	evicted: [dynamic]u64
	defer delete(evicted)
	media_evict(&media, 2, &evicted) // b: last used before frame 2
	testing.expect_value(t, len(evicted), 2)
	b := media.images["b.png"]
	testing.expect(t, b.pixels == nil && b.key == 0)
	_, ok := media_image(&media, "b.png", 5)
	testing.expect(t, ok && len(b.pixels) == 256)
	pm := media_premultiplied(&media, "b.png", 5)
	testing.expect_value(t, media.cache.bytes, 256 * 3)
	testing.expect_value(t, pm[2], 128)
	clear(&evicted)
	media_evict(&media, 2, &evicted) // a (frame 2) and b (frame 5) in flight
	testing.expect_value(t, len(evicted), 0)
	a_key := a.key
	media_evict(&media, 3, &evicted)
	testing.expect(t, len(evicted) == 2 && evicted[0] == a_key && evicted[1] == a_key | 1)
	testing.expect(t, a.pixels == nil && media.cache.bytes == 512)
}

// Files of the media folder that do not decode are warnings of the load,
// named, and the rest of the folder still loads; a .json file that is
// neither Lottie nor captions is the script's data, not a problem.
@(test)
test_media_problems :: proc(t: ^testing.T) {
	m: Media
	media_init(&m)
	defer media_destroy(&m)
	testing.expect_value(t, media_load_test_files(&m, {"bad.wav", "not audio"}, {"bad.ttf", "junk"}, {"bad.svg", "<svg"}, {"bad.srt", "no cues here"}, {"data.json", `{"rows": [1, 2]}`}), Error.None)
	want := []string{"bad.wav", "bad.ttf", "bad.svg", "bad.srt"}
	testing.expect_value(t, len(m.problems), len(want))
	for d in m.problems {
		testing.expectf(t, slice.contains(want, d.name) && d.code == .Undecodable_Media && d.severity == .Warning, "unexpected problem %v", d)
	}
}

// Loads `files` ({name, contents}) into `m` the way the app does: written to
// a folder that `media_load_dir` reads.
@(private)
media_load_test_files :: proc(m: ^Media, files: ..[2]string) -> Error {
	dir, err := os.make_directory_temp("", "onimite_media_test_*", context.temp_allocator)
	if err != nil {
		return .Io
	}
	defer os.remove_all(dir)
	for f in files {
		if os.write_entire_file(fmt.tprintf("%s/%s", dir, f[0]), transmute([]u8)f[1]) != nil {
			return .Io
		}
	}
	return media_load_dir(m, dir)
}
