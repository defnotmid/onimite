package onimite_app

import "core:reflect"
import "core:strings"

// Every action is a command row, as in paf (after raddbg): the command line,
// the MCP server and the preview window's input and widgets push rows;
// `dispatch` applies them in one place, draining until no row is left. Each
// kind's row in COMMAND_KINDS (raddbg's command kind table) says what it
// does, where it runs, what it needs and how users meet it; `dispatch`
// checks a row against it (`command_validate`) before its handler sees it.

Command_Kind :: enum u8 {
	None,
	// The command line's commands and the MCP server's tools, in the order
	// the help lists them; their names are the kinds' (`command_name`).
	Render,
	Frame,
	Strip,
	Onion,
	Snapshot,
	Show,
	Timeline,
	Inspect,
	Audio_Render,
	Audio_Analyze,
	Audio_At,
	Audio_Onsets,
	Preview,
	Probe,
	Update,
	// The settings and the load they push before them, and a batch.
	Script_Load,
	Output_Set,
	Backend_Set,
	Scale_Set,
	Image_Cache_Set,
	Threads_Set,
	Debug_Set,
	Batch_Render,
	// The preview window (preview.odin).
	Playback_Toggle,
	Playback_Set,
	Frame_Set,
	Frame_Step,
	Frame_Start,
	Seconds_Step,
	Scene_Step,
	Script_Reload,
	Script_Open,
	File_Dialog,
	Loop_Toggle,
	Loop_Set,
	Mute_Toggle,
	Mute_Set,
	Volume_Set,
	Volume_Step,
	Bookmark_Toggle,
	Timeline_Zoom,
	Timeline_Fit,
	Timeline_Pan,
	Timeline_Follow,
	Timeline_Toggle,
	Timeline_Row_Toggle,
	Timeline_Rows_Scroll,
	Video_Zoom,
	Video_Pan,
	Video_Fit,
	Fullscreen_Toggle,
	Cursor_Hover,
	Dismiss,
	Watch_Show,
	Watch_Section_Set,
	Watch_Scroll,
	Problem_Step,
	Quit,
	// The preview's workspace (preview_workspace.odin): panels and their views.
	Panel_Split,
	Panel_Close,
	Panel_Resize,
	View_Open,
	View_Close,
	View_Select,
	View_Move,
	Lister_Open,
	Lister_Filter,
	Lister_Close,
}

// Where a kind runs: what must be there before its handler sees a row
// (`command_validate`).
Command_Domain :: enum u8 {
	// Anywhere: what later rows read (the settings, the script load).
	Settings,
	// Anywhere, without a script.
	Tool,
	// After Script_Load loaded the script.
	Script,
	// After a Script_Load row (the media only): a batch loads the script
	// once per row.
	Script_Inputs,
	// While the preview window runs (preview_apply).
	Preview,
	// The preview window's panels and views, while it runs (workspace_apply).
	Workspace,
}

// The domains as a failure names them: "{kind} runs only {phrase}".
@(rodata)
COMMAND_DOMAIN_TEXT := [Command_Domain]string {
	.Settings      = "",
	.Tool          = "",
	.Script        = "after a script loaded",
	.Script_Inputs = "after a script load row",
	.Preview       = "in the preview window",
	.Workspace     = "in the preview window",
}

Command_Kind_Flag :: enum u8 {
	// A command of the command line, named `command_cli_name`.
	Command_Line,
	// A tool of the MCP server, named `command_name`.
	Mcp_Tool,
}
Command_Kind_Flags :: bit_set[Command_Kind_Flag;u8]

FRONT :: Command_Kind_Flags{.Command_Line, .Mcp_Tool}

// The images an MCP result carries: none, every frame's `path`, the
// document's `output`, its `waveform`.
Mcp_Images :: enum u8 {
	None,
	Frames,
	Output,
	Waveform,
}

