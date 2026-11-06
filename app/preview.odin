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
import "../animation"
import ui "../ui"
import vg "deps:ovg"
import vgsdl "deps:ovg/sdlgpu"
import odimg "deps:oicut/image"
import sdl "vendor:sdl3"

// The preview window, after paf: platform events and ui widgets publish
// command rows, `dispatch` applies them, and views only read state. Playback,
// the timeline following the playhead and the file watch are updates of
// state the clock owns, as paf's source update is. The views (the video,
// the timeline, Watch views) are tabs in a workspace of panels
// (preview_workspace.odin) above the transport controls and the status
// line.

Preview_State :: struct {
	// Where playback opened: the frame `preview AT` names, else 0.
	start_frame:        int,
	// The script's props for the worker's loads (the app's --props text).
	script_props:       [dynamic]string,
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
	// The timeline's camera as shown: its zoom (1 = the whole video) and the
	// frame at its left edge, following `timeline_camera`, which commands
	// set (camera_follow, as onib's cameras); the playhead frame the view
	// last followed.
	zoom:               f64,
	view_first:         f64,
	timeline_camera:    Timeline_Camera,
	detached:           bool,
	followed_frame:     int,
	timeline_collapsed: bool,
	// The timeline's items open (their keys: their paths' hashes, so they
	// stay open across reloads).
	rows_open:          [dynamic]u64,
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
	// Per view (by View_Id - 1): the list its rows scroll in, which follows
	// the view's scroll, and its filter as typed (preview_list.odin).
	view_lists:         [dynamic]View_List,
	view_filters:       [dynamic]Filter_Field,
	dpi:                f32,
	// A tab being dragged (gesture state, not a command): RAD's drag/drop
	// state and the view dragged.
	drag:               Drag_State,
	drag_view:          View_Id,
	// The window's font size in points (RAD's window font size:
	// Font_Size_Increase, Font_Size_Decrease); the UI's text is sized by it
	// over FONT_SIZE_DEFAULT.
	font_size:          f32,
	// The window's bars' height in pixels, the transport controls' and the
	// status line's (preview_layout: from the window's font, its one
	// computation).
	bar_height:         f32,
	// The panel tree apart from its ratios, and its ratios, last frame
	// (panel_areas_ease).
	panel_shape:        u64,
	panel_ratios:       u64,
	// A splitter is being dragged this frame (RAD's changing panel
	// boundaries): a tab appearing takes its width at once.
	panels_resizing:    bool,
	// Where the dragged tab would drop among a panel's tabs this frame
	// (after `after`, 0: first), the bar's slot (tabs_view).
	drop_slot:          struct {
		panel: Panel_Id,
		after: View_Id,
	},
	fullscreen:         bool,
	// --bare: the video alone on the whole window (bare_area, the only view
	// shown), played once; the end of the video or Escape closes the window.
	bare:               bool,
	bare_area:          Workspace_Rect,
	// --present: bare and fullscreen, waiting at each scene's end (its hold,
	// Preview_Scene) for the presenter. Playing toward the stop `toward`
	// (scene `toward_scene`, once `aimed`: kept, so a clock steered back a
	// frame toward the sound can't land on the stop just left), `holding`
	// there (or looping the scene, Hold.Loop), the held scene's clock run on
	// `hold_time` seconds past it (Hold.Alive; `hold_paused` stops it), and
	// once moved on, the scenes up to `carry_through` still `carry` seconds
	// ahead (the held one leaves from where it was); the screen black while
	// `blackout`.
	present:            bool,
	// --live: bare and fullscreen, playing on past the end for good (the
	// clock runs on, the last frame held: preview_request), `now_start`
	// following the system clock; no input but Control+Q. Otherwise
	// `now_start` is the app's --now.
	live:               bool,
	now_start:          f64,
	aimed:              bool,
	toward:             int,
	toward_scene:       int,
	holding:            bool,
	hold_paused:        bool,
	hold_time:          f64,
	carry:              f64,
	carry_through:      int,
	blackout:           bool,
	quit:               bool,
	// File_Dialog asked for the open-file dialog (the loop opens it).
	file_dialog:        bool,
	script_path:        string,
	media_dir:          string,
	// Script folder and media changes, polled on its own thread.
	watcher:            File_Watcher,
	// Requests to the worker: what was last asked, and the reload generation.
	asked_frame:        int,
	asked_hold:         f64,
	asked_through:      int,
	asked_now_start:    f64,
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
	seen_tables:        u64,
	seen_waves:         u64,
	seen_media:         u64,
	seen_thumbs:        u64,
	// The bands rows' sources drawn this window frame (asked of the worker
	// when they change), the last asked, and the textures it made.
	bands_shown:        [dynamic]i32,
	// The thumbnail frames the timeline laid out this window frame (asked of
	// the worker nearest the centre first: thumbs_wanted).
	thumbs_shown:       [dynamic]int,
	sent_bands:         [dynamic]i32,
	seen_bands:         u64,
	band_textures:      [dynamic]Band_Texture,
	// The media views (preview_media_views.odin): the files they show by durable
	// id (asked of the worker when they change), the last asked, and the worker's
	// table of them; the file heard alone, the one last asked of the worker and the
	// one the audio thread has by now (0: the video's sound).
	files_open:         [dynamic]u64,
	solo:               Solo,
	sent_solo:          u64,
	solo_heard:         u64,
	sent_images:        [dynamic]u64,
	images:             [dynamic]Image_Shown,
	seen_images:        u64,
	timeline:           Preview_Timeline,
	shown_frame:        int,
	shown_size:         [2]u32,
	render_ms:          f64,
	latency_ms:         f64,
	// Frames published per second, counted over the last second.
	worker_fps:         f64,
	// While playing, frames render at PLAY_SCALES[play_level] of the
	// fitted scale: a step lower after a second of missed frames, a step
	// higher after PLAY_STEADY seconds at the full rate; a step down that
	// doesn't raise the rate (the script isn't limited by pixels) is undone
	// and held, as is a step up that misses frames, until the next load.
	// Paused, frames render at the full scale.
	play_level:         int,
	play_held:          bool,
	play_steady:        int,
	// The last step (+1 lower, -1 higher), the rate before it, whether the
	// window being counted played throughout, and whether it is the first
	// after a step (the renderer rebuilt: not counted).
	play_step:          int,
	play_ratio:         f64,
	play_window:        bool,
	play_settling:      bool,
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
	// A placed song's sample sets are still loading: playback holds.
	sounds_loading:     bool,
	// While loading: what the worker is doing, the media files, the time so far.
	load_phase:         Load_Phase,
	load_files:         int,
	load_seconds:       f64,
	// The video's tables (the evaluator's), the expression a Watch is
	// typing, the timeline's table (its tracks too) and the media's.
	tables:             Video_Tables,
	watch_edit:         Watch_Edit,
	waves:              Wave_Table,
	media:              Media_Table,
	media_images:       [dynamic]vg.Image_Id, // parallel to media.rows (image thumbnails, the window's canvas's)
	media_uploaded:     int, // rows whose thumbnail texture exists (a few more per window frame)
	thumbs:             [dynamic]Preview_Thumb, // sorted by frame
	thumb_size:         [2]u32,
	// The last load's failure as text (made when taken), "" after a good one.
	reload_error:       string,
	seen_reload:        u64,
	// The newest frame the worker published: its texture (the worker's,
	// shown through a borrowed image) and size.
	video_texture:      ^sdl.GPUTexture,
	video_size:         [2]u32,
	// The window's frame (preview_run's), whose borrowed images show the
	// worker's textures.
	renderer:           ^render.Renderer,
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

// What the window clears to (the UI theme's background): the preview's, or
// black for --bare, --present and --live.
PREVIEW_BG :: [4]u8{18, 20, 26, 255}
BARE_BG :: [4]u8{0, 0, 0, 255}
// The panels' own background (the controls, a Watch, an empty panel).
COLOR_PANEL_BG :: [4]u8{24, 26, 32, 255}
// RAD Debugger's menu animation rates (a floating view, panels sliding,
// drop sites), its slow menu rate and its entity-alive rate (a row fading
// in), as ui.Animation_Params rates.
MENU_RATE :: 70 * math.LN2
MENU_SLOW_RATE :: 50 * math.LN2
ALIVE_RATE :: 30 * math.LN2
// The window's font size in points: RAD's default (its font_size setting),
// and RAD's range.
FONT_SIZE_DEFAULT :: 11
FONT_SIZE_MIN :: 6
FONT_SIZE_MAX :: 72
// The preview's icons: path data in the icons' 24 unit box (ui/icons.odin
// strokes them into their boxes), in one table, as onib keeps its icon
// sources in its tables.
Preview_Icon :: enum u8 {
	Search,
	Close,
	Play,
	Pause,
	Loop,
	Bookmark,
	Sound,
	Muted,
	Collapsed,
	Expanded,
}
PREVIEW_ICONS :: [Preview_Icon]string {
	.Search = "M10 4 A6 6 0 1 0 10 16 A6 6 0 1 0 10 4 Z M14.5 14.5 L20 20",
	.Close  = "M7 7 L17 17 M17 7 L7 17",
	.Play   = "M8 5 L19 12 L8 19 Z",
	.Pause  = "M9 5 L9 19 M15 5 L15 19",
	.Loop     = "M17 2 L21 6 L17 10 M3 11 L3 9 A4 4 0 0 1 7 5 L21 5 M7 22 L3 18 L7 14 M21 13 L21 15 A4 4 0 0 1 17 19 L3 19",
	.Bookmark = "M6 3 L18 3 L18 21 L12 16 L6 21 Z",
	// a speaker with its waves, and with an X (muted)
	.Sound    = "M11 5 L6 9 L2 9 L2 15 L6 15 L11 19 Z M15.5 8.5 A5 5 0 0 1 15.5 15.5 M19 5 A10 10 0 0 1 19 19",
	.Muted    = "M11 5 L6 9 L2 9 L2 15 L6 15 L11 19 Z M16 9 L22 15 M22 9 L16 15",
	// an expander's: closed (pointing on) and open (pointing down), RAD's
	// right and down arrows
	.Collapsed = "M9 6 L15 12 L9 18",
	.Expanded  = "M6 9 L12 15 L18 9",
}

// The window's bars (the transport controls, the status line), in the
// font's size (RAD's top and bottom bars: three).
BAR_HEIGHT :: 3
// Points a Watch opened beside the video takes (at most 45% of it).
WATCH_WIDTH :: 360
VOLUME_STEP :: 0.1

// A camera on the timeline (the frame at its left edge, its zoom: 1 = the
// whole video) and on the video (its centre in normalized panel units, its
// zoom: 1 = fit). As onib's: commands set the target, and the camera shown
// follows it each frame (camera_follow).
Timeline_Camera :: struct {
	first, zoom: f64,
}

// Where a picture view looks (Picture_Zoom, Picture_Pan, Picture_Fit): its zoom
// on the picture fitted in its box (1: fit), and the point at the box's middle,
// in fractions of the box from the picture's centre at zoom 1. Relative to the
// box, so it follows a box that changes.
Picture_Camera :: struct {
	center: [2]f64,
	zoom:   f64,
}

// What each picture view's camera opens at and a fit goes back to, on its fit
// (0: the view shows no picture). An image keeps its canvas in sight around it,
// as RAD's does (raddbg_views.c:4934).
PICTURE_ZOOM := #partial [View_Kind]f64 {
	.Video = 1,
	.Image = 0.8,
}

