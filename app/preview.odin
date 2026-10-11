package onimite_app

import "core:fmt"
import "core:hash"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import om "../onimite"
import platform "../platform"
import render "../render"
import script "../script"
import ui "../ui"
import vg "deps:ovg"
import sdl "vendor:sdl3"

// The preview window, after paf: platform events and ui widgets publish
// command rows, `dispatch` applies them, and views only read state. Playback,
// the timeline following the playhead and the file watch are updates of
// state the clock owns, as paf's source update is.

Preview_State :: struct {
	// Set by Preview_Open; `run` opens the window when it is.
	requested:          bool,
	start_frame:        int,
	// The command line gave the start frame: it wins over the bookmark once.
	start_given:        bool,
	exit_after:         int,
	active:             bool,
	playing:            bool,
	loop:               bool,
	muted:              bool,
	// 0..1; kept while muted, so unmuting restores it.
	volume:             f32,
	frame:              int,
	// Seconds into the video; drives `frame` when there is no audio device.
	clock:              f64,
	hover_frame:        int,
	hover_valid:        bool,
	// The timeline is being dragged this window frame: sound pauses.
	scrubbing:          bool,
	// The bookmarked frame (-1: none); reloads return to it. The script's
	// first load brings the saved one.
	bookmark:           int,
	bookmark_unread:    bool,
	// The timeline view: 1 = the whole video; the frame at the left edge;
	// the playhead frame the view last followed.
	zoom:               f64,
	view_first:         f64,
	followed_frame:     int,
	timeline_collapsed: bool,
	// The timeline groups open (their paths' hashes: they stay open across
	// reloads) and the first row shown below the scenes.
	rows_open:          [dynamic]u64,
	rows_scroll:        int,
	// The press on the timeline began on a group's name (no scrubbing).
	press_on_name:      bool,
	fullscreen:         bool,
	show_diagnostics:   bool,
	show_media:         bool,
	media_grid:         bool,
	media_scroll:       int,
	quit:               bool,
	// File_Dialog asked for the open-file dialog (the loop opens it).
	file_dialog:        bool,
	// Measurements (Preview_Open): a PNG of the last window frame, and
	// scripted input (`preview_drive`); owned, "" for none.
	capture:            string,
	drive:              string,
	script_path:        string,
	media_dir:          string,
	// Script folder and media changes, polled on its own thread.
	watcher:            File_Watcher,
	// Requests to the worker: what was last asked, and the reload generation.
	asked_frame:        int,
	asked_scale:        f32,
	asked_reload:       u64,
	reload_gen:         u64,
	reload_media:       bool,
	sent_busy:          bool,
	sent_bookmark:      int,
	sent_thumbs:        [dynamic]int,
	// What the UI took from the mailbox (owned copies).
	seen_publish:       u64,
	seen_timeline:      u64,
	seen_problems:      u64,
	seen_waves:         u64,
	seen_media:         u64,
	seen_thumbs:        u64,
	timeline:           Preview_Timeline,
	shown_frame:        int,
	shown_size:         [2]u32,
	render_ms:          f64,
	latency_ms:         f64,
	// Frames published per second, counted over the last second.
	worker_fps:         f64,
	fps_count:          int,
	fps_since:          f64,
	// Seconds from the window opening to the first frame shown.
	first_frame_at:     f64,
	rendering:          bool,
	loading:            bool,
	// While loading: what the worker is doing, the media files, the time so far.
	load_phase:         Load_Phase,
	load_files:         int,
	load_seconds:       f64,
	problems:           Problem_Table,
	waves:              Wave_Table,
	media:              Media_Table,
	media_images:       [dynamic]render.Image, // parallel to media.rows (image thumbnails)
	media_uploaded:     int, // rows whose thumbnail texture exists (a few more per window frame)
	thumbs:             [dynamic]Preview_Thumb, // sorted by frame
	thumb_size:         [2]u32,
	// The last load's failure as text (made when taken), "" after a good one.
	reload_error:       string,
	seen_reload:        u64,
	video_image:        render.Image,
	device_name:        string,
	// Owned by the preview's run; shared with the worker and audio thread.
	mailbox:            ^Mailbox,
	worker:             ^Render_Worker,
	audio:              ^Audio_Shared,
	audio_stream:       ^sdl.AudioStream,
	// Per window frame: the UI thread's work before presenting, and the
	// interval between frames (vsync included), in ms. For --exit-after and
	// ONIMITE_DEBUG.
	ui_ms:              [dynamic]f32,
	interval_ms:        [dynamic]f32,
}

// The UI's face: ovg's bundled Vera, not a second embedded copy.
UI_FONT :: vg.DEFAULT_FONT_DATA

PREVIEW_BG :: [4]f32{0.07, 0.078, 0.102, 1}
CONTROLS_HEIGHT :: 40
STATUS_HEIGHT :: 26
DIAGNOSTICS_HEIGHT :: 160
MEDIA_WIDTH :: 340
VOLUME_STEP :: 0.1

// Preview_Open: remembers the request; `run` opens the window after the
// command line's rows are applied. The start spec resolves against the
// script main loaded (declarations only, no rendering).
preview_open :: proc(app: ^App_State, regs: Command_Regs) -> Error {
	pv := &app.preview
	pv.requested = true
	pv.exit_after = regs.count
	pv.playing = .Paused not_in regs.flags
	pv.loop = .No_Loop not_in regs.flags
	pv.muted = .Mute in regs.flags
	pv.capture = strings.clone(regs.path)
	pv.drive = strings.clone(regs.args)
	if regs.spec != "" {
		tl, err := om.resolve_timeline(&app.script.video, &app.media, context.temp_allocator)
		if err != nil {
			// The script was loaded without its media (the worker loads it);
			// a timeline that needs it (audio lengths) loads it here.
			dir := regs.media if regs.media != "" else default_media_dir(app.script.path)
			if os.is_dir(dir) {
				om.media_load_dir(&app.media, dir, app.pool)
			}
			tl, err = om.resolve_timeline(&app.script.video, &app.media, context.temp_allocator)
		}
		if err == nil {
			f, ferr := om.parse_frame(tl, max(app.script.video.fps, 1), regs.spec)
			if ferr != nil {
				return fail(app, spec_failure(&tl, max(app.script.video.fps, 1), regs.spec, ferr))
			}
			pv.start_frame = f
			pv.start_given = true
		}
	}
	pv.script_path = strings.clone(app.script.path)
	pv.media_dir = strings.clone(regs.media if regs.media != "" else default_media_dir(app.script.path))
	return nil
}

// Applies queued rows; when Preview_Open asked for it, then runs the window.
run :: proc(app: ^App_State) {
	dispatch(app)
	if app.preview.requested && app.exit_code == 0 {
		if preview_run(app) != nil {
			failure_print(app)
			failure_clear(app)
		}
	}
}