Command_Descriptor :: struct {
	// What it does, with which registers.
	help:     string,
	domain:   Command_Domain,
	flags:    Command_Kind_Flags,
	// The string registers its rows must fill.
	needs:    bit_set[Regs_Text],
	// What users are told: the help, the MCP tool, the lister.
	about:    string,
	// Its name in the preview's lister.
	label:    string,
	// A command's: its arguments, a struct whose fields' tags say how each
	// fills the rows (options.odin); its registers' defaults; another name
	// on the command line; what the usage error says is missing when its
	// positional argument is ("": it is optional); what an MCP result
	// carries and the rest of the tool's description.
	args:     typeid,
	regs:     Command_Regs,
	alias:    string,
	missing:  string,
	images:   Mcp_Images,
	mcp_note: string,
}

@(rodata)
COMMAND_KINDS := [Command_Kind]Command_Descriptor {
	.None = {},
	.Render = {
		help = "regs.spec a range, regs.path the output (.mp4, or a directory for PNGs), regs.option codec (0 H.264, 1 H.265), regs.count qp (0 default), .Native / .Draft in regs.flags",
		domain = .Script, flags = FRONT, args = Render_Args,
		about = "the video to a file (.mp4 with the audio mix, or a directory of PNGs)",
	},
	.Frame = {
		help = "regs.spec comma-separated frame specs, regs.path the output directory, .Svg in regs.flags: an SVG next to every PNG",
		domain = .Script, flags = FRONT, needs = {.Spec}, args = Frame_Args, alias = "frames", missing = "at least one time spec", images = .Frames,
		about = "single frames to PNG with the problems found in them",
		mcp_note = "The PNGs come back as images.",
	},
	.Strip = {
		help = "regs.spec a range (\"\" = everything), regs.count frames, regs.columns, regs.width (cell px), regs.path the PNG",
		domain = .Script, flags = FRONT, args = Strip_Args, images = .Output,
		about = "a labelled contact sheet of evenly spaced frames",
		mcp_note = "The PNG comes back as an image.",
	},
	.Onion = {
		help = "regs.spec a range, regs.count frames, regs.path the PNG",
		domain = .Script, flags = FRONT, needs = {.Spec}, args = Onion_Args, missing = "a range", images = .Output,
		about = "frames blended into one image, later ones stronger: motion at a glance",
		mcp_note = "The PNG comes back as an image.",
	},
	.Snapshot = {
		help = "regs.spec frame specs, regs.path the snapshot directory, regs.threshold, regs.ratio, .Update in regs.flags",
		domain = .Script, flags = FRONT, needs = {.Spec}, args = Snapshot_Args, missing = "at least one time spec",
		about = "compare frames with approved PNGs (visual regression); fails when a frame differs",
	},
	.Show = {
		help = "regs.spec a path (\"\" = the video), regs.at a time spec for what changes over time, regs.count the page (1-based)",
		domain = .Script, flags = FRONT, args = Show_Args,
		about = "one thing in the video, its fields and its children, a page at a time: the video, scenes, scene/Race, cue/drop, buses, bus/sfx, track/12, clip/tick_1900, says, say/intro, say/intro/3 (a spoken word and when it is said), media, media/logo.png, fonts, bodies, body/ball (physics), nodes, node/scenes/race.lua:19[2] (what drew it)",
	},
	.Timeline = {
		help = "regs.spec a range: only what happens in it (\"\" = everything)",
		domain = .Script, flags = FRONT, args = Timeline_Args,
		about = "scenes, duration, audio tracks and sync points",
	},
	.Inspect = {
		help = "regs.spec a range, regs.every (a duration spec), regs.option fail-on (Fail_On), .All_Frames / .Info in regs.flags",
		domain = .Script, flags = FRONT, args = Inspect_Args,
		about = "problems: missing media and fonts, clipped or overlapping text, NaN, script errors, unused options, cues that drift, sounds off the music's beat, physics bodies that overlap, leave or never settle; fails at the fail-on level",
	},
	.Audio_Render = {
		help = "regs.spec a range, regs.path the WAV, .Float in regs.flags; regs.track one track (\"\" = the mix)",
		domain = .Script, flags = FRONT, args = Audio_Render_Args,
		about = "the mix (or one track) to a stereo WAV",
	},
	.Audio_Analyze = {
		help = "regs.spec a range; regs.path a waveform PNG (\"\" = none); regs.track one track (\"\" = the mix)",
		domain = .Script, flags = FRONT, args = Audio_Analyze_Args, images = .Waveform,
		about = "loudness, true peak, clipping, silence, loudness per scene and over time",
		mcp_note = "The waveform PNG comes back as an image.",
	},
	.Audio_At = {
		help = "regs.spec frame specs; regs.track one track (\"\" = all)",
		domain = .Script, flags = FRONT, needs = {.Spec}, args = Audio_At_Args, missing = "at least one time spec",
		about = "which tracks play at the given times, where in their files, how loud",
	},
	.Audio_Onsets = {
		help = "regs.spec a range, regs.ratio the weakest strength listed (0 = all); regs.track one track (\"\" = the mix)",
		domain = .Script, flags = FRONT, args = Audio_Onsets_Args, regs = {ratio = 0.1},
		about = "where sounds start (time, strength 0..1) and the beat (BPM, first beat)",
	},
	.Preview = {
		help = "opens the window and runs it until it closes: regs.spec the start frame, .Paused / .No_Loop / .Mute in regs.flags, regs.count window frames to exit after (0 = never); for measurements, regs.path a PNG of the last window frame and regs.args scripted input (`preview_drive`)",
		domain = .Script, flags = FRONT, args = Preview_Args,
		about = "a window that plays the video with sound and reloads when the script or media change",
		mcp_note = "It opens for the user and the call returns at once; the window stays open (one per script).",
	},
	.Probe = {
		help = "regs.args media files, one per line: their streams (no script)",
		domain = .Tool, flags = FRONT, needs = {.Args}, args = Probe_Args, missing = "a media file",
		about = "the streams of media files (container, video, audio)",
	},
	.Update = {
		help = "regs.flag: only check for a newer release (update.odin)",
		domain = .Tool, flags = FRONT, args = Update_Args,
		about = "replace this onimite with the latest release, checked against the release's SHA256SUMS",
		mcp_note = "The running server keeps the old version: restart the app (Claude Desktop: quit and reopen it) to use the new one.",
	},
	.Script_Load = {
		help = "regs.path the script; regs.media a media directory (\"\" = `media/` beside the script); regs.props a JSON file of props (\"\" = none); .No_Media in regs.flags: the script only; .No_Script: the media only (a batch loads the script per row)",
		domain = .Settings,
	},
	.Output_Set = {help = "regs.flag: print one JSON document per command instead of text", domain = .Settings},
	.Backend_Set = {help = "regs.flag: draw on the CPU instead of the GPU", domain = .Settings},
	.Scale_Set = {help = "regs.scalar output scale for later renders (0 = not given)", domain = .Settings},
	.Image_Cache_Set = {help = "regs.count MB of decoded images the media keeps (least recently used freed first)", domain = .Settings},
	.Threads_Set = {help = "regs.count threads for fork-join work, the caller's included (0 = one per core; 1 = no task pool, everything on the caller)", domain = .Settings},
	.Debug_Set = {help = ".Timing in regs.flags: time and log what runs (ONIMITE_DEBUG); .Clip_Log: the video clip frames each preview frame shows", domain = .Settings},
	.Batch_Render = {
		help = "Render once per row: regs.props the rows (.json array of objects or .csv), regs.path the output template (`{field}` from the row, `{index}` the row number), regs.rows the rows to render (1-based, inclusive; 0 = from the first / to the last)",
		domain = .Script_Inputs, needs = {.Props},
	},
	.Playback_Toggle = {domain = .Preview},
	.Playback_Set = {help = "regs.flag playing", domain = .Preview},
	.Frame_Set = {help = "regs.count video frame (clamped); regs.flag while scrubbing (sound pauses for that window frame)", domain = .Preview},
	.Frame_Step = {help = "regs.count frames, signed", domain = .Preview},
	.Frame_Start = {help = "to the bookmark when there is one and the playhead isn't on it, else the first frame", domain = .Preview},
	.Seconds_Step = {help = "regs.scalar seconds, signed", domain = .Preview},
	.Scene_Step = {help = "regs.count scenes, signed: to the start of the next / previous scene", domain = .Preview},
	.Script_Reload = {help = "re-run the script (and its media when regs.flag); a failing edit keeps the last good one", domain = .Preview},
	.Script_Open = {help = "regs.path another script (dropped on the window or picked): the preview switches to it", domain = .Preview, needs = {.Path}},
	.File_Dialog = {help = "the open-file dialog for another script", domain = .Preview},
	.Loop_Toggle = {domain = .Preview},
	.Loop_Set = {help = "regs.flag looping", domain = .Preview},
	.Mute_Toggle = {help = "muting keeps the volume, so unmuting restores it", domain = .Preview},
	.Mute_Set = {help = "regs.flag muted", domain = .Preview},
	.Volume_Set = {help = "regs.scalar volume 0..1 (above 0 unmutes)", domain = .Preview},
	.Volume_Step = {help = "regs.scalar signed change of the volume (from 0 while muted)", domain = .Preview},
	.Bookmark_Toggle = {help = "sets the bookmark at the playhead, or clears it when the playhead is on it", domain = .Preview},
	.Timeline_Zoom = {help = "regs.scalar zoom factor (> 1 in), regs.count the frame that keeps its place on screen (-1: the playhead), regs.ratio fractional 0..1 anchor across the view (when > 0 or count < 0)", domain = .Preview},
	.Timeline_Fit = {help = "the whole video in view", domain = .Preview},
	.Timeline_Pan = {help = "regs.scalar frames, signed", domain = .Preview},
	.Timeline_Follow = {help = "regs.flag: whether the timeline view follows the playhead", domain = .Preview},
	.Timeline_Toggle = {help = "collapse / expand the timeline area", domain = .Preview},
	.Timeline_Row_Toggle = {help = "regs.spec a timeline group's path (\"bus/sfx\"): open or close it", domain = .Preview},
	.Timeline_Rows_Scroll = {help = "regs.count rows, signed: the timeline's rows below the scenes", domain = .Preview},
	.Video_Zoom = {help = "regs.scalar zoom factor (> 1 in), regs.at_xy 0..1 anchor in the video panel", domain = .Preview},
	.Video_Pan = {help = "regs.at_xy pan in pixels", domain = .Preview},
	.Video_Fit = {help = "fit the video in its panel", domain = .Preview},
	.Fullscreen_Toggle = {domain = .Preview},
	.Cursor_Hover = {help = "regs.count the frame under the mouse on the timeline; lasts one window frame", domain = .Preview},
	.Dismiss = {help = "Escape: closes the lister, else the Watch, else leaves fullscreen, else quits", domain = .Preview},
	.Watch_Show = {help = "regs.section: the Watch on that section, opened beside the video when none is", domain = .Preview},
	.Watch_Section_Set = {help = "regs.view a Watch, regs.section", domain = .Preview},
	.Watch_Scroll = {help = "regs.view a Watch, regs.count rows, signed", domain = .Preview},
	.Problem_Step = {help = "regs.count: to the next (-1: previous) Watch row with a warning or error after the playhead, wrapping around", domain = .Preview},
	.Quit = {domain = .Preview},
	.Panel_Split = {
		help = "regs.panel a leaf, regs.direction the side an empty panel opens on, regs.ratio the first side's share (0: half)",
		domain = .Workspace, label = "Split", about = "an empty panel on that side of this one",
	},
	.Panel_Close = {help = "regs.panel a leaf, with its views", domain = .Workspace, label = "Close panel", about = "with its views"},
	.Panel_Resize = {help = "regs.panel a split, regs.ratio its first side's share", domain = .Workspace},
	.View_Open = {help = "regs.view_kind (a Watch on regs.section) in regs.panel after regs.previous, or with regs.direction in a new panel on that side (regs.ratio as Panel_Split); an open video or timeline moves there instead", domain = .Workspace},
	.View_Close = {help = "regs.view; a panel it leaves empty closes", domain = .Workspace},
	.View_Select = {help = "regs.view: the tab its panel shows", domain = .Workspace},
	.View_Move = {help = "regs.view into regs.panel after regs.previous (0: first), or with regs.direction into a new panel on that side; what a tab dropped somewhere pushes", domain = .Workspace},
	.Lister_Open = {help = "regs.lister the mode (what it lists), for leaf regs.panel (0: the focused one)", domain = .Workspace},
	.Lister_Filter = {help = "regs.spec the lister's filter", domain = .Workspace},
	.Lister_Close = {domain = .Workspace},
}

