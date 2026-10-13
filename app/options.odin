package onimite_app

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// The commands of the command line and the MCP server (COMMANDS) and their
// options (OPTIONS), each option naming the command row and the register it
// fills. The command line (cli_parse) and an MCP call (mcp_call) both fill
// a command's Front_Rows through these tables and push them
// (front_rows_push); `onimite --help` and the MCP tool list are written from
// them too.

// A command: a subcommand of the command line, a tool of the MCP server.
Front_Command :: enum u8 {
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
}
Front_Commands :: bit_set[Front_Command;u16]

// The commands that load a script (all but probe).
SCRIPT_COMMANDS :: Front_Commands{.Render, .Frame, .Strip, .Onion, .Snapshot, .Show, .Timeline, .Inspect, .Audio_Render, .Audio_Analyze, .Audio_At, .Audio_Onsets, .Preview}
AUDIO_COMMANDS :: Front_Commands{.Audio_Render, .Audio_Analyze, .Audio_At, .Audio_Onsets}
RANGE_COMMANDS :: Front_Commands{.Render, .Strip, .Onion, .Timeline, .Inspect, .Audio_Render, .Audio_Analyze, .Audio_Onsets}

// The images an MCP result carries: none, every frame's `path`, the
// document's `output`, its `waveform`.
Mcp_Images :: enum u8 {
	None,
	Frames,
	Output,
	Waveform,
}

Command_Info :: struct {
	// Its names on the command line, `|`-separated; the first is the one shown.
	cli:      string,
	tool:     string, // its MCP tool
	kind:     Command_Kind,
	about:    string,
	// What the usage error says is missing when the positional argument is
	// ("": it is optional).
	missing:  string,
	regs:     Command_Regs, // defaults
	images:   Mcp_Images,
	mcp_note: string, // the rest of the MCP tool's description
}

@(rodata)
COMMANDS := [Front_Command]Command_Info {
	.Render = {
		cli = "render", tool = "render", kind = .Video_Render,
		about = "the video to a file (.mp4 with the audio mix, or a directory of PNGs)",
	},
	.Frame = {
		cli = "frame|frames", tool = "frame", kind = .Frames_Export, missing = "at least one time spec", images = .Frames,
		about = "single frames to PNG with the problems found in them",
		mcp_note = "The PNGs come back as images.",
	},
	.Strip = {
		cli = "strip", tool = "strip", kind = .Strip_Export, images = .Output,
		about = "a labelled contact sheet of evenly spaced frames",
		mcp_note = "The PNG comes back as an image.",
	},
	.Onion = {
		cli = "onion", tool = "onion", kind = .Onion_Export, missing = "a range", images = .Output,
		about = "frames blended into one image, later ones stronger: motion at a glance",
		mcp_note = "The PNG comes back as an image.",
	},
	.Snapshot = {
		cli = "snapshot", tool = "snapshot", kind = .Snapshot_Check, missing = "at least one time spec",
		about = "compare frames with approved PNGs (visual regression); fails when a frame differs",
	},
	.Show = {
		cli = "show", tool = "show", kind = .Show_Print,
		about = "one thing in the video, its fields and its children, a page at a time: the video, scenes, scene/Race, cue/drop, buses, bus/sfx, track/12, clip/tick_1900, says, say/intro, say/intro/3 (a spoken word and when it is said), media, media/logo.png, fonts, bodies, body/ball (physics), nodes, node/scenes/race.lua:19[2] (what drew it)",
	},
	.Timeline = {
		cli = "timeline", tool = "timeline", kind = .Timeline_Print,
		about = "scenes, duration, audio tracks and sync points",
	},
	.Inspect = {
		cli = "inspect", tool = "inspect", kind = .Inspect,
		about = "problems: missing media and fonts, clipped or overlapping text, NaN, script errors, unused options, cues that drift, sounds off the music's beat, physics bodies that overlap, leave or never settle; fails at the fail-on level",
	},
	.Audio_Render = {
		cli = "audio render", tool = "audio_render", kind = .Audio_Render,
		about = "the mix (or one track) to a stereo WAV",
	},
	.Audio_Analyze = {
		cli = "audio analyze", tool = "audio_analyze", kind = .Audio_Analyze, images = .Waveform,
		about = "loudness, true peak, clipping, silence, loudness per scene and over time",
		mcp_note = "The waveform PNG comes back as an image.",
	},
	.Audio_At = {
		cli = "audio at", tool = "audio_at", kind = .Audio_At, missing = "at least one time spec",
		about = "which tracks play at the given times, where in their files, how loud",
	},
	.Audio_Onsets = {
		cli = "audio onsets", tool = "audio_onsets", kind = .Audio_Onsets, regs = {ratio = 0.1},
		about = "where sounds start (time, strength 0..1) and the beat (BPM, first beat)",
	},
	.Preview = {
		cli = "preview", tool = "preview", kind = .Preview_Open,
		about = "a window that plays the video with sound and reloads when the script or media change",
		mcp_note = "It opens for the user and the call returns at once; the window stays open (one per script).",
	},
	.Probe = {
		cli = "probe", tool = "probe", kind = .Probe_Print, missing = "a media file",
		about = "the streams of media files (container, video, audio)",
	},
}