// The window loop. Never waits on Lua, the render worker or a fence: it
// samples the newest frame the worker published.
preview_run :: proc(app: ^App_State) -> Error {
	pv := &app.preview
	pv.active = true
	// Scrubbing seeks backwards a lot: native decoding seeks fastest.
	app.video.native = true
	file_watcher_start(&pv.watcher, pv.script_path, pv.media_dir)
	defer file_watcher_stop(&pv.watcher)
	pv.asked_frame = -1
	pv.volume = 1
	pv.bookmark = -1
	pv.sent_bookmark = -1
	pv.bookmark_unread = true
	pv.zoom = 1
	defer preview_state_destroy(pv)
	// Scripted input for measurements is pushed as command rows (see
	// preview_drive).
	capture, drive := pv.capture, pv.drive
	debug := app.debug || pv.exit_after > 0

	p: platform.Platform
	title := strings.clone_to_cstring(fmt.tprintf("onimite · %s", filepath.base(pv.script_path)), context.temp_allocator)
	if err, detail := platform.init(&p, title, 1280, 820); err != nil {
		return fail(app, {code = .Window, window = err, spec = detail})
	}
	defer platform.shutdown(&p)

	r: render.Renderer
	if err := render.init(&r, p.device, p.window, p.width, p.height); err != nil {
		return fail(app, {code = .Window_Drawing, drawing = err})
	}
	defer render.shutdown(&r)
	defer media_images_release(pv, &r)

	font, font_ok := render.font_load(&r, UI_FONT, 32)
	if !font_ok {
		return fail(app, {code = .Window_Drawing, drawing = .Font})
	}
	defer render.font_unload(&r, &font)

	s: ui.State
	ui.init(&s, &r, &p, &font)
	defer ui.destroy(&s)
	s.theme.default_font_px = 15 * p.dpi_scale
	s.theme.default_padding = 6 * p.dpi_scale
	// The UI's text sizes, rasterized before the first frame.
	{
		dpi := p.dpi_scale
		render.font_warm(&r, &font, {15 * dpi, 13 * dpi, 12 * dpi, 11 * dpi, 10 * dpi})
	}

	pv.device_name = strings.clone("software" if app.software else string(sdl.GetGPUDeviceDriver(p.device)))
	props := sdl.GetGPUDeviceProperties(p.device)
	if name := sdl.GetStringProperty(props, sdl.PROP_GPU_DEVICE_NAME_STRING, nil); name != nil && !app.software {
		delete(pv.device_name)
		pv.device_name = fmt.aprintf("%s (%s)", name, sdl.GetGPUDeviceDriver(p.device))
	}

	// The threads: audio (SDL's, through the callback) and the render worker.
	mb := new(Mailbox)
	mb.slot = -1
	mb.displayed_slot = -1
	mb.bookmark = -1
	mb.bookmark_loaded = -1
	audio := new(Audio_Shared)
	worker := new(Render_Worker)
	worker^ = {mb = mb, audio = audio, device = p.device, software = app.software, debug = app.debug, log_clips = app.clip_log, image_budget = app.image_budget, script_path = strings.clone(pv.script_path), script_args = app.script.args, script_props = app.script.props, media_dir = strings.clone(pv.media_dir), video = &app.video, pool = app.pool}
	pv.mailbox, pv.worker, pv.audio = mb, worker, audio
	pv.audio_stream = audio_open(audio)
	if pv.audio_stream == nil {
		warn("no audio device, the preview plays without sound")
	}
	worker_start(worker)
	defer {
		// The worker releases its GPU objects before the device goes.
		worker_stop(worker)
		audio.stream = nil // the playhead stops asking the stream
		audio_close(pv.audio_stream)
		mailbox_destroy(mb)
		audio_shared_destroy(audio)
		free(worker)
		free(mb)
		free(audio)
		pv.mailbox, pv.worker, pv.audio, pv.audio_stream = nil, nil, nil, nil
	}

	// The opening state, through the same commands as the keys (the volume
	// first: setting it unmutes).
	command_push(&app.commands, .Volume_Set, {scalar = 1})
	command_push(&app.commands, .Frame_Set, {count = pv.start_frame})
	command_push(&app.commands, .Playback_Set, {flag = pv.playing})
	command_push(&app.commands, .Loop_Set, {flag = pv.loop})
	command_push(&app.commands, .Mute_Set, {flag = pv.muted})

	frames := 0
	last_audio_log := 0
	fullscreen := false
	for platform.tick(&p) {
		defer free_all(context.temp_allocator)
		tick_began := time.tick_now()
		if p.resized {
			render.resize(&r, p.width, p.height)
		}
		frames += 1
		if pv.exit_after > 0 && frames >= pv.exit_after {
			platform.request_close(&p)
		}
		now := platform.time(&p)
		dt := clamp(f64(p.frame_time), 0, 0.25)

		pv.hover_valid = false
		if pv.scrubbing {
			// Like hover, a scrub lasts one window frame.
			pv.scrubbing = false
			preview_sync_audio(app)
		}
		preview_gather_from_platform(app, &p)
		if drive != "" {
			preview_drive(app, drive, frames)
		}
		preview_watch_files(app, now)
		dispatch(app)
		preview_playback_advance(app, dt)
		preview_take_published(app, &r, now)
		preview_view_follow(app)
		preview_request(app, &p)
		if pv.quit {
			break
		}
		if pv.file_dialog {
			pv.file_dialog = false
			platform.file_dialog_open(&p)
		}
		if pv.fullscreen != fullscreen {
			fullscreen = pv.fullscreen
			platform.set_fullscreen(&p, fullscreen)
		}

		render.begin_frame(&r, PREVIEW_BG)
		ui.build_begin(&s)
		preview_global_actions(app, &s, &p)
		preview_views(app, &s, &p)
		ui.build_end(&s)
		dispatch(app)
		append(&pv.ui_ms, f32(time.duration_milliseconds(time.tick_since(tick_began))))
		append(&pv.interval_ms, p.frame_time * 1000)
		if capture != "" && pv.exit_after > 0 && frames >= pv.exit_after {
			if pixels, ok := render.end_frame_capture(&r); ok {
				vg.write_png(capture, pixels, r.fb_w, r.fb_h)
				delete(pixels)
				fmt.eprintln("preview: captured", capture)
			}
		} else {
			render.end_frame(&r)
		}
		if debug && pv.audio_stream != nil && frames - last_audio_log >= 30 {
			last_audio_log = frames
			pos, playing, fed := audio_position(audio)
			fmt.eprintfln(
				"preview audio: playhead %.3fs (frame %d), audio position %.3fs, fed %.3fs, playing %v, muted %v",
				f64(pv.frame) / f64(preview_fps(app)),
				pv.frame,
				f64(pos) / om.MIX_RATE,
				f64(fed) / om.MIX_RATE,
				playing,
				pv.muted,
			)
		}
	}
	if debug {
		preview_report(app)
	}
	return nil
}

