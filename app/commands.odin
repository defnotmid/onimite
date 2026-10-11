package onimite_app

import "core:strings"

// Every action is a command row, as in paf (after raddbg): the command line,
// and later the preview window's input and widgets, push rows; `dispatch`
// applies them in one place, draining until no row is left.

Command_Kind :: enum u8 {
	None,
	Script_Load, // regs.path the script; regs.media a media directory ("" = `media/` beside the script); regs.props a JSON file of props ("" = none); .No_Media in regs.flags: the script only; .No_Script: the media only (a batch loads the script per row)
	Output_Set, // regs.flag: print one JSON document per command instead of text
	Backend_Set, // regs.flag: draw on the CPU instead of the GPU
	Show_Print, // regs.spec a path ("" = the video), regs.at a time spec for what changes over time, regs.count the page (1-based)
	Timeline_Print, // regs.spec a range: only what happens in it ("" = everything)
	Frames_Export, // regs.spec comma-separated frame specs, regs.path the output directory, .Svg in regs.flags: an SVG next to every PNG
	Strip_Export, // regs.spec a range ("" = everything), regs.count frames, regs.columns, regs.width (cell px), regs.path the PNG
	Onion_Export, // regs.spec a range, regs.count frames, regs.path the PNG
	Snapshot_Check, // regs.spec frame specs, regs.path the snapshot directory, regs.threshold, regs.ratio, .Update in regs.flags
	Inspect, // regs.spec a range, regs.every (a duration spec), regs.option fail-on (Fail_On), .All_Frames / .Info in regs.flags
	Video_Render, // regs.spec a range, regs.path the output (.mp4, or a directory for PNGs), regs.option codec (0 H.264, 1 H.265), regs.count qp (0 default), .Native / .Draft in regs.flags
	Batch_Render, // Video_Render once per row: regs.props the rows (.json array of objects or .csv), regs.path the output template (`{field}` from the row, `{index}` the row number), regs.rows the rows to render (1-based, inclusive; 0 = from the first / to the last)
	Scale_Set, // regs.scalar output scale for later renders (0 = not given)
	Image_Cache_Set, // regs.count MB of decoded images the media keeps (least recently used freed first)
	Threads_Set, // regs.count threads for fork-join work, the caller's included (0 = one per core; 1 = no task pool, everything on the caller)
	Audio_Analyze, // regs.spec a range; regs.path a waveform PNG ("" = none); regs.track one track ("" = the mix)
	Audio_Render, // regs.spec a range, regs.path the WAV, .Float in regs.flags; regs.track one track ("" = the mix)
	Audio_At, // regs.spec frame specs; regs.track one track ("" = all)
	Audio_Onsets, // regs.spec a range, regs.ratio the weakest strength listed (0 = all); regs.track one track ("" = the mix)
	Probe_Print, // regs.args media files, one per line: their streams (no script)
	Preview_Open, // regs.spec the start frame, .Paused / .No_Loop / .Mute in regs.flags, regs.count window frames to exit after (0 = never); for measurements, regs.path a PNG of the last window frame and regs.args scripted input (`preview_drive`)
	Debug_Set, // .Timing in regs.flags: time and log what runs (ONIMITE_DEBUG); .Clip_Log: the video clip frames each preview frame shows
	// Preview window (preview.odin).
	Playback_Toggle,
	Playback_Set, // regs.flag playing
	Frame_Set, // regs.count video frame (clamped); regs.flag while scrubbing (sound pauses for that window frame)
	Frame_Step, // regs.count frames, signed
	Frame_Start, // to the bookmark when there is one and the playhead isn't on it, else the first frame
	Seconds_Step, // regs.scalar seconds, signed
	Scene_Step, // regs.count scenes, signed: to the start of the next / previous scene
	Script_Reload, // re-run the script (and its media when regs.flag); a failing edit keeps the last good one
	Script_Open, // regs.path another script (dropped on the window or picked): the preview switches to it
	File_Dialog, // the open-file dialog for another script
	Loop_Toggle,
	Loop_Set, // regs.flag looping
	Mute_Toggle, // muting keeps the volume, so unmuting restores it
	Mute_Set, // regs.flag muted
	Volume_Set, // regs.scalar volume 0..1 (above 0 unmutes)
	Volume_Step, // regs.scalar signed change of the volume (from 0 while muted)
	Bookmark_Toggle, // sets the bookmark at the playhead, or clears it when the playhead is on it
	Timeline_Zoom, // regs.scalar zoom factor (> 1 in), regs.count the frame that keeps its place on screen (-1: the playhead)
	Timeline_Fit, // the whole video in view
	Timeline_Pan, // regs.scalar frames, signed
	Timeline_Toggle, // collapse / expand the timeline area
	Timeline_Row_Toggle, // regs.spec a timeline group's path ("bus/sfx"): open or close it
	Timeline_Rows_Scroll, // regs.count rows, signed: the timeline's rows below the scenes
	Fullscreen_Toggle,
	Media_Toggle, // the media panel
	Media_Layout_Toggle, // the media panel as a list or a grid
	Media_Scroll, // regs.count rows, signed
	Diagnostics_Toggle,
	Cursor_Hover, // regs.count the frame under the mouse on the timeline; lasts one frame
	Quit,
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
	flag:       bool,
	flags:      Command_Flags,
}

Command_Row :: struct {
	kind: Command_Kind,
	regs: Command_Regs,
}

Command_Storage :: struct {
	rows:            [dynamic]Command_Row,
	// Rows being applied; swapped with `rows` so rows pushed during a
	// dispatch land in the next pass.
	applying:        [dynamic]Command_Row,
	next_request_id: u64,
}

command_storage_make :: proc() -> Command_Storage {
	return {
		rows = make([dynamic]Command_Row),
		applying = make([dynamic]Command_Row),
		next_request_id = 1,
	}
}

command_storage_destroy :: proc(s: ^Command_Storage) {
	for row in s.rows {
		regs_delete(row.regs)
	}
	delete(s.rows)
	delete(s.applying)
	s^ = {}
}

// Appends one row. Strings are cloned so a row outlives the temporary
// strings it was built from.
command_push :: proc(s: ^Command_Storage, kind: Command_Kind, regs: Command_Regs = {}) -> u64 {
	if kind == .None {
		return 0
	}
	row := Command_Row{kind, regs}
	row.regs.request_id = s.next_request_id
	s.next_request_id += 1
	row.regs.path = strings.clone(row.regs.path)
	row.regs.spec = strings.clone(row.regs.spec)
	row.regs.media = strings.clone(row.regs.media)
	row.regs.every = strings.clone(row.regs.every)
	row.regs.args = strings.clone(row.regs.args)
	row.regs.props = strings.clone(row.regs.props)
	row.regs.track = strings.clone(row.regs.track)
	row.regs.at = strings.clone(row.regs.at)
	append(&s.rows, row)
	return row.regs.request_id
}

@(private)
regs_delete :: proc(r: Command_Regs) {
	delete(r.path)
	delete(r.spec)
	delete(r.media)
	delete(r.every)
	delete(r.args)
	delete(r.props)
	delete(r.track)
	delete(r.at)
}