Option_Type :: enum u8 {
	String,
	Integer,
	Number,
	Boolean, // the command line: present or not
	Enum, // one of `values`
	Rows, // batch rows: 2, 1..3, 2.., ..2
	Key_Value, // the command line: key=value, repeated; MCP: an object
	List, // of strings
}

// The rows one command line or MCP call pushes: the command's own first
// here, pushed last after the settings and the script load in this order.
// They are filled in full before any is pushed, so a usage error pushes
// nothing and the order of the arguments does not matter.
Front_Row :: enum u8 {
	Command,
	Threads,
	Output,
	Backend,
	Debug,
	Image_Cache,
	Load,
	Scale,
}
Front_Rows :: [Front_Row]Command_Row

@(rodata)
FRONT_ROW_KINDS := [Front_Row]Command_Kind {
	.Command     = .None,
	.Threads     = .Threads_Set,
	.Output      = .Output_Set,
	.Backend     = .Backend_Set,
	.Debug       = .Debug_Set,
	.Image_Cache = .Image_Cache_Set,
	.Load        = .Script_Load,
	.Scale       = .Scale_Set,
}

// The settings pushed only when an option sets them.
FRONT_ROWS_GIVEN :: bit_set[Front_Row]{.Threads, .Image_Cache}

// The register of its row an option fills.
Option_Reg :: enum u8 {
	Path,
	Spec,
	Media,
	Props,
	Every,
	Track,
	At,
	Args, // Key_Value: one more line; List: the items, one per line
	Scalar,
	Count,
	Columns,
	Width,
	Threshold,
	Ratio,
	Option, // Boolean: 1 when on; Enum: the value's index
	Rows, // Rows: a..b; Integer: that one row
	Flag,
	Flags, // the option's `flag`
}

// A number that must be positive or not negative.
Option_Check :: enum u8 {
	None,
	Positive,
	Not_Negative,
}

Option :: struct {
	// Its spellings on the command line, `|`-separated, the first shown;
	// "": a positional argument there.
	cli:         string,
	mcp:         string, // its MCP argument ("": the command line only)
	type:        Option_Type,
	row:         Front_Row,
	reg:         Option_Reg,
	flag:        Command_Flag, // reg .Flags
	commands:    Front_Commands,
	arg:         string, // the value in the help (PATH, N)
	about:       string,
	default:     string,
	mcp_default: string, // when the MCP tool's differs
	values:      []string, // Enum
	check:       Option_Check,
	// What the usage error says of a value the check or the type refuses.
	invalid:     string,
}