// The --exit-after / ONIMITE_DEBUG summary: UI work and frame intervals as
// median / p95 / max (the first frames, window and pipeline creation, are
// skipped), budget misses, and the worker's last render and latency.
@(private)
preview_report :: proc(app: ^App_State) {
	pv := &app.preview
	SKIP :: 10
	stats :: proc(list: []f32) -> (median, p95, worst: f32, over: int) {
		if len(list) == 0 {
			return
		}
		sorted := make([]f32, len(list), context.temp_allocator)
		copy(sorted, list)
		slice.sort(sorted)
		for ms in sorted {
			if ms > 1000.0 / 60 + 0.5 {
				over += 1
			}
		}
		return sorted[len(sorted) / 2], sorted[min(len(sorted) * 95 / 100, len(sorted) - 1)], sorted[len(sorted) - 1], over
	}
	wm, wp, ww, wo := stats(pv.ui_ms[min(SKIP, len(pv.ui_ms)):])
	im, ip, iw, io := stats(pv.interval_ms[min(SKIP, len(pv.interval_ms)):])
	fmt.eprintfln(
		"preview: %d frames, first frame at %.2f s; UI work median %.2f / p95 %.2f / max %.2f ms (%d over budget); interval median %.2f / p95 %.2f / max %.2f ms (%d over budget); last video render %.2f ms, latency %.2f ms on %s; frame %d shown %d; %d thumbnails, %d lanes, %d media, %d problems%s%s",
		len(pv.ui_ms),
		pv.first_frame_at,
		wm,
		wp,
		ww,
		wo,
		im,
		ip,
		iw,
		io,
		pv.render_ms,
		pv.latency_ms,
		pv.device_name,
		pv.frame,
		pv.shown_frame,
		len(pv.thumbs),
		len(pv.waves.lanes),
		len(pv.media.rows),
		len(pv.problems.rows),
		", rendering" if pv.rendering else "",
		fmt.tprintf(", reload error: %s", pv.reload_error) if pv.reload_error != "" else "",
	)
}

// ONIMITE_PREVIEW_DRIVE: input for repeatable measurements, as the rows the
// widgets would push. "scrub" sweeps the playhead back and forth over the
// whole video as a drag, "slowscrub" two frames per window frame;
// "zoom" zooms in and out around the playhead; "pause" pauses first (so
// thumbnails render); "media" opens the media panel; "mark" toggles the
// bookmark at frame 42; "reload" reloads at window frame 60; "lanes" shows
// every audio lane; "seek" jumps to frame 130, 75 and 340, then back to
// the start frame (40 window frames apart; feedback buffers' checkpoints).
@(private)
preview_drive :: proc(app: ^App_State, drive: string, frames: int) {
	c := &app.commands
	total := preview_duration(app)
	PERIOD :: 240
	t := frames % PERIOD
	pos := t if t < PERIOD / 2 else PERIOD - t
	if strings.contains(drive, "slowscrub") {
		// Two frames per window frame back and forth from the start frame.
		command_push(c, .Frame_Set, {count = app.preview.start_frame + pos * 2, flag = true})
	} else if strings.contains(drive, "scrub") {
		command_push(c, .Frame_Set, {count = pos * total / (PERIOD / 2), flag = true})
	}
	if strings.contains(drive, "zoom") {
		command_push(c, .Timeline_Zoom, {scalar = 1.04 if t < PERIOD / 2 else 1 / 1.04, count = app.preview.frame})
	}
	if frames == 2 && strings.contains(drive, "pause") {
		command_push(c, .Playback_Set, {flag = false})
	}
	if frames == 2 && strings.contains(drive, "media") {
		command_push(c, .Media_Toggle)
	}
	if frames == 90 && strings.contains(drive, "lanes") {
		for it in app.preview.waves.items {
			if it.kind == .Group {
				command_push(c, .Timeline_Row_Toggle, {spec = text_of(app.preview.waves.text[:], it.path)})
			}
		}
	}
	if strings.contains(drive, "mark") {
		if frames == 20 {
			command_push(c, .Frame_Set, {count = 42})
		} else if frames == 21 {
			command_push(c, .Bookmark_Toggle)
		}
	}
	if strings.contains(drive, "seek") {
		switch frames {
		case 2:
			command_push(c, .Frame_Set, {count = 130})
		case 40:
			command_push(c, .Frame_Set, {count = 75})
		case 80:
			command_push(c, .Frame_Set, {count = 340})
		case 120:
			command_push(c, .Frame_Set, {count = app.preview.start_frame})
		}
	}
	if frames == 60 && strings.contains(drive, "reload") {
		command_push(c, .Frame_Set, {count = 7})
		command_push(c, .Script_Reload, {flag = true})
	}
}

@(private)
preview_state_destroy :: proc(pv: ^Preview_State) {
	delete(pv.script_path)
	delete(pv.capture)
	delete(pv.drive)
	delete(pv.media_dir)
	delete(pv.reload_error)
	delete(pv.device_name)
	problem_table_destroy(&pv.problems)
	wave_table_destroy(&pv.waves)
	media_table_destroy(&pv.media)
	delete(pv.media_images)
	delete(pv.rows_open)
	delete(pv.thumbs)
	delete(pv.sent_thumbs)
	preview_timeline_destroy(&pv.timeline)
	delete(pv.ui_ms)
	delete(pv.interval_ms)
	pv^ = {}
}

@(private)
media_images_release :: proc(pv: ^Preview_State, r: ^render.Renderer) {
	for &img in pv.media_images {
		render.image_destroy(r, &img)
	}
	clear(&pv.media_images)
}

@(private)
default_media_dir :: proc(script_path: string) -> string {
	return filepath.join({filepath.dir(script_path), "media"}, context.temp_allocator) or_else "media"
}


// ---- commands ----------------------------------------------------------------------

@(private)
preview_duration :: proc(app: ^App_State) -> int {
	return max(app.preview.timeline.frames, 1)
}

@(private)
preview_fps :: proc(app: ^App_State) -> int {
	return max(app.preview.timeline.fps, 1)
}

// Moves the playhead (and the audio position with it).
@(private)
preview_seek :: proc(app: ^App_State, frame: int) {
	pv := &app.preview
	if pv.timeline.frames > 0 {
		pv.frame = clamp(frame, 0, preview_duration(app) - 1)
	} else {
		pv.frame = max(frame, 0)
	}
	pv.clock = f64(pv.frame) / f64(preview_fps(app))
	if pv.audio != nil {
		audio_seek(pv.audio, i64(pv.clock * om.MIX_RATE))
	}
}

@(private)
preview_sync_audio :: proc(app: ^App_State) {
	pv := &app.preview
	if pv.audio != nil {
		audio_set_state(pv.audio, pv.playing && !pv.scrubbing, pv.muted, pv.loop)
		audio_set_gain(pv.audio, pv.volume)
	}
}