// A kind's name where the outside world sees it: its enum name in snake
// case ("audio_render"), the MCP tool's name.
command_name :: proc(kind: Command_Kind) -> string {
	name, _ := reflect.enum_name_from_value(kind)
	return strings.to_lower(name, context.temp_allocator)
}

// A command's name on the command line: "audio render".
command_cli_name :: proc(kind: Command_Kind) -> string {
	name, _ := strings.replace_all(command_name(kind), "_", " ", context.temp_allocator)
	return name
}

// Whether `row` can run now (COMMAND_KINDS): in its kind's domain, with the
// string registers it needs. A row that can't fails here, before its
// handler sees it.
command_validate :: proc(app: ^App_State, row: ^Command_Row) -> Error {
	d := COMMAND_KINDS[row.kind]
	ready: bool
	switch d.domain {
	case .Settings, .Tool:
		ready = true
	case .Script:
		ready = app.script_loaded
	case .Script_Inputs:
		ready = app.script_path != ""
	case .Preview, .Workspace:
		ready = app.preview.active
	}
	if !ready {
		return fail(app, {code = .Command_Domain, name = command_name(row.kind), spec = COMMAND_DOMAIN_TEXT[d.domain]})
	}
	for field in d.needs {
		if regs_text(&row.regs)[field]^ == "" {
			missing := d.missing
			if missing == "" {
				name, _ := reflect.enum_name_from_value(field)
				missing = strings.to_lower(name, context.temp_allocator)
			}
			return fail(app, {code = .Command_Needs, name = command_name(row.kind), spec = missing})
		}
	}
	return nil
}

