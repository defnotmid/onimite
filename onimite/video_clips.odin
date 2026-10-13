package onimite

import "core:math"
import "core:strings"
import vg "deps:ovg"

// Video clips in the media, drawn in sync with the frame clock (fframes'
// `get_synced_video_frame`). The core holds the clip table; decoding lives
// behind a `Video_Source` the host provides (onimite' `encode` package
// decodes with odecs on one background thread per clip).

Video_Info :: struct {
	width, height: int,
	// Seconds, after the container's edit list.
	duration:      f64,
	fps:           f64,
	frames:        int,
	// Clockwise degrees (0, 90, 180, 270) the container asks players to
	// rotate by; frames arrive unrotated and are turned when drawn.
	rotation:      int,
	// How its frames' planes read.
	format:        Video_Format,
}

// How a clip's decoded planes read (`Video_Frame.planes`), from the stream
// as the decoder resolved it.
Video_Format :: struct {
	// Bits per sample (8, 10 or 12); `wide`: two bytes per sample
	// (little-endian, LSB-aligned), else one.
	bit_depth:           int,
	wide:                bool,
	// Chroma subsampling as shifts (4:2:0 is 1, 1); no chroma planes when
	// monochrome.
	shift_x, shift_y:    int,
	monochrome:          bool,
	alpha:               bool,
	// The colour planes are premultiplied by alpha (else straight).
	alpha_premultiplied: bool,
	// H.273 codes (matrix 0 at 4:4:4: the planes are G', B', R').
	matrix_coeffs:       u8,
	transfer:            u8,
	primaries:           u8,
	full_range:          bool,
}

// What a frame request does when the frame isn't decoded yet.
Video_Wait :: enum u8 {
	// Wait for the exact frame (export renders, inspect, strips).
	Block,
	// Return the nearest decoded frame now (preview) and keep decoding.
	Nearest,
}

// A decoded frame lent to the caller until it calls `release` for the clip
// (or requests again): its planes, rows tight (`video_plane_size`), Y' (G'),
// Cb (B'), Cr (R') and alpha; empty planes the frame lacks.
Video_Frame :: struct {
	planes:        [4][]u8,
	format:        Video_Format,
	width, height: int,
	// Presentation index in the clip and its time.
	index:         int,
	seconds:       f64,
	// False when a nearer frame is still being decoded (`.Nearest`).
	exact:         bool,
	ok:            bool,
}

// The host's decoder. Every procedure is safe to call from any thread.
Video_Source :: struct {
	data:    rawptr,
	// Reads the clip's header; the decode thread starts on first request.
	// `why` says what failed (`err` is `.No_Video_Track` or `.Video_Decode`).
	open:    proc(data: rawptr, path: string) -> (clip: int, info: Video_Info, why: Video_Failure, err: Error),
	request: proc(data: rawptr, clip: int, seconds: f64, wait: Video_Wait) -> Video_Frame,
	release: proc(data: rawptr, clip: int),
	// Hints that frames from `seconds` on will be asked for (prefetch).
	prefetch: proc(data: rawptr, clip: int, seconds: f64),
	// Converts a frame to premultiplied RGBA8 into `out` (`width * height
	// * 4` bytes) on the CPU, for software renders (GPU ones convert in a
	// program, video_yuv.odin).
	to_rgba:  proc(data: rawptr, frame: Video_Frame, out: []u8),
}

// The clip table: parallel arrays indexed by clip number, plus a name
// index.
Video_Clips :: struct {
	names:   [dynamic]string,
	paths:   [dynamic]string,
	infos:   [dynamic]Video_Info,
	// The source's handle for each clip (-1 if it failed to open, and why).
	handles:  [dynamic]int,
	failures: [dynamic]Video_Failure,
	by_name: map[string]int,
	source:  Video_Source,
}

// Frees the table (the source's clips stay open: their decoders own them).
video_clips_destroy :: proc(v: ^Video_Clips) {
	for s in v.names {delete(s)}
	for s in v.paths {delete(s)}
	delete(v.names)
	delete(v.paths)
	delete(v.infos)
	delete(v.handles)
	delete(v.failures)
	delete(v.by_name)
	v^ = {source = v.source}
}

// Registers the clip at `path` under `name`, reading its header through the
// media's video source. An error (kept for diagnostics) when it can't be
// opened.
media_add_video :: proc(m: ^Media, name, path: string) -> Error {
	return video_clips_add(&m.videos, name, path)
}