// Frames across the timeline at the current zoom.
@(private)
view_frames :: proc(app: ^App_State) -> f64 {
	return f64(preview_duration(app)) / app.preview.zoom
}

@(private)
view_clamp :: proc(app: ^App_State) {
	pv := &app.preview
	total := f64(preview_duration(app))
	// At most 24 frames across the view.
	pv.zoom = clamp(pv.zoom, 1, max(total / 24, 1))
	pv.view_first = clamp(pv.view_first, 0, max(total - view_frames(app), 0))
}

preview_apply :: proc(app: ^App_State, kind: Command_Kind, regs: Command_Regs) {
	pv := &app.preview
	#partial switch kind {
	case .Playback_Toggle:
		if !pv.playing && !pv.loop && pv.frame >= preview_duration(app) - 1 {
			preview_seek(app, 0)
		}
		pv.playing = !pv.playing
		preview_seek(app, pv.frame)
		preview_sync_audio(app)
	case .Playback_Set:
		pv.playing = regs.flag
		preview_seek(app, pv.frame)
		preview_sync_audio(app)
	case .Frame_Set:
		if regs.flag && !pv.scrubbing {
			pv.scrubbing = true
			preview_sync_audio(app)
		}
		preview_seek(app, regs.count)
	case .Frame_Step:
		pv.playing = false
		preview_seek(app, pv.frame + regs.count)
		preview_sync_audio(app)
	case .Frame_Start:
		preview_seek(app, start_target(app))
	case .Seconds_Step:
		pv.playing = false
		preview_seek(app, pv.frame + int(math.round(regs.scalar * f64(preview_fps(app)))))
		preview_sync_audio(app)
	case .Scene_Step:
		preview_seek(app, scene_step_target(app, regs.count))
	case .Script_Open:
		preview_switch_script(app, regs.path)
	case .File_Dialog:
		pv.file_dialog = true
	case .Script_Reload:
		// The worker reloads; the UI keeps showing the last frame meanwhile.
		pv.reload_gen += 1
		pv.reload_media |= regs.flag
		pv.asked_frame = -1
	case .Loop_Toggle:
		pv.loop = !pv.loop
		preview_sync_audio(app)
	case .Loop_Set:
		pv.loop = regs.flag
		preview_sync_audio(app)
	case .Mute_Toggle:
		pv.muted = !pv.muted
		if !pv.muted && pv.volume <= 0 {
			pv.volume = VOLUME_STEP
		}
		preview_sync_audio(app)
	case .Mute_Set:
		pv.muted = regs.flag
		preview_sync_audio(app)
	case .Volume_Set:
		pv.volume = clamp(f32(regs.scalar), 0, 1)
		if pv.volume > 0 {
			pv.muted = false
		}
		preview_sync_audio(app)
	case .Volume_Step:
		from: f32 = 0 if pv.muted else pv.volume
		// Steps land on multiples of the step; stepping to 0 mutes and keeps
		// one step to come back to.
		pv.volume = clamp(math.round((from + f32(regs.scalar)) / VOLUME_STEP) * VOLUME_STEP, 0, 1)
		pv.muted = pv.volume <= 0
		if pv.muted {
			pv.volume = VOLUME_STEP
		}
		preview_sync_audio(app)
	case .Bookmark_Toggle:
		pv.bookmark = -1 if pv.bookmark == pv.frame else pv.frame
	case .Timeline_Zoom:
		visible := view_frames(app)
		anchor := f64(regs.count if regs.count >= 0 else pv.frame)
		at := clamp((anchor - pv.view_first) / visible, 0, 1) if visible > 0 else 0
		pv.zoom *= regs.scalar
		view_clamp(app)
		pv.view_first = anchor - at * view_frames(app)
		view_clamp(app)
	case .Timeline_Fit:
		pv.zoom = 1
		pv.view_first = 0
	case .Timeline_Pan:
		pv.view_first += regs.scalar
		view_clamp(app)
	case .Timeline_Toggle:
		pv.timeline_collapsed = !pv.timeline_collapsed
	case .Timeline_Row_Toggle:
		h := hash.fnv64a(transmute([]u8)regs.spec)
		if i, found := slice.linear_search(pv.rows_open[:], h); found {
			unordered_remove(&pv.rows_open, i)
		} else {
			append(&pv.rows_open, h)
		}
		timeline_rows_clamp(app)
	case .Timeline_Rows_Scroll:
		pv.rows_scroll += regs.count
		timeline_rows_clamp(app)
	case .Fullscreen_Toggle:
		pv.fullscreen = !pv.fullscreen
	case .Media_Toggle:
		pv.show_media = !pv.show_media
	case .Media_Layout_Toggle:
		pv.media_grid = !pv.media_grid
		pv.media_scroll = 0
	case .Media_Scroll:
		pv.media_scroll = clamp(pv.media_scroll + regs.count, 0, max(len(pv.media.rows) - 1, 0))
	case .Diagnostics_Toggle:
		pv.show_diagnostics = !pv.show_diagnostics
	case .Cursor_Hover:
		pv.hover_frame = regs.count
		pv.hover_valid = true
	case .Quit:
		pv.quit = true
	}
}

// The first frame of the scene `steps` scenes after (or before) the one
// at the current frame. Stepping back from inside a scene goes to its start.
@(private)
scene_step_target :: proc(app: ^App_State, steps: int) -> int {
	pv := &app.preview
	scenes := pv.timeline.scenes
	if len(scenes) == 0 {
		return 0 if steps < 0 else preview_duration(app) - 1
	}
	target := pv.frame
	for _ in 0 ..< abs(steps) {
		if steps > 0 {
			next := preview_duration(app) - 1
			for s in scenes {
				if s.start_frame > target {
					next = s.start_frame
					break
				}
			}
			target = next
		} else {
			prev := 0
			for s in scenes {
				if s.start_frame < target {
					prev = s.start_frame
				}
			}
			target = prev
		}
	}
	return target
}

// Home / 0 / Shift+Left: the bookmark when there is one and the playhead
// isn't on it, else the first frame (fframes' seek to start).
@(private)
start_target :: proc(app: ^App_State) -> int {
	pv := &app.preview
	if pv.bookmark >= 0 && pv.frame != pv.bookmark {
		return pv.bookmark
	}
	return 0
}

// ---- updates ------------------------------------------------------------------------

@(private)
preview_gather_from_platform :: proc(app: ^App_State, p: ^platform.Platform) {
	for path in platform.dropped_files(p) {
		if strings.has_suffix(strings.to_lower(path, context.temp_allocator), ".lua") {
			command_push(&app.commands, .Script_Open, {path = path})
			break
		}
	}
	if path, ok := platform.file_dialog_take(p); ok {
		command_push(&app.commands, .Script_Open, {path = path})
		delete(path)
	}
}

