// Encodes rendered frames to MP4 with odecs' video writer: BT.709
// limited-range 4:2:0 frames encoded as H.264 or H.265 (hardware through
// Vulkan Video when available, else odecs' native encoders); the audio mix
// becomes an interleaved AAC track.
//
// The work runs off the caller's thread so rendering never waits on
// encoding: `write_nv12` queues the caller's frame as it is (GPU_NV12's
// mapped download, no copy) and `write_i420` copies the frame into a ring
// slot; both return at once unless the ring is full. An encoder thread
// feeds the audio that accompanies the frame and encodes it.
// Only the encoder thread touches the video writer until `close`. GPU renders
// convert to NV12 on the GPU (gpu_nv12.odin), the layout Vulkan Video takes;
// software renders convert to I420 with `rgba_to_i420` on the thread that
// drew them; both use odecs' conversion coefficients and produce identical
// samples. The native encoder codes its
// slices on the application's task pool, shared with the frame builders
// (`Pool_Work`).
package onimite_encode

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "base:runtime"
import common "deps:odecs/common"
import native "deps:odecs/media/native"
import video "deps:odecs/video"
import om "../onimite"

Codec :: enum u8 {
	H264,
	H265,
}

// What failed. Text is made at the edge (`error_message`) from ERROR_TEXT,
// where `{path}`, `{frame}`, `{width}`, `{height}`, `{movie}` and
// `{detail}` stand for the `Failure` fields.
Error :: enum u8 {
	None,
	Odd_Size,
	Create,
	Audio,
	Frame,
	Finish,
	// GPU conversion (gpu_nv12.odin).
	Gpu_Unsupported,
	Gpu_Submit,
	Gpu_Map,
	// probe.odin.
	Probe_Open,
}

// An encoder's first failure and its operands: odecs' error and its detail
// (a static string), the file, the frame or the size.
Failure :: struct {
	code:          Error,
	// Owned.
	path:          string,
	frame:         i64,
	width, height: int,
	movie:         video.Error,
	detail:        string,
}

@(rodata)
ERROR_TEXT := [Error]string {
	.None            = "",
	.Odd_Size        = "4:2:0 video needs even dimensions, got {width}x{height}",
	.Create          = "can not create {path}: {movie} {detail}",
	.Audio           = "audio: {movie} {detail}",
	.Frame           = "encode frame {frame}: {movie} {detail}",
	.Finish          = "finish: {movie} {detail}",
	.Gpu_Unsupported = "the GPU can not convert frames to I420",
	.Gpu_Submit      = "can not convert the frame on the GPU",
	.Gpu_Map         = "can not read the converted frame back",
	.Probe_Open      = "can not read {path}: {movie} {detail}",
}

// The failure's text.
error_message :: proc(f: Failure, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	f := f
	om.template_write(&b, ERROR_TEXT[f.code], &f, proc(b: ^strings.Builder, field, mode: string, data: rawptr) -> bool {
		f := (^Failure)(data)
		switch field {
		case "path":
			om.template_string(b, f.path, mode)
		case "frame":
			fmt.sbprintf(b, "%d", f.frame)
		case "width":
			fmt.sbprintf(b, "%d", f.width)
		case "height":
			fmt.sbprintf(b, "%d", f.height)
		case "movie":
			fmt.sbprintf(b, "%v", f.movie)
		case "detail":
			strings.write_string(b, f.detail)
		case:
			return false
		}
		return true
	})
	return strings.to_string(b)
}

Options :: struct {
	codec:          Codec,
	// Constant quantizer, 1 (best) to 51; 0 selects 23.
	qp:             i32,
	// Frames between keyframes; 0 is about one second.
	gop:            int,
	// Skip Vulkan Video and use the native encoder.
	software:       bool,
	// Add an AAC stereo track at onimite' mix rate (see `write_audio`).
	audio:          bool,
	// AAC bit rate; 0 is 192 kb/s.
	audio_bit_rate: int,
	// H.264 slices the native encoder codes in parallel; 0 picks one per
	// core but two (more slices, slightly larger files). Fixed by the
	// machine, not the pool, so the file doesn't depend on --threads.
	native_slices:  int,
	// The application's task pool (borrowed; nil codes slices on the
	// encoder thread alone).
	pool:           ^thread.Pool,
}