// Every option, in the order the help and the MCP tool schemas list them:
// the positional arguments, each command's own, then the ones every script
// command takes. A batch is a render with the rows file in its `props`.
@(rodata)
OPTIONS := [?]Option {
	{mcp = "script", row = .Load, reg = .Path, commands = SCRIPT_COMMANDS, arg = "video.lua", about = "the video script (.lua)"},
	{mcp = "range", reg = .Spec, commands = RANGE_COMMANDS, arg = "RANGE", about = "frames a..b (end exclusive), a.., ..b, all, or a scene name; times like 3.2s, 1:05.5, 50%, Intro@1.5s, a cue: drop, drop@0.5s", default = "all"},
	{mcp = "specs", reg = .Spec, commands = {.Frame, .Snapshot, .Audio_At}, arg = "SPECS", about = "comma-separated times: 120 (frame), 3.2s, 1:05.5, 50%, start, end, Intro, #3, Intro@1.5s, Intro@50%, a cue: drop, drop@0.5s"},
	{mcp = "path", reg = .Spec, commands = {.Show}, arg = "PATH", about = "what to show", default = "the video"},
	{mcp = "at", reg = .Spec, commands = {.Preview}, arg = "AT", about = "where to start, a time spec", default = "the start"},
	{mcp = "files", type = .List, reg = .Args, commands = {.Probe}, arg = "FILE", about = "media files"},

	{cli = "-o|--output|--out", mcp = "output", reg = .Path, commands = {.Render}, arg = "PATH", about = "the .mp4, or a directory for PNGs; with a batch, a name template with {field} from the row and {index}, the row number", default = "out.mp4; with a batch, out/{index}.mp4"},
	{cli = "--draft", mcp = "draft", type = .Boolean, reg = .Flags, flag = .Draft, commands = {.Render}, about = "half size, fastest encoding"},
	{cli = "--h265", mcp = "h265", type = .Boolean, reg = .Option, commands = {.Render}, about = "H.265 instead of H.264"},
	{cli = "--qp", mcp = "qp", type = .Integer, reg = .Count, commands = {.Render}, arg = "N", about = "quantizer, 0 best .. 51"},
	{cli = "--native", mcp = "native", type = .Boolean, reg = .Flags, flag = .Native, commands = {.Render}, about = "no hardware encoder"},
	{cli = "--batch", mcp = "batch", reg = .Props, commands = {.Render}, arg = "ROWS", about = "a .json array or .csv of rows: one video per row, the row as props; a failing row is reported, the others still render"},
	{cli = "--rows", mcp = "rows", type = .Rows, reg = .Rows, commands = {.Render}, arg = "A..B", about = "the batch rows to render, 1-based and inclusive: 2, 1..3, 2.., ..2", invalid = "takes rows like 2, 1..3, 2.. or ..2"},
	{cli = "--only", type = .Integer, reg = .Rows, commands = {.Render}, arg = "N", about = "the one batch row to render (1-based)"},
	{cli = "-o|--output|--out", mcp = "output", reg = .Path, commands = {.Frame}, arg = "PATH", about = "a directory for the PNGs, or a .png for one frame", default = "frames", mcp_default = "none kept"},
	{cli = "--svg", mcp = "svg", type = .Boolean, reg = .Flags, flag = .Svg, commands = {.Frame}, about = "also write each frame as SVG next to its PNG"},
	{cli = "-n|--count", mcp = "count", type = .Integer, reg = .Count, commands = {.Strip}, arg = "N", about = "frames", default = "12"},
	{cli = "--columns", mcp = "columns", type = .Integer, reg = .Columns, commands = {.Strip}, arg = "N", about = "columns", default = "4"},
	{cli = "--width", mcp = "width", type = .Integer, reg = .Width, commands = {.Strip}, arg = "PX", about = "cell width in pixels", default = "480"},
	{cli = "-o|--output|--out", mcp = "output", reg = .Path, commands = {.Strip}, arg = "PATH", about = "the PNG", default = "strip.png", mcp_default = "none kept"},
	{cli = "-n|--count", mcp = "count", type = .Integer, reg = .Count, commands = {.Onion}, arg = "N", about = "frames", default = "6"},
	{cli = "-o|--output|--out", mcp = "output", reg = .Path, commands = {.Onion}, arg = "PATH", about = "the PNG", default = "onion.png", mcp_default = "none kept"},
	{cli = "--dir", mcp = "dir", reg = .Path, commands = {.Snapshot}, arg = "DIR", about = "the approved PNGs", default = "_frame_snapshots"},
	{cli = "--update", mcp = "update", type = .Boolean, reg = .Flags, flag = .Update, commands = {.Snapshot}, about = "accept the current frames"},
	{cli = "--threshold", mcp = "threshold", type = .Integer, reg = .Threshold, commands = {.Snapshot}, arg = "N", about = "the per-channel difference that counts", default = "16"},
	{cli = "--max-diff", mcp = "max_diff", type = .Number, reg = .Ratio, commands = {.Snapshot}, arg = "F", about = "the fraction of pixels allowed to differ", default = "0.001"},
	{cli = "--at", mcp = "at", reg = .At, commands = {.Show}, arg = "TIME", about = "a time spec, for nodes and what plays"},
	{cli = "--page", mcp = "page", type = .Integer, reg = .Count, commands = {.Show}, arg = "N", about = "the page of a long list (1-based)"},
	{cli = "--every", mcp = "every", reg = .Every, commands = {.Inspect}, arg = "SPEC", about = "the distance between checked frames", default = "0.25s"},
	{cli = "--all-frames", mcp = "all_frames", type = .Boolean, reg = .Flags, flag = .All_Frames, commands = {.Inspect}, about = "check every frame"},
	{cli = "--info", mcp = "info", type = .Boolean, reg = .Flags, flag = .Info, commands = {.Inspect}, about = "list informational findings too"},
	{cli = "--fail-on", mcp = "fail_on", type = .Enum, reg = .Option, commands = {.Inspect}, values = {"error", "warning", "never"}, about = "the findings that fail the check", default = "error"},
	{cli = "-o|--output|--out", mcp = "output", reg = .Path, commands = {.Audio_Render}, arg = "PATH", about = "the WAV", default = "audio.wav"},
	{cli = "--float", mcp = "float", type = .Boolean, reg = .Flags, flag = .Float, commands = {.Audio_Render}, about = "32-bit float samples"},
	{cli = "--waveform", mcp = "waveform", reg = .Path, commands = {.Audio_Analyze}, arg = "PATH", about = "a PNG of the waveform, loudness, scenes and cues"},
	{cli = "--min", mcp = "min", type = .Number, reg = .Ratio, commands = {.Audio_Onsets}, arg = "S", about = "the weakest strength listed; 0 lists every onset", default = "0.1"},
	{cli = "--track", mcp = "track", reg = .Track, commands = AUDIO_COMMANDS, arg = "FILE", about = "one track (its file name) or bus alone, as it sounds in the mix"},
	{cli = "--paused", mcp = "paused", type = .Boolean, reg = .Flags, flag = .Paused, commands = {.Preview}, about = "open paused"},
	{cli = "--mute", mcp = "mute", type = .Boolean, reg = .Flags, flag = .Mute, commands = {.Preview}, about = "no sound"},
	{cli = "--no-loop", mcp = "no_loop", type = .Boolean, reg = .Flags, flag = .No_Loop, commands = {.Preview}, about = "stop at the end"},
	{cli = "--exit-after", type = .Integer, reg = .Count, commands = {.Preview}, arg = "N", about = "close after N window frames"},

	{cli = "--media", mcp = "media", row = .Load, reg = .Media, commands = SCRIPT_COMMANDS, arg = "DIR", about = "fonts, images and sounds", default = "media/ beside the script"},
	{cli = "--props", mcp = "props", row = .Load, reg = .Props, commands = SCRIPT_COMMANDS, arg = "FILE", about = "a JSON object the script reads as the table props (props.title, ...)"},
	{cli = "--set", mcp = "set", type = .Key_Value, row = .Load, reg = .Args, commands = SCRIPT_COMMANDS, arg = "K=V", about = "script arguments (Lua: arg.K, a string) that also set props.K (a number when it looks like one); they win over a batch row, which wins over the props file", invalid = "takes key=value"},
	{cli = "--scale", mcp = "scale", type = .Number, row = .Scale, reg = .Scalar, commands = SCRIPT_COMMANDS, arg = "S", about = "output resolution factor, e.g. 0.5 for half resolution", check = .Positive, invalid = "needs a positive number"},
	{cli = "--software", mcp = "software", type = .Boolean, row = .Backend, reg = .Flag, commands = SCRIPT_COMMANDS, about = "draw on the CPU instead of the GPU"},
	{cli = "--json", type = .Boolean, row = .Output, reg = .Flag, commands = SCRIPT_COMMANDS + {.Probe}, about = "print one JSON document to stdout; progress and warnings go to stderr"},
	{cli = "--threads", type = .Integer, row = .Threads, reg = .Count, commands = SCRIPT_COMMANDS, arg = "N", about = "threads for parallel work, this one included; 1: everything on one thread", default = "one per core", check = .Positive, invalid = "needs a count of at least 1"},
	{cli = "--image-cache", type = .Integer, row = .Image_Cache, reg = .Count, commands = SCRIPT_COMMANDS, arg = "MB", about = "decoded images kept in memory; the least recently used are freed between frames and decode again when used", default = "1024", check = .Not_Negative, invalid = "needs a size in MB"},
}