// Points the preview at another script (and its media): the worker
// restarts on it.
@(private)
preview_switch_script :: proc(app: ^App_State, path: string) {
	pv := &app.preview
	delete(pv.script_path)
	delete(pv.media_dir)
	pv.script_path = strings.clone(path)
	pv.media_dir = strings.clone(default_media_dir(path))
	file_watcher_stop(&pv.watcher)
	file_watcher_start(&pv.watcher, pv.script_path, pv.media_dir)
	// The new script brings its own bookmark.
	pv.bookmark = -1
	pv.sent_bookmark = -1
	pv.bookmark_unread = true
	pv.zoom = 1
	pv.view_first = 0
	if w := pv.worker; w != nil {
		// The worker reads its paths only between requests; restart it on the
		// new script (the stop waits for the frame in progress).
		mb := w.mb
		// Its textures go with it: stop showing them.
		pv.video_image = {}
		clear(&pv.thumbs)
		worker_stop(w)
		sync.mutex_lock(&mb.mutex)
		mb.quit = false
		mb.slot = -1
		mb.slot_texture = nil
		mb.displayed_slot = -1
		mb.bookmark = -1
		mb.bookmark_seq = 0
		mb.bookmark_loaded = -1
		clear(&mb.thumbs)
		mb.thumb_gen = 0
		mb.thumb_ack = 0
		mb.thumbs_seq += 1
		sync.mutex_unlock(&mb.mutex)
		w^ = {mb = mb, audio = w.audio, device = w.device, software = w.software, debug = w.debug, log_clips = w.log_clips, image_budget = w.image_budget, script_path = strings.clone(pv.script_path), script_args = app.script.args, script_props = app.script.props, media_dir = strings.clone(pv.media_dir), video = w.video, pool = w.pool}
		worker_start(w)
	}
	command_push(&app.commands, .Script_Reload, {flag = true})
	command_push(&app.commands, .Frame_Set, {count = 0})
}

@(private)
preview_watch_files :: proc(app: ^App_State, now: f64) {
	changes := file_watcher_take(&app.preview.watcher)
	if changes != {} {
		command_push(&app.commands, .Script_Reload, {flag = .Media in changes})
	}
}

// The clock: the audio thread's play position when there is a device,
// else real time.
@(private)
preview_playback_advance :: proc(app: ^App_State, dt: f64) {
	pv := &app.preview
	if !pv.playing || pv.scrubbing || pv.timeline.frames <= 0 {
		return
	}
	fps := f64(preview_fps(app))
	total := f64(preview_duration(app)) / fps
	if pv.audio_stream != nil {
		pos, playing, _ := audio_position(pv.audio)
		pv.clock = f64(pos) / om.MIX_RATE
		if !playing && pv.clock >= total - 1.5 / fps {
			// The audio stopped at the end (not looping).
			pv.playing = false
			pv.clock = total - 1 / fps
		}
	} else {
		pv.clock += dt
		if pv.clock >= total {
			if pv.loop {
				pv.clock -= total * math.floor(pv.clock / total)
			} else {
				pv.clock = total - 1 / fps
				pv.playing = false
			}
		}
	}
	pv.frame = clamp(int(pv.clock * fps), 0, preview_duration(app) - 1)
}

// When the playhead moves out of the zoomed timeline (playing, stepping,
// seeking), the view jumps to put it at the left edge (fframes'
// useViewportFollow).
@(private)
preview_view_follow :: proc(app: ^App_State) {
	pv := &app.preview
	if pv.frame == pv.followed_frame {
		return
	}
	pv.followed_frame = pv.frame
	f := f64(pv.frame)
	if f < pv.view_first || f >= pv.view_first + view_frames(app) {
		pv.view_first = f
		view_clamp(app)
	}
}

// Takes what the worker published since the last look: the newest frame's
// texture (the worker won't render into it while it is shown), the
// timeline, the problems, waveforms, media and thumbnail tables, and the
// load state.
@(private)
preview_take_published :: proc(app: ^App_State, r: ^render.Renderer, now: f64) {
	pv := &app.preview
	mb := pv.mailbox
	timeline_changed, media_changed := false, false
	bookmark_loaded := -1
	sync.mutex_lock(&mb.mutex)
	if mb.published_seq != pv.seen_publish && mb.slot >= 0 {
		pv.fps_count += int(mb.published_seq - pv.seen_publish)
		if pv.seen_publish == 0 {
			pv.first_frame_at = now
		}
		pv.seen_publish = mb.published_seq
		mb.displayed_slot = mb.slot
		pv.video_image = {mb.slot_texture, mb.slot_size.x, mb.slot_size.y}
		pv.shown_frame = mb.slot_frame
		pv.shown_size = mb.slot_size
		pv.render_ms = mb.render_ms
		pv.latency_ms = mb.latency_ms
	}
	if mb.timeline_seq != pv.seen_timeline {
		pv.seen_timeline = mb.timeline_seq
		preview_timeline_destroy(&pv.timeline)
		pv.timeline = preview_timeline_clone(mb.timeline)
		bookmark_loaded = mb.bookmark_loaded
		timeline_changed = true
	}
	if mb.problems_seq != pv.seen_problems {
		pv.seen_problems = mb.problems_seq
		problem_table_copy(&pv.problems, &mb.problems)
	}
	if mb.waves_seq != pv.seen_waves {
		pv.seen_waves = mb.waves_seq
		wave_table_copy(&pv.waves, &mb.waves)
	}
	if mb.media_seq != pv.seen_media {
		pv.seen_media = mb.media_seq
		media_table_copy(&pv.media, &mb.media)
		media_changed = true
	}
	if mb.thumbs_seq != pv.seen_thumbs {
		pv.seen_thumbs = mb.thumbs_seq
		table_copy(&pv.thumbs, mb.thumbs[:])
		pv.thumb_size = mb.thumb_size
		// The textures of older generations may now be reused.
		mb.thumb_ack = mb.thumb_gen
	}
	if mb.reload_seq != pv.seen_reload {
		pv.seen_reload = mb.reload_seq
		delete(pv.reload_error)
		pv.reload_error = script.error_message(mb.reload_failure) if mb.reload_failure.code != .None else ""
	}
	pv.rendering = mb.rendering
	pv.loading = mb.loading
	pv.load_phase = mb.load_phase
	pv.load_files = mb.load_files
	if pv.loading {
		pv.load_seconds = time.duration_seconds(time.tick_since(mb.load_began))
	}
	sync.mutex_unlock(&mb.mutex)

	if now - pv.fps_since >= 1 {
		pv.worker_fps = f64(pv.fps_count) / (now - pv.fps_since)
		pv.fps_count = 0
		pv.fps_since = now
	}
	if media_changed {
		media_images_release(pv, r)
		resize(&pv.media_images, len(pv.media.rows))
		slice.zero(pv.media_images[:])
		pv.media_uploaded = 0
	}
	// Small textures for the image thumbnails: uploads, never waited on, a
	// few per window frame so a folder of images doesn't stall one.
	MEDIA_UPLOADS_PER_FRAME :: 4
	for uploads := 0; pv.media_uploaded < pv.media.thumbs_ready && uploads < MEDIA_UPLOADS_PER_FRAME; pv.media_uploaded += 1 {
		row := pv.media.rows[pv.media_uploaded]
		if row.thumb_size.x > 0 {
			w, h := u32(row.thumb_size.x), u32(row.thumb_size.y)
			pv.media_images[pv.media_uploaded] = render.image_texture_make(r, w, h, pv.media.pixels[row.thumb:][:w * h * 4])
			uploads += 1
		}
	}
	if timeline_changed {
		// A new script: keep the playhead (clamped), or return to the
		// bookmark; resync the audio.
		if pv.bookmark_unread {
			pv.bookmark_unread = false
			pv.bookmark = bookmark_loaded
			pv.sent_bookmark = bookmark_loaded
		}
		target := pv.frame
		if pv.bookmark >= 0 && !pv.start_given {
			target = pv.bookmark
		}
		pv.start_given = false
		view_clamp(app)
		preview_seek(app, target)
		preview_sync_audio(app)
	}
}

