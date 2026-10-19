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
// state the clock owns, as paf's source update is. The views (the video,
// the timeline, Watch views) are tabs in a workspace of panels
// (preview_workspace.odin) above the transport controls and the status
// line.

Preview_State :: struct {
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
	// The marks a person made for the agent (time order) and the pending in
	// point (-1: none); the script's first load brings the saved ones.
	// `marks_changed`: to be written (by the worker).
	marks:              [dynamic]Mark,
	mark_in:            int,
	marks_unread:       bool,
	marks_changed:      bool,
	// The timeline view: 1 = the whole video; the frame at the left edge;
	// the playhead frame the view last followed; oasic's motion tracks and
	// cursor anchor for logarithmic zoom and pan smoothing.
	zoom:               f64,
	view_first:         f64,
	zoom_track:         ui.Track,
	first_track:        ui.Track,
	anchor_frame:       f64,
	anchor_ratio:       f64,
	anchor_active:      bool,
	detached:           bool,
	followed_frame:     int,
	timeline_collapsed: bool,
	// The timeline groups open (their paths' hashes: they stay open across
	// reloads) and the smooth scroll register of the rows below the scenes.
	rows_open:          [dynamic]u64,
	rows_scroll:        int,
	rows_scroll_reg:    ui.Scroll,
	// The video's 2D camera (oasic's Space_View): zoom (1 = fit), offset in
	// video pixels from the centre, and its motion tracks and cursor anchor.
	video_zoom:         f64,
	video_pan:          [2]f64,
	video_zoom_track:   ui.Track,
	video_pan_tracks:   [2]ui.Track,
	video_anchor_pt:    [2]f64,
	video_anchor_at:    [2]f64,
	video_anchor_active: bool,
	video_drag_moved:   bool,
	// The press on the timeline began on a group's name (no scrubbing).
	press_on_name:      bool,
	// Points the timeline's rows below the scenes get in its panel, and
	// how it lies there (from the last layout).
	rows_room:          f32,
	timeline_axis:      Time_Axis,
	// The panels and their views, laid out each window frame at `dpi`.
	workspace:          Workspace,
	// The lister's draft filter, selection and scroll (presentation).
	lister:             Lister_View,
	dpi:                f32,
	// A tab being dragged (gesture state, not a command): its view, where
	// the press began and whether it has moved far enough to be a drag.
	drag_view:          View_Id,
	drag_start:         [2]f32,
	drag_active:        bool,
	fullscreen:         bool,
	// --bare: the video alone on the whole window (bare_area, the only view
	// shown), played once; the end of the video or Escape closes the window.
	bare:               bool,
	bare_area:          Workspace_Rect,
	quit:               bool,
	// File_Dialog asked for the open-file dialog (the loop opens it).
	file_dialog:        bool,
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
	seen_watch:         u64,
	seen_waves:         u64,
	seen_media:         u64,
	seen_thumbs:        u64,
	// The bands rows' sources drawn this window frame (asked of the worker
	// when they change), the last asked, and the textures it made.
	bands_shown:        [dynamic]i32,
	sent_bands:         [dynamic]i32,
	seen_bands:         u64,
	band_textures:      [dynamic]Band_Texture,
	timeline:           Preview_Timeline,
	shown_frame:        int,
	shown_size:         [2]u32,
	render_ms:          f64,
	latency_ms:         f64,
	// Frames published per second, counted over the last second.
	worker_fps:         f64,
	// The audio position last heard and the seconds since it last moved
	// (preview_playback_advance runs the clock on between audio blocks).
	heard:              f64,
	since_heard:        f64,
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
	watch:              Watch_Table,
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
BARE_BG :: [4]f32{0, 0, 0, 1}
CONTROLS_HEIGHT :: 40
STATUS_HEIGHT :: 26
// Points a Watch opened beside the video takes (at most 45% of it).
WATCH_WIDTH :: 360
VOLUME_STEP :: 0.1

// Preview: opens the window and runs it until it closes. The start
// spec resolves against the script the load row loaded (declarations only,
// no rendering).
preview_open :: proc(app: ^App_State, regs: Command_Regs) -> Error {
	pv := &app.preview
	pv.exit_after = regs.count
	pv.playing = .Paused not_in regs.flags
	pv.loop = .No_Loop not_in regs.flags
	pv.muted = .Mute in regs.flags
	pv.fullscreen = .Fullscreen in regs.flags
	if .Bare in regs.flags {
		pv.bare, pv.loop = true, false
	}
	if regs.spec != "" {
		tl, err := om.resolve_timeline(&app.script.video, &app.media, context.temp_allocator)
		if err != nil {
			// The script was loaded without its media (the worker loads it);
			// a timeline that needs it (audio lengths) loads it here.
			if os.exists(app.media_dir) {
				om.media_load_dir(&app.media, app.media_dir, app.pool)
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
	pv.media_dir = strings.clone(app.media_dir)
	return preview_run(app, capture = regs.path, drive = regs.args)
}

// The window loop. Never waits on Lua, the render worker or a fence: it
// samples the newest frame the worker published. For measurements,
// `capture` a PNG of the last window frame and `drive` scripted input
// (`preview_drive`), "" for none.
@(private)
preview_run :: proc(app: ^App_State, capture, drive: string) -> Error {
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
	pv.mark_in = -1
	pv.marks_unread = true
	pv.zoom = 1
	pv.zoom_track.target = 1
	pv.video_zoom = 1
	pv.video_zoom_track.target = 1
	pv.rows_room = ROWS_AREA_MAX
	workspace_init(&pv.workspace)
	defer preview_state_destroy(pv)
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
		audio.sdl_stream = nil // the playhead stops asking the stream
		audio_close(pv.audio_stream)
		mailbox_destroy(mb)
		audio_shared_destroy(audio)
		free(worker)
		free(mb)
		free(audio)
		pv.mailbox, pv.worker, pv.audio, pv.audio_stream = nil, nil, nil, nil
	}

	// The opening state, through the same commands as the keys (the volume
	// first: setting it unmutes), before the first window frame.
	command_push(&app.commands, .Volume_Set, {scalar = 1})
	command_push(&app.commands, .Frame_Set, {count = pv.start_frame})
	command_push(&app.commands, .Playback_Set, {flag = pv.playing})
	command_push(&app.commands, .Loop_Set, {flag = pv.loop})
	command_push(&app.commands, .Mute_Set, {flag = pv.muted})
	dispatch(app)

	// Each window frame: what the worker published and the clock, then the
	// frame is built while input, widgets and the file watch push rows; once
	// it is presented, its rows are applied in one dispatch, what they ask of
	// the window happens, and the worker is asked for the frame they lead
	// to. Applying after the present keeps a script switch from releasing
	// textures the frame still draws.
	frames := 0
	last_audio_log := 0
	fullscreen := false
	if pv.bare {
		platform.set_cursor_visible(false)
	}
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

		preview_playback_advance(app, dt)
		preview_take_published(app, &r, now)
		preview_motion_advance(app, f32(dt))
		preview_view_follow(app)
		preview_layout(app, &p)

		render.begin_frame(&r, BARE_BG if pv.bare else PREVIEW_BG)
		ui.build_begin(&s)
		ui.modal_input_set(&s, pv.workspace.lister.panel != 0)
		preview_input(app, &s)
		if drive != "" {
			preview_drive(app, &s, drive, frames)
		}
		preview_watch_files(app, now)
		preview_views(app, &s, &p)
		ui.build_end(&s)
		built := time.tick_since(tick_began)
		if capture != "" && pv.exit_after > 0 && frames >= pv.exit_after {
			if pixels, ok := render.end_frame_capture(&r); ok {
				vg.write_png(capture, pixels, r.fb_w, r.fb_h)
				delete(pixels)
				fmt.eprintln("preview: captured", capture)
			}
		} else {
			render.end_frame(&r)
		}

		presented := time.tick_now()
		preview_frame_apply(app)
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
		preview_request(app, &p)
		append(&pv.ui_ms, f32(time.duration_milliseconds(built + time.tick_since(presented))))
		append(&pv.interval_ms, p.frame_time * 1000)
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
		"preview: %d frames, first frame at %.2f s; UI work median %.2f / p95 %.2f / max %.2f ms (%d over budget); interval median %.2f / p95 %.2f / max %.2f ms (%d over budget); last video render %.2f ms, latency %.2f ms, %.0f video fps on %s; frame %d shown %d; %d thumbnails, %d lanes, %d media, %d problems%s%s",
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
		pv.worker_fps,
		pv.device_name,
		pv.frame,
		pv.shown_frame,
		len(pv.thumbs),
		len(pv.waves.lanes),
		len(pv.media.rows),
		pv.watch.sections[.Problems].count,
		", rendering" if pv.rendering else "",
		fmt.tprintf(", reload error: %s", pv.reload_error) if pv.reload_error != "" else "",
	)
}

// ONIMITE_PREVIEW_DRIVE: input for repeatable measurements, as the rows the
// widgets would push. "scrub" sweeps the playhead back and forth over the
// whole video as a drag, "slowscrub" two frames per window frame;
// "zoom" zooms in and out around the playhead; "pause" pauses first (so
// thumbnails render); "mark" toggles the bookmark at frame 42; "marks"
// marks frames 30..90 and 120 and shows them in the Watch; "reload"
// reloads at window frame 60; "lanes" shows every audio lane; "seek" jumps
// to frame 130, 75 and 340, then back to the start frame (40 window frames
// apart; feedback buffers' checkpoints); "fullscreen" toggles fullscreen
// every 60 window frames, from frame 30. The workspace: "watch" opens the
// Watch on its cues (window frame 2), "media" on the media (as I does),
// "split" splits the video's panel to
// the right (10), "move" moves the timeline into the empty panel (20),
// "drag" drops the timeline's tab on the left edge of the video's panel
// (30), "pick" clicks the Watch's third row (40), "next" goes to the next
// warning or error (45), "close" closes the Watch (50), "hover" moves the
// mouse down and up the Watch's rows (from 10). The lister, as
// keys and typing reach it (`preview_drive_lister`): "goto" and "openview".
@(private)
preview_drive :: proc(app: ^App_State, s: ^ui.State, drive: string, frames: int) {
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
	if frames % 60 == 30 && strings.contains(drive, "fullscreen") {
		command_push(c, .Fullscreen_Toggle, {})
	}
	preview_drive_workspace(app, drive, frames)
	preview_drive_lister(app, s, drive, frames)
	if frames >= 10 && strings.contains(drive, "hover") {
		// Down and up the Watch's rows, a row's height every two window
		// frames, as the mouse's motion reaches the widgets.
		ws := &app.preview.workspace
		if v := workspace_view(ws, workspace_find(ws, .Watch)); v != nil {
			r := ws.areas[int(v.panel) - 1].content
			k := (frames / 2) % 40
			y := r.y + r.height * (f32(k if k < 20 else 40 - k) + 0.5) / 20
			input := &s.p.input
			input.mouse_prev = input.mouse
			input.mouse = {r.x + r.width / 3, y}
			input.mouse_delta = input.mouse - input.mouse_prev
			input.user_seen = true
		}
	}
	if frames == 90 && strings.contains(drive, "lanes") {
		for it in app.preview.waves.items {
			if it.children > 0 {
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
	if strings.contains(drive, "marks") {
		// a range from frame 30 to 90 and a moment at 120, then the Watch
		// on the marks
		switch frames {
		case 20:
			command_push(c, .Frame_Set, {count = 30})
		case 22:
			command_push(c, .Mark_In)
		case 24:
			command_push(c, .Frame_Set, {count = 90})
		case 26:
			command_push(c, .Mark_Out)
		case 28:
			command_push(c, .Frame_Set, {count = 120})
		case 30:
			command_push(c, .Mark_Point)
		case 32:
			command_push(c, .Watch_Show, {section = .Marks})
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

// The drive's workspace steps: what clicks, tabs dragged and dropped push.
@(private = "file")
preview_drive_workspace :: proc(app: ^App_State, drive: string, frames: int) {
	c := &app.commands
	ws := &app.preview.workspace
	video := workspace_view(ws, workspace_find(ws, .Video))
	timeline := workspace_find(ws, .Timeline)
	if frames == 2 && strings.contains(drive, "watch") {
		command_push(c, .Watch_Show, {section = .Cues})
	}
	if frames == 2 && strings.contains(drive, "media") {
		command_push(c, .Watch_Show, {section = .Media})
	}
	if frames == 10 && strings.contains(drive, "split") && video != nil {
		command_push(c, .Panel_Split, {panel = video.panel, direction = .Right})
	}
	if frames == 20 && strings.contains(drive, "move") {
		for p, i in ws.panels {
			if p.live && p.children[0] == 0 && p.first == 0 {
				command_push(c, .View_Move, {view = timeline, panel = Panel_Id(i + 1)})
			}
		}
	}
	if frames == 30 && strings.contains(drive, "drag") && video != nil {
		if row, ok := workspace_drop_command(ws, timeline, {kind = .Panel_Split, panel = video.panel, direction = .Left}); ok {
			command_push(c, row.kind, row.regs)
		}
	}
	if frames == 40 && strings.contains(drive, "pick") {
		if v := workspace_view(ws, workspace_find(ws, .Watch)); v != nil {
			g := app.preview.watch.sections[v.section]
			if g.count > 0 {
				watch_row_click(app, app.preview.watch.rows[g.first + min(2, g.count - 1)])
			}
		}
	}
	if frames == 45 && strings.contains(drive, "next") {
		command_push(c, .Problem_Step, {count = 1})
	}
	if frames == 50 && strings.contains(drive, "close") {
		command_push(c, .View_Close, {view = workspace_find(ws, .Watch)})
	}
}

// The drive's lister steps, as Ctrl+P, the + and typed keys reach it:
// "goto" opens it on the places to go (window frame 60), types its filter
// ("goto=QUERY", default "scene"; 64), moves the selection down (70) and
// picks with Enter (80); "openview" opens it on the views of the video's
// panel (60), types "cues" (64) and picks with Enter (80).
@(private = "file")
preview_drive_lister :: proc(app: ^App_State, s: ^ui.State, drive: string, frames: int) {
	c := &app.commands
	ws := &app.preview.workspace
	go_to := strings.contains(drive, "goto")
	if !go_to && !strings.contains(drive, "openview") {
		return
	}
	query := "cues"
	if go_to {
		query = "scene"
		if i := strings.index(drive, "goto="); i >= 0 {
			query = drive[i + len("goto="):]
			if end := strings.index_any(query, " ,"); end >= 0 {
				query = query[:end]
			}
		}
	}
	key :: proc(s: ^ui.State, k: platform.Key) {
		append(&s.actions.rows, ui.Action_Row{kind = .Key, key = k})
	}
	switch frames {
	case 60:
		if go_to {
			command_push(c, .Lister_Open, {lister = .Go_To})
		} else if v := workspace_view(ws, workspace_find(ws, .Video)); v != nil {
			command_push(c, .Lister_Open, {panel = v.panel, lister = .Panel})
		}
	case 64:
		for r in query {
			append(&s.actions.rows, ui.Action_Row{kind = .Text, text = r})
		}
	case 70:
		if go_to {
			key(s, .Down)
		}
	case 80:
		key(s, .Enter)
	}
}

@(private)
preview_state_destroy :: proc(pv: ^Preview_State) {
	delete(pv.script_path)
	delete(pv.media_dir)
	delete(pv.reload_error)
	delete(pv.device_name)
	watch_table_destroy(&pv.watch)
	workspace_destroy(&pv.workspace)
	delete(pv.lister.query)
	wave_table_destroy(&pv.waves)
	media_table_destroy(&pv.media)
	delete(pv.media_images)
	delete(pv.rows_open)
	delete(pv.marks)
	delete(pv.thumbs)
	delete(pv.sent_thumbs)
	delete(pv.bands_shown)
	delete(pv.sent_bands)
	delete(pv.band_textures)
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
	// a video file loads as a video of itself: its media is the file alone
	if kind, ok := om.media_kind_of(script_path); ok && kind == .Video {
		return script_path
	}
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
	return f64(preview_duration(app)) / max(app.preview.zoom, 1)
}

@(private)
zoom_max :: proc(app: ^App_State) -> f64 {
	// Down to 4 frames across the view (oasic's TIMELINE_MIN_FRAMES).
	return max(f64(preview_duration(app)) / 4, 1)
}

@(private)
view_clamp :: proc(app: ^App_State) {
	pv := &app.preview
	total := f64(preview_duration(app))
	pv.zoom = clamp(pv.zoom, 1, zoom_max(app))
	pv.view_first = clamp(pv.view_first, 0, max(total - view_frames(app), 0))
	if !pv.zoom_track.active {
		pv.zoom_track.target = pv.zoom
	}
	if !pv.first_track.active {
		pv.first_track.target = pv.view_first
	}
}

@(private = "file")
timeline_cancel_focus :: proc(pv: ^Preview_State) {
	if pv.zoom_track.active && pv.zoom_track.rate == 0 {
		pv.zoom_track.active = false
		pv.zoom_track.target = pv.zoom
	}
	if pv.first_track.active {
		pv.first_track.active = false
		pv.first_track.target = pv.view_first
	}
	pv.anchor_active = false
}

@(private = "file")
video_cancel_focus :: proc(pv: ^Preview_State) {
	if pv.video_zoom_track.active && pv.video_zoom_track.rate == 0 {
		pv.video_zoom_track.active = false
		pv.video_zoom_track.target = pv.video_zoom
	}
	for &t, i in pv.video_pan_tracks {
		if t.active {
			t.active = false
			t.target = pv.video_pan[i]
		}
	}
	pv.video_anchor_active = false
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
		pv.detached = false
		preview_seek(app, regs.count)
	case .Frame_Step:
		pv.playing = false
		pv.detached = false
		preview_seek(app, pv.frame + regs.count)
		preview_sync_audio(app)
	case .Frame_Start:
		pv.detached = false
		preview_seek(app, start_target(app))
	case .Seconds_Step:
		pv.playing = false
		pv.detached = false
		preview_seek(app, pv.frame + int(math.round(regs.scalar * f64(preview_fps(app)))))
		preview_sync_audio(app)
	case .Scene_Step:
		pv.detached = false
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
	case .Mark_In:
		pv.mark_in = -1 if pv.mark_in == pv.frame else pv.frame
	case .Mark_Out:
		from := max(pv.mark_in, 0)
		pv.mark_in = -1
		mark_add(pv, min(from, pv.frame), max(from, pv.frame))
	case .Mark_Point:
		on := -1
		for m, i in pv.marks {
			if m.to < 0 && m.at == pv.frame {
				on = i
			}
		}
		if on >= 0 {
			ordered_remove(&pv.marks, on)
			pv.marks_changed = true
		} else {
			mark_add(pv, pv.frame, -1)
		}
	case .Mark_Delete:
		newest := -1
		for m, i in pv.marks {
			under := m.at == pv.frame if m.to < 0 else m.at <= pv.frame && pv.frame <= m.to
			if under && (newest < 0 || m.n > pv.marks[newest].n) {
				newest = i
			}
		}
		if newest >= 0 {
			ordered_remove(&pv.marks, newest)
			pv.marks_changed = true
		} else {
			pv.mark_in = -1
		}
	case .Timeline_Zoom:
		// Logarithmic zoom pinned to the cursor's fractional position, after
		// oasic's space_zoom_2d: rapid wheel ticks accumulate on zoom_track.target
		// and preview_motion_advance repins view_first every frame.
		visible := view_frames(app)
		if !pv.zoom_track.active {
			pv.zoom_track.target = pv.zoom
		}
		timeline_cancel_focus(pv)
		if regs.flag {
			at := clamp(regs.ratio, 0, 1)
			pv.anchor_ratio = at
			pv.anchor_frame = pv.view_first + at * visible
		} else {
			anchor := f64(regs.count if regs.count >= 0 else pv.frame)
			at := clamp((anchor - pv.view_first) / visible, 0, 1) if visible > 0 else 0
			pv.anchor_ratio = at
			pv.anchor_frame = anchor
		}
		pv.anchor_active = true
		pv.detached = true
		target := clamp(pv.zoom_track.target * regs.scalar, 1, zoom_max(app))
		ui.track_target(&pv.zoom_track, pv.zoom, target, space = .Logarithmic, rate = 18)
	case .Timeline_Fit:
		timeline_cancel_focus(pv)
		pv.detached = false
		ui.track_target(&pv.zoom_track, pv.zoom, 1, duration = 0.25, space = .Logarithmic)
		ui.track_target(&pv.first_track, pv.view_first, 0, duration = 0.25)
		if pv.video_zoom != 1 || pv.video_pan != {} {
			video_cancel_focus(pv)
			ui.track_target(&pv.video_zoom_track, pv.video_zoom, 1, duration = 0.35, space = .Logarithmic)
			ui.track_target(&pv.video_pan_tracks[0], pv.video_pan.x, 0, duration = 0.35)
			ui.track_target(&pv.video_pan_tracks[1], pv.video_pan.y, 0, duration = 0.35)
		}
	case .Timeline_Pan:
		// Middle-drag passes flag = true for direct 1:1 pixel panning; wheel
		// pan eases smoothly across frames (oasic's timeline_display_target).
		pv.detached = true
		total := f64(preview_duration(app))
		limit := max(total - view_frames(app), 0)
		if regs.flag {
			timeline_cancel_focus(pv)
			pv.view_first = clamp(pv.view_first + regs.scalar, 0, limit)
			pv.first_track.target = pv.view_first
		} else {
			base := pv.first_track.target if pv.first_track.active else pv.view_first
			pv.anchor_active = false
			target := clamp(base + regs.scalar, 0, limit)
			ui.track_target(&pv.first_track, pv.view_first, target, duration = 0.18)
		}
	case .Timeline_Follow:
		pv.detached = !regs.flag
		if !pv.detached {
			pv.followed_frame = -1
		}
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
	case .Video_Zoom:
		// 2D canvas wheel zoom around the cursor in the video panel (oasic's
		// space_zoom_2d). Coordinates are relative to the panel centre in
		// normalized panel units.
		if !pv.video_zoom_track.active {
			pv.video_zoom_track.target = pv.video_zoom
		}
		video_cancel_focus(pv)
		z := max(pv.video_zoom, 1e-4)
		at := [2]f64{f64(regs.at_xy.x) - 0.5, f64(regs.at_xy.y) - 0.5}
		pv.video_anchor_at = at
		pv.video_anchor_pt = {(at.x - pv.video_pan.x) / z, (at.y - pv.video_pan.y) / z}
		pv.video_anchor_active = true
		target := clamp(pv.video_zoom_track.target * regs.scalar, 0.25, 32)
		ui.track_target(&pv.video_zoom_track, pv.video_zoom, target, space = .Logarithmic, rate = 18)
		if target == 1 {
			pv.video_anchor_active = false
			ui.track_target(&pv.video_pan_tracks[0], pv.video_pan.x, 0, duration = 0.25)
			ui.track_target(&pv.video_pan_tracks[1], pv.video_pan.y, 0, duration = 0.25)
		}
	case .Video_Pan:
		video_cancel_focus(pv)
		bound := 0.5 * max(pv.video_zoom, 1)
		pv.video_pan.x = clamp(pv.video_pan.x + f64(regs.at_xy.x), -bound, bound)
		pv.video_pan.y = clamp(pv.video_pan.y + f64(regs.at_xy.y), -bound, bound)
		pv.video_pan_tracks[0].target = pv.video_pan.x
		pv.video_pan_tracks[1].target = pv.video_pan.y
	case .Video_Fit:
		video_cancel_focus(pv)
		ui.track_target(&pv.video_zoom_track, pv.video_zoom, 1, duration = 0.35, space = .Logarithmic)
		ui.track_target(&pv.video_pan_tracks[0], pv.video_pan.x, 0, duration = 0.35)
		ui.track_target(&pv.video_pan_tracks[1], pv.video_pan.y, 0, duration = 0.35)
	case .Fullscreen_Toggle:
		pv.fullscreen = !pv.fullscreen
	case .Watch_Show:
		watch_show(app, regs.section)
	case .Watch_Section_Set:
		if v := workspace_view(&pv.workspace, regs.view); v != nil && v.kind == .Watch {
			v.section = regs.section
			v.scroll = 0
			v.scroll_reg = {}
		}
	case .Watch_Scroll:
		if v := workspace_view(&pv.workspace, regs.view); v != nil && v.kind == .Watch {
			v.scroll = clamp(v.scroll + regs.count, 0, max(pv.watch.sections[v.section].count - 1, 0))
			ui.scroll_to(&v.scroll_reg, f64(v.scroll))
		}
	case .Problem_Step:
		pv.detached = false
		preview_seek(app, problem_step_target(app, regs.count))
	case .Cursor_Hover:
		pv.hover_frame = regs.count
		pv.hover_valid = true
	case .Dismiss:
		// Closes the lister, then the Watch, then leaves fullscreen, then
		// the window; the player closes at once.
		ws := &pv.workspace
		c := &app.commands
		switch {
		case pv.bare:
			command_push(c, .Quit)
		case ws.lister.panel != 0:
			command_push(c, .Lister_Close)
		case workspace_find(ws, .Watch) != 0:
			command_push(c, .View_Close, {view = workspace_find(ws, .Watch)})
		case pv.fullscreen:
			command_push(c, .Fullscreen_Toggle)
		case:
			command_push(c, .Quit)
		}
	case .Quit:
		pv.quit = true
	}
}

// The first frame of the scene `steps` scenes after (or before) the one
// at the current frame. Stepping back from inside a scene goes to its start.
@(private)
scene_step_target :: proc(app: ^App_State, steps: int) -> int {
	pv := &app.preview
	scenes := pv.timeline.scenes[:]
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

// Shows the Watch on `section`: the open one, else a new one beside the
// video (WATCH_WIDTH wide), else in the focused panel.
@(private)
watch_show :: proc(app: ^App_State, section: Watch_Section) {
	pv := &app.preview
	ws := &pv.workspace
	id := workspace_find(ws, .Watch)
	if id == 0 {
		if video := workspace_view(ws, workspace_find(ws, .Video)); video != nil {
			ratio: f32 = 0.55
			if int(video.panel) <= len(ws.areas) {
				if width := ws.areas[video.panel - 1].rect.width; width > 0 {
					ratio = clamp(1 - WATCH_WIDTH * pv.dpi / width, 0.55, 0.8)
				}
			}
			id = workspace_open(ws, video.panel, .Watch, .Right, ratio, section = section)
		} else {
			id = workspace_open(ws, ws.focused, .Watch, section = section)
		}
	}
	if v := workspace_view(ws, id); v != nil {
		workspace_select(ws, id)
		v.section = section
		v.scroll = 0
		v.scroll_reg = {}
	}
}

// The frame of the next (`steps` > 0) or previous Watch row with a warning
// or an error after (before) the playhead, wrapping around; the playhead
// when there is none.
@(private)
problem_step_target :: proc(app: ^App_State, steps: int) -> int {
	pv := &app.preview
	near, wrap := -1, -1
	for row in pv.watch.rows {
		if row.status < .Warning || row.frame < 0 {
			continue
		}
		f := row.frame
		if steps > 0 {
			if f > pv.frame && (near < 0 || f < near) {
				near = f
			}
			if wrap < 0 || f < wrap {
				wrap = f
			}
		} else {
			if f < pv.frame && (near < 0 || f > near) {
				near = f
			}
			if wrap < 0 || f > wrap {
				wrap = f
			}
		}
	}
	if near >= 0 {
		return near
	}
	return wrap if wrap >= 0 else pv.frame
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

// Applies the rows the window frame pushed. A hover and a scrub last one
// window frame: they hold until the next frame's rows renew them.
@(private)
preview_frame_apply :: proc(app: ^App_State) {
	pv := &app.preview
	scrubbed := pv.scrubbing
	pv.hover_valid = false
	pv.scrubbing = false
	dispatch(app)
	if scrubbed && !pv.scrubbing {
		preview_sync_audio(app)
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
	// The new script brings its own bookmark and marks.
	pv.bookmark = -1
	pv.sent_bookmark = -1
	pv.bookmark_unread = true
	clear(&pv.marks)
	pv.mark_in = -1
	pv.marks_unread = true
	pv.marks_changed = false
	pv.zoom = 1
	pv.view_first = 0
	pv.zoom_track = {target = 1}
	pv.first_track = {}
	pv.anchor_active = false
	pv.detached = false
	pv.video_zoom = 1
	pv.video_pan = {}
	pv.video_zoom_track = {target = 1}
	pv.video_pan_tracks = {}
	pv.video_anchor_active = false
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
		clear(&mb.marks)
		mb.marks_seq = 0
		clear(&mb.marks_loaded)
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

// The share of the gap to the heard position the clock closes each window
// frame: small enough to stay smooth, enough to follow the sound within a
// few frames.
@(private = "file")
CLOCK_STEER :: 0.1

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
		// The heard position moves a device block at a time (about 21 ms at
		// 48 kHz). The clock runs on real time instead, steered toward what is
		// being heard (the last heard position plus the time since, at most a
		// block): every window frame gets its own video frame, and the picture
		// stays with the sound. More than two blocks apart (a seek, a loop,
		// playing again) it jumps.
		heard := f64(pos) / om.MIX_RATE
		if heard != pv.heard {
			pv.heard, pv.since_heard = heard, 0
		} else {
			pv.since_heard += dt
		}
		block := f64(pv.audio.device_frames) / om.MIX_RATE if pv.audio.device_frames > 0 else 0.05
		hearing := heard + min(pv.since_heard, block)
		pv.clock += dt
		if off := hearing - pv.clock; abs(off) > 2 * block {
			pv.clock = hearing
		} else {
			pv.clock += off * CLOCK_STEER
		}
		if !playing && pv.clock >= total - 1.5 / fps {
			// The audio stopped at the end (not looping).
			pv.playing = false
			pv.clock = total - 1 / fps
			pv.quit ||= pv.bare
		}
	} else {
		pv.clock += dt
		if pv.clock >= total {
			if pv.loop {
				pv.clock -= total * math.floor(pv.clock / total)
			} else {
				pv.clock = total - 1 / fps
				pv.playing = false
				pv.quit ||= pv.bare
			}
		}
	}
	pv.frame = clamp(int(pv.clock * fps), 0, preview_duration(app) - 1)
}

// Advances the timeline and video camera motion tracks and repins their
// cursor anchors across eased zoom frames (oasic's space_advance /
// presentation_advance).
@(private)
preview_motion_advance :: proc(app: ^App_State, dt: f32) {
	pv := &app.preview
	ui.track_advance(&pv.zoom, &pv.zoom_track, dt)
	ui.track_advance(&pv.view_first, &pv.first_track, dt)
	if pv.anchor_active {
		pv.view_first = pv.anchor_frame - pv.anchor_ratio * view_frames(app)
		if !pv.zoom_track.active {
			pv.anchor_active = false
		}
	}
	view_clamp(app)

	ui.track_advance(&pv.video_zoom, &pv.video_zoom_track, dt)
	ui.track_advance(&pv.video_pan[0], &pv.video_pan_tracks[0], dt)
	ui.track_advance(&pv.video_pan[1], &pv.video_pan_tracks[1], dt)
	if pv.video_anchor_active {
		pv.video_pan = {
			pv.video_anchor_at.x - pv.video_anchor_pt.x * pv.video_zoom,
			pv.video_anchor_at.y - pv.video_anchor_pt.y * pv.video_zoom,
		}
		if !pv.video_zoom_track.active {
			pv.video_anchor_active = false
		}
	}
}

// Keeps the playhead inside the zoomed timeline while following (oasic's
// timeline_follow / series_follow): zooming or panning detaches the view so
// playback doesn't yank it away; seeking or re-engaging Follow reattaches it,
// and when following moves the window, it disarms the pan/zoom tracks so the
// view doesn't lag behind the playhead.
@(private)
preview_view_follow :: proc(app: ^App_State) {
	pv := &app.preview
	if pv.detached || pv.frame == pv.followed_frame {
		return
	}
	pv.followed_frame = pv.frame
	f := f64(pv.frame)
	visible := view_frames(app)
	before := pv.view_first
	if f < pv.view_first {
		pv.view_first = f
	} else if f >= pv.view_first + visible {
		pv.view_first = f - visible + 1 if pv.playing else f
	}
	view_clamp(app)
	if pv.view_first != before {
		timeline_cancel_focus(pv)
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
	marks_loaded := false
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
		preview_timeline_copy(&pv.timeline, &mb.timeline)
		bookmark_loaded = mb.bookmark_loaded
		if pv.marks_unread {
			// the saved marks, read with the script's first load
			table_copy(&pv.marks, mb.marks_loaded[:])
			pv.marks_unread = false
			marks_loaded = true
		}
		timeline_changed = true
	}
	if mb.watch_seq != pv.seen_watch {
		pv.seen_watch = mb.watch_seq
		watch_table_copy(&pv.watch, &mb.watch)
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
	if mb.bands_seq != pv.seen_bands {
		pv.seen_bands = mb.bands_seq
		table_copy(&pv.band_textures, mb.band_textures[:])
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
	bands_changed := !slice.equal(pv.bands_shown[:], pv.sent_bands[:])
	if busy != pv.sent_busy || pv.bookmark != pv.sent_bookmark || pv.marks_changed || thumbs_changed || bands_changed {
		sync.mutex_lock(&mb.mutex)
		mb.busy = busy
		if pv.marks_changed {
			pv.marks_changed = false
			table_copy(&mb.marks, pv.marks[:])
			mb.marks_seq += 1
		}
		if pv.bookmark != pv.sent_bookmark {
			mb.bookmark = pv.bookmark
			mb.bookmark_seq += 1
		}
		if thumbs_changed {
			table_copy(&mb.thumb_wanted, wanted)
			mb.thumb_wanted_seq += 1
		}
		if bands_changed {
			table_copy(&mb.bands_wanted, pv.bands_shown[:])
			mb.bands_wanted_seq += 1
		}
		sync.cond_signal(&mb.cond)
		sync.mutex_unlock(&mb.mutex)
		pv.sent_busy = busy
		pv.sent_bookmark = pv.bookmark
		table_copy(&pv.sent_thumbs, wanted)
		table_copy(&pv.sent_bands, pv.bands_shown[:])
	}

	// The scale that fits the video's panel (kept while it is hidden),
	// multiplied by the video camera's zoom when zoomed in.
	scale := pv.asked_scale if pv.asked_scale > 0 else 1
	if area, shown := view_area(app, .Video); shown && pv.timeline.width > 0 {
		fit := min(max(area.width, 16) / f32(pv.timeline.width), max(area.height, 16) / f32(pv.timeline.height)) * f32(max(pv.video_zoom, 1))
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

// Lays the workspace out above the controls and the status line (a bare
// window is the video alone): the
// timeline's panel, while fitted, at the timeline's natural height. The
// timeline lies along its panel or down it, and its rows get what the
// panel leaves them.
@(private)
preview_layout :: proc(app: ^App_State, p: ^platform.Platform) {
	pv := &app.preview
	pv.dpi = p.dpi_scale
	if pv.bare {
		pv.bare_area = {0, 0, f32(p.width), f32(p.height)}
		return
	}
	natural := [View_Kind]f32{.Video = -1, .Timeline = timeline_height(app) * pv.dpi, .Watch = -1}
	workspace_measure(&pv.workspace, workspace_rect(p), pv.dpi, natural)
	pv.rows_room = ROWS_AREA_MAX
	pv.timeline_axis = TIME_ALONG
	if area, shown := view_area(app, .Timeline); shown {
		ws := &pv.workspace
		vertical := timeline_vertical(ws, workspace_view(ws, workspace_shown(ws, .Timeline)).panel, area)
		pv.timeline_axis = timeline_axis(app, area, pv.dpi, vertical)
		pv.rows_room = timeline_rows_room(pv.timeline_axis, area, pv.dpi)
	}
}

// The window above the controls and the status line, in pixels.
@(private)
workspace_rect :: proc(p: ^platform.Platform) -> Workspace_Rect {
	h := f32(p.height) - (CONTROLS_HEIGHT + STATUS_HEIGHT) * p.dpi_scale
	return {0, 0, f32(p.width), max(h, 0)}
}

// Where the view of `kind` draws, in pixels, when its panel shows it.
@(private)
view_area :: proc(app: ^App_State, kind: View_Kind) -> (area: Workspace_Rect, shown: bool) {
	if app.preview.bare {
		return app.preview.bare_area, kind == .Video
	}
	ws := &app.preview.workspace
	v := workspace_view(ws, workspace_shown(ws, kind))
	if v == nil || int(v.panel) > len(ws.areas) || !ws.areas[v.panel - 1].visible {
		return
	}
	return ws.areas[v.panel - 1].content, true
}

// ---- views ---------------------------------------------------------------------------

// The window's input that no widget takes: the keys' rows, and a script
// dropped on the window or picked in the open-file dialog.
@(private)
preview_input :: proc(app: ^App_State, s: ^ui.State) {
	preview_keys(app, s.actions.rows[:], s.modal_input)
	for &a in s.actions.rows {
		if a.kind == .Drop && !a.consumed && strings.has_suffix(strings.to_lower(a.path, context.temp_allocator), ".lua") {
			a.consumed = true
			command_push(&app.commands, .Script_Open, {path = a.path})
			break
		}
	}
}

COLOR_TEXT_DIM :: [4]u8{150, 158, 172, 255}
COLOR_ERROR :: [4]u8{232, 92, 92, 255}
COLOR_WARNING :: [4]u8{230, 180, 80, 255}
COLOR_PLAYHEAD :: [4]u8{250, 250, 250, 255}
COLOR_HOVER :: [4]u8{250, 250, 250, 110}
COLOR_BOOKMARK :: [4]u8{255, 196, 64, 255}
COLOR_MARK :: [4]u8{96, 200, 255, 255}
COLOR_TRACK :: [4]u8{30, 33, 41, 255}
// Scene segments and audio lanes cycle through these.
SCENE_COLORS := [?][4]u8{{58, 96, 160, 255}, {92, 70, 150, 255}, {48, 120, 110, 255}, {140, 90, 60, 255}, {120, 60, 100, 255}}

// The workspace's panels, then the controls and the status line, and
// the lister over them.
@(private)
preview_views :: proc(app: ^App_State, s: ^ui.State, p: ^platform.Platform) {
	dpi := p.dpi_scale
	ui.set_next_pref_width(s, ui.fill())
	ui.set_next_pref_height(s, ui.fill())
	ui.column(s, "preview")
	defer ui.pop_parent(s)

	if area, _ := view_area(app, .Video); app.preview.bare {
		video_view(app, s, dpi, area)
		return
	}

	// The panels place their boxes in window pixels: this box is at the origin.
	ui.set_next_pref_width(s, ui.fill())
	ui.set_next_pref_height(s, ui.px(workspace_rect(p).height))
	ui.push_parent(s, ui.build_box(s, {}, "###workspace"))
	panels_view(app, s, dpi)
	ui.pop_parent(s)

	controls_view(app, s, dpi)
	status_view(app, s, dpi)
	lister_view(app, s, dpi)
}

@(private = "file")
video_draw :: proc(s: ^ui.State, box: ^ui.Box, data: rawptr) {
	pv := (^Preview_State)(data)
	if !render.image_loaded(&pv.video_image) {
		return
	}
	w := box.rect.max.x - box.rect.min.x
	h := box.rect.max.y - box.rect.min.y
	if w <= 0 || h <= 0 || pv.video_image.width <= 0 || pv.video_image.height <= 0 {
		return
	}
	iw, ih := f32(pv.video_image.width), f32(pv.video_image.height)
	fit := min(w / iw, h / ih)
	z := f32(max(pv.video_zoom, 1e-4))
	dw, dh := iw * fit * z, ih * fit * z
	cx := box.rect.min.x + w * (0.5 + f32(pv.video_pan.x))
	cy := box.rect.min.y + h * (0.5 + f32(pv.video_pan.y))
	render.draw_image_rect(s.r, &pv.video_image, cx - dw * 0.5, cy - dh * 0.5, dw, dh)
}

// The video, letterboxed in `area` with 2D wheel zoom and drag pan; a click
// toggles playback and a double-click fits the camera. Over it, what the
// worker is doing until the first frame shows, and a failed reload.
@(private)
video_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32, area: Workspace_Rect) {
	pv := &app.preview
	c := &app.commands
	video := place_box(s, area, {.Clickable, .Clip}, "###video")
	video.custom_draw = video_draw
	video.custom_draw_data = pv
	sig := ui.signal_from_box(s, video)
	w, h := video.rect.max.x - video.rect.min.x, video.rect.max.y - video.rect.min.y
	if ui.pressed(sig) {
		pv.video_drag_moved = false
	}
	if w > 0 && h > 0 {
		if ui.dragging(sig) && (abs(sig.drag_delta.x) > 3 * dpi || abs(sig.drag_delta.y) > 3 * dpi) {
			pv.video_drag_moved = true
		}
		if (pv.video_drag_moved && ui.dragging(sig)) || ui.middle_dragging(sig) || ui.right_dragging(sig) {
			if sig.drag_motion != {} {
				command_push(c, .Video_Pan, {at_xy = {sig.drag_motion.x / w, sig.drag_motion.y / h}})
			}
		}
		if wheel := sig.zoom if sig.zoom != 0 else sig.scroll; wheel != 0 {
			mouse := platform.mouse_pos(s.p)
			at_xy := [2]f32 {
				clamp((mouse.x - video.rect.min.x) / w, 0, 1),
				clamp((mouse.y - video.rect.min.y) / h, 0, 1),
			}
			command_push(c, .Video_Zoom, {scalar = math.pow(1.25, f64(wheel)), at_xy = at_xy})
		}
	}
	if ui.clicked(sig) && !pv.video_drag_moved {
		command_push(c, .Playback_Toggle)
	}
	if pv.loading || !render.image_loaded(&pv.video_image) {
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
		ui.set_next_fixed_y(s, 12 * dpi if render.image_loaded(&pv.video_image) else area.height * 0.5 - 16 * dpi)
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
}

// The transport controls across the window, under the panels.
@(private)
controls_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32) {
	pv := &app.preview
	c := &app.commands
	ui.set_next_pref_width(s, ui.fill())
	ui.set_next_pref_height(s, ui.px(CONTROLS_HEIGHT * dpi))
	ui.set_next_bg_color(s, s.theme.background)
	ui.set_next_child_layout_axis(s, .X)
	ui.set_next_corner_radius(s, 0)
	controls := ui.build_box(s, {.Draw_Background}, "###controls")
	ui.push_parent(s, controls)
	defer ui.pop_parent(s)
	pad := ui.px(TRACK_PAD * dpi)

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
	// A narrow window drops the buttons that have keys (D, R) and the scene
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

	if !narrow && (pv.zoom > 1.01 || pv.detached) {
		if button(s, "Follow###follow", 60, button_h, dpi, !pv.detached) {
			command_push(c, .Timeline_Follow, {flag = pv.detached})
		}
		gap(s, dpi)
	}
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
		// The Watch opens on the problems, or closes.
		watch := workspace_find(&pv.workspace, .Watch)
		if button(s, "Watch###watch", 64, button_h, dpi, watch != 0) {
			if watch != 0 {
				command_push(c, .View_Close, {view = watch})
			} else {
				command_push(c, .Watch_Show, {section = .Problems})
			}
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
	return frame_clock(f, preview_fps(app))
}

// Frame `f` at `fps` as minutes and seconds: "00:03.20".
frame_clock :: proc(f, fps: int) -> string {
	secs := f32(f) / f32(fps)
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
			scene = fmt.tprintf("%s@%.2fs · ", scene_name(&app.preview.timeline, sc), f32(f - sc.start_frame) / fps)
		}
	}
	return fmt.tprintf("%s%s · f %d/%d", scene, clock_label(app, f), f, total)
}

@(private)
status_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32) {
	pv := &app.preview
	// Problems since the load, not per frame: the line holds still while
	// frames with and without findings alternate.
	errors, warnings := 0, 0
	g := pv.watch.sections[.Problems]
	for row in pv.watch.rows[g.first:][:g.count] {
		errors += int(row.status == .Error)
		warnings += int(row.status == .Warning)
	}
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
		command_push(&app.commands, .Watch_Show, {section = .Problems})
	}
}

// Adds a mark (frames `at` to `to`, -1: a moment) numbered after the
// highest, in time order, to be written.
@(private)
mark_add :: proc(pv: ^Preview_State, at, to: int) {
	n := 0
	for m in pv.marks {
		n = max(n, m.n)
	}
	append(&pv.marks, Mark{n + 1, at, to})
	marks_sort(pv.marks[:])
	pv.marks_changed = true
}