// Registers the clip at `path` under `name` in `v`, opened on its source.
video_clips_add :: proc(v: ^Video_Clips, name, path: string) -> Error {
	if i, exists := v.by_name[name]; exists && v.paths[i] == path && v.handles[i] >= 0 {
		// Reloading the media keeps clips already open (and their threads).
		return nil
	}
	handle := -1
	info: Video_Info
	why := Video_Failure{code = .No_Video_Decoder}
	err := Error.No_Video_Decoder
	if v.source.open != nil {
		handle, info, why, err = v.source.open(v.source.data, path)
	}
	if i, exists := v.by_name[name]; exists {
		v.infos[i], v.handles[i], v.failures[i] = info, handle, why
	} else {
		owned := strings.clone(name)
		v.by_name[owned] = len(v.names) // the key is the name's own string
		append(&v.names, owned)
		append(&v.paths, strings.clone(path))
		append(&v.infos, info)
		append(&v.handles, handle)
		append(&v.failures, why)
	}
	return err
}

media_video_info :: proc(m: ^Media, name: string) -> (Video_Info, bool) {
	i, ok := m.videos.by_name[name]
	if !ok || m.videos.handles[i] < 0 {
		return {}, false
	}
	return m.videos.infos[i], true
}

// ---- the node ---------------------------------------------------------------------

// A clip frame placed like an image. `start_from` is the time on the frame
// clock where playback begins (before it, nothing is drawn); past the end
// the clip disappears unless it loops (fframes semantics). `clip_start`
// skips into the clip.
Video_Clip_Params :: struct {
	src:          string,
	x, y, w, h:   f32,
	start_from:   f32,
	clip_start:   f32,
	looping:      bool,
	// How the frame fits the box and sits in it (`fit_box`).
	fit:          Image_Fit,
	align:        Maybe(Vec2),
	opacity:      Maybe(f32),
}

// The node: which clip and the clip time this frame shows.
Video_Clip :: struct {
	clip:       int,
	seconds:    f64,
	x, y, w, h: f32,
	fit:        Image_Fit,
	align:      Maybe(Vec2),
	opacity:    Maybe(f32),
}

// Adds the clip's frame for `f` (or nothing before `start_from` / after a
// non-looping clip ends). Returns false and reports when the clip is
// missing.
video_clip :: proc(ctx: ^Context, f: Frame, p: Video_Clip_Params) -> bool {
	v := ctx.videos
	i, ok := v.by_name[p.src]
	if !ok {
		report(ctx, .Error, {code = .Missing_Video, name = p.src})
		return false
	}
	if v.handles[i] < 0 {
		report(ctx, .Error, {code = .Undecodable_Video, name = p.src, video = v.failures[i]})
		return false
	}
	t, showing := video_clip_time(v.infos[i], f, p.start_from, p.clip_start, p.looping)
	if !showing {
		return true
	}
	tree_add(&ctx.tree, Video_Clip{i, t, p.x, p.y, p.w, p.h, p.fit, p.align, p.opacity})
	if v.source.prefetch != nil && !ctx.recording {
		v.source.prefetch(v.source.data, v.handles[i], t)
	}
	return true
}

// The clip time frame `f` shows: playback starts at `start_from` on the
// frame clock, `clip_start` seconds into the clip; false before the start
// or after a non-looping clip ends.
video_clip_time :: proc(info: Video_Info, f: Frame, start_from, clip_start: f32, looping: bool) -> (t: f64, showing: bool) {
	start_frame := frame_at(f64(start_from), f.fps)
	if f.index < start_frame {
		return 0, false
	}
	t = f64(f.index - start_frame) / f64(f.fps) + f64(clip_start)
	if looping && info.duration > 0 {
		t = math.mod(t, info.duration)
	} else if t > info.duration {
		return t, false
	}
	// fframes shows the first clip frame whose timestamp is at or after this
	// time (its decoder's `decode_up_to`: pts >= target), the last one past
	// it: snap to the middle of that frame's interval.
	if info.fps > 0 && info.frames > 0 {
		k := min(math.ceil(t * info.fps - 1e-6), f64(info.frames - 1))
		t = (k + 0.5) / info.fps
	}
	return t, true
}

// ---- drawing ----------------------------------------------------------------------