// Asks the worker for the frame on the playhead at the size that fits the
// window (latest request wins), and passes what it needs for idle work and
// the bookmark file without asking for a render.
@(private)
preview_request :: proc(app: ^App_State, p: ^platform.Platform) {
	pv := &app.preview
	mb := pv.mailbox
	busy := pv.playing || pv.scrubbing
	wanted := thumbs_wanted(app, p)
	thumbs_changed := !slice.equal(wanted, pv.sent_thumbs[:])
	if busy != pv.sent_busy || pv.bookmark != pv.sent_bookmark || thumbs_changed {
		sync.mutex_lock(&mb.mutex)
		mb.busy = busy
		if pv.bookmark != pv.sent_bookmark {
			mb.bookmark = pv.bookmark
			mb.bookmark_seq += 1
		}
		if thumbs_changed {
			table_copy(&mb.thumb_wanted, wanted)
			mb.thumb_wanted_seq += 1
		}
		sync.cond_signal(&mb.cond)
		sync.mutex_unlock(&mb.mutex)
		pv.sent_busy = busy
		pv.sent_bookmark = pv.bookmark
		table_copy(&pv.sent_thumbs, wanted)
	}

	scale: f32 = 1
	if pv.timeline.width > 0 {
		aw, ah := preview_video_area(app, p)
		fit := min(aw / f32(pv.timeline.width), ah / f32(pv.timeline.height))
		// Quantized, so a window drag doesn't rebuild the renderer every pixel.
		scale = clamp(math.ceil(fit * 32) / 32, 1.0 / 32, 2)
	}
	if pv.asked_frame == pv.frame && pv.asked_scale == scale && pv.reload_gen == pv.asked_reload {
		return
	}
	sync.mutex_lock(&mb.mutex)
	mb.request = {frame = pv.frame, scale = scale, reload = pv.reload_gen, reload_media = pv.reload_media, asked = time.tick_now()}
	mb.request_seq += 1
	sync.cond_signal(&mb.cond)
	sync.mutex_unlock(&mb.mutex)
	pv.asked_frame = pv.frame
	pv.asked_scale = scale
	pv.asked_reload = pv.reload_gen
	pv.reload_media = false
}

// The area above the transport (left of the media panel).
@(private)
preview_video_area :: proc(app: ^App_State, p: ^platform.Platform) -> (w, h: f32) {
	pv := &app.preview
	dpi := p.dpi_scale
	h = f32(p.height) - (transport_height(app) + STATUS_HEIGHT) * dpi
	if pv.show_diagnostics {
		h -= DIAGNOSTICS_HEIGHT * dpi
	}
	w = f32(p.width)
	if pv.show_media {
		w -= media_width(p)
	}
	return max(w, 16), max(h, 16)
}

// The media panel's width in pixels: MEDIA_WIDTH, at most 45% of the window.
@(private)
media_width :: proc(p: ^platform.Platform) -> f32 {
	return min(MEDIA_WIDTH * p.dpi_scale, f32(p.width) * 0.45)
}

// ---- views ---------------------------------------------------------------------------

@(private)
preview_global_actions :: proc(app: ^App_State, s: ^ui.State, p: ^platform.Platform) {
	pv := &app.preview
	c := &app.commands
	preview_keys(app, p)
	if ui.action_pressed(s, .Cancel) {
		// Escape closes the panels first, then leaves fullscreen, then the window.
		switch {
		case pv.show_diagnostics:
			command_push(c, .Diagnostics_Toggle)
		case pv.show_media:
			command_push(c, .Media_Toggle)
		case pv.fullscreen:
			command_push(c, .Fullscreen_Toggle)
		case:
			command_push(c, .Quit)
		}
	}
}

COLOR_TEXT_DIM :: [4]u8{150, 158, 172, 255}
COLOR_ERROR :: [4]u8{232, 92, 92, 255}
COLOR_WARNING :: [4]u8{230, 180, 80, 255}
COLOR_PLAYHEAD :: [4]u8{250, 250, 250, 255}
COLOR_HOVER :: [4]u8{250, 250, 250, 110}
COLOR_BOOKMARK :: [4]u8{255, 196, 64, 255}
COLOR_TRACK :: [4]u8{30, 33, 41, 255}
// Scene segments and audio lanes cycle through these.
SCENE_COLORS := [?][4]u8{{58, 96, 160, 255}, {92, 70, 150, 255}, {48, 120, 110, 255}, {140, 90, 60, 255}, {120, 60, 100, 255}}