Command_Flag :: enum u8 {
	Draft, // render: half size, fastest encoding
	Native, // render: no hardware encoder
	Update, // snapshot: accept the current frames
	All_Frames, // inspect: every frame
	Info, // inspect: informational findings too
	Float, // audio render: 32-bit float WAV
	Paused, // preview: open paused
	No_Loop, // preview: stop at the end
	Mute, // preview: no sound
	No_Media, // script load: skip the media (the preview's worker loads it)
	Svg, // frame: also write the frame's node tree as SVG
	No_Script, // script load: the media only (a batch loads the script per row)
	Timing, // debug: time and log what runs
	Clip_Log, // debug: log the video clip frames the preview shows
}
Command_Flags :: bit_set[Command_Flag;u16]

// When `inspect` exits with code 2.
Fail_On :: enum u8 {
	Error,
	Warning,
	Never,
}

Command_Regs :: struct {
	request_id: u64,
	path:       string,
	spec:       string,
	media:      string,
	// inspect: distance between checked frames, a duration spec ("0.25s").
	every:      string,
	// Script arguments, one per line (`--set key=value`, positionals).
	args:       string,
	// Audio commands: the one track (its file name) to hear alone.
	track:      string,
	// show: the moment for what changes over time (a time spec).
	at:         string,
	// Script_Load: a JSON file of props; Batch_Render: the rows file.
	props:      string,
	// Batch_Render: first and last row, 1-based and inclusive (0 = open).
	rows:       [2]int,
	scalar:     f64,
	count:      int,
	option:     int,
	columns:    int,
	width:      int,
	threshold:  int,
	ratio:      f64,
	at_xy:      [2]f32,
	flag:       bool,
	flags:      Command_Flags,
	// The preview's workspace commands.
	panel:      Panel_Id,
	view:       View_Id,
	previous:   View_Id,
	direction:  Direction,
	view_kind:  View_Kind,
	section:    Watch_Section,
	lister:     Lister_Mode,
}

