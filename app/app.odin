package onimite_app

import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:os"
import "core:thread"
import om "../onimite"
import enc "../encode"
import script "../script"
import "../speech"
import vg "deps:ovg"
import vgsdl "deps:ovg/sdlgpu"

App_State :: struct {
	commands:       Command_Storage,
	script:         script.Script,
	script_loaded:  bool,
	// What Script_Load was given (owned), for a batch's per-row loads: the
	// script, its arguments and the --props file's text ("" = none).
	script_path:    string,
	script_args:    []string,
	props_text:     string,
	// The media folder: --media, else media/ beside the script (owned);
	// the preview's worker loads it too.
	media_dir:      string,
	media:          om.Media,
	// Script_Load loaded the media (not with .No_Media).
	media_loaded:   bool,
	// Decode threads behind the media's video clips.
	video:          enc.Video_Decoders,
	renderer:       om.Renderer,
	renderer_ready: bool,
	renderer_scale: f32,
	// Output scale requested with --scale (`scale_given`); commands have
	// their own default otherwise (strip 480 px cells, onion and draft 0.5).
	scale:          f32,
	scale_given:    bool,
	// Print JSON documents instead of text.
	json:           bool,
	// Where `emit` and `failure_print` write (nil: stdout): the MCP server's
	// call result.
	out:            ^strings.Builder,
	// Draw with the CPU instead of the GPU.
	software:       bool,
	// Bytes of decoded images every media keeps (--image-cache).
	image_budget:   int,
	gpu:            vgsdl.SDL_Backend,
	gpu_ready:      bool,
	// The GPU 3D layers render on (on `gpu`'s device).
	gpu3d:          om.View3d_Gpu,
	// The GPU could not be set up: renderers draw on the CPU (the choice
	// in `software` stays the user's).
	gpu_failed:     bool,
	// The preview window's device, shared with the GPU backend (nil: headless).
	gpu_device:     rawptr,
	preview:        Preview_State,
	// Debug_Set: time and log what runs; log the clip frames shown.
	debug:          bool,
	clip_log:       bool,
	// Process exit status: 1 for failures, 2 for inspect errors.
	exit_code:      int,
	// Why the command failed (`fail`), its strings in the arena.
	failure:        Failure,
	failure_arena:  virtual.Arena,
	// The application's task pool for fork-join work (media decoding, frame
	// building and PNG writing in renders, native encoder slices, shader
	// bands on the CPU), lent to the libraries; see onimite/pool.odin. Nil
	// with --threads 1: everything runs on its caller.
	pool:           ^thread.Pool,
	pool_storage:   thread.Pool,
}

app_init :: proc(app: ^App_State) {
	app.commands = command_storage_make()
	app.scale = 1
	app.image_budget = om.IMAGE_BUDGET_DEFAULT
	_ = virtual.arena_init_growing(&app.failure_arena)
	enc.video_decoders_init(&app.video)
	media_open(&app.media, app.image_budget, &app.video)
	pool_set_threads(app, 0)
	speech.set_log(speech_log, false)
}

// say()'s progress (ottis's downloads, lines being synthesized) on stderr.
@(private)
speech_log :: proc(message: string) {
	fmt.eprintln(message)
}

// A media ready to load (every one the app makes is set up here): the
// image budget and the host's decoders, for the audio formats the core
// lacks and video clips on `video` (nil: none).
media_open :: proc(m: ^om.Media, budget: int, video: ^enc.Video_Decoders) {
	om.media_init(m)
	m.cache.budget = budget
	m.decoder = enc.audio_decoder
	if video != nil {
		m.videos.source = enc.video_source(video)
	}
}

// The task pool for `threads` threads in all (0: one per core): the caller
// plus `threads - 1` workers. One thread means no pool.
@(private)
pool_set_threads :: proc(app: ^App_State, threads: int) {
	if app.pool != nil {
		thread.pool_finish(app.pool)
		thread.pool_destroy(app.pool)
		app.pool = nil
	}
	n := threads if threads > 0 else os.get_processor_core_count()
	if n <= 1 {
		return
	}
	thread.pool_init(&app.pool_storage, os.heap_allocator(), n - 1)
	thread.pool_start(&app.pool_storage)
	app.pool = &app.pool_storage
}