// Frames in flight between the renderer and the encoder thread.
RING_SLOTS :: 4

@(private)
Slot :: struct {
	// Y then the chroma: interleaved UV with `y_stride` per row (`nv12`), or
	// U and V planes with `y_stride / 2`. The caller's bytes (`write_nv12`)
	// or `own`'s.
	data:     []u8,
	// The slot's copy of a `write_i420` frame (made on the first one).
	own:      []u8,
	y_stride: int,
	nv12:     bool,
	frame:    i64,
	filled:   bool,
}

Encoder :: struct {
	writer:      video.Writer,
	width:       int,
	height:      int,
	fps:         int,
	audio:       bool,
	// The encoder implementation odecs selected.
	backend:     string,
	// The first failure (complete after `close`).
	failure:     Failure,

	// Frame ring: the caller fills slots in order, the encoder thread
	// drains them in the same order.
	slots:       [RING_SLOTS]Slot,
	write_index: int,
	read_index:  int,
	next_frame:  i64,
	// Frames the encoder thread is done with (encoded, or dropped after a
	// failure), under `lock`: a `write_nv12` frame's bytes may change once
	// this passes it (`wait_frame`).
	done:        i64,
	closing:     bool,
	lock:        sync.Mutex,
	slot_free:   sync.Cond,
	slot_filled: sync.Cond,
	worker:      ^thread.Thread,
	// Set by any thread on the first failure; read with atomics.
	failed:      bool,

	// Encoder-thread state. The native encoder's slices run on the task
	// pool through `work`; the encoder must not move while open (pool tasks
	// point into it).
	work:        om.Pool_Work,
	native:      native.Options,
	// The mix (interleaved stereo at the mix rate) and how much of it the
	// video writer has been given.
	mix:         []f32,
	mix_fed:     int,
}

// Creates the file and starts the encoder thread; on failure `e.failure`
// says why.
open :: proc(e: ^Encoder, path: string, width, height, fps: int, opts: Options = {}) -> Error {
	e^ = {width = width, height = height, fps = fps, audio = opts.audio}
	if width % 2 != 0 || height % 2 != 0 {
		return set_error(e, {code = .Odd_Size, width = width, height = height})
	}
	cfg := video.default_writer_config(width, height, fps, 1)
	cfg.codec = .H265 if opts.codec == .H265 else .H264
	cfg.qp = int(opts.qp)
	cfg.gop = opts.gop
	cfg.preference = .Native if opts.software else .Automatic
	cfg.alpha = .Premultiplied
	om.pool_work_init(&e.work, opts.pool)
	slices := opts.native_slices if opts.native_slices > 0 else clamp(os.get_processor_core_count() - 2, 1, common.MAX_STATIC_POOL_THREADS)
	e.native = {pool = &e.work.work_pool, h264_slice_count = min(slices, (height + 15) / 16)}
	cfg.native_options = &e.native
	if opts.audio {
		cfg.sample_rate = om.MIX_RATE
		cfg.channels = 2
		cfg.audio_bit_rate = opts.audio_bit_rate if opts.audio_bit_rate > 0 else 192_000
	}
	if err := video.create(&e.writer, path, cfg); err != .None {
		set_error(e, {code = .Create, path = path, movie = err, detail = e.writer.error_detail})
		video.destroy(&e.writer)
		return .Create
	}
	_, e.backend = video.video_backend(&e.writer)
	e.worker = thread.create_and_start_with_poly_data(e, encode_loop, context)
	return nil
}

// Sets the audio mix (interleaved stereo at the mix rate; copied). Call it
// before the first frame so the file interleaves; later calls still work,
// with the audio stored after the video. Ignored without an audio track or
// once a mix is set; the failure's code once encoding has failed.
write_audio :: proc(e: ^Encoder, mix: []f32) -> Error {
	if sync.atomic_load(&e.failed) {
		return failure_code(e)
	}
	if !e.audio {
		return nil
	}
	sync.mutex_lock(&e.lock)
	defer sync.mutex_unlock(&e.lock)
	if e.mix != nil {
		return nil
	}
	e.mix = make([]f32, len(mix))
	copy(e.mix, mix)
	return nil
}