Command_Row :: struct {
	kind: Command_Kind,
	regs: Command_Regs,
}

// The string registers, which a queued row keeps as spans of its batch's
// text.
Regs_Text :: enum u8 {
	Path,
	Spec,
	Media,
	Every,
	Args,
	Track,
	At,
	Props,
}

@(private = "file")
regs_text :: proc(r: ^Command_Regs) -> [Regs_Text]^string {
	return {.Path = &r.path, .Spec = &r.spec, .Media = &r.media, .Every = &r.every, .Args = &r.args, .Track = &r.track, .At = &r.at, .Props = &r.props}
}

// A pushed row: its string registers are empty, their text is in `text`.
Queued_Row :: struct {
	using row: Command_Row,
	text:      [Regs_Text]Text_Span,
}

// Rows and the bytes of their strings, reused from pass to pass.
Command_Batch :: struct {
	rows: [dynamic]Queued_Row,
	text: [dynamic]u8,
}

Command_Storage :: struct {
	// What was pushed since the last pass began.
	pending:         Command_Batch,
	// A cleared batch: the next pass takes `pending` and pushes go here
	// meanwhile, so the rows being applied and their strings stay put
	// however long their handlers run (a render, the preview window, whose
	// own passes nest inside its row's).
	spare:           Command_Batch,
	next_request_id: u64,
}