// Canvas images showing clip frames, reused across frames: parallel arrays.
Video_Images :: struct {
	clip:       [dynamic]int,
	image:      [dynamic]vg.Image_Id,
	width:      [dynamic]int,
	height:     [dynamic]int,
	// Frame index uploaded, and the render that last used the image.
	shown:      [dynamic]int,
	used_frame: [dynamic]int,
	// The frame's planes (GPU renders convert them into `image`; invalid
	// ids for planes the clip lacks), and the program that converts them.
	planes:     [dynamic][4]vg.Image_Id,
	yuv:        Yuv_Program,
	// Software renders: the frame converted on the CPU before its upload.
	rgba:       [dynamic]u8,
	// Clip frames drawn inexactly in the last render (still decoding).
	pending:    int,
	// How frame requests wait; set `.Nearest` for interactive previews.
	wait:       Video_Wait,
}

video_images_destroy :: proc(vi: ^Video_Images, c: ^vg.Canvas) {
	for id in vi.image {
		vg.delete_image(c, id)
	}
	for planes in vi.planes {
		for id in planes {
			if vg.image_id_valid(id) {
				vg.delete_image(c, id)
			}
		}
	}
	yuv_program_destroy(&vi.yuv, c)
	delete(vi.clip)
	delete(vi.image)
	delete(vi.width)
	delete(vi.height)
	delete(vi.shown)
	delete(vi.used_frame)
	delete(vi.planes)
	delete(vi.rgba)
	vi^ = {wait = vi.wait}
}

// The image showing clip `clip` at `seconds` (an index into
// `r.video_images`): fetched, and uploaded when it changed. False when
// nothing is decoded.
video_clip_image :: proc(r: ^Renderer, clip: int, seconds: f64) -> (slot: int, ok: bool) {
	v := r.ctx.videos
	vi := &r.video_images
	src := v.source
	if src.request == nil {
		return -1, false
	}
	if r.recording {
		return video_clip_image_recorded(r, clip, seconds)
	}
	handle := v.handles[clip]
	frame := src.request(src.data, handle, seconds, vi.wait)
	defer src.release(src.data, handle)
	if !frame.exact {
		vi.pending += 1
	}

	// An image of this clip already showing this frame, else a free one.
	slot = -1
	frame_no := r.ctx.frame.global_index
	for c, k in vi.clip {
		if c != clip {continue}
		if frame.ok && vi.shown[k] == frame.index && vi.width[k] == frame.width && vi.height[k] == frame.height {
			slot = k
			break
		}
		if slot < 0 && vi.used_frame[k] != frame_no {
			slot = k
		}
	}
	if !frame.ok {
		// Nothing decoded yet (non-blocking): keep whatever this clip showed.
		if slot < 0 || vi.shown[slot] < 0 {
			return -1, false
		}
	} else {
		if slot < 0 || vi.width[slot] != frame.width || vi.height[slot] != frame.height {
			if slot >= 0 {
				vg.delete_image(&r.canvas, vi.image[slot])
				video_slot_planes_free(r, slot)
			} else {
				slot = video_slot_add(vi, clip)
			}
			id, err := vg.create_image_empty(&r.canvas, u32(frame.width), u32(frame.height), .RGBA8, {.Premultiplied})
			if err != nil {
				report(&r.ctx, .Error, {code = .Video_Frame_Image, gpu = err})
				return -1, false
			}
			vi.image[slot], vi.width[slot], vi.height[slot], vi.shown[slot] = id, frame.width, frame.height, -1
		}
		if vi.shown[slot] != frame.index {
			if !video_frame_upload(r, clip, slot, frame) {
				return -1, false
			}
			vi.shown[slot] = frame.index
		}
	}
	vi.used_frame[slot] = frame_no
	return slot, true
}

