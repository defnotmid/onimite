package onimite

import "deps:o3d"
import vg "deps:ovg"

// Frames built on one thread and drawn on another: a recording renderer
// (`renderer_init(..., recording = true)`) runs the render procs and records
// the ovg frame on any thread (`record_frame`); a `Frame_Player` on the
// thread that owns the GPU draws the records in frame order (`play_frame`).
// Several recording renderers, each with its own script state, can build
// frames at once while one thread plays them. The pixels are those of
// `render_frame` on the player's backend.

// A clip frame to upload when the frame is played: decoders serve requests
// in frame order, so recording threads only name the frame.
Video_Upload :: struct {
	image:   vg.Image_Id,
	// GPU players: the plane images the recorded program converts into
	// `image` (video_yuv.odin); none: convert on the CPU into `image`.
	planes:  [4]vg.Image_Id,
	// The video source's handle.
	clip:    int,
	seconds: f64,
}

// One recorded frame, handed whole from the recording thread to the player:
// flat arrays, reused frame after frame.
Frame_Record :: struct {
	frame:       int,
	canvas:      vg.Recorded_Frame,
	video:       [dynamic]Video_Upload,
	// The 3D layers' renders, run on the GPU before the frame is drawn.
	view3d:      View3d_Jobs,
	// Its 3D jobs are prepared and the 3D tables read-locked until drawn.
	view3d_locked: bool,
	// What building and drawing the frame reported.
	diagnostics: [dynamic]Diagnostic,
	// Earlier frames' feedback buffer passes to play first, when the
	// renderer caught up (feedback.odin); the first `sim_count` are used.
	sims:        [dynamic]Frame_Record,
	sim_count:   int,
	// The frame has multipass shaders.
	feedback:    bool,
}

frame_record_destroy :: proc(f: ^Frame_Record) {
	for &s in f.sims {
		frame_record_destroy(&s)
	}
	delete(f.sims)
	vg.recorded_frame_destroy(&f.canvas)
	delete(f.video)
	view3d_jobs_destroy(&f.view3d)
	diagnostics_free(f.diagnostics[:])
	delete(f.diagnostics)
	f^ = {}
}

// Builds and records frame `index` into `out`, which takes the frame's
// diagnostics too (clear them with `frame_record_clear_diagnostics`).
record_frame :: proc(r: ^Renderer, index: int, out: ^Frame_Record) {
	assert(r.recording)
	frame_record_clear_diagnostics(out)
	out.sim_count = 0
	build_frame(r, index)
	feedback_catch_up(r, index, out)
	draw_frame(r)
	out.feedback = r.shader_state.feedback.drew
	vg.canvas_take(&r.canvas, &out.canvas)
	out.frame = index
	r.video_uploads, out.video = out.video, r.video_uploads
	clear(&r.video_uploads)
	r.view3d.jobs, out.view3d = out.view3d, r.view3d.jobs
	r.view3d.jobs.count = 0
	r.ctx.diagnostics, out.diagnostics = out.diagnostics, r.ctx.diagnostics
}

// Builds frame `index` (nothing is drawn or kept) and decodes the media
// images it shows (and makes what its 3D layers need), so that renderers
// recording it later find them ready: a render's look-ahead. The images count as used by that frame, so
// evictions before it is played spare them.
prefetch_frame_images :: proc(r: ^Renderer, index: int) {
	build_frame(r, index)
	for n in r.ctx.tree.nodes {
		#partial switch k in n.kind {
		case Image:
			media_image(r.media, k.src, index)
		case Shader:
			for chs in k.channels {
				for ch in chs {
					if ch.kind == .Image {
						media_image(r.media, ch.image, index)
					}
				}
			}
		case View3d:
			view3d_make_textures(r.media, k, index)
		}
	}
	diagnostics_clear(&r.ctx)
}

frame_record_clear_diagnostics :: proc(f: ^Frame_Record) {
	diagnostics_free(f.diagnostics[:])
	clear(&f.diagnostics)
}