app_destroy :: proc(app: ^App_State) {
	if app.renderer_ready {
		om.renderer_destroy(&app.renderer)
	}
	om.view3d_gpu_destroy(&app.gpu3d)
	if app.gpu_ready {
		vgsdl.destroy(&app.gpu)
	}
	script.unload(&app.script)
	script_inputs_clear(app)
	virtual.arena_destroy(&app.failure_arena)
	om.media_destroy(&app.media)
	enc.video_decoders_destroy(&app.video)
	command_storage_destroy(&app.commands)
	pool_set_threads(app, 1)
}

DISPATCH_PASS_LIMIT :: 16

// Applies queued rows in order, including rows they push, until none is
// left. The pass limit only guards against a row that re-queues itself. A
// row that fails is reported here (exit code 1) and the rows after it,
// except loads, are skipped.
dispatch :: proc(app: ^App_State) {
	for _ in 0 ..< DISPATCH_PASS_LIMIT {
		if len(app.commands.pending.rows) == 0 {
			break
		}
		dispatch_pass(app)
	}
}

// One pass over the rows pushed so far. Rows pushed while it runs wait for
// the next pass; a handler may run passes of its own (the preview window
// applies its rows each window frame).
@(private)
dispatch_pass :: proc(app: ^App_State) {
	batch := command_batch_take(&app.commands)
	defer command_batch_return(&app.commands, &batch)
	for queued in batch.rows {
		row := command_row_of(&batch, queued)
		if app.exit_code == 1 && row.kind != .Script_Load {
			// A failed load leaves nothing to act on.
			continue
		}
		err := command_validate(app, &row)
		if err == nil {
			err = command_apply(app, row)
		}
		if err != nil {
			failure_print(app)
			failure_clear(app)
		}
	}
}

// Runs a row's handler; the row is valid where it runs (command_validate).
@(private)
command_apply :: proc(app: ^App_State, row: Command_Row) -> Error {
	regs := row.regs
	switch row.kind {
	case .None:
		unreachable()
	case .Script_Load:
		return script_load(app, regs)
	case .Threads_Set:
		pool_set_threads(app, regs.count)
	case .Scale_Set:
		app.scale = f32(regs.scalar) if regs.scalar > 0 else 1
		app.scale_given = regs.scalar > 0
	case .Output_Set:
		app.json = regs.flag
	case .Backend_Set:
		app.software = regs.flag
	case .Debug_Set:
		app.debug = .Timing in regs.flags
		app.clip_log = .Clip_Log in regs.flags
		speech.set_log(speech_log, app.debug)
	case .Image_Cache_Set:
		app.image_budget = regs.count << 20
		app.media.cache.budget = app.image_budget
	case .Show:
		return show_print(app, regs)
	case .Timeline:
		return timeline_print(app, regs)
	case .Frame:
		return frames_export(app, regs)
	case .Strip:
		return strip_export(app, regs)
	case .Onion:
		return onion_export(app, regs)
	case .Snapshot:
		return snapshot_check(app, regs)
	case .Inspect:
		return inspect(app, regs)
	case .Render:
		return video_render(app, regs)
	case .Batch_Render:
		return batch_render(app, regs)
	case .Audio_Analyze:
		return audio_analyze(app, regs)
	case .Audio_Render:
		return audio_render(app, regs)
	case .Audio_At:
		return audio_at(app, regs)
	case .Audio_Onsets:
		return audio_onsets(app, regs)
	case .Probe:
		return probe_print(app, regs)
	case .Preview:
		return preview_open(app, regs)
	case .Update:
		return update_run(app, regs)
	case .Playback_Toggle, .Playback_Set, .Frame_Set, .Frame_Step, .Frame_Start, .Seconds_Step, .Scene_Step, .Script_Reload, .Script_Open, .File_Dialog, .Loop_Toggle, .Loop_Set, .Mute_Toggle, .Mute_Set, .Volume_Set, .Volume_Step, .Bookmark_Toggle, .Timeline_Zoom, .Timeline_Fit, .Timeline_Pan, .Timeline_Toggle, .Timeline_Row_Toggle, .Timeline_Rows_Scroll, .Fullscreen_Toggle, .Cursor_Hover, .Dismiss, .Watch_Show, .Watch_Section_Set, .Watch_Scroll, .Problem_Step, .Quit:
		preview_apply(app, row.kind, regs)
	case .Panel_Split, .Panel_Close, .Panel_Resize, .View_Open, .View_Close, .View_Select, .View_Move, .Lister_Open, .Lister_Filter, .Lister_Close:
		workspace_apply(&app.preview.workspace, row.kind, regs)
	}
	return nil
}