@(private)
preview_views :: proc(app: ^App_State, s: ^ui.State, p: ^platform.Platform) {
	pv := &app.preview
	c := &app.commands
	dpi := p.dpi_scale
	video_w, video_h := preview_video_area(app, p)

	ui.set_next_pref_width(s, ui.fill())
	ui.set_next_pref_height(s, ui.fill())
	ui.column(s, "preview")
	defer ui.pop_parent(s)

	ui.set_next_pref_width(s, ui.fill())
	ui.set_next_pref_height(s, ui.px(video_h))
	ui.set_next_child_layout_axis(s, .X)
	top := ui.build_box(s, {}, "###top")
	ui.push_parent(s, top)

	// The video, letterboxed; a click toggles playback.
	ui.set_next_pref_width(s, ui.px(video_w))
	ui.set_next_pref_height(s, ui.px(video_h))
	ui.set_next_bg_color(s, {12, 13, 17, 255})
	ui.set_next_corner_radius(s, 0)
	// No background: paf's box drawing paints the image before the background.
	video := ui.build_box(s, {.Clickable, .Draw_Image}, "###video")
	video.image = &pv.video_image if render.image_loaded(&pv.video_image) else nil
	if ui.clicked(ui.signal_from_box(s, video)) {
		command_push(c, .Playback_Toggle)
	}
	if pv.loading || !render.image_loaded(&pv.video_image) {
		// What the worker is doing until the first frame is on screen (and
		// over the last frame during a reload).
		label := "Rendering the first frame…"
		if pv.loading {
			phase := "running the script"
			switch pv.load_phase {
			case .Script:
			case .Media:
				phase = fmt.tprintf("loading media (%d files)", pv.load_files)
			case .Timeline:
				phase = "resolving the timeline"
			}
			label = fmt.tprintf("Loading %s: %s · %.1f s", filepath.base(pv.script_path), phase, pv.load_seconds)
		}
		ui.push_parent(s, video)
		ui.set_next_fixed_x(s, 12 * dpi)
		ui.set_next_fixed_y(s, 12 * dpi if render.image_loaded(&pv.video_image) else video_h * 0.5 - 16 * dpi)
		ui.set_next_bg_color(s, {30, 34, 44, 235})
		ui.set_next_text_color(s, {225, 230, 240, 255})
		ui.set_next_pref_width(s, ui.text_content(12 * dpi))
		ui.set_next_pref_height(s, ui.text_content(10 * dpi))
		ui.build_box(s, {.Draw_Background, .Draw_Text}, fmt.tprintf("%s###loading", label))
		ui.pop_parent(s)
	}
	if pv.reload_error != "" {
		ui.push_parent(s, video)
		first_line := pv.reload_error
		if i := strings.index_byte(first_line, '\n'); i >= 0 {
			first_line = first_line[:i]
		}
		ui.set_next_fixed_x(s, 12 * dpi)
		ui.set_next_fixed_y(s, 12 * dpi)
		ui.set_next_bg_color(s, {70, 24, 28, 235})
		ui.set_next_text_color(s, {255, 220, 220, 255})
		ui.set_next_pref_width(s, ui.text_content(12 * dpi))
		ui.set_next_pref_height(s, ui.text_content(10 * dpi))
		ui.build_box(s, {.Draw_Background, .Draw_Text}, fmt.tprintf("reload failed: %s###reload_error", first_line))
		ui.pop_parent(s)
	}
	if pv.show_media {
		media_view(app, s, dpi, media_width(p), video_h)
	}
	ui.pop_parent(s)

	transport_view(app, s, dpi)
	status_view(app, s, dpi)
	if pv.show_diagnostics {
		diagnostics_view(app, s, dpi)
	}
}

// The timeline across the full width (unless collapsed), the controls
// below it.
@(private)
transport_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32) {
	pv := &app.preview
	c := &app.commands
	ui.set_next_pref_width(s, ui.fill())
	ui.set_next_pref_height(s, ui.px(transport_height(app) * dpi))
	ui.set_next_bg_color(s, s.theme.background)
	ui.set_next_child_layout_axis(s, .Y)
	ui.set_next_corner_radius(s, 0)
	bar := ui.build_box(s, {.Draw_Background}, "###transport")
	ui.push_parent(s, bar)
	defer ui.pop_parent(s)
	pad := ui.px(TRACK_PAD * dpi)

	if !pv.timeline_collapsed {
		ui.set_next_pref_width(s, ui.fill())
		ui.set_next_pref_height(s, ui.px(timeline_height(app) * dpi))
		ui.set_next_child_layout_axis(s, .X)
		timeline_row := ui.build_box(s, {}, "###timeline_row")
		ui.push_parent(s, timeline_row)
		ui.spacer(s, pad)
		timeline_view(app, s, dpi)
		ui.spacer(s, pad)
		ui.pop_parent(s)
	}

	ui.set_next_pref_width(s, ui.fill())
	ui.set_next_pref_height(s, ui.px(CONTROLS_HEIGHT * dpi))
	ui.set_next_child_layout_axis(s, .X)
	controls := ui.build_box(s, {}, "###controls")
	ui.push_parent(s, controls)
	defer ui.pop_parent(s)

	button_h := (CONTROLS_HEIGHT - 10) * dpi
	button :: proc(s: ^ui.State, text: string, width, h, dpi: f32, on := false) -> bool {
		ui.set_next_fixed_y(s, (CONTROLS_HEIGHT * dpi - h) * 0.5 - 2 * dpi)
		ui.set_next_pref_width(s, ui.px(width * dpi))
		ui.set_next_pref_height(s, ui.px(h))
		if on {
			ui.set_next_bg_color(s, s.theme.active)
		}
		return ui.clicked(ui.button(s, text))
	}
	gap :: proc(s: ^ui.State, dpi: f32) {ui.spacer(s, ui.px(4 * dpi))}
	// A narrow window drops the buttons that have keys (I, R) and the scene
	// from the time.
	narrow := f32(s.p.width) / dpi < 1000

	ui.spacer(s, pad)
	if button(s, "Pause###play" if pv.playing else "Play###play", 72, button_h, dpi) {
		command_push(c, .Playback_Toggle)
	}
	ui.spacer(s, pad)
	ui.set_next_fixed_y(s, (CONTROLS_HEIGHT * dpi - button_h) * 0.5 - 2 * dpi)
	ui.set_next_pref_width(s, ui.text_content(8 * dpi, 0))
	ui.set_next_pref_height(s, ui.px(button_h))
	clock := fmt.tprintf("%s · f %d", clock_label(app, pv.frame), pv.frame) if narrow else time_label(app, pv.frame)
	ui.build_box(s, {.Draw_Text}, fmt.tprintf("%s###time", clock))
	ui.spacer(s, ui.fill())

	if button(s, "-###zoom_out", 28, button_h, dpi) {
		command_push(c, .Timeline_Zoom, {scalar = 1 / 1.5, count = pv.frame})
	}
	if button(s, fmt.tprintf("%d%%###zoom_fit", int(math.round(pv.zoom * 100))), 56, button_h, dpi) {
		command_push(c, .Timeline_Fit)
	}
	if button(s, "+###zoom_in", 28, button_h, dpi) {
		command_push(c, .Timeline_Zoom, {scalar = 1.5, count = pv.frame})
	}
	ui.spacer(s, pad)
	mark := "Mark###bookmark" if pv.bookmark < 0 || narrow else fmt.tprintf("Mark %s###bookmark", clock_label(app, pv.bookmark))
	if button(s, mark, 64 if pv.bookmark < 0 || narrow else 118, button_h, dpi, pv.bookmark >= 0) {
		command_push(c, .Bookmark_Toggle)
	}
	gap(s, dpi)
	if button(s, "Loop###loop", 56, button_h, dpi, pv.loop) {
		command_push(c, .Loop_Toggle)
	}
	gap(s, dpi)
	if button(s, "Muted###mute" if pv.muted else "Sound###mute", 64, button_h, dpi, pv.muted) {
		command_push(c, .Mute_Toggle)
	}
	gap(s, dpi)
	slider_h := 10 * dpi
	ui.set_next_fixed_y(s, (CONTROLS_HEIGHT * dpi - slider_h) * 0.5 - 2 * dpi)
	ui.set_next_pref_width(s, ui.px(90 * dpi))
	ui.set_next_pref_height(s, ui.px(slider_h))
	ui.set_next_corner_radius(s, 0)
	shown_volume: f32 = 0 if pv.muted else pv.volume
	if next, changed, _ := ui.slider_value(s, "###volume", shown_volume, 0, 1); changed {
		command_push(c, .Volume_Set, {scalar = f64(next)})
	}
	ui.spacer(s, pad)
	if !narrow {
		if button(s, "Media###media", 64, button_h, dpi, pv.show_media) {
			command_push(c, .Media_Toggle)
		}
		gap(s, dpi)
		if button(s, "Reload###reload", 72, button_h, dpi) {
			command_push(c, .Script_Reload, {flag = true})
		}
		ui.spacer(s, pad)
	}
}