// A value given for an option, as its type reads it.
Option_Value :: struct {
	str:  string,
	num:  f64,
	on:   bool,
	list: []string,
}

// The rows of command `c` before any option: its defaults, the settings
// every command pushes, the script load for a script command (the preview's
// without the media: its worker loads them).
front_rows_make :: proc(c: Front_Command) -> (rows: Front_Rows) {
	rows[.Command] = {COMMANDS[c].kind, COMMANDS[c].regs}
	rows[.Output].kind = .Output_Set
	rows[.Backend].kind = .Backend_Set
	rows[.Debug].kind = .Debug_Set
	if c in SCRIPT_COMMANDS {
		rows[.Load].kind = .Script_Load
		rows[.Scale].kind = .Scale_Set
	}
	if c == .Preview {
		rows[.Load].regs.flags += {.No_Media}
	}
	return
}

// Puts `v` where option `o` says; what the usage error says when the value
// is wrong ("" when it is right).
option_set :: proc(rows: ^Front_Rows, o: Option, v: Option_Value) -> string {
	n := f64(int(v.num)) if o.type == .Integer else v.num
	switch o.check {
	case .None:
	case .Positive:
		if n <= 0 {
			return o.invalid
		}
	case .Not_Negative:
		if n < 0 {
			return o.invalid
		}
	}
	if o.row in FRONT_ROWS_GIVEN {
		rows[o.row].kind = FRONT_ROW_KINDS[o.row]
	}
	r := &rows[o.row].regs
	switch o.reg {
	case .Path:
		r.path = v.str
	case .Spec:
		r.spec = v.str
	case .Media:
		r.media = v.str
	case .Props:
		r.props = v.str
	case .Every:
		r.every = v.str
	case .Track:
		r.track = v.str
	case .At:
		r.at = v.str
	case .Args:
		if o.type == .List {
			r.args = strings.join(v.list, "\n", context.temp_allocator)
		} else if strings.index_byte(v.str, '=') <= 0 {
			return o.invalid
		} else {
			args_append(r, v.str)
		}
	case .Scalar:
		r.scalar = n
	case .Count:
		r.count = int(n)
	case .Columns:
		r.columns = int(n)
	case .Width:
		r.width = int(n)
	case .Threshold:
		r.threshold = int(n)
	case .Ratio:
		r.ratio = n
	case .Option:
		if o.type == .Boolean {
			r.option = 1 if v.on else 0
			break
		}
		for name, i in o.values {
			if name == v.str {
				r.option = i
				return ""
			}
		}
		return fmt.tprintf("takes %s", option_values(o, ", ", " or "))
	case .Rows:
		if o.type == .Integer {
			r.rows = {int(n), int(n)}
			break
		}
		lo, sep, hi := strings.partition(v.str, "..")
		if sep == "" {
			hi = lo
		}
		ok_lo, ok_hi := true, true
		if lo != "" {
			r.rows[0], ok_lo = strconv.parse_int(lo, 10)
		}
		if hi != "" {
			r.rows[1], ok_hi = strconv.parse_int(hi, 10)
		}
		if !ok_lo || !ok_hi || r.rows[0] < 0 || r.rows[1] < 0 {
			return o.invalid
		}
	case .Flag:
		r.flag = v.on
	case .Flags:
		if v.on {
			r.flags += {o.flag}
		} else {
			r.flags -= {o.flag}
		}
	}
	return ""
}