// ---- handlers ---------------------------------------------------------------------------

@(private)
script_load :: proc(app: ^App_State, regs: Command_Regs) -> Error {
	script_inputs_clear(app)
	app.script_path = strings.clone(regs.path)
	args := strings.split(regs.args, "\n", context.temp_allocator) if regs.args != "" else nil
	app.script_args = make([]string, len(args))
	for a, i in args {
		app.script_args[i] = strings.clone(a)
	}
	if regs.props != "" {
		data, err := os.read_entire_file(regs.props, context.allocator)
		if err != nil {
			return fail(app, {code = .Props_Read, path = regs.props, os = err})
		}
		app.props_text = string(data)
	}
	// The media first: scripts measure text with its fonts at load.
	app.media_dir = strings.clone(regs.media if regs.media != "" else default_media_dir(regs.path))
	app.media_loaded = .No_Media not_in regs.flags
	if app.media_loaded {
		dir := app.media_dir
		if os.is_dir(dir) {
			if om.media_load_dir(&app.media, dir, app.pool) != nil {
				fmt.eprintfln("can not read media directory %s", dir)
			}
		} else if regs.media != "" {
			return fail(app, {code = .No_Media_Dir, path = dir})
		}
	}
	if .No_Script not_in regs.flags {
		return script_reload(app, "")
	}
	return nil
}

// (Re)loads the script with the inputs Script_Load was given; `row` is a
// JSON object merged over the --props file (a batch row, "" = none).
@(private)
script_reload :: proc(app: ^App_State, row: string) -> Error {
	if app.renderer_ready {
		om.renderer_destroy(&app.renderer)
		app.renderer_ready = false
	}
	app.script_loaded = false
	props := make([dynamic]string, context.temp_allocator)
	if app.props_text != "" {
		append(&props, app.props_text)
	}
	if row != "" {
		append(&props, row)
	}
	// The main load synthesizes the spoken lines the store lacks (the
	// preview's too, before its window opens); frame builders and the
	// preview's worker read them from the store.
	loaded := script.load(&app.script, app.script_path, app.script_args, &app.media, nil, props[:])
	if loaded != nil {
		return fail(app, {code = .Script, script = app.script.failure})
	}
	app.script_loaded = true
	warn_load(&app.script, app_media(app))
	return nil
}

// The media when Script_Load loaded it, else nil (what the load found then
// says nothing about it).
app_media :: proc(app: ^App_State) -> ^om.Media {
	return &app.media if app.media_loaded else nil
}

@(private)
script_inputs_clear :: proc(app: ^App_State) {
	delete(app.script_path)
	for a in app.script_args {
		delete(a)
	}
	delete(app.script_args)
	delete(app.props_text)
	delete(app.media_dir)
	app.script_path, app.script_args, app.props_text, app.media_dir = "", nil, "", ""
}

// The renderer at the current scale, rebuilt when the scale changes.
@(private)
renderer :: proc(app: ^App_State, scale: f32) -> (^om.Renderer, Error) {
	if app.renderer_ready && app.renderer_scale != scale {
		om.renderer_destroy(&app.renderer)
		app.renderer_ready = false
	}
	if !app.renderer_ready {
		backend: Maybe(vg.Backend)
		if !app.software && !app.gpu_ready && !app.gpu_failed {
			if err := vgsdl.init(&app.gpu, auto_cast app.gpu_device); err != nil {
				warn("no GPU (%v), drawing on the CPU", err)
				app.gpu_failed = true
			} else {
				app.gpu_ready = true
				app.gpu3d.device = app.gpu.device
			}
		}
		if app.gpu_ready && !app.software {
			backend = vgsdl.backend(&app.gpu)
		}
		if err := om.renderer_init(&app.renderer, &app.script.video, &app.media, scale, backend); err != nil {
			return nil, fail(app, {code = .Renderer, render = err})
		}
		app.renderer.pool = app.pool
		if backend != nil {
			app.renderer.gpu3d = &app.gpu3d
		}
		app.renderer_ready = true
		app.renderer_scale = scale
	}
	return &app.renderer, nil
}

// PNG from premultiplied RGBA8 (straight alpha in the file).
write_png :: proc(path: string, pixels: []u8, w, h: u32) -> vg.Error {
	return vg.write_png(path, om.straight_alpha(pixels), w, h)
}