// Queues one NV12 frame as GPU_NV12 maps it: Y, then interleaved U and V,
// both with `y_stride` bytes per row, without copying it: `data` must stay
// as it is until `wait_frame(e, frame)`. Returns at once unless all ring
// slots are busy. The failure's code once encoding has failed.
write_nv12 :: proc(e: ^Encoder, data: []u8, y_stride: int) -> (frame: i64, err: Error) {
	return queue_frame(e, data, y_stride, true)
}

// Queues one I420 frame: Y with `y_stride` bytes per row, then U and V with
// `y_stride / 2` (`rgba_to_i420` packs it with `y_stride = width`). Copied:
// `data` is the caller's again on return.
write_i420 :: proc(e: ^Encoder, data: []u8, y_stride: int) -> Error {
	_, err := queue_frame(e, data, y_stride, false)
	return err
}

// Waits until the encoder thread is done with queued frame `frame` (a
// `write_nv12` frame's bytes are the caller's again). The failure's code
// once encoding has failed.
wait_frame :: proc(e: ^Encoder, frame: i64) -> Error {
	sync.mutex_lock(&e.lock)
	for e.done <= frame && !sync.atomic_load(&e.failed) {
		sync.cond_wait(&e.slot_free, &e.lock)
	}
	sync.mutex_unlock(&e.lock)
	if sync.atomic_load(&e.failed) {
		return failure_code(e)
	}
	return nil
}

@(private)
queue_frame :: proc(e: ^Encoder, data: []u8, y_stride: int, borrow: bool) -> (frame: i64, err: Error) {
	if sync.atomic_load(&e.failed) {
		return 0, failure_code(e)
	}
	sync.mutex_lock(&e.lock)
	for e.slots[e.write_index].filled && !sync.atomic_load(&e.failed) {
		sync.cond_wait(&e.slot_free, &e.lock)
	}
	if sync.atomic_load(&e.failed) {
		sync.mutex_unlock(&e.lock)
		return 0, failure_code(e)
	}
	slot := &e.slots[e.write_index]
	sync.mutex_unlock(&e.lock)

	// The slot is ours until marked filled: copy outside the lock.
	if borrow {
		slot.data = data
	} else {
		if len(slot.own) < len(data) {
			delete(slot.own)
			slot.own = make([]u8, len(data))
		}
		copy(slot.own, data)
		slot.data = slot.own[:len(data)]
	}
	slot.y_stride = y_stride
	slot.nv12 = borrow
	slot.frame = e.next_frame
	frame = e.next_frame
	e.next_frame += 1

	sync.mutex_lock(&e.lock)
	slot.filled = true
	e.write_index = (e.write_index + 1) % RING_SLOTS
	sync.cond_signal(&e.slot_filled)
	sync.mutex_unlock(&e.lock)
	return
}

// Drains and finishes the file. An error if anything failed along the way
// (`e.failure` says what).
close :: proc(e: ^Encoder) -> Error {
	sync.mutex_lock(&e.lock)
	e.closing = true
	sync.cond_broadcast(&e.slot_filled)
	sync.mutex_unlock(&e.lock)
	thread.join(e.worker)
	thread.destroy(e.worker)

	ok := !sync.atomic_load(&e.failed)
	if ok && e.audio {
		ok = feed_audio(e, len(e.mix) / 2)
	}
	if ok {
		if err := video.finish(&e.writer); err != .None {
			set_error(e, {code = .Finish, movie = err, detail = e.writer.error_detail})
			ok = false
		}
	}
	video.destroy(&e.writer)
	om.pool_work_destroy(&e.work)
	for s in e.slots {
		delete(s.own)
	}
	delete(e.mix)
	return nil if ok else failure_code(e)
}

destroy :: proc(e: ^Encoder) {
	delete(e.failure.path)
	e^ = {}
}