// One more script argument, a line of the load's `args`.
@(private = "file")
args_append :: proc(r: ^Command_Regs, arg: string) {
	r.args = arg if r.args == "" else fmt.tprintf("%s\n%s", r.args, arg)
}

// Pushes the rows: the settings, the script load, the scale, then the
// command. A render with a rows file is a batch: it loads only the media
// (the script once per row, with the row as props).
front_rows_push :: proc(c: ^Command_Storage, rows: Front_Rows) {
	rows := rows
	if rows[.Command].kind == .Video_Render && rows[.Command].regs.props != "" {
		rows[.Command].kind = .Batch_Render
		rows[.Load].regs.flags += {.No_Script}
	}
	for row, slot in rows {
		if slot != .Command {
			command_push(c, row.kind, row.regs)
		}
	}
	command_push(c, rows[.Command].kind, rows[.Command].regs)
}

// Runs the rows on an App_State of their own, the output to `out` (nil:
// stdout); the exit code.
front_rows_run :: proc(rows: Front_Rows, out: ^strings.Builder = nil) -> int {
	a: App_State
	app_init(&a)
	a.out = out
	front_rows_push(&a.commands, rows)
	run(&a)
	code := a.exit_code
	app_destroy(&a)
	return code
}

// ---- the command line -----------------------------------------------------------