command_storage_make :: proc() -> Command_Storage {
	return {next_request_id = 1}
}

command_storage_destroy :: proc(s: ^Command_Storage) {
	command_batch_destroy(&s.pending)
	command_batch_destroy(&s.spare)
	s^ = {}
}

@(private = "file")
command_batch_destroy :: proc(b: ^Command_Batch) {
	delete(b.rows)
	delete(b.text)
	b^ = {}
}

// Appends one row; its strings are copied, so it outlives the temporary
// strings it was built from.
command_push :: proc(s: ^Command_Storage, kind: Command_Kind, regs: Command_Regs = {}) -> u64 {
	if kind == .None {
		return 0
	}
	q := Queued_Row {
		row = {kind, regs},
	}
	q.regs.request_id = s.next_request_id
	s.next_request_id += 1
	for str, field in regs_text(&q.regs) {
		q.text[field] = text_push(&s.pending.text, str^)
		str^ = ""
	}
	append(&s.pending.rows, q)
	return q.regs.request_id
}

// Takes the pending rows for a pass; pushes go to the spare batch.
command_batch_take :: proc(s: ^Command_Storage) -> Command_Batch {
	batch := s.pending
	s.pending, s.spare = s.spare, {}
	return batch
}

// Clears a batch a pass is done with and keeps it as the spare (a nested
// pass may have left one there already).
command_batch_return :: proc(s: ^Command_Storage, batch: ^Command_Batch) {
	clear(&batch.rows)
	clear(&batch.text)
	if cap(s.spare.rows) == 0 && cap(s.spare.text) == 0 {
		s.spare = batch^
	} else {
		command_batch_destroy(batch)
	}
}

// The row as pushed: its string registers read the batch's text.
command_row_of :: proc(batch: ^Command_Batch, q: Queued_Row) -> Command_Row {
	row := q.row
	for str, field in regs_text(&row.regs) {
		str^ = text_of(batch.text[:], q.text[field])
	}
	return row
}