// Keeps the first failure (its path cloned) and returns its code.
@(private)
set_error :: proc(e: ^Encoder, f: Failure) -> Error {
	sync.mutex_lock(&e.lock)
	defer sync.mutex_unlock(&e.lock)
	if e.failure.code == .None {
		e.failure = f
		e.failure.path = strings.clone(f.path)
	}
	return f.code
}

@(private)
failure_code :: proc(e: ^Encoder) -> Error {
	sync.mutex_lock(&e.lock)
	defer sync.mutex_unlock(&e.lock)
	return e.failure.code
}

@(private)
fail :: proc(e: ^Encoder, f: Failure) {
	set_error(e, f)
	sync.atomic_store(&e.failed, true)
	sync.mutex_lock(&e.lock)
	sync.cond_broadcast(&e.slot_free)
	sync.mutex_unlock(&e.lock)
}

// Gives the writer the mix up to sample `until` (per channel).
@(private)
feed_audio :: proc(e: ^Encoder, until: int) -> bool {
	sync.mutex_lock(&e.lock)
	mix := e.mix
	sync.mutex_unlock(&e.lock)
	end := min(until, len(mix) / 2)
	if end <= e.mix_fed {
		return true
	}
	if err := video.write_audio(&e.writer, mix[e.mix_fed * 2:end * 2]); err != .None {
		fail(e, {code = .Audio, movie = err, detail = e.writer.error_detail})
		return false
	}
	e.mix_fed = end
	return true
}

// ---- encoder thread ---------------------------------------------------------------

@(private)
encode_loop :: proc(e: ^Encoder) {
	for {
		sync.mutex_lock(&e.lock)
		for !e.slots[e.read_index].filled && !e.closing {
			sync.cond_wait(&e.slot_filled, &e.lock)
		}
		if !e.slots[e.read_index].filled {
			sync.mutex_unlock(&e.lock)
			return
		}
		slot := &e.slots[e.read_index]
		sync.mutex_unlock(&e.lock)

		if !sync.atomic_load(&e.failed) {
			encode_slot(e, slot)
		}

		sync.mutex_lock(&e.lock)
		slot.filled = false
		slot.data = nil
		e.read_index = (e.read_index + 1) % RING_SLOTS
		e.done += 1
		// Writers wait for a free slot, `wait_frame` for `done`.
		sync.cond_broadcast(&e.slot_free)
		sync.mutex_unlock(&e.lock)
	}
}

@(private)
encode_slot :: proc(e: ^Encoder, slot: ^Slot) {
	// The audio of this frame goes in first, so the file interleaves.
	if e.audio && !feed_audio(e, int((slot.frame + 1) * om.MIX_RATE / i64(e.fps))) {
		return
	}
	ys, cs := slot.y_stride, slot.y_stride / 2
	u := ys * e.height
	err: video.Error
	if slot.nv12 {
		err = video.write_nv12(&e.writer, {slot.data[:u], slot.data[u:u + ys * e.height / 2]}, {ys, ys})
	} else {
		v := u + cs * e.height / 2
		err = video.write_i420(&e.writer, {slot.data[:u], slot.data[u:v], slot.data[v:v + cs * e.height / 2]}, {ys, cs, cs})
	}
	if err != .None {
		fail(e, {code = .Frame, frame = slot.frame, movie = err, detail = e.writer.error_detail})
	}
}

// ---- RGB -> YUV ------------------------------------------------------------------

// Bytes of an I420 frame packed with `y_stride = width` (`rgba_to_i420`).
i420_size :: proc(width, height: int) -> int {
	return width * height * 3 / 2
}

// Converts a frame of premultiplied RGBA8 rows to I420 planes packed with
// `y_stride = width` in `out` (`i420_size` bytes): odecs' converter, the
// same planes the GPU pass writes. Even sizes.
rgba_to_i420 :: proc(pixels: []u8, width, height: int, out: []u8) {
	k := video.rgb_to_yuv_coefficients(.BT709, false)
	cw, ch := width / 2, height / 2
	y := width * height
	video.rgba_to_i420(pixels, width * 4, width, height, {out[:y], out[y:][:cw * ch], out[y + cw * ch:][:cw * ch]}, {width, cw, cw}, &k, .Opaque, {})
}