// Parses the arguments after the program's name into the rows they push;
// `help` when they ask for the usage. A usage error exits (usage_error).
cli_parse :: proc(args: []string) -> (rows: Front_Rows, help: bool) {
	if len(args) == 0 {
		usage_error("missing command")
	}
	// `onimite video.lua [options]` renders, like fframes without a subcommand.
	name, rest := args[0], args[1:]
	if strings.has_suffix(name, ".lua") {
		name, rest = "render", args
	} else if name == "audio" {
		if len(rest) == 0 {
			usage_error("audio needs render, analyze, at or onsets")
		}
		name = fmt.tprintf("audio %s", rest[0])
		rest = rest[1:]
	}
	command, known := command_find(name)
	rows = front_rows_make(command)
	cmd := &rows[.Command].regs
	if !known || command in SCRIPT_COMMANDS {
		if len(rest) == 0 || strings.has_prefix(rest[0], "-") {
			usage_error("missing the video script")
		}
		rows[.Load].regs.path = rest[0]
		rest = rest[1:]
	}
	positional := make([dynamic]string, context.temp_allocator)
	for i := 0; i < len(rest); i += 1 {
		arg := rest[i]
		if arg == "--" {
			// Everything after `--` goes to the script as positionals.
			for a in rest[i + 1:] {
				args_append(&rows[.Load].regs, a)
			}
			break
		}
		if arg == "-h" || arg == "--help" {
			return rows, true
		}
		o, is_option, takes := option_find_cli(arg, command)
		if is_option && known && !takes {
			usage_error("%s does not take %s", command_name(command), arg)
		}
		if !is_option {
			if strings.has_prefix(arg, "-") && len(arg) > 1 && !(arg[1] >= '0' && arg[1] <= '9') && arg[1] != '.' {
				usage_error("unknown option %s", arg)
			}
			append(&positional, arg)
			continue
		}
		v: Option_Value
		if o.type == .Boolean {
			v.on = true
		} else {
			if i + 1 >= len(rest) {
				usage_error("%s needs a value", arg)
			}
			i += 1
			v.str = rest[i]
			if o.type == .Integer || o.type == .Number {
				ok: bool
				v.num, ok = strconv.parse_f64(v.str)
				if !ok {
					usage_error("%s needs a number", arg)
				}
			}
		}
		if problem := option_set(&rows, o, v); problem != "" {
			usage_error("%s %s", arg, problem)
		}
	}
	if !known {
		usage_error("unknown command %q", name)
	}
	info := COMMANDS[command]
	if o, ok := option_positional(command); ok {
		option_set(&rows, o, {str = strings.join(positional[:], ",", context.temp_allocator), list = positional[:]})
		if info.missing != "" && (len(positional) == 0 if o.type == .List else cmd.spec == "") {
			usage_error("%s needs %s", command_name(command), info.missing)
		}
	}
	#partial switch command {
	case .Snapshot:
		if env_set("FFRAMES_UPDATE_SNAPSHOTS") || env_set("ONIMITE_UPDATE_SNAPSHOTS") {
			cmd.flags += {.Update}
		}
	case .Preview:
		// Measurements: a PNG of the last window frame, scripted input.
		cmd.path = os.get_env("ONIMITE_PREVIEW_CAPTURE", context.temp_allocator)
		cmd.args = os.get_env("ONIMITE_PREVIEW_DRIVE", context.temp_allocator)
	}
	if cmd.props == "" && cmd.rows != {} {
		usage_error("--rows and --only need --batch")
	}
	if env_set("ONIMITE_DEBUG") {
		rows[.Debug].regs.flags += {.Timing}
	}
	if env_set("ONIMITE_CLIP_LOG") {
		rows[.Debug].regs.flags += {.Clip_Log}
	}
	return rows, false
}

