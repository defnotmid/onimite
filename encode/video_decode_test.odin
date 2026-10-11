package onimite_encode

import "core:log"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"
import om "../onimite"

@(private = "file")
fixture :: proc(name: string) -> string {
	for dir in ([2]string{"testdata/", "../testdata/"}) {
		p := string_concat(dir, name)
		if os.exists(p) {
			return p
		}
	}
	return ""
}

@(private = "file")
string_concat :: proc(a, b: string) -> string {
	buf := make([]u8, len(a) + len(b), context.temp_allocator)
	copy(buf, a)
	copy(buf[len(a):], b)
	return string(buf)
}

// Frames fetched in order, by random seeks, and backwards are identical, for
// a High-profile clip with B-frames (reordered) and a Baseline one.
@(test)
test_video_seek_matches_sequential :: proc(t: ^testing.T) {
	for name in ([2]string{"clip_high.mp4", "clip_baseline.mp4"}) {
		path := fixture(name)
		if path == "" {
			testing.fail_now(t, "missing testdata fixture")
		}
		d: Video_Decoders
		video_decoders_init(&d, native = true)
		defer video_decoders_destroy(&d)
		src := video_source(&d)
		clip, info, why, err := src.open(src.data, path)
		testing.expectf(t, err == nil && clip >= 0, "%s: %v", name, why)
		testing.expect_value(t, info.width, 320)
		testing.expect_value(t, info.frames, 90)

		// Sequential pass: keep a checksum per frame.
		sums := make([]u64, info.frames)
		defer delete(sums)
		began := time.tick_now()
		for i in 0 ..< info.frames {
			f := src.request(src.data, clip, (f64(i) + 0.5) / info.fps, .Block)
			testing.expect(t, f.ok && f.exact)
			testing.expect_value(t, f.index, i)
			sums[i] = frame_checksum(f)
			src.release(src.data, clip)
		}
		seq := time.duration_seconds(time.tick_since(began))

		// Random order, including backwards jumps across GOPs.
		order := [?]int{70, 3, 89, 44, 45, 46, 15, 14, 0, 61, 29, 30}
		began = time.tick_now()
		for i in order {
			f := src.request(src.data, clip, (f64(i) + 0.5) / info.fps, .Block)
			testing.expectf(t, f.ok && f.index == i, "%s: frame %d came back as %d", name, i, f.index)
			testing.expectf(t, frame_checksum(f) == sums[i], "%s: frame %d differs after seeking", name, i)
			src.release(src.data, clip)
		}
		seeks := time.duration_seconds(time.tick_since(began))
		log.infof("%s: sequential %.0f fps, random seeks %.1f ms each", name, f64(info.frames) / seq, seeks * 1000 / f64(len(order)))

		// The final frame stays through the clip's end.
		last := src.request(src.data, clip, info.duration, .Block)
		testing.expect(t, last.ok && last.index == info.frames - 1)
		src.release(src.data, clip)
	}
}

// Non-blocking requests answer at once and become exact as decoding catches up.
@(test)
test_video_nearest_does_not_block :: proc(t: ^testing.T) {
	path := fixture("clip_high.mp4")
	if path == "" {
		testing.fail_now(t, "missing testdata fixture")
	}
	d: Video_Decoders
	video_decoders_init(&d, native = true)
	defer video_decoders_destroy(&d)
	src := video_source(&d)
	clip, info, _, _ := src.open(src.data, path)
	target := 2.0
	f := src.request(src.data, clip, target, .Nearest)
	src.release(src.data, clip)
	exact := f.ok && f.exact
	deadline := time.tick_now()
	for !exact && time.tick_since(deadline) < 5 * time.Second {
		time.sleep(2 * time.Millisecond)
		f = src.request(src.data, clip, target, .Nearest)
		exact = f.ok && f.exact
		src.release(src.data, clip)
	}
	testing.expect(t, exact)
	testing.expect_value(t, f.index, int(target * info.fps))
	_ = om.Video_Wait.Nearest
}

// A preview playing into a clip off a keyframe: `.Nearest` requests arrive
// faster than the seek decodes (back from the keyframe), each a little
// later. They must wait for the seek in flight rather than restart it, or
// no frame ever lands and the clip stays blank (the suite's later cuts).
@(test)
test_video_nearest_seek_lands_while_playing :: proc(t: ^testing.T) {
	path := fixture("clip_high.mp4")
	if path == "" {
		testing.fail_now(t, "missing testdata fixture")
	}
	d: Video_Decoders
	video_decoders_init(&d, native = true)
	defer video_decoders_destroy(&d)
	src := video_source(&d)
	clip, info, _, _ := src.open(src.data, path)
	start := 0.45 // keyframes every 0.5 s: the seek decodes 13 frames
	// Twenty preview frames asked before the seek can finish restart it
	// at most once (the first request starts it).
	for k in 0 ..< 20 {
		src.prefetch(src.data, clip, start + f64(k) / 60)
	}
	w := d.workers[clip]
	sync.mutex_lock(&w.mutex)
	restarts := w.generation
	sync.mutex_unlock(&w.mutex)
	testing.expectf(t, restarts <= 2, "the seek restarted %d times", restarts)
	began := time.tick_now()
	shown := -1
	for shown < 0 && time.tick_since(began) < 3 * time.Second {
		// Playback at a quarter speed, asked as fast as the caller can.
		at := start + time.duration_seconds(time.tick_since(began)) / 4
		src.prefetch(src.data, clip, at)
		f := src.request(src.data, clip, at, .Nearest)
		if f.ok {
			shown = f.index
		}
		src.release(src.data, clip)
	}
	testing.expectf(t, shown >= int(start * info.fps), "no frame landed while playing from %.2f s (got %d)", start, shown)
}

@(private = "file")
checksum :: proc(b: []u8) -> u64 {
	h: u64 = 1469598103934665603
	for x in b {
		h = (h ~ u64(x)) * 1099511628211
	}
	return h
}

// Failures are codes with fields: a file that is not a video, and an
// encoder asked for odd dimensions.
@(test)
test_errors :: proc(t: ^testing.T) {
	d: Video_Decoders
	video_decoders_init(&d, native = true)
	defer video_decoders_destroy(&d)
	src := video_source(&d)
	// This source file.
	clip, _, why, err := src.open(src.data, #location().file_path)
	testing.expect_value(t, clip, -1)
	testing.expect_value(t, err, om.Error.Video_Decode)
	testing.expect_value(t, why.code, om.Error.Video_Decode)
	testing.expect(t, why.cause != "")

	e: Encoder
	defer destroy(&e)
	testing.expect_value(t, open(&e, "odd.mp4", 641, 361, 30), Error.Odd_Size)
	testing.expect_value(t, error_message(e.failure, context.temp_allocator), "4:2:0 video needs even dimensions, got 641x361")
}

// The frame's planes, summed in order.
frame_checksum :: proc(f: om.Video_Frame) -> u64 {
	h: u64 = 0
	for p in f.planes {
		h = h * 31 + checksum(p)
	}
	return h
}