// Draws one recording renderer's frames with a backend: an ovg player
// (the renderer's images and programs, same ids) plus the clip frames the
// records ask for.
Frame_Player :: struct {
	player: vg.Player,
	media:  ^Media,
	// The GPU the records' 3D layers render on (set by the owner after
	// `frame_player_init`; nil on the CPU, where they come drawn).
	gpu3d:  ^View3d_Gpu,
	// The clip frame index each video image shows (parallel arrays), so an
	// unchanged frame is not uploaded again.
	images: [dynamic]vg.Image_Id,
	shown:  [dynamic]int,
	// Software players: the frame converted on the CPU before its upload.
	rgba:   [dynamic]u8,
}

// `shared` holds the media images every player of a render shares.
frame_player_init :: proc(p: ^Frame_Player, backend: vg.Backend, media: ^Media, shared: ^vg.Shared_Images) {
	p^ = {media = media}
	vg.player_init(&p.player, backend, shared)
}

frame_player_destroy :: proc(p: ^Frame_Player) {
	vg.player_destroy(&p.player)
	delete(p.images)
	delete(p.shown)
	delete(p.rgba)
	p^ = {}
}

// Draws a record (frames of one renderer, in order) into `output`.
play_frame :: proc(p: ^Frame_Player, f: ^Frame_Record, output: vg.Render_Output = 0) {
	play_frame_images(p, f)
	play_frame_draw(p, f, output)
}

// The first half of `play_frame`: the record's image work and its clip
// frames (requested from the decoders, which serve them in frame order),
// after playing the frames its renderer caught up with.
play_frame_images :: proc(p: ^Frame_Player, f: ^Frame_Record) {
	for &s in f.sims[:f.sim_count] {
		play_frame(p, &s)
	}
	vg.player_apply(&p.player, &f.canvas)
	for up in f.video {
		play_video_upload(p, f, up)
	}
	if jobs := &f.view3d; jobs.count > 0 && p.gpu3d != nil {
		// recorded by their canvas rows as the frame is drawn
		err: o3d.Error
		err, f.view3d_locked = view3d_gpu_prepare(p.gpu3d, &p.media.view3d, jobs.list[:jobs.count], &p.player.images)
		if err != nil {
			append(&f.diagnostics, Diagnostic{severity = .Error, code = .View3d_Render, frame = f.frame, o3d = err})
		}
	}
}

// The second half of `play_frame`: draws the record with the backend.
play_frame_draw :: proc(p: ^Frame_Player, f: ^Frame_Record, output: vg.Render_Output = 0) {
	vg.player_render(&p.player, &f.canvas, output)
	if f.view3d_locked {
		f.view3d_locked = false
		if err := view3d_gpu_done(&p.media.view3d, f.view3d.list[:f.view3d.count]); err != nil {
			append(&f.diagnostics, Diagnostic{severity = .Error, code = .View3d_Render, frame = f.frame, o3d = err})
		}
	}
}

@(private = "file")
play_video_upload :: proc(p: ^Frame_Player, f: ^Frame_Record, up: Video_Upload) {
	v := p.media.videos
	src := v.source
	frame := src.request(src.data, up.clip, up.seconds, .Block)
	defer src.release(src.data, up.clip)
	if frame.failure.code != nil {
		name := ""
		for h, i in v.handles {
			if h == up.clip {
				name = v.names[i]
			}
		}
		append(&f.diagnostics, Diagnostic{severity = .Error, code = .Undecodable_Video, frame = f.frame, name = name, video = frame.failure})
		return
	}
	if !frame.ok {
		return
	}
	k := -1
	for id, i in p.images {
		if id == up.image {
			k = i
			break
		}
	}
	if k < 0 {
		k = len(p.images)
		append(&p.images, up.image)
		append(&p.shown, -1)
	}
	if p.shown[k] == frame.index {
		return
	}
	if vg.image_id_valid(up.planes[0]) {
		sources := video_plane_sources(frame)
		for id, i in up.planes {
			if vg.image_id_valid(id) && vg.player_update_image(&p.player, id, sources[i], 0, 0) != nil {
				return
			}
		}
		p.shown[k] = frame.index
		return
	}
	resize(&p.rgba, frame.width * frame.height * 4)
	src.to_rgba(src.data, frame, p.rgba[:])
	if vg.player_update_image(&p.player, up.image, vg.image_source_rgba(p.rgba[:], u32(frame.width), u32(frame.height)), 0, 0) == nil {
		p.shown[k] = frame.index
	}
}