// "01:03.20"
@(private)
clock_label :: proc(app: ^App_State, f: int) -> string {
	secs := f32(f) / f32(preview_fps(app))
	return fmt.tprintf("%02d:%05.2f", int(secs) / 60, math.mod(secs, 60))
}

// "Scene@1.25s · 00:03.20 · f 96/900"
@(private)
time_label :: proc(app: ^App_State, f: int) -> string {
	fps := f32(preview_fps(app))
	total := preview_duration(app)
	scene := ""
	for sc in app.preview.timeline.scenes {
		if f >= sc.start_frame && f < sc.end_frame {
			scene = fmt.tprintf("%s@%.2fs · ", sc.name, f32(f - sc.start_frame) / fps)
		}
	}
	return fmt.tprintf("%s%s · f %d/%d", scene, clock_label(app, f), f, total)
}

@(private)
problem_counts :: proc(pv: ^Preview_State) -> (errors, warnings: int) {
	for row in pv.problems.rows {
		switch row.severity {
		case .Error:
			errors += 1
		case .Warning:
			warnings += 1
		case .Info:
		}
	}
	return
}

@(private)
status_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32) {
	pv := &app.preview
	// Problems since the load, not per frame: the line holds still while
	// frames with and without findings alternate.
	errors, warnings := problem_counts(pv)
	problems := "no problems"
	if errors + warnings > 0 {
		problems = fmt.tprintf("%d errors, %d warnings", errors, warnings)
	}
	hover := ""
	if pv.hover_valid {
		hover = fmt.tprintf(" · hover %s", time_label(app, pv.hover_frame))
	}
	ui.set_next_pref_width(s, ui.fill())
	ui.set_next_pref_height(s, ui.px(STATUS_HEIGHT * dpi))
	ui.set_next_bg_color(s, {18, 19, 24, 255})
	ui.set_next_text_color(s, COLOR_ERROR if errors > 0 else (COLOR_WARNING if warnings > 0 else COLOR_TEXT_DIM))
	ui.set_next_font_size(s, 13 * dpi)
	ui.set_next_corner_radius(s, 0)
	work := ""
	switch {
	case pv.loading:
		work = fmt.tprintf(" · loading %.1f s…", pv.load_seconds)
	case pv.rendering || pv.shown_frame != pv.frame:
		work = " · rendering…"
	}
	// The preview's resolution against the video's, so a scaled preview shows.
	size := ""
	if pv.timeline.width > 0 && pv.shown_size.x > 0 {
		size = fmt.tprintf(" · %d×%d (%d%% of %d×%d)", pv.shown_size.x, pv.shown_size.y, int(math.round(f64(pv.shown_size.x) * 100 / f64(pv.timeline.width))), pv.timeline.width, pv.timeline.height)
	}
	text := fmt.tprintf(
		"%s%s · %.2f ms/frame, latency %.1f ms, %.0f fps%s · %s%s%s%s%s###status",
		pv.device_name,
		size,
		pv.render_ms,
		pv.latency_ms,
		pv.worker_fps,
		work,
		problems,
		" · loop" if pv.loop else "",
		" · muted" if pv.muted else fmt.tprintf(" · volume %d%%", int(math.round(pv.volume * 100))),
		" · no audio device" if pv.audio_stream == nil else "",
		hover,
	)
	b := ui.build_box(s, {.Clickable, .Draw_Background, .Draw_Text, .Draw_Hot_Effects}, text)
	if ui.clicked(ui.signal_from_box(s, b)) {
		command_push(&app.commands, .Diagnostics_Toggle)
	}
}

// Problems since the last load, grouped by key, with the frames they were
// seen in; a click goes to the first.
@(private)
diagnostics_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32) {
	pv := &app.preview
	ui.set_next_pref_width(s, ui.fill())
	ui.set_next_pref_height(s, ui.px(DIAGNOSTICS_HEIGHT * dpi))
	ui.scroll_list_begin(s, "###diagnostics")
	defer ui.scroll_list_end(s)
	line :: proc(s: ^ui.State, dpi: f32, color: [4]u8, text: string, clickable := false) -> bool {
		ui.set_next_pref_width(s, ui.fill())
		ui.set_next_pref_height(s, ui.px(20 * dpi))
		ui.set_next_text_color(s, color)
		ui.set_next_font_size(s, 13 * dpi)
		if !clickable {
			ui.build_box(s, {.Draw_Text}, text)
			return false
		}
		ui.set_next_bg_color(s, {0, 0, 0, 0})
		b := ui.build_box(s, {.Clickable, .Draw_Text, .Draw_Background, .Draw_Hot_Effects}, text)
		return ui.clicked(ui.signal_from_box(s, b))
	}
	if pv.reload_error != "" {
		for l, i in strings.split_lines(pv.reload_error, context.temp_allocator) {
			line(s, dpi, COLOR_ERROR, fmt.tprintf("%s###reload%d", l, i))
		}
	}
	if len(pv.problems.rows) == 0 && pv.reload_error == "" {
		line(s, dpi, COLOR_TEXT_DIM, "No problems at load or in the frames shown since.###none")
	}
	text := pv.problems.text[:]
	for d, i in pv.problems.rows {
		scene := text_of(text, d.scene)
		where_ := scene if scene != "" else "video"
		color := COLOR_ERROR if d.severity == .Error else (COLOR_WARNING if d.severity == .Warning else COLOR_TEXT_DIM)
		if d.first == LOAD_FRAME {
			line(s, dpi, color, fmt.tprintf("%s [load] %s###diag%d", severity_name(d.severity), text_of(text, d.message), i))
			continue
		}
		frames := fmt.tprintf("f %d", d.first) if d.first == d.last else fmt.tprintf("f %d–%d", d.first, d.last)
		label := fmt.tprintf("%s [%s] %s (%s, %s)###diag%d", severity_name(d.severity), where_, text_of(text, d.message), frames, clock_label(app, d.first), i)
		if line(s, dpi, color, label, true) {
			command_push(&app.commands, .Frame_Set, {count = d.first})
		}
	}
}