// Whether environment variable `name` is set to something other than 0.
env_set :: proc(name: string) -> bool {
	v := os.get_env(name, context.temp_allocator)
	return v != "" && v != "0"
}

// Usage errors exit with 2, as clap's do in fframes.
usage_error :: proc(format: string, args: ..any) -> ! {
	fmt.eprintfln("error: %s\n", fmt.tprintf(format, ..args))
	fmt.eprint(usage())
	os.exit(2)
}

// The command named `name` on the command line.
command_find :: proc(name: string) -> (Front_Command, bool) {
	for info, c in COMMANDS {
		if names_have(info.cli, name) {
			return c, true
		}
	}
	return {}, false
}

// The command's name on the command line.
command_name :: proc(c: Front_Command) -> string {
	name, _, _ := strings.partition(COMMANDS[c].cli, "|")
	return name
}

// The option spelled `arg` on the command line: command `c`'s (`takes`), else
// any command's.
option_find_cli :: proc(arg: string, c: Front_Command) -> (o: Option, found, takes: bool) {
	for row in OPTIONS {
		if row.cli != "" && names_have(row.cli, arg) {
			if c in row.commands {
				return row, true, true
			}
			if !found {
				o, found = row, true
			}
		}
	}
	return
}

// The command's positional argument, after the script.
option_positional :: proc(c: Front_Command) -> (Option, bool) {
	for o in OPTIONS {
		if o.cli == "" && o.row == .Command && c in o.commands {
			return o, true
		}
	}
	return {}, false
}

@(private = "file")
names_have :: proc(names, name: string) -> bool {
	names := names
	for n in strings.split_iterator(&names, "|") {
		if n == name {
			return true
		}
	}
	return false
}

// The values of an Enum option: "error, warning or never".
option_values :: proc(o: Option, sep, last: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for v, i in o.values {
		if i > 0 {
			strings.write_string(&b, last if i == len(o.values) - 1 else sep)
		}
		strings.write_string(&b, v)
	}
	return strings.to_string(b)
}

// An option's description with its default (the MCP tool's when `mcp`).
option_about :: proc(o: Option, mcp: bool) -> string {
	d := o.mcp_default if mcp && o.mcp_default != "" else o.default
	return o.about if d == "" else fmt.tprintf("%s (default: %s)", o.about, d)
}