// Recording: an image of the clip's frame size (`Video_Info`, which is what
// the decoder delivers) not used yet this frame, and an upload of the
// frame to do when the frame is played.
@(private = "file")
video_clip_image_recorded :: proc(r: ^Renderer, clip: int, seconds: f64) -> (slot: int, ok: bool) {
	v := r.ctx.videos
	vi := &r.video_images
	info := v.infos[clip]
	frame_no := r.ctx.frame.global_index
	slot = -1
	for c, k in vi.clip {
		if c == clip && vi.used_frame[k] != frame_no {
			slot = k
			break
		}
	}
	if slot < 0 {
		slot = video_slot_add(vi, clip)
	}
	if vi.width[slot] != info.width || vi.height[slot] != info.height {
		if vg.image_id_valid(vi.image[slot]) {
			vg.delete_image(&r.canvas, vi.image[slot])
		}
		video_slot_planes_free(r, slot)
		id, err := vg.create_image_empty(&r.canvas, u32(info.width), u32(info.height), .RGBA8, {.Premultiplied})
		if err != nil {
			report(&r.ctx, .Error, {code = .Video_Frame_Image, gpu = err})
			return -1, false
		}
		vi.image[slot], vi.width[slot], vi.height[slot] = id, info.width, info.height
	}
	vi.used_frame[slot] = frame_no
	// GPU players get the planes, which the recorded program converts;
	// software ones convert the frame themselves.
	planes: [4]vg.Image_Id
	if video_on_gpu(r) {
		if !video_slot_planes(r, slot, info) || !video_yuv_run(r, slot, info) {
			return -1, false
		}
		planes = vi.planes[slot]
	}
	append(&r.video_uploads, Video_Upload{vi.image[slot], planes, v.handles[clip], seconds})
	return slot, true
}

// A new slot for `clip`'s frames.
@(private = "file")
video_slot_add :: proc(vi: ^Video_Images, clip: int) -> int {
	append(&vi.clip, clip)
	append(&vi.image, vg.Image_Id{})
	append(&vi.width, 0)
	append(&vi.height, 0)
	append(&vi.shown, -1)
	append(&vi.used_frame, -1)
	append(&vi.planes, [4]vg.Image_Id{})
	return len(vi.clip) - 1
}

// Puts `frame` into slot `slot`'s image: its planes uploaded and converted
// on the GPU, or converted on the CPU and uploaded.
@(private = "file")
video_frame_upload :: proc(r: ^Renderer, clip: int, slot: int, frame: Video_Frame) -> bool {
	vi := &r.video_images
	c := &r.canvas
	if video_on_gpu(r) {
		info := r.ctx.videos.infos[clip]
		if !video_slot_planes(r, slot, info) {
			return false
		}
		sources := video_plane_sources(frame)
		for id, i in vi.planes[slot] {
			if vg.image_id_valid(id) {
				vg.update_image(c, id, sources[i], 0, 0)
			}
		}
		return video_yuv_run(r, slot, info)
	}
	src := r.ctx.videos.source
	resize(&vi.rgba, frame.width * frame.height * 4)
	src.to_rgba(src.data, frame, vi.rgba[:])
	vg.update_image(c, vi.image[slot], vg.image_source_rgba(vi.rgba[:], u32(frame.width), u32(frame.height)), 0, 0)
	return true
}

draw_video_clip :: proc(r: ^Renderer, n: Video_Clip) {
	v := r.ctx.videos
	vi := &r.video_images
	slot, ok := video_clip_image(r, n.clip, n.seconds)
	if !ok {
		return
	}

	// Fit the frame, as shown (turned by the clip's rotation), into the box.
	rotation := v.infos[n.clip].rotation
	fw, fh := rotated_size(f32(vi.width[slot]), f32(vi.height[slot]), rotation)
	box, pic := fit_box(n.x, n.y, n.w, n.h, fw, fh, n.fit, n.align)
	c := &r.canvas
	vg.save(c)
	defer vg.restore(c)
	if n.fit == .Cover {
		vg.intersect_scissor(c, box.x, box.y, box.w, box.h)
	}
	// Draw around the picture's centre so the clip's rotation turns it in place.
	vg.translate(c, pic.x + pic.w / 2, pic.y + pic.h / 2)
	if rotation != 0 {
		vg.rotate(c, f32(rotation) * math.RAD_PER_DEG)
	}
	// The frame's own sides: the picture turned back.
	iw, ih := rotated_size(pic.w, pic.h, rotation)
	p := vg.paint_image(vi.image[slot], -iw / 2, -ih / 2, iw, ih, 0, n.opacity.? or_else 1)
	vg.path_reset(&r.path)
	vg.path_rect(&r.path, -iw / 2, -ih / 2, iw, ih)
	vg.fill_path(c, &r.path, p)
}

// The sides of a `w x h` frame turned by `rotation` degrees (0, 90, 180,
// 270): a sideways one swaps them.
@(private)
rotated_size :: proc "contextless" (w, h: f32, rotation: int) -> (f32, f32) {
	if rotation == 90 || rotation == 270 {
		return h, w
	}
	return w, h
}