picture_home :: proc(kind: View_Kind) -> Picture_Camera {
	return {zoom = PICTURE_ZOOM[kind]}
}

// The video view's camera as shown, as far as it zooms in (what it renders at).
@(private)
video_zoom :: proc(pv: ^Preview_State) -> f64 {
	v := workspace_view(&pv.workspace, workspace_find(&pv.workspace, .Video))
	return v.shown.zoom if v != nil else 1
}

// The scale the worker renders at, for the video in a box `area`: what fits it,
// times the camera's zoom when zoomed in, less while playing. Quantized, so a
// window drag doesn't rebuild the renderer every pixel.
@(private)
video_scale :: proc(pv: ^Preview_State, area: Workspace_Rect) -> f32 {
	fit := min(max(area.width, 16) / f32(pv.timeline.width), max(area.height, 16) / f32(pv.timeline.height)) * f32(max(video_zoom(pv), 1))
	if pv.playing && !pv.scrubbing {
		fit *= PLAY_SCALES[pv.play_level]
	}
	return clamp(math.ceil(fit * 32) / 32, 1.0 / 32, 2)
}

// The view a camera command is for: `id`; with none (a key's), the focused
// panel's picture, or else the video.
@(private)
picture_target :: proc(ws: ^Workspace, id: View_Id) -> ^View_Record {
	if id != 0 do return workspace_view(ws, id)
	if p := workspace_panel(ws, ws.focused); p != nil {
		if v := workspace_view(ws, p.shown); v != nil && PICTURE_ZOOM[v.kind] > 0 do return v
	}
	return workspace_view(ws, workspace_find(ws, .Video))
}

// Rate of the exponential approach (onib's, oasic's and odincade's).
CAMERA_RATE :: 18

// The shown camera (`center`, `zoom`) follows its target, as onib's
// camera_follow: zoom moves in log space about the one point both cameras
// put at the same place on screen ((x - center) * zoom), so the point under
// a zooming pointer stays still the whole way. Settled once every centre is
// within `settle` of its target in screen units (center * zoom); `snap`
// follows at once, for drags that must track the pointer exactly.
camera_follow :: proc(center: []f64, zoom: ^f64, target_center: []f64, target_zoom: f64, dt: f32, snap: bool, settle: f64) -> (moving: bool) {
	same := zoom^ == target_zoom
	for c, i in center {
		same = same && c == target_center[i]
	}
	if snap || zoom^ <= 0 || same {
		copy(center, target_center)
		zoom^ = target_zoom
		return false
	}
	f := 1 - math.exp(-CAMERA_RATE * f64(max(dt, 0)))
	z0, z1 := zoom^, target_zoom
	z := math.exp(math.ln(z0) + (math.ln(z1) - math.ln(z0)) * f)
	if abs(z1 - z0) > 1e-9 * z1 {
		// (p - c0) z0 = (p - c1) z1: the fixed point of the move from shown to target.
		for &c, i in center {
			p := (c * z0 - target_center[i] * z1) / (z0 - z1)
			c = p - (p - c) * z0 / z
		}
	} else {
		for &c, i in center {
			c += (target_center[i] - c) * f
		}
		z = z1
	}
	zoom^ = z
	settled := abs(math.ln(z1) - math.ln(z)) < 1e-5
	for c, i in center {
		settled = settled && abs(c - target_center[i]) * z1 < settle
	}
	if settled {
		copy(center, target_center)
		zoom^ = z1
	}
	return !settled
}

// Both cameras at rest, showing everything.
preview_cameras_reset :: proc(pv: ^Preview_State) {
	pv.zoom, pv.view_first, pv.timeline_camera = 1, 0, {0, 1}
	if v := workspace_view(&pv.workspace, workspace_find(&pv.workspace, .Video)); v != nil {
		v.camera, v.shown = picture_home(.Video), picture_home(.Video)
	}
}

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
	if .Present in regs.flags {
		pv.present, pv.bare, pv.fullscreen, pv.loop = true, true, true, false
	}
	pv.now_start = app.now
	if .Live in regs.flags {
		pv.live, pv.bare, pv.fullscreen, pv.loop, pv.playing = true, true, true, false, true
	}
	// The worker loads the script (the start frame resolved with it).
	pv.script_path = strings.clone(app.script_path)
	pv.media_dir = strings.clone(app.media_dir)
	if app.props_text != "" {
		append(&pv.script_props, app.props_text)
	}
	return preview_run(app, capture = regs.path, drive = regs.args, start_spec = regs.spec)
}