// ---- the help -------------------------------------------------------------------

@(private = "file")
USAGE_HEAD :: `Render and inspect onimite videos.

usage: onimite <command> <video.lua> [args] [options]
       onimite <video.lua>                         (render the whole video)
       onimite --version

commands:
`

@(private = "file")
USAGE_TAIL :: `
TIME SPECS: 120 (frame), 3.2s, 1:05.5, 50%, start, end, Intro (first frame of the scene),
#3 (scene index), Intro[1] (second scene named Intro), Intro@1.5s, Intro@50%, Intro@end
(an offset must land inside its scene); cues and sync ids too: drop, drop@0.5s, drop@-6.
RANGES: a..b (end exclusive, drop..beat[8]), a.., ..b, all, or a scene name for the whole scene.
After "--", the arguments go to the script as positionals (arg[1..]).
Exit codes: 1 when a command fails, 2 for usage errors and failed checks (inspect, snapshot).
Run ` + "`timeline`" + ` to list scenes. Add --json to any command for machine-readable output.
`

// The column descriptions start at, and the width they wrap at.
@(private = "file")
USAGE_COLUMN :: 28
@(private = "file")
USAGE_WIDTH :: 100

// `onimite --help`: each command with its own options, then the options
// every command takes.
usage :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, USAGE_HEAD)
	shared :: proc(o: Option) -> bool {
		return card(o.commands) >= card(SCRIPT_COMMANDS)
	}
	for info, c in COMMANDS {
		head := command_name(c)
		if o, ok := option_positional(c); ok {
			head = fmt.tprintf("%s %s", head, o.arg) if info.missing != "" else fmt.tprintf("%s [%s]", head, o.arg)
		}
		usage_line(&b, 2, head, info.about)
		for o in OPTIONS {
			if o.cli != "" && c in o.commands && !shared(o) {
				usage_line(&b, 4, option_head(o), option_about(o, false))
			}
		}
	}
	usage_line(&b, 2, "mcp [--dir PATH]", "serve the commands above as MCP tools on stdin/stdout (JSON-RPC 2.0, one message per line; frames come back as images), plus `guide`, the built-in skill; --dir: the folder relative paths resolve in")
	strings.write_string(&b, "\noptions:\n")
	for o in OPTIONS {
		if o.cli != "" && shared(o) {
			usage_line(&b, 2, option_head(o), option_about(o, false))
		}
	}
	strings.write_string(&b, USAGE_TAIL)
	return strings.to_string(b)
}

// The option as the help shows it: `-o PATH`, `--fail-on error|warning|never`.
@(private = "file")
option_head :: proc(o: Option) -> string {
	name, _, _ := strings.partition(o.cli, "|")
	switch {
	case o.type == .Enum:
		return fmt.tprintf("%s %s", name, option_values(o, "|", "|"))
	case o.arg != "":
		return fmt.tprintf("%s %s", name, o.arg)
	}
	return name
}

// `head` indented, then `text` from USAGE_COLUMN (on the next line when the
// head reaches it), wrapped at USAGE_WIDTH.
@(private = "file")
usage_line :: proc(b: ^strings.Builder, indent: int, head, text: string) {
	pad :: proc(b: ^strings.Builder, n: int) {
		for _ in 0 ..< n {
			strings.write_byte(b, ' ')
		}
	}
	pad(b, indent)
	strings.write_string(b, head)
	col := indent + len(head)
	if col >= USAGE_COLUMN - 1 {
		strings.write_byte(b, '\n')
		col = 0
	}
	text := text
	first := true
	for word in strings.split_iterator(&text, " ") {
		if !first && col + 1 + len(word) > USAGE_WIDTH {
			strings.write_byte(b, '\n')
			col = 0
			first = true
		}
		if first {
			pad(b, USAGE_COLUMN - col)
			col = USAGE_COLUMN
		} else {
			strings.write_byte(b, ' ')
			col += 1
		}
		strings.write_string(b, word)
		col += len(word)
		first = false
	}
	strings.write_byte(b, '\n')
}