// The window loop. Never waits on Lua, the render worker or a fence: it
// samples the newest frame the worker published. For measurements,
// `capture` a PNG of the last window frame and `drive` scripted input
// (`preview_drive`), "" for none.
@(private)
preview_run :: proc(app: ^App_State, capture, drive, start_spec: string) -> Error {
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
	preview_cameras_reset(pv)
	pv.rows_room = ROWS_AREA_MAX
	workspace_init(&pv.workspace)
	defer preview_state_destroy(pv)
	debug := app.debug || pv.exit_after > 0

	p: platform.Platform
	title := strings.clone_to_cstring(fmt.tprintf("onimite · %s", filepath.base(pv.script_path)), context.temp_allocator)
	// Mailbox where the window takes it, else vsync (the window paces its
	// frames: preview_pace).
	if err, detail := platform.init(&p, title, 1280, 820, .Auto); err != nil {
		return fail(app, {code = .Window, window = err, spec = detail})
	}
	defer platform.shutdown(&p)

	r: render.Renderer
	render.init(&r, p.device, p.window)
	defer render.destroy(&r)
	pv.renderer = &r
	defer pv.renderer = nil
	font, font_ok := render.font_load(UI_FONT)
	if !font_ok {
		return fail(app, {code = .Window_Drawing, drawing = .Font})
	}
	defer render.font_unload(&font)
	gpu: vgsdl.SDL_Backend
	if vgsdl.init(&gpu, p.device) != nil {
		return fail(app, {code = .Window_Drawing, drawing = .Backend})
	}
	defer vgsdl.destroy(&gpu)
	// One ovg canvas draws the whole frame.
	canvas: vg.Canvas
	vg.canvas_init(&canvas, vgsdl.backend(&gpu))
	defer vg.canvas_destroy(&canvas)
	defer media_images_release(pv, &canvas)

	s: ui.State
	ui.init(&s, &canvas, &p, &font)
	defer ui.destroy(&s)
	// The icons the views draw: the UI's own (the scroll bar's) and the
	// preview's (PREVIEW_ICONS).
	ui.icons_set(&s, ui.ICONS[:])
	preview_icons := PREVIEW_ICONS
	ui.icons_set(&s, slice.enumerated_array(&preview_icons))
	s.theme.background = BARE_BG if pv.bare else PREVIEW_BG
	pv.font_size = FONT_SIZE_DEFAULT

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
	mb.start_loaded = -1
	audio := new(Audio_Shared)
	worker := new(Render_Worker)
	worker^ = {mb = mb, audio = audio, device = p.device, software = app.software, debug = app.debug, log_clips = app.clip_log, image_budget = app.image_budget, script_path = strings.clone(pv.script_path), script_args = app.script_args, script_props = pv.script_props[:], start_spec = strings.clone(start_spec), media_dir = strings.clone(pv.media_dir), video = &app.video, pool = app.pool, background = app.background}
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
	// The next frame's start (preview_pace).
	next_ns: u64
	last_audio_log := 0
	fullscreen := false
	if pv.bare {
		platform.set_cursor_visible(false)
	}
	for platform.tick(&p) {
		defer free_all(context.temp_allocator)
		tick_began := time.tick_now()
		frames += 1
		if pv.exit_after > 0 && frames >= pv.exit_after {
			platform.request_close(&p)
		}
		now := platform.time(&p)
		dt := clamp(f64(p.frame_time), 0, 0.25)

		preview_playback_advance(app, dt)
		preview_take_published(app, &canvas, now)
		preview_motion_advance(app, p.frame_dt) // the cameras ease as the UI does
		preview_view_follow(app)
		preview_layout(app, &p)

		// The frame's input rows, made before the build as RAD's events are
		// before ui_begin_build: the window's events in order, then the
		// drive's.
		preview_input(app, &s, &p)
		if drive != "" {
			preview_drive(app, &s, drive, frames)
		}
		preview_watch_files(app, now)
		// The UI's text and padding at the window's display scale now (it
		// moves displays), times its font size over RAD's default: at the
		// default the window's font is RAD's 11 points, and what is sized
		// from it (tabs, rows) keeps RAD's proportions.
		s.theme.default_font_px = FONT_SIZE_DEFAULT * p.dpi_scale
		s.theme.default_padding = 6 * p.dpi_scale
		s.font_scale = pv.font_size / FONT_SIZE_DEFAULT
		ui.build_begin(&s)
		s.target = render.begin_frame(&r, &canvas, p.width, p.height)
		preview_views(app, &s, &p)
		ui.build_end(&s)
		// A drop lasts the frame its button was released in.
		if pv.drag == .Dropping do preview_drag_end(app)
		built := time.tick_since(tick_began)
		if capture != "" && pv.exit_after > 0 && frames >= pv.exit_after {
			if pixels, ok := render.end_frame_capture(&r, &canvas); ok {
				odimg.write_png(capture, pixels, int(r.fb_w), int(r.fb_h))
				delete(pixels)
				fmt.eprintln("preview: captured", capture)
			}
		} else {
			_, shown := render.end_frame(&r, &canvas)
			preview_pace(&p, shown, &next_ns)
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
		len(pv.tables.problems),
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
// every 60 window frames, from frame 30; "closeup" zooms the focused picture four
// times (20). The workspace: "watch" opens the
// Watch's tab on its cues (window frame 2), "media" on the media (as I does),
// "split" splits the video's panel to
// the right, the new panel a third of it, so a timeline moved there is
// taller than wide (10), "move" moves the timeline into the empty panel (20),
// "drag" drops the timeline's tab on the left edge of the video's panel
// (30), "pick" clicks the shown Watch tab's third row (40), "next" goes to
// the next warning or error (45), "hover"
// moves the mouse down and up the shown Watch tab's rows (from 10), "openimage"
// opens the first row with a view (8), "pullimage" and "pullsound" drag out the
// first image's and sound's view beside the video (20), "playsolo" plays the first
// sound's view from its start (25), "tabpointer" points into a shown image's tab
// (from 30), "loadloop" reloads every 30 window frames, the media with every
// second one. The lister, as
// keys and typing reach it (`preview_drive_lister`): "goto" and "openview".
// A presentation: "present_next" moves on every 240 window frames from 300.
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
	if frames >= 300 && frames % 240 == 60 && strings.contains(drive, "present_next") {
		command_push(c, .Present_Next, {})
	}
	preview_drive_workspace(app, drive, frames)
	preview_drive_lister(app, s, drive, frames)
	if frames >= 10 && strings.contains(drive, "hover") {
		// Down and up the Watch's rows, a row's height every two window
		// frames, as the mouse's motion reaches the widgets.
		ws := &app.preview.workspace
		if v := workspace_view(ws, workspace_shown(ws, .Watch)); v != nil {
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
	if frames >= 30 && strings.contains(drive, "tabpointer") {
		// over a pulled-out image, near its middle
		if v := workspace_view(&app.preview.workspace, workspace_shown(&app.preview.workspace, .Image)); v != nil {
			r := app.preview.workspace.areas[int(v.panel) - 1].content
			input := &s.p.input
			input.mouse_prev = input.mouse
			input.mouse = {r.x + r.width * 0.46, r.y + r.height * 0.47}
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
			command_push(c, .Watch_Show, {spec = "video:marks"})
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
	if frames == 20 && strings.contains(drive, "closeup") {
		command_push(c, .Picture_Zoom, {scalar = 4, at_xy = {0.5, 0.5}})
	}
	if frames == 2 && strings.contains(drive, "watch") {
		command_push(c, .Watch_Show, {spec = "video:cues"})
	}
	if frames == 2 && strings.contains(drive, "media") {
		command_push(c, .Watch_Show, {spec = "video:media"})
	}
	if frames == 8 && strings.contains(drive, "openimage") {
		// the first media row with a view, as a press on its expander opens it
		id := workspace_shown(ws, .Watch)
		if v := workspace_view(ws, id); v != nil {
			blocks := watch_blocks(app, v)
			rows := make([dynamic]View_Row, context.temp_allocator)
			blocks_window(&blocks, 0, max(int), &rows)
			for row in rows {
				if _, ok := visualizer_of(&blocks.r, row.value); ok {
					command_push(c, .Watch_Expand, {view = id, spec = row.key})
					break
				}
			}
		}
	}
	if frames == 25 && strings.contains(drive, "playsolo") {
		// the first sound's view, as its button plays it
		r := preview_reader(app)
		for v in ws.views {
			if !v.live || v.kind != .Audio do continue
			if value, error := evaluate(&r, v.inputs[0].source); error == "" {
				command_push(c, .Solo_Set, {row = r.tables.media[value.ref.row].id, count = 0, flag = true})
				break
			}
		}
	}
	if frames == 20 && strings.contains(drive, "pullimage") && video != nil {
		// the first row's view dragged out beside the video
		for v, i in ws.views {
			if v.live && v.kind == .Image && v.owner != 0 {
				command_push(c, .View_Move, {view = View_Id(i + 1), panel = video.panel, direction = .Right})
				break
			}
		}
	}
	if frames == 20 && strings.contains(drive, "pullsound") && video != nil {
		for v, i in ws.views {
			if v.live && v.kind == .Audio && v.owner != 0 {
				command_push(c, .View_Move, {view = View_Id(i + 1), panel = video.panel, direction = .Right})
				break
			}
		}
	}
	if frames >= 30 && frames % 30 == 0 && strings.contains(drive, "loadloop") {
		// the script alone and with its media, in turn
		command_push(c, .Script_Reload, {flag = frames % 60 == 0})
	}
	if frames == 10 && strings.contains(drive, "split") && video != nil {
		command_push(c, .Panel_Split, {panel = video.panel, direction = .Right, ratio = 2.0 / 3})
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
		if v := workspace_view(ws, workspace_shown(ws, .Watch)); v != nil {
			// its third row's frame, as a click on it goes there
			blocks := watch_blocks(app, v)
			rows := make([dynamic]View_Row, context.temp_allocator)
			blocks_window(&blocks, min(2, max(blocks.total - 1, 0)), 1, &rows)
			if len(rows) > 0 {
				if f := row_frame(&blocks.r, rows[0].value); f >= 0 do command_push(c, .Go_To, {count = f})
			}
		}
	}
	if frames == 45 && strings.contains(drive, "next") {
		command_push(c, .Problem_Step, {count = 1})
	}
	// "filter=QUERY" types QUERY into the shown Watch tab's filter (window frame 30).
	if frames == 30 && strings.contains(drive, "filter=") {
		query := drive[strings.index(drive, "filter=") + len("filter="):]
		if end := strings.index_any(query, " ,"); end >= 0 do query = query[:end]
		view := workspace_shown(ws, .Watch)
		view_filter_field(&app.preview, view).open = true
		command_push(c, .View_Filter, {view = view, spec = query})
	}
}

// The drive's lister steps, as Ctrl+P, the + and typed keys reach it:
// "goto" presses Ctrl+P (Go_To's query: the scenes, cues, problems and
// marks; window frame 60), types its filter ("goto=QUERY", default none;
// 64), moves the selection down (70) and picks with Enter (80); "openview"
// opens it on the views of the video's panel (60), types "cues" (64) and
// picks with Enter (80).
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
		query = ""
		if i := strings.index(drive, "goto="); i >= 0 {
			query = drive[i + len("goto="):]
			if end := strings.index_any(query, " ,"); end >= 0 {
				query = query[:end]
			}
		}
	}
	// A key and typing as the window takes them (key_route): Down moves
	// the lister's cursor, Enter accepts.
	key :: proc(app: ^App_State, s: ^ui.State, k: platform.Key) {
		press := [1]platform.Event{key_press(k)}
		key_route(app, s, press[:])
	}
	switch frames {
	case 60:
		if go_to {
			press := [1]platform.Event{key_press(.P, {.Control})}
			key_route(app, s, press[:])
		} else if v := workspace_view(ws, workspace_find(ws, .Video)); v != nil {
			command_push(c, .Lister_Open, {panel = v.panel, lister = .Panel})
		}
	case 64:
		key_route(app, s, text_events(query))
	case 70:
		if go_to {
			key(app, s, .Down)
		}
	case 80:
		key(app, s, .Enter)
	}
}

@(private)
preview_state_destroy :: proc(pv: ^Preview_State) {
	for &f in pv.view_filters do delete(f.text)
	delete(pv.view_filters)
	delete(pv.view_lists)
	delete(pv.script_path)
	delete(pv.media_dir)
	delete(pv.script_props)
	delete(pv.reload_error)
	delete(pv.device_name)
	video_tables_destroy(&pv.tables)
	delete(pv.watch_edit.text)
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
	delete(pv.thumbs_shown)
	delete(pv.sent_bands)
	delete(pv.band_textures)
	delete(pv.files_open)
	delete(pv.sent_images)
	delete(pv.images)
	preview_timeline_destroy(&pv.timeline)
	delete(pv.ui_ms)
	delete(pv.interval_ms)
	pv^ = {}
}

@(private)
media_images_release :: proc(pv: ^Preview_State, c: ^vg.Canvas) {
	for img in pv.media_images {
		if vg.image_id_valid(img) do vg.delete_image(c, img)
	}
	clear(&pv.media_images)
}

@(private)
default_media_dir :: proc(script_path: string) -> string {
	// a video or audio file loads as a video of itself: its media is the
	// file alone
	if kind, ok := om.media_kind_of(script_path); ok && (kind == .Video || kind == .Audio) {
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
	// a live board's clock only runs forward: past its end the last frame
	// holds while the clock goes on, so a seek there (the sound's resync
	// after a reload) must not take it back to the end (f.now would jump
	// into the past for a frame)
	at := f64(pv.frame) / f64(preview_fps(app))
	pv.clock = max(pv.clock, at) if pv.live else at
	// (a file heard alone holds the audio thread; the video seeks when it is back)
	if pv.audio != nil && pv.solo.file == 0 {
		audio_seek(pv.audio, i64(pv.clock * om.MIX_RATE))
	}
}

@(private)
preview_sync_audio :: proc(app: ^App_State) {
	pv := &app.preview
	if pv.audio != nil {
		playing := pv.solo.playing if pv.solo.file != 0 else pv.playing && !pv.scrubbing && !pv.sounds_loading
		audio_set_state(pv.audio, playing && solo_settled(pv), pv.muted, pv.loop && pv.solo.file == 0)
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

// Keeps the timeline's camera, its target and as shown, inside the video:
// from the whole of it down to four frames across.
@(private)
view_clamp :: proc(app: ^App_State) {
	pv := &app.preview
	total := f64(preview_duration(app))
	clamp_camera :: proc(first, zoom: ^f64, total, most: f64) {
		zoom^ = clamp(zoom^, 1, most)
		first^ = clamp(first^, 0, max(total - total / zoom^, 0))
	}
	clamp_camera(&pv.timeline_camera.first, &pv.timeline_camera.zoom, total, zoom_max(app))
	clamp_camera(&pv.view_first, &pv.zoom, total, zoom_max(app))
}

preview_apply :: proc(app: ^App_State, kind: Command_Kind, regs: Command_Regs) {
	pv := &app.preview
	#partial switch kind {
	case .Frame_Set:
		// (a load's keeps the frame it is on, and the file plays on)
		if pv.solo.file != 0 && regs.count != pv.frame do solo_set(app, 0, -1, false)
	case .Playback_Toggle, .Playback_Set, .Frame_Step, .Frame_Start, .Seconds_Step, .Scene_Step, .Problem_Step, .Present_Next, .Present_Previous, .Go_To:
		// The video taken up again: a file heard alone gives way to it.
		if pv.solo.file != 0 do solo_set(app, 0, -1, false)
	}
	#partial switch kind {
	case .Solo_Set:
		solo_set(app, regs.row, regs.count, regs.flag)
	case .Playback_Toggle:
		if pv.present && pv.holding && !pv.playing {
			// a held scene: its clock stops and runs on
			pv.hold_paused = !pv.hold_paused
			break
		}
		if !pv.playing && !pv.loop && !pv.present && pv.frame >= preview_duration(app) - 1 {
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
	case .Present_Next:
		stop, scene := present_stop(app, pv.frame)
		switch {
		case scene < 0:
		case !pv.holding && !pv.playing:
			// paused (opened --paused, or P): play on
			pv.playing = true
		case !pv.holding:
			// playing: on to the end it is playing toward
			present_hold(app, stop, scene)
		case pv.frame < stop && pv.timeline.scenes[scene].hold != .Loop:
			// held before the first scene's end (back at the start): play it
			pv.holding, pv.playing, pv.aimed, pv.carry = false, true, false, 0
		case stop + 1 < preview_duration(app):
			// on: the transition and the next scene, from the held frame (the
			// sound paused there), or from the stop when looping the scene;
			// the held scene leaves from where the hold left it (a looping
			// one from where its loop was)
			#partial switch pv.timeline.scenes[scene].hold {
			case .Alive:
				pv.carry = pv.hold_time
			case .Loop:
				pv.carry = f64(pv.frame - stop) / f64(preview_fps(app))
			case:
				pv.carry = 0
			}
			pv.carry_through = stop
			pv.holding, pv.hold_time, pv.hold_paused, pv.playing = false, 0, false, true
			if pv.frame != stop {
				preview_seek(app, stop + 1)
			}
			pv.toward, pv.toward_scene = present_stop(app, stop + 1)
			pv.aimed = true
		}
		preview_sync_audio(app)
	case .Present_Previous:
		// back to the end of the scene before the one showing (past those
		// that flow on), held; before the first, its start, still
		_, scene := present_stop(app, pv.frame)
		first := max(scene, 0)
		for first > 0 && pv.timeline.scenes[first - 1].hold == .Flow {
			first -= 1
		}
		if first > 0 {
			stop, before := present_stop(app, pv.timeline.scenes[first].start_frame - 1)
			present_hold(app, stop, before)
		} else {
			pv.playing, pv.holding, pv.hold_time, pv.hold_paused, pv.aimed = false, true, 0, true, false
			preview_seek(app, 0)
		}
		pv.carry = 0
		preview_sync_audio(app)
	case .Blackout_Toggle:
		pv.blackout = !pv.blackout
	case .Script_Open:
		preview_switch_script(app, regs.path)
	case .File_Dialog:
		pv.file_dialog = true
	case .Script_Reload:
		// The worker reloads; the UI keeps showing the last frame meanwhile
		// (a presentation aims again at the new timeline's stops).
		pv.aimed = false
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
		// Logarithmic zoom about the frame under the cursor (or the playhead):
		// that frame keeps its place in the target, and the shown camera
		// follows about the point both put at one place, so it stays still
		// the whole way; rapid wheel ticks accumulate on the target.
		cam := &pv.timeline_camera
		total := f64(preview_duration(app))
		visible := total / cam.zoom
		at, anchor: f64
		if regs.flag {
			at = clamp(regs.ratio, 0, 1)
			anchor = cam.first + at * visible
		} else {
			anchor = f64(regs.count if regs.count >= 0 else pv.frame)
			at = clamp((anchor - cam.first) / visible, 0, 1) if visible > 0 else 0
		}
		cam.zoom = clamp(cam.zoom * regs.scalar, 1, zoom_max(app))
		cam.first = anchor - at * total / cam.zoom
		pv.detached = true
		view_clamp(app)
	case .Timeline_Fit:
		pv.detached = false
		pv.timeline_camera = {0, 1}
		if v := workspace_view(&pv.workspace, workspace_find(&pv.workspace, .Video)); v != nil do v.camera = picture_home(.Video)
	case .Timeline_Pan:
		// A middle drag pans 1:1 with the pointer (flag: the shown camera
		// snaps); the wheel's pans accumulate on the target and ease.
		pv.detached = true
		pv.timeline_camera.first += regs.scalar
		view_clamp(app)
		if regs.flag {
			pv.view_first, pv.zoom = pv.timeline_camera.first, pv.timeline_camera.zoom
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
	case .Picture_Zoom:
		// 2D zoom about the cursor (fractions of the box from its centre):
		// the point under it keeps its place in the target; back at the zoom it
		// opened at, the picture is centred again.
		if v := picture_target(&pv.workspace, regs.view); v != nil {
			cam := &v.camera
			at := [2]f64{f64(regs.at_xy.x) - 0.5, f64(regs.at_xy.y) - 0.5}
			point := at / cam.zoom + cam.center
			cam.zoom = clamp(cam.zoom * regs.scalar, 1.0 / 256, 256)
			cam.center = point - at / cam.zoom if cam.zoom != PICTURE_ZOOM[v.kind] else {}
		}
	case .Picture_Pan:
		// A drag moves the picture 1:1 with the pointer (the shown camera
		// snaps), within half a box past fitting.
		if v := picture_target(&pv.workspace, regs.view); v != nil {
			cam := &v.camera
			bound := 0.5 * max(cam.zoom, 1)
			pan := -cam.center * cam.zoom + {f64(regs.at_xy.x), f64(regs.at_xy.y)}
			pan = {clamp(pan.x, -bound, bound), clamp(pan.y, -bound, bound)}
			cam.center = -pan / cam.zoom
			v.shown = cam^
		}
	case .Picture_Fit:
		if v := picture_target(&pv.workspace, regs.view); v != nil do v.camera = picture_home(v.kind)
	case .Fullscreen_Toggle:
		pv.fullscreen = !pv.fullscreen
	case .Watch_Show:
		watch_show(app, regs.spec)
	case .Go_To:
		pv.detached = false
		preview_seek(app, regs.count)
	case .View_Scroll:
		// A view's register: its first row shown, within its rows.
		if v := workspace_view(&pv.workspace, regs.view); v != nil {
			switch v.kind {
			case .Watch:
				blocks := watch_blocks(app, v)
				v.scroll = clamp(regs.count, 0, max(blocks.total - 1 + int(!v.scoped), 0))
			case .Timeline:
				// its rows' list's: units of ROW_UNIT points, to its last
				v.scroll = clamp(regs.count, 0, max(int(timeline_rows(app).points) / ROW_UNIT - 1, 0))
			case .Video, .Image, .Audio:
			}
			// A dragged thumb's: the list there at once (RAD's off = 0).
			if regs.flag do animation.scroll_jump(&view_list(pv, regs.view).scroll, f32(v.scroll))
		}
	case .View_Filter:
		if v := workspace_view(&pv.workspace, regs.view); v != nil && v.kind == .Watch {
			clear(&v.filter)
			append(&v.filter, regs.spec)
			v.scroll = 0
		}
	case .Problem_Step:
		pv.detached = false
		preview_seek(app, problem_step_target(app, regs.count))
	case .Cursor_Hover:
		pv.hover_frame = regs.count
		pv.hover_valid = true
	case .Quit:
		pv.quit = true
	case .Font_Size_Increase:
		pv.font_size = clamp(pv.font_size + 1, FONT_SIZE_MIN, FONT_SIZE_MAX)
	case .Font_Size_Decrease:
		pv.font_size = clamp(pv.font_size - 1, FONT_SIZE_MIN, FONT_SIZE_MAX)
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

// Where a presentation holds for the scene showing at `frame`: the last
// frame before the next scene comes in (where its overlap, the transition,
// begins), past scenes that flow on (Hold.Flow), and the scene whose hold
// it is; the video's last frame for the last. Scene -1 before the timeline
// is known.
@(private)
present_stop :: proc(app: ^App_State, frame: int) -> (stop: int, scene: int) {
	pv := &app.preview
	scenes := pv.timeline.scenes[:]
	last := preview_duration(app) - 1
	if len(scenes) == 0 {
		return last, -1
	}
	scene = 0
	for s, i in scenes {
		if s.start_frame <= frame {
			scene = i
		}
	}
	for {
		stop = last
		if scene + 1 < len(scenes) {
			stop = min(scenes[scene].end_frame, scenes[scene + 1].start_frame) - 1
		}
		if scene + 1 >= len(scenes) || (scenes[scene].hold != .Flow && stop >= frame) {
			return
		}
		scene += 1
	}
}

// Holds at `stop`, scene `scene`'s end: running on, still, or (Hold.Loop)
// playing the scene again from its start until the presenter moves on.
@(private)
present_hold :: proc(app: ^App_State, stop, scene: int) {
	pv := &app.preview
	pv.holding, pv.hold_time, pv.hold_paused = true, 0, false
	pv.toward, pv.toward_scene, pv.aimed = stop, scene, true
	if scene >= 0 && pv.timeline.scenes[scene].hold == .Loop {
		pv.playing = true
		preview_seek(app, pv.timeline.scenes[scene].start_frame)
	} else {
		pv.playing = false
		preview_seek(app, stop)
	}
	preview_sync_audio(app)
}

// After playback moved on from `from`: holds where it reached the stop it
// is playing toward (that of the scene at `from` until one is aimed at).
@(private)
present_reach :: proc(app: ^App_State, from: int) {
	pv := &app.preview
	if !pv.aimed {
		pv.toward, pv.toward_scene = present_stop(app, from)
		pv.aimed = pv.toward_scene >= 0
	}
	if pv.aimed && pv.frame >= pv.toward {
		present_hold(app, pv.toward, pv.toward_scene)
	}
}

// The hold of the scene a presentation is held in.
@(private)
present_scene_hold :: proc(app: ^App_State) -> om.Hold {
	_, scene := present_stop(app, app.preview.frame)
	return app.preview.timeline.scenes[scene].hold if scene >= 0 else .Freeze
}

// Shows the Watch tab on `expression` and focuses its panel (RAD's views
// grouped in a panel as tabs). One not open opens after the other Watch
// tabs; with none open, in a panel of its own beside the video
// (WATCH_WIDTH wide), else in the focused panel.
@(private)
watch_show :: proc(app: ^App_State, expression: string) {
	pv := &app.preview
	ws := &pv.workspace
	id := workspace_find_watch(ws, expression)
	if other := workspace_view(ws, workspace_find(ws, .Watch)); id == 0 && other != nil {
		id = workspace_open(ws, other.panel, .Watch, previous = workspace_panel(ws, other.panel).last, expression = expression)
	} else if id == 0 {
		panel, direction, ratio := ws.focused, Direction.None, f32(0)
		if video := workspace_view(ws, workspace_find(ws, .Video)); video != nil {
			panel, direction, ratio = video.panel, .Right, 0.55
			if int(video.panel) <= len(ws.areas) {
				if width := ws.areas[video.panel - 1].rect.width; width > 0 {
					ratio = clamp(1 - WATCH_WIDTH * pv.dpi / width, 0.55, 0.8)
				}
			}
		}
		id = workspace_open(ws, panel, .Watch, direction, ratio, expression = expression)
	}
	workspace_select(ws, id)
}

// The frame of the next (`steps` > 0) or previous scene, cue, problem or
// media file with a warning or an error after (before) the playhead,
// wrapping around; the playhead when there is none.
@(private)
problem_step_target :: proc(app: ^App_State, steps: int) -> int {
	pv := &app.preview
	t := &pv.tables
	frames := make([dynamic]int, context.temp_allocator)
	for r in t.scenes do if r.status >= .Warning do append(&frames, r.start)
	for r in t.cues do if r.status >= .Warning do append(&frames, r.frame)
	for r in t.problems do if r.status >= .Warning && r.first >= 0 do append(&frames, r.first)
	for r in t.media do if r.status >= .Warning && r.first >= 0 do append(&frames, r.first)
	near, wrap := -1, -1
	for f in frames {
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
	preview_cameras_reset(pv)
	pv.detached = false
	if w := pv.worker; w != nil {
		// The worker reads its paths only between requests; restart it on the
		// new script (the stop waits for the frame in progress).
		mb := w.mb
		// Its textures go with it: stop showing them.
		pv.video_texture, pv.video_size = nil, {}
		clear(&pv.thumbs)
		clear(&pv.band_textures)
		clear(&pv.bands_shown)
		clear(&pv.sent_bands)
		clear(&pv.images)
		clear(&pv.sent_images)
		pv.solo = {}
		pv.sent_solo, pv.solo_heard = 0, 0
		worker_stop(w)
		sync.mutex_lock(&mb.mutex)
		mb.quit = false
		mb.slot = -1
		mb.slot_texture = nil
		mb.displayed_slot = -1
		mb.bookmark = -1
		mb.bookmark_seq = 0
		mb.bookmark_loaded = -1
		mb.start_loaded = -1
		clear(&mb.marks)
		mb.marks_seq = 0
		clear(&mb.marks_loaded)
		clear(&mb.thumbs)
		mb.thumb_gen = 0
		mb.thumb_ack = 0
		mb.thumbs_seq += 1
		clear(&mb.band_textures)
		clear(&mb.bands_wanted)
		mb.bands_seq += 1
		clear(&mb.files_wanted)
		mb.solo_file, mb.solo_heard = 0, 0
		clear(&mb.images)
		clear(&mb.image_pixels)
		mb.images_seq += 1
		sync.mutex_unlock(&mb.mutex)
		w^ = {mb = mb, audio = w.audio, device = w.device, software = w.software, debug = w.debug, log_clips = w.log_clips, image_budget = w.image_budget, script_path = strings.clone(pv.script_path), script_args = app.script_args, script_props = pv.script_props[:], media_dir = strings.clone(pv.media_dir), video = w.video, pool = w.pool, background = w.background}
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
	defer if pv.live {
		// f.now is the system clock: the clock's start moves when the two
		// part by more than a frame (a stall, the system clock set)
		wall := f64(time.time_to_unix_nano(time.now())) / 1e9
		if start := wall - pv.clock; abs(start - pv.now_start) > 1 / f64(max(preview_fps(app), 1)) {
			pv.now_start = start
		}
	}
	if pv.present && pv.holding && !pv.playing && !pv.hold_paused {
		pv.hold_time += dt
	}
	solo_update(app)
	if !pv.playing || pv.scrubbing || pv.sounds_loading || pv.timeline.frames <= 0 || !solo_settled(pv) {
		return
	}
	from := pv.frame
	defer if pv.present {
		present_reach(app, from)
	}
	fps := f64(preview_fps(app))
	total := f64(preview_duration(app)) / fps
	if pv.live && pv.clock >= total - 1.5 / fps {
		// a live board runs on past its end, on real time (the sound is
		// over), its last frame held (preview_request)
		pv.clock += dt
		pv.frame = preview_duration(app) - 1
		return
	}
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
		if !playing && pv.clock >= total - 1.5 / fps && !pv.live {
			// The audio stopped at the end (not looping).
			pv.playing = false
			pv.clock = total - 1 / fps
			pv.quit ||= pv.bare && !pv.present
		}
	} else {
		pv.clock += dt
		if pv.clock >= total && !pv.live {
			if pv.loop {
				pv.clock -= total * math.floor(pv.clock / total)
			} else {
				pv.clock = total - 1 / fps
				pv.playing = false
				pv.quit ||= pv.bare && !pv.present
			}
		}
	}
	pv.frame = clamp(int(pv.clock * fps), 0, preview_duration(app) - 1)
}

// The cameras shown follow their targets (camera_follow): the timeline's
// settles within a ten-thousandth of the video's width, the video's within
// a hundred-thousandth of its panel.
@(private)
preview_motion_advance :: proc(app: ^App_State, dt: f32) {
	pv := &app.preview
	first := [1]f64{pv.view_first}
	camera_follow(first[:], &pv.zoom, {pv.timeline_camera.first}, pv.timeline_camera.zoom, dt, false, 1e-4 * f64(preview_duration(app)))
	pv.view_first = first[0]
	view_clamp(app)
	for &v in pv.workspace.views {
		if v.live && PICTURE_ZOOM[v.kind] > 0 {
			camera_follow(v.shown.center[:], &v.shown.zoom, v.camera.center[:], v.camera.zoom, dt, false, 1e-5)
		}
	}
}

// Keeps the playhead inside the zoomed timeline while following (oasic's
// timeline_follow / series_follow): zooming or panning detaches the view so
// playback doesn't yank it away; seeking or re-engaging Follow reattaches it,
// and when following moves the window, the camera moves with it at once so
// the view doesn't lag behind the playhead.
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
		// following moves the window at once: the camera doesn't lag the playhead
		pv.timeline_camera = {pv.view_first, pv.zoom}
	}
}

// Takes what the worker published since the last look: the newest frame's
// texture (the worker won't render into it while it is shown), the
// timeline, the problems, waveforms, media and thumbnail tables, and the
// load state.
@(private)
preview_take_published :: proc(app: ^App_State, c: ^vg.Canvas, now: f64) {
	pv := &app.preview
	mb := pv.mailbox
	timeline_changed, media_changed := false, false
	bookmark_loaded, start_loaded := -1, -1
	marks_loaded := false
	sync.mutex_lock(&mb.mutex)
	if mb.published_seq != pv.seen_publish && mb.slot >= 0 {
		pv.fps_count += int(mb.published_seq - pv.seen_publish)
		if pv.seen_publish == 0 {
			pv.first_frame_at = now
		}
		pv.seen_publish = mb.published_seq
		mb.displayed_slot = mb.slot
		pv.video_texture, pv.video_size = mb.slot_texture, mb.slot_size
		pv.shown_frame = mb.slot_frame
		pv.shown_size = mb.slot_size
		pv.render_ms = mb.render_ms
		pv.latency_ms = mb.latency_ms
	}
	if mb.timeline_seq != pv.seen_timeline {
		pv.seen_timeline = mb.timeline_seq
		preview_timeline_copy(&pv.timeline, &mb.timeline)
		// a new load: playback starts again at the full scale
		pv.play_level, pv.play_held, pv.play_steady, pv.play_step, pv.play_settling = 0, false, 0, 0, false
		bookmark_loaded = mb.bookmark_loaded
		start_loaded = mb.start_loaded
		mb.start_loaded = -1
		if pv.marks_unread {
			// the saved marks, read with the script's first load
			table_copy(&pv.marks, mb.marks_loaded[:])
			pv.marks_unread = false
			marks_loaded = true
		}
		timeline_changed = true
	}
	if mb.tables_seq != pv.seen_tables {
		pv.seen_tables = mb.tables_seq
		video_tables_copy(&pv.tables, &mb.tables)
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
	images_take(pv, mb)
	solo_heard := mb.solo_heard
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
	sounds_were := pv.sounds_loading
	pv.sounds_loading = mb.sounds_loading
	pv.load_phase = mb.load_phase
	pv.load_files = mb.load_files
	if pv.loading {
		pv.load_seconds = time.duration_seconds(time.tick_since(mb.load_began))
	}
	sync.mutex_unlock(&mb.mutex)
	solo_take(app, solo_heard)
	if pv.sounds_loading != sounds_were {
		// held or let go: the stream starts again where the picture is
		preview_seek(app, pv.frame)
		preview_sync_audio(app)
	}

	playing := pv.playing && !pv.scrubbing
	pv.play_window &&= playing
	if now - pv.fps_since >= 1 {
		pv.worker_fps = f64(pv.fps_count) / (now - pv.fps_since)
		pv.fps_count = 0
		pv.fps_since = now
		if pv.play_window && pv.timeline.fps > 0 {
			level := pv.play_level
			play_scale_adapt(pv, pv.worker_fps / f64(pv.timeline.fps))
			if app.debug && pv.play_level != level {
				fmt.eprintfln("preview: %.0f of %d fps, playing at %.0f%% of the fitted scale%s", pv.worker_fps, pv.timeline.fps, PLAY_SCALES[pv.play_level] * 100, " (held)" if pv.play_held else "")
			}
		}
		pv.play_window = playing
	}
	if media_changed {
		media_images_release(pv, c)
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
			pv.media_images[pv.media_uploaded], _ = vg.create_image(c, vg.image_source_rgba(pv.media.pixels[row.thumb:][:w * h * 4], w, h))
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
		// `preview AT` wins over the bookmark, once.
		target := pv.frame
		if start_loaded >= 0 {
			pv.start_frame = start_loaded
			target = start_loaded
		} else if pv.bookmark >= 0 {
			target = pv.bookmark
		}
		view_clamp(app)
		command_push(&app.commands, .Frame_Set, {count = target})
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
	wanted := thumbs_wanted(app)
	// a hidden timeline asks for nothing (its rows keep their last lists)
	bands := pv.bands_shown[:] if timeline_shown(app) else nil
	thumbs_changed := !slice.equal(wanted, pv.sent_thumbs[:])
	bands_changed := !slice.equal(bands, pv.sent_bands[:])
	images_changed := !slice.equal(pv.files_open[:], pv.sent_images[:])
	if busy != pv.sent_busy || pv.bookmark != pv.sent_bookmark || pv.marks_changed || thumbs_changed || bands_changed || images_changed || pv.solo.file != pv.sent_solo {
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
			table_copy(&mb.bands_wanted, bands)
			mb.bands_wanted_seq += 1
		}
		if images_changed {
			table_copy(&mb.files_wanted, pv.files_open[:])
			mb.files_wanted_seq += 1
		}
		mb.solo_file = pv.solo.file
		pv.sent_solo = pv.solo.file
		sync.cond_signal(&mb.cond)
		sync.mutex_unlock(&mb.mutex)
		pv.sent_busy = busy
		pv.sent_bookmark = pv.bookmark
		table_copy(&pv.sent_thumbs, wanted)
		table_copy(&pv.sent_bands, bands)
		table_copy(&pv.sent_images, pv.files_open[:])
	}

	// The scale that fits the video's panel (kept while it is hidden),
	// multiplied by the video camera's zoom when zoomed in.
	scale := pv.asked_scale if pv.asked_scale > 0 else 1
	if area, shown := view_area(app, .Video); shown && pv.timeline.width > 0 do scale = video_scale(pv, area)
	frame, hold, through := preview_asked(app)
	fps := max(preview_fps(app), 1)
	if pv.asked_frame == frame && pv.asked_hold == hold && pv.asked_through == through && pv.asked_scale == scale && pv.reload_gen == pv.asked_reload && pv.asked_now_start == pv.now_start {
		return
	}
	// the frame's moment on the wall clock: what a reload's track_changes
	// stamps the rows it finds changed with
	now := pv.now_start + f64(frame) / f64(fps) + hold
	sync.mutex_lock(&mb.mutex)
	mb.request = {frame = frame, hold = hold, hold_through = through, now_start = pv.now_start, now = now, scale = scale, reload = pv.reload_gen, reload_media = mb.request.reload_media || pv.reload_media, asked = time.tick_now()}
	mb.request_seq += 1
	sync.cond_signal(&mb.cond)
	sync.mutex_unlock(&mb.mutex)
	pv.asked_frame = frame
	pv.asked_hold = hold
	pv.asked_through = through
	pv.asked_now_start = pv.now_start
	pv.asked_scale = scale
	pv.asked_reload = pv.reload_gen
	pv.reload_media = false
}

// The frame the worker is asked for, and the hold it runs the scenes up to
// `through` on by (Render_Request.hold).
@(private)
preview_asked :: proc(app: ^App_State) -> (frame: int, hold: f64, through: int) {
	pv := &app.preview
	frame = pv.frame
	// a presentation's hold: the held scene runs on past its last frame, and
	// leaves from there (Hold.Alive); a looping one plays on its last frame,
	// alone (no previous scene coming in), its clock going round from its
	// start with the sound (Hold.Loop)
	if pv.present {
		switch {
		case pv.holding && !pv.playing && present_scene_hold(app) == .Alive:
			hold, through = pv.hold_time, pv.frame
		case pv.holding && pv.playing:
			frame = pv.toward
			hold, through = f64(pv.frame - pv.toward) / f64(preview_fps(app)), pv.toward
		case:
			hold, through = pv.carry, pv.carry_through
		}
	}
	// a live board past its end: the last frame held, every scene running
	// on in whole frames of the clock (as a render's)
	fps := max(preview_fps(app), 1)
	if k := int(pv.clock * f64(fps)); pv.live && k > frame {
		hold, through = f64(k - frame) / f64(fps), frame
	}
	return
}

// The shares of the fitted scale playback steps down through when frames
// are missed, and the seconds at the full rate before a step back up.
PLAY_SCALES := [?]f32{1, 0.75, 0.5, 0.35, 0.25}
PLAY_STEADY :: 3

// One played second's rate (frames shown over the video's fps) moves the
// playback scale (`play_level`, see Preview_State).
@(private)
play_scale_adapt :: proc(pv: ^Preview_State, ratio: f64) {
	if pv.play_settling {
		pv.play_settling = false
		return
	}
	step := 0
	switch {
	case pv.play_step > 0 && ratio < pv.play_ratio * 1.05:
		// lower didn't help: back up, and stay
		pv.play_level -= 1
		pv.play_held = true
	case pv.play_step < 0 && ratio < 0.9:
		// higher misses frames: back down, and stay
		pv.play_level += 1
		pv.play_held = true
	case pv.play_held:
	case ratio < 0.9 && pv.play_level < len(PLAY_SCALES) - 1:
		pv.play_level += 1
		step = 1
	case ratio >= 0.98 && pv.play_level > 0:
		pv.play_steady += 1
		if pv.play_steady >= PLAY_STEADY {
			pv.play_level -= 1
			step = -1
		}
	case:
		pv.play_steady = 0
	}
	if step != 0 {
		pv.play_steady = 0
		pv.play_settling = true
	}
	pv.play_step = step
	pv.play_ratio = ratio
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
	natural := [View_Kind]f32{.Video = -1, .Timeline = timeline_height(app) * pv.dpi, .Watch = -1, .Image = -1, .Audio = -1}
	// What is sized from the window's font, once: the window's bars and a
	// leaf's tab bar.
	font_px := pv.font_size * pv.dpi
	pv.bar_height = math.floor(BAR_HEIGHT * font_px)
	workspace_measure(&pv.workspace, workspace_rect(pv, p), pv.dpi, tabs_height(font_px), natural)
	pv.rows_room = ROWS_AREA_MAX
	pv.timeline_axis = TIME_ALONG
	if area, shown := view_area(app, .Timeline); shown {
		ws := &pv.workspace
		vertical := timeline_vertical(ws, workspace_view(ws, workspace_shown(ws, .Timeline)).panel, area)
		pv.timeline_axis = timeline_axis(vertical)
		pv.rows_room = timeline_rows_room(app, pv.timeline_axis, area, pv.dpi)
	}
}

// The window above the controls and the status line, in pixels.
@(private)
workspace_rect :: proc(pv: ^Preview_State, p: ^platform.Platform) -> Workspace_Rect {
	h := f32(p.height) - 2 * pv.bar_height
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

// The window's input before the build: the keys (preview_key_input), a
// script dropped on the window or picked in the open-file dialog, and a
// dragged tab's release (RAD's drag drop: the drop sites take it this
// frame).
@(private)
preview_input :: proc(app: ^App_State, s: ^ui.State, p: ^platform.Platform) {
	preview_key_input(app, s, p)
	for path in platform.dropped_files(p) {
		if strings.has_suffix(strings.to_lower(path, context.temp_allocator), ".lua") {
			command_push(&app.commands, .Script_Open, {path = path})
			break
		}
	}
	drag_input(app, s)
}

// A dragged tab's release (the left button's, as the UI's rows carry it):
// RAD's drop kickoff, before the build. With no drag, a view made for one that
// the button let go of first goes.
@(private)
drag_input :: proc(app: ^App_State, s: ^ui.State) {
	pv := &app.preview
	for a in s.actions.rows {
		if a.kind != .Mouse_Release || a.button != .Left do continue
		if pv.drag == .Dragging {
			pv.drag = .Dropping
		} else if pv.drag == .Null {
			for v, i in pv.workspace.views do if v.live && v.transient do command_push(&app.commands, .Row_View_Close, {view = View_Id(i + 1)})
		}
	}
}

COLOR_TEXT :: [4]u8{232, 236, 242, 255}
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

// Built front to back, as RAD Debugger's window: what is built first takes
// the pointer first and draws on top. First the lister (a floating view),
// then the workspace's panels, the controls and the status line. What the
// views left of the wheel with Control becomes the window's font size
// (RAD's top-level font size changing), and Cancel ends a tab's drag.
@(private)
preview_views :: proc(app: ^App_State, s: ^ui.State, p: ^platform.Platform) {
	pv := &app.preview
	dpi := p.dpi_scale
	files_open_update(app)
	if area, _ := view_area(app, .Video); pv.bare {
		video_view(app, s, dpi, area)
	} else {
		lister_view(app, s, dpi, workspace_rect(pv, p))
		// The window, laid out down it: the workspace's panels (at their
		// places in the tree), the controls and the status line.
		ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_pref_height(s, ui.pct(1)); ui.set_next_child_layout_axis(s, .Y)
		ui.push_parent(s, ui.build_box(s, {}, "###window"))
		ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_pref_height(s, ui.px(workspace_rect(pv, p).height))
		ui.push_parent(s, ui.build_box(s, {}, "###workspace"))
		panels_view(app, s, dpi)
		ui.pop_parent(s)
		controls_view(app, s, dpi)
		status_view(app, s, dpi)
		ui.pop_parent(s)
	}
	if pv.drag != .Null && ui.action_pressed(s, .Cancel) {
		preview_drag_end(app)
		ui.kill_action(s)
	}
	for &a in s.actions.rows {
		if a.consumed || a.kind != .Scroll || a.modifiers != {.Control} do continue
		a.consumed = true
		// RAD's: up a point up, down a point down, an event a step.
		if a.scroll_delta.y < 0 do command_push(&app.commands, .Font_Size_Increase)
		if a.scroll_delta.y > 0 do command_push(&app.commands, .Font_Size_Decrease)
	}
}

// The video: the worker's newest frame as a picture (picture_gestures), and a
// click toggles playback (a live board's takes none of it). Over it, what the
// worker is doing until the first frame shows, and a failed reload.
@(private)
video_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32, area: Workspace_Rect) {
	pv := &app.preview
	c := &app.commands
	ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_pref_height(s, ui.pct(1, 0)); ui.set_next_child_layout_axis(s, .Y)
	video := ui.build_box(s, {.Clickable, .Scroll, .Clip}, "###video")
	sig := ui.signal_from_box(s, video)
	id := workspace_find(&pv.workspace, .Video)
	if ui.pressed(sig) && !pv.bare do focus_panel(app, id)
	moved := !pv.live && picture_gestures(app, s, id, sig, video)
	if ui.clicked(sig) && !moved && !pv.live {
		command_push(c, .Present_Next if pv.present else .Playback_Toggle)
	}
	if pv.present && ui.right_clicked(sig) {
		command_push(c, .Present_Previous)
	}
	// Focused, it takes the keys' events as the preview's commands (a
	// frame, a second, the volume, a scene, the ends, a mark), as RAD's
	// views take what their focus gets (a live board's takes none).
	if !pv.live {
		ui.push_focus(s, .On)
		view_events_take(app, s)
		ui.pop_focus(s)
	}
	// Over it, laid out down from its top a little in (centred while no
	// frame shows): what the worker is doing, a failed reload.
	ui.push_parent(s, video)
	defer ui.pop_parent(s)
	ui.spacer(s, ui.px(12 * dpi if pv.video_texture != nil else area.height * 0.5 - 16 * dpi))
	label_row :: proc(s: ^ui.State, dpi: f32, text: string, bg, fg: [4]u8) {
		ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_pref_height(s, ui.children_sum()); ui.set_next_child_layout_axis(s, .X)
		ui.push_parent(s, ui.build_box(s, {}, ""))
		ui.spacer(s, ui.px(12 * dpi))
		ui.set_next_bg_color(s, bg)
		ui.set_next_text_color(s, fg)
		ui.set_next_pref_width(s, ui.text_content(12 * dpi))
		ui.set_next_pref_height(s, ui.text_content(10 * dpi))
		ui.build_box(s, {.Draw_Background, .Draw_Text}, text)
		ui.pop_parent(s)
	}
	// a live board shows the last good frame while it reloads
	if (pv.loading && !pv.live) || pv.video_texture == nil {
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
		label_row(s, dpi, fmt.tprintf("%s###loading", label), {30, 34, 44, 235}, {225, 230, 240, 255})
	}
	// (a live board's goes to stderr only: the worker's warning)
	if pv.reload_error != "" && !pv.live {
		first_line := pv.reload_error
		if i := strings.index_byte(first_line, '\n'); i >= 0 {
			first_line = first_line[:i]
		}
		label_row(s, dpi, fmt.tprintf("reload failed: %s###reload_error", first_line), {70, 24, 28, 235}, {255, 220, 220, 255})
	}
	// Built last, it lies under them.
	if v := workspace_view(&pv.workspace, id); v != nil && pv.video_texture != nil && !pv.blackout && pv.video_size.x > 0 && pv.video_size.y > 0 && area.width > 0 && area.height > 0 {
		// (`area` as the layout places its box this frame, on whole pixels)
		dim := [2]f32{math.floor(area.x + area.width) - math.floor(area.x), math.floor(area.y + area.height) - math.floor(area.y)}
		lo, hi := picture_rect({f32(pv.video_size.x), f32(pv.video_size.y)}, dim, v.shown)
		picture_box(s, {pv.renderer, pv.video_texture, pv.video_size, {}, lo, hi}, {}, "###video_picture")
	}
}

// The transport controls across the window, under the panels: a media
// player's bar (RAD has none; its layout approved) laid out by RAD's passes
// (a children-sum column, a WidthFill column): at the left the playback
// group (play/pause, the time, loop) and the bookmark (an icon); at the
// right Reload, the sound (an icon) and its volume (the timeline's zoom is
// the timeline's, at its ruler's end: timeline_zoom_view). Text buttons fill the
// bar's height and are as wide as their text and RAD's padding (its menu
// bar's text_dim(20), its text padding three tenths of an em), drawn inside
// half an em of the bar's height and a quarter em across (visual margins);
// icon buttons are square at the bar's height, drawn inside half an em (RAD's
// top-bar icon buttons), and show their command and its key when hovered
// (RAD's command tooltip, above them).
@(private)
controls_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32) {
	pv := &app.preview
	c := &app.commands
	fs := ui.top_font_size(s)
	h := pv.bar_height
	ui.set_next_pref_width(s, ui.fill()); ui.set_next_pref_height(s, ui.px(h)); ui.set_next_child_layout_axis(s, .X)
	ui.set_next_bg_color(s, COLOR_PANEL_BG)
	ui.set_next_corner_radius(s, 0)
	ui.push_parent(s, ui.build_box(s, {.Draw_Background}, "###controls"))
	defer ui.pop_parent(s)
	ui.push_pref_height(s, ui.pct(1))
	defer ui.pop_pref_height(s)
	margin := [2]f32{math.floor(fs * 0.25), math.floor(fs * 0.5)}
	button :: proc(s: ^ui.State, text: string, margin: [2]f32, on := false) -> bool {
		ui.set_next_pref_width(s, ui.text_content(20, 1))
		ui.set_next_visual_margin(s, margin)
		ui.set_next_text_padding(s, math.floor(ui.top_font_size(s) * 0.3))
		if on do ui.set_next_bg_color(s, s.theme.active)
		return ui.clicked(ui.button(s, text))
	}
	// A narrow window drops the buttons that have keys (D, R) and the scene
	// from the time.
	narrow := f32(s.p.width) / dpi < 1000

	// Left: play / pause, the time, loop, the bookmark.
	ui.set_next_pref_width(s, ui.children_sum()); ui.set_next_child_layout_axis(s, .X)
	ui.push_parent(s, ui.build_box(s, {}, "###controls_left"))
	ui.spacer(s, ui.px(math.floor(fs * 0.5)))
	space: Key_Binding // play / pause is Space's accept in the video or the timeline
	for b in PREVIEW_KEYS do if b.kind == .Accept && b.key == .Space do space = b
	if icon_button(s, .Pause if pv.playing else .Play, "###play", h, false, "Pause" if pv.playing else "Play", space) do command_push(c, .Playback_Toggle)
	clock := fmt.tprintf("%s · f %d", clock_label(app, pv.frame), pv.frame) if narrow else time_label(app, pv.frame)
	ui.set_next_pref_width(s, ui.text_content(math.floor(fs), 1)); ui.set_next_text_align(s, .Center)
	ui.build_box(s, {.Draw_Text}, fmt.tprintf("%s###time", clock))
	loop, _ := command_binding(.Loop_Toggle)
	if icon_button(s, .Loop, "###loop", h, pv.loop, "Loop", loop) do command_push(c, .Loop_Toggle)
	// The bookmark: on while one is set, its time in its tooltip.
	mark, _ := command_binding(.Bookmark_Toggle)
	mark_tip := "Mark" if pv.bookmark < 0 else fmt.tprintf("Mark · %s", clock_label(app, pv.bookmark))
	if icon_button(s, .Bookmark, "###bookmark", h, pv.bookmark >= 0, mark_tip, mark) do command_push(c, .Bookmark_Toggle)
	ui.pop_parent(s)

	// Right: reload, the sound and its volume.
	ui.set_next_pref_width(s, ui.fill()); ui.set_next_child_layout_axis(s, .X)
	ui.push_parent(s, ui.build_box(s, {}, "###controls_right"))
	ui.spacer(s, ui.fill())
	if !narrow && button(s, "Reload###reload", margin) do command_push(c, .Script_Reload, {flag = true})
	// The sound: a speaker, its waves or (muted, on) an X.
	mute, _ := command_binding(.Mute_Toggle)
	if icon_button(s, .Muted if pv.muted else .Sound, "###mute", h, pv.muted, "Unmute" if pv.muted else "Mute", mute) do command_push(c, .Mute_Toggle)
	// The volume slider, eight ems long, its middle the bar's.
	slider_h := math.floor(fs * 0.6)
	ui.set_next_pref_width(s, ui.px(math.floor(fs * 8))); ui.set_next_child_layout_axis(s, .Y)
	ui.push_parent(s, ui.build_box(s, {}, "###volume_column"))
	ui.spacer(s, ui.px((h - slider_h) * 0.5))
	ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_pref_height(s, ui.px(slider_h))
	ui.set_next_corner_radius(s, 0)
	// The volume as shown (0 while muted); a change sends the command.
	volume: f32 = 0 if pv.muted else pv.volume
	before := volume
	ui.slider(s, &volume, 0, 1, "###volume", slider_h)
	ui.pop_parent(s)
	if volume != before do command_push(c, .Volume_Set, {scalar = f64(volume)})
	ui.spacer(s, ui.px(math.floor(fs * 0.5)))
	ui.pop_parent(s)
}

// An icon button, square at the bar's height `h` and drawn inside half an
// em, rounded an em (RAD's top-bar icon buttons); `on`, in the active
// colour. Hovered, its command's tooltip.
@(private)
icon_button :: proc(s: ^ui.State, icon: Preview_Icon, key: string, h: f32, on: bool, title: string, binding: Key_Binding) -> bool {
	fs := ui.top_font_size(s)
	icons := PREVIEW_ICONS
	ui.set_next_pref_width(s, ui.px(h))
	ui.set_next_visual_margin(s, {math.floor(fs * 0.5), math.floor(fs * 0.5)})
	ui.set_next_corner_radius(s, fs); ui.set_next_icon(s, icons[icon])
	if on do ui.set_next_bg_color(s, s.theme.active)
	b := ui.build_box(s, {.Clickable, .Draw_Background, .Draw_Border, .Draw_Icon, .Draw_Hot_Effects, .Draw_Active_Effects}, key)
	sig := ui.signal_from_box(s, b)
	if ui.hovering(sig) do command_tooltip(s, b, title, binding)
	return ui.clicked(sig)
}

// RAD's command tooltip (its hover regs' command name): the command's name
// and its key's chip in a row, a floating view's colours, over everything
// (the tooltip root) just above `anchor` (RAD's sits below and is pushed
// back into the window: here the bar is the window's bottom).
@(private)
command_tooltip :: proc(s: ^ui.State, anchor: ^ui.Box, title: string, binding: Key_Binding) {
	fs := ui.top_font_size(s)
	row := math.floor(fs * 2)
	ui.tooltip_begin(s)
	defer ui.tooltip_end(s)
	ui.set_next_fixed_x(s, anchor.rect.min.x); ui.set_next_fixed_y(s, anchor.rect.min.y - row - math.floor(fs * 0.5))
	ui.set_next_pref_width(s, ui.children_sum()); ui.set_next_pref_height(s, ui.px(row)); ui.set_next_child_layout_axis(s, .X)
	ui.set_next_bg_color(s, s.theme.floating); ui.set_next_border_color(s, s.theme.floating_border)
	ui.set_next_corner_radius(s, math.floor(fs * 0.3))
	ui.push_parent(s, ui.build_box(s, {.Draw_Background, .Draw_Border}, "###command_tooltip"))
	defer ui.pop_parent(s)
	ui.push_pref_height(s, ui.pct(1))
	defer ui.pop_pref_height(s)
	ui.spacer(s, ui.px(math.floor(fs * 0.5)))
	ui.set_next_pref_width(s, ui.text_content(5, 1))
	ui.build_box(s, {.Draw_Text}, fmt.tprintf("%s###command_tooltip_title", title))
	binding_chip(s, binding)
	ui.spacer(s, ui.px(math.floor(fs * 0.5)))
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
	errors, warnings := pv.tables.errors, pv.tables.warnings
	problems := "no problems"
	if errors + warnings > 0 {
		problems = fmt.tprintf("%d errors, %d warnings", errors, warnings)
	}
	hover := ""
	if pv.hover_valid {
		hover = fmt.tprintf(" · hover %s", time_label(app, pv.hover_frame))
	}
	work := ""
	switch {
	case pv.loading:
		work = fmt.tprintf(" · loading %.1f s…", pv.load_seconds)
	case pv.sounds_loading:
		work = " · loading sounds (playback waits)…"
	case pv.rendering || pv.shown_frame != pv.frame:
		work = " · rendering…"
	}
	// The preview's resolution against the video's, so a scaled preview shows.
	size := ""
	if pv.timeline.width > 0 && pv.shown_size.x > 0 {
		size = fmt.tprintf(" · %d×%d (%d%% of %d×%d)", pv.shown_size.x, pv.shown_size.y, int(math.round(f64(pv.shown_size.x) * 100 / f64(pv.timeline.width))), pv.timeline.width, pv.timeline.height)
	}
	text := fmt.tprintf(
		"%s%s · %.2f ms/frame, latency %.1f ms, %.0f fps%s · %s%s%s%s%s###status_text",
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
	// RAD's bottom bar: a bar tall, its status an em in, at its text's
	// width (RAD's text_dim(10)), in the window's font: the weak colour, a
	// warning's or an error's while the frames shown have them. A click
	// shows the problems.
	ui.set_next_pref_width(s, ui.fill()); ui.set_next_pref_height(s, ui.px(pv.bar_height)); ui.set_next_child_layout_axis(s, .X)
	ui.set_next_bg_color(s, {18, 19, 24, 255})
	ui.set_next_corner_radius(s, 0)
	bar := ui.build_box(s, {.Clickable, .Draw_Background, .Draw_Hot_Effects}, "###status")
	ui.push_parent(s, bar)
	ui.spacer(s, ui.px(math.floor(ui.top_font_size(s))))
	ui.set_next_text_color(s, COLOR_ERROR if errors > 0 else (COLOR_WARNING if warnings > 0 else COLOR_TEXT_DIM))
	ui.set_next_text_align(s, .Left); ui.set_next_text_padding(s, 0)
	ui.set_next_pref_width(s, ui.text_content(10, 1)); ui.set_next_pref_height(s, ui.pct(1))
	ui.build_box(s, {.Draw_Text}, text)
	ui.pop_parent(s)
	if ui.clicked(ui.signal_from_box(s, bar)) {
		command_push(&app.commands, .Watch_Show, {spec = "video:problems"})
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


// The window loop's wait after a frame (`shown`: render.end_frame's). A
// window nobody sees sleeps a while; a frame not shown, briefly (a
// swapchain image comes back soon). A mailbox window's frames are spaced a
// display refresh apart (as FIFO's vsync wait spaces them): it sleeps to
// the next frame's start (`next_ns`), a refresh of the window's display
// (the platform's, kept as the window moves displays).
@(private = "file")
preview_pace :: proc(p: ^platform.Platform, shown: bool, next_ns: ^u64) {
	if sdl.GetWindowFlags(p.window) & {.HIDDEN, .MINIMIZED, .OCCLUDED} != {} {
		sdl.Delay(16)
		return
	}
	if p.present_mode != .MAILBOX {
		if !shown {
			sdl.Delay(2)
		}
		return
	}
	period := u64(p.refresh_ns)
	now := sdl.GetTicksNS()
	if next_ns^ > now {
		sdl.DelayPrecise(next_ns^ - now)
		now = next_ns^
	}
	next_ns^ += period
	if next_ns^ <= now {
		next_ns^ = now + period // late: start again from now, no burst to catch up
	}
}
