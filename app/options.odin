package onimite_app

import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strconv"
import "core:strings"

// The commands of the command line and the MCP server are the kinds with
// .Command_Line / .Mcp_Tool in COMMAND_KINDS; each names its arguments, an
// Odin struct whose fields are its options (`command_options`). The command
// line (cli_parse) and an MCP call (mcp_call) both fill a command's
// Front_Rows through them and push them (front_rows_push); `onimite --help`
// and the MCP tool list are written from them too.
//
// A field's name is its MCP argument and, with dashes, its spelling on the
// command line (--all-frames); its type is the value's: string, int, f64,
// bool, an enum (one of its names in lower case), []string (a list) or a
// map (key=value pairs; MCP: an object of the map's value types). Its tags:
//   pos          a positional argument on the command line, after the script
//   cli          its spellings there instead, `|`-separated, the first shown
//   mcp:"-"      the command line only
//   row          the Front_Row it fills (default: Command)
//   reg          the register of that row, a field of Command_Regs (default:
//                the field's name); `flag`: the Command_Flag a boolean sets
//   arg, about   the value in the help (PATH, N) and what the option does
//   default      what the help says it defaults to (`mcp_default`: the MCP
//                tool's, when it differs)
//   check        Positive or Not_Negative: a number the usage refuses else
//   invalid      what the usage error says of a value the check or the
//                register refuses
// A `using` field of struct type adds its fields there; tagged `shared`,
// they are the ones every command takes, listed once in the help.

// ---- the commands' arguments ----------------------------------------------------

// The video script, first after the command on the command line.
Script_Arg :: struct {
	script: string `pos:"" row:"Load" reg:"path" arg:"video.lua" about:"the video script (.lua)"`,
}

Range_Arg :: struct {
	range: string `pos:"" reg:"spec" arg:"RANGE" about:"frames a..b (end exclusive), a.., ..b, all, or a scene name; times like 3.2s, 1:05.5, 50%, Intro@1.5s, a cue: drop, drop@0.5s" default:"all"`,
}

Specs_Arg :: struct {
	specs: string `pos:"" reg:"spec" arg:"SPECS" about:"comma-separated times: 120 (frame), 3.2s, 1:05.5, 50%, start, end, Intro, #3, Intro@1.5s, Intro@50%, a cue: drop, drop@0.5s"`,
}

Track_Option :: struct {
	track: string `arg:"FILE" about:"one track (its file name) or bus alone, as it sounds in the mix"`,
}

Json_Option :: struct {
	json: bool `mcp:"-" row:"Output" reg:"flag" about:"print one JSON document to stdout; progress and warnings go to stderr"`,
}

// A script argument's value as an MCP call may give it.
Set_Value :: union {
	string,
	f64,
	bool,
}

// What every command that loads a script takes.
Script_Options :: struct {
	media:            string               `row:"Load" arg:"DIR" about:"fonts, images and sounds" default:"media/ beside the script"`,
	props:            string               `row:"Load" arg:"FILE" about:"a JSON object the script reads as the table props (props.title, ...)"`,
	set:              map[string]Set_Value `row:"Load" reg:"args" arg:"K=V" about:"script arguments (Lua: arg.K, a string) that also set props.K (a number when it looks like one); they win over a batch row, which wins over the props file" invalid:"takes key=value"`,
	scale:            f64                  `row:"Scale" reg:"scalar" arg:"S" about:"output resolution factor, e.g. 0.5 for half resolution (rounded to an even size)" check:"Positive" invalid:"needs a positive number"`,
	software:         bool                 `row:"Backend" reg:"flag" about:"draw on the CPU instead of the GPU"`,
	using json_option: Json_Option,
	threads:          int                  `mcp:"-" row:"Threads" reg:"count" arg:"N" about:"threads for all parallel work, this one included (a quarter render songs and audio, the rest frames); 1: everything on one thread" default:"one per core" check:"Positive" invalid:"needs a count of at least 1"`,
	image_cache:      int                  `mcp:"-" row:"Image_Cache" reg:"count" arg:"MB" about:"decoded images kept in memory; the least recently used are freed between frames and decode again when used" default:"1024" check:"Not_Negative" invalid:"needs a size in MB"`,
}

// A render with a rows file (`batch`) is a batch.
Render_Args :: struct {
	using script_arg:     Script_Arg,
	using range_arg:      Range_Arg,
	output:               string `cli:"-o|--output|--out" reg:"path" arg:"PATH" about:"the .mp4, or a directory for PNGs; with a batch, a name template with {field} from the row and {index}, the row number" default:"out.mp4; with a batch, out/{index}.mp4"`,
	draft:                bool   `flag:"Draft" about:"half size, fastest encoding"`,
	h265:                 bool   `reg:"option" about:"H.265 instead of H.264"`,
	qp:                   int    `reg:"count" arg:"N" about:"quantizer, 0 best .. 51"`,
	native:               bool   `flag:"Native" about:"no hardware encoder"`,
	slices:               int    `arg:"N" about:"H.264 slices odecs' native encoder codes in parallel; the file depends on it (more: faster, slightly larger), never on the machine; hardware encoders ignore it" default:"4" check:"Positive" invalid:"needs a count of at least 1"`,
	batch:                string `reg:"props" arg:"ROWS" about:"a .json array or .csv of rows: one video per row, the row as props; a failing row is reported, the others still render"`,
	rows:                 string `arg:"A..B" about:"the batch rows to render, 1-based and inclusive: 2, 1..3, 2.., ..2" invalid:"takes rows like 2, 1..3, 2.. or ..2"`,
	only:                 int    `mcp:"-" reg:"rows" arg:"N" about:"the one batch row to render (1-based)"`,
	using script_options: Script_Options `shared:""`,
}

Frame_Args :: struct {
	using script_arg:     Script_Arg,
	using specs_arg:      Specs_Arg,
	output:               string `cli:"-o|--output|--out" reg:"path" arg:"PATH" about:"a directory for the PNGs, or a .png for one frame" default:"frames" mcp_default:"none kept"`,
	svg:                  bool   `flag:"Svg" about:"also write each frame as SVG next to its PNG"`,
	using script_options: Script_Options `shared:""`,
}

Strip_Args :: struct {
	using script_arg:     Script_Arg,
	using range_arg:      Range_Arg,
	count:                int    `cli:"-n|--count" arg:"N" about:"frames" default:"12"`,
	columns:              int    `arg:"N" about:"columns" default:"4"`,
	width:                int    `arg:"PX" about:"cell width in pixels" default:"480"`,
	output:               string `cli:"-o|--output|--out" reg:"path" arg:"PATH" about:"the PNG" default:"strip.png" mcp_default:"none kept"`,
	using script_options: Script_Options `shared:""`,
}

Onion_Args :: struct {
	using script_arg:     Script_Arg,
	using range_arg:      Range_Arg,
	count:                int    `cli:"-n|--count" arg:"N" about:"frames" default:"6"`,
	output:               string `cli:"-o|--output|--out" reg:"path" arg:"PATH" about:"the PNG" default:"onion.png" mcp_default:"none kept"`,
	using script_options: Script_Options `shared:""`,
}

Snapshot_Args :: struct {
	using script_arg:     Script_Arg,
	using specs_arg:      Specs_Arg,
	dir:                  string `reg:"path" arg:"DIR" about:"the approved PNGs" default:"_frame_snapshots"`,
	update:               bool   `flag:"Update" about:"accept the current frames"`,
	threshold:            int    `arg:"N" about:"the per-channel difference that counts" default:"16"`,
	max_diff:             f64    `reg:"ratio" arg:"F" about:"the fraction of pixels allowed to differ" default:"0.001"`,
	using script_options: Script_Options `shared:""`,
}

Show_Args :: struct {
	using script_arg:     Script_Arg,
	path:                 string `pos:"" reg:"spec" arg:"PATH" about:"what to show" default:"the video"`,
	at:                   string `arg:"TIME" about:"a time spec, for nodes and what plays"`,
	page:                 int    `reg:"count" arg:"N" about:"the page of a long list (1-based)"`,
	using script_options: Script_Options `shared:""`,
}

Timeline_Args :: struct {
	using script_arg:     Script_Arg,
	using range_arg:      Range_Arg,
	using script_options: Script_Options `shared:""`,
}

Inspect_Args :: struct {
	using script_arg:     Script_Arg,
	using range_arg:      Range_Arg,
	every:                string  `arg:"SPEC" about:"the distance between checked frames (and every scene's first and last frame and the first frames after each cue and scene start, where a slam overshoots)" default:"0.25s"`,
	all_frames:           bool    `flag:"All_Frames" about:"check every frame (once before delivering: a motion between the checked frames goes unseen otherwise)"`,
	info:                 bool    `flag:"Info" about:"list informational findings too"`,
	fail_on:              Fail_On `reg:"option" about:"the findings that fail the check" default:"error"`,
	using script_options: Script_Options `shared:""`,
}

Audio_Render_Args :: struct {
	using script_arg:     Script_Arg,
	using range_arg:      Range_Arg,
	output:               string `cli:"-o|--output|--out" reg:"path" arg:"PATH" about:"the WAV" default:"audio.wav"`,
	float:                bool   `flag:"Float" about:"32-bit float samples"`,
	using track_option:   Track_Option,
	using script_options: Script_Options `shared:""`,
}

Audio_Analyze_Args :: struct {
	using script_arg:     Script_Arg,
	using range_arg:      Range_Arg,
	waveform:             string `reg:"path" arg:"PATH" about:"a PNG of the waveform, loudness, spectrogram, scenes and cues"`,
	using track_option:   Track_Option,
	using script_options: Script_Options `shared:""`,
}

Audio_At_Args :: struct {
	using script_arg:     Script_Arg,
	using specs_arg:      Specs_Arg,
	using track_option:   Track_Option,
	using script_options: Script_Options `shared:""`,
}

Audio_Onsets_Args :: struct {
	using script_arg:     Script_Arg,
	using range_arg:      Range_Arg,
	min:                  f64 `reg:"ratio" arg:"S" about:"the weakest strength listed; 0 lists every onset" default:"0.1"`,
	using track_option:   Track_Option,
	using script_options: Script_Options `shared:""`,
}

Audio_Pin_Args :: struct {
	using script_arg:     Script_Arg,
	using script_options: Script_Options `shared:""`,
}

Audio_Parts_Args :: struct {
	using script_arg:     Script_Arg,
	against:              string `reg:"path" arg:"FILE" about:"an earlier --json of it: say what drifted (notes, first notes, more than 1 LU of level) and fail"`,
	using script_options: Script_Options `shared:""`,
}

// The environment adds what measurements use (cli_parse): a PNG of the
// last window frame (ONIMITE_PREVIEW_CAPTURE, regs.path) and scripted input
// (ONIMITE_PREVIEW_DRIVE, regs.args).
Preview_Args :: struct {
	using script_arg:     Script_Arg,
	at:                   string `pos:"" reg:"spec" arg:"AT" about:"where to start, a time spec" default:"the start"`,
	paused:               bool   `flag:"Paused" about:"open paused"`,
	mute:                 bool   `flag:"Mute" about:"no sound"`,
	no_loop:              bool   `flag:"No_Loop" about:"stop at the end"`,
	bare:                 bool   `flag:"Bare" about:"the video alone (no controls, panels or timeline), played once, then the window closes; Escape closes it sooner"`,
	fullscreen:           bool   `flag:"Fullscreen" about:"open fullscreen (F toggles)"`,
	exit_after:           int    `mcp:"-" reg:"count" arg:"N" about:"close after N window frames"`,
	using script_options: Script_Options `shared:""`,
}

Probe_Args :: struct {
	files:             []string `pos:"" reg:"args" arg:"FILE" about:"media files"`,
	using json_option: Json_Option `shared:""`,
}

Update_Args :: struct {
	check:             bool `reg:"flag" about:"only say whether a newer release is out"`,
	using json_option: Json_Option `shared:""`,
}

// ---- options ----------------------------------------------------------------------

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

// A number that must be positive or not negative.
Option_Check :: enum u8 {
	None,
	Positive,
	Not_Negative,
}

// An option: a field of a command's arguments struct, as its tags say.
Option :: struct {
	name:        string, // its MCP argument
	// Its spellings on the command line, `|`-separated, the first shown;
	// "": a positional argument there.
	cli:         string,
	mcp:         bool,
	type:        ^reflect.Type_Info, // the value's
	row:         Front_Row,
	reg:         reflect.Struct_Field, // in Command_Regs
	flag:        Command_Flag,
	check:       Option_Check,
	// One every command takes (in the help's options).
	shared:      bool,
	arg:         string,
	about:       string,
	default:     string,
	mcp_default: string,
	invalid:     string,
}

// Command `kind`'s options in the order its arguments struct has them (none
// for a kind without one), in temp memory.
command_options :: proc(kind: Command_Kind) -> []Option {
	out := make([dynamic]Option, context.temp_allocator)
	if args := COMMAND_KINDS[kind].args; args != nil {
		options_append(&out, args, false)
	}
	return out[:]
}

// The fields of struct `T` as options, a `using` struct's in its place.
options_append :: proc(out: ^[dynamic]Option, T: typeid, shared: bool) {
	for f in reflect.struct_fields_zipped(T) {
		if f.is_using {
			_, is_shared := reflect.struct_tag_lookup(f.tag, "shared")
			options_append(out, f.type.id, shared || is_shared)
		} else {
			append(out, option_of(f, shared))
		}
	}
}

// Field `f` as an option, through its tags (see the top of the file).
@(private = "file")
option_of :: proc(f: reflect.Struct_Field, shared: bool) -> Option {
	tag := f.tag
	o := Option {
		name        = f.name,
		mcp         = reflect.struct_tag_get(tag, "mcp") != "-",
		type        = reflect.type_info_base(f.type),
		shared      = shared,
		arg         = reflect.struct_tag_get(tag, "arg"),
		about       = reflect.struct_tag_get(tag, "about"),
		default     = reflect.struct_tag_get(tag, "default"),
		mcp_default = reflect.struct_tag_get(tag, "mcp_default"),
		invalid     = reflect.struct_tag_get(tag, "invalid"),
	}
	if _, positional := reflect.struct_tag_lookup(tag, "pos"); !positional {
		dashed, _ := strings.replace_all(f.name, "_", "-", context.temp_allocator)
		o.cli = reflect.struct_tag_lookup(tag, "cli") or_else fmt.tprintf("--%s", dashed)
	}
	reg := f.name
	if name, ok := reflect.struct_tag_lookup(tag, "row"); ok {
		o.row, ok = reflect.enum_from_name(Front_Row, name)
		assert(ok, f.name)
	}
	if name, ok := reflect.struct_tag_lookup(tag, "flag"); ok {
		o.flag, ok = reflect.enum_from_name(Command_Flag, name)
		assert(ok, f.name)
		reg = "flags"
	}
	if name, ok := reflect.struct_tag_lookup(tag, "check"); ok {
		o.check, ok = reflect.enum_from_name(Option_Check, name)
		assert(ok, f.name)
	}
	o.reg = reflect.struct_field_by_name(Command_Regs, reflect.struct_tag_lookup(tag, "reg") or_else reg)
	assert(o.reg.type != nil, f.name)
	return o
}

// A value given for an option, as its type reads it.
Option_Value :: struct {
	str:  string,
	num:  f64,
	on:   bool,
	list: []string,
}

// Whether command `kind` is given a script (it runs on the script or on its
// inputs).
takes_script :: proc "contextless" (kind: Command_Kind) -> bool {
	d := COMMAND_KINDS[kind].domain
	return d == .Script || d == .Script_Inputs
}

// The rows of command `kind` before any option: its defaults, the settings
// every command pushes, the script load for a command of the script or its
// inputs (the preview's reads only the inputs: its worker loads them).
front_rows_make :: proc(kind: Command_Kind) -> (rows: Front_Rows) {
	rows[.Command] = {kind, COMMAND_KINDS[kind].regs}
	rows[.Output].kind = .Output_Set
	rows[.Backend].kind = .Backend_Set
	rows[.Debug].kind = .Debug_Set
	if takes_script(kind) {
		rows[.Load].kind = .Script_Load
		rows[.Scale].kind = .Scale_Set
	}
	if kind == .Preview {
		// Its worker loads both (once: the physics, shared() values and
		// spoken lines a load makes aren't made twice).
		rows[.Load].regs.flags += {.No_Media, .No_Script}
	}
	if kind == .Audio_Pin {
		// Its songs fetch what isn't pinned from their first read: a
		// source's SFZ, read as the song is made, says what it plays.
		rows[.Load].regs.flags += {.Pinning}
	}
	return
}

// Puts `v` in the register option `o` fills, as the register's type takes
// the option's; what the usage error says when the value is wrong ("" when
// it is right).
option_set :: proc(rows: ^Front_Rows, o: Option, v: Option_Value) -> string {
	_, integer := o.type.variant.(reflect.Type_Info_Integer)
	n := f64(int(v.num)) if integer else v.num
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
	reg := rawptr(uintptr(&rows[o.row].regs) + o.reg.offset)
	switch o.reg.type.id {
	case string:
		#partial switch _ in o.type.variant {
		case reflect.Type_Info_Slice:
			(^string)(reg)^ = strings.join(v.list, LIST_SEP, context.temp_allocator)
		case reflect.Type_Info_Map:
			if strings.index_byte(v.str, '=') <= 0 {
				return o.invalid
			}
			list_append((^string)(reg), v.str)
		case:
			(^string)(reg)^ = v.str
		}
	case int:
		#partial switch t in o.type.variant {
		case reflect.Type_Info_Boolean:
			(^int)(reg)^ = 1 if v.on else 0
		case reflect.Type_Info_Enum:
			for name, i in option_choices(o) {
				if name == v.str {
					(^int)(reg)^ = int(t.values[i])
					return ""
				}
			}
			return fmt.tprintf("takes %s", option_values(o, ", ", " or "))
		case:
			(^int)(reg)^ = int(n)
		}
	case f64:
		(^f64)(reg)^ = n
	case bool:
		(^bool)(reg)^ = v.on
	case [2]int:
		// Batch rows: one (an integer), or a..b, a.., ..b.
		r := (^[2]int)(reg)
		if integer {
			r^ = {int(n), int(n)}
			break
		}
		lo, sep, hi := strings.partition(v.str, "..")
		if sep == "" {
			hi = lo
		}
		ok_lo, ok_hi := true, true
		if lo != "" {
			r[0], ok_lo = strconv.parse_int(lo, 10)
		}
		if hi != "" {
			r[1], ok_hi = strconv.parse_int(hi, 10)
		}
		if !ok_lo || !ok_hi || r[0] < 0 || r[1] < 0 {
			return o.invalid
		}
	case Command_Flags:
		if v.on {
			(^Command_Flags)(reg)^ += {o.flag}
		} else {
			(^Command_Flags)(reg)^ -= {o.flag}
		}
	case:
		unreachable()
	}
	return ""
}

// A list in a string register (script arguments, media files) separates
// its items with NUL, the one byte no command-line argument holds: a value
// can span lines (--set text="$(cat banner.txt)").
LIST_SEP :: "\x00"

// One more item of a string register's list.
@(private = "file")
list_append :: proc(reg: ^string, item: string) {
	reg^ = item if reg^ == "" else fmt.tprintf("%s%s%s", reg^, LIST_SEP, item)
}

// Pushes the rows: the settings, the script load, the scale, then the
// command. A render with a rows file is a batch: it loads only the media
// (the script once per row, with the row as props).
front_rows_push :: proc(c: ^Command_Storage, rows: Front_Rows) {
	rows := rows
	if rows[.Command].kind == .Render && rows[.Command].regs.props != "" {
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
	dispatch(&a)
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
			usage_error("audio needs %s", command_group_words("audio"))
		}
		name = fmt.tprintf("audio %s", rest[0])
		rest = rest[1:]
	}
	command, known := command_find(name)
	rows = front_rows_make(command)
	cmd := &rows[.Command].regs
	if !known || takes_script(command) {
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
				list_append(&rows[.Load].regs.args, a)
			}
			break
		}
		if arg == "-h" || arg == "--help" {
			return rows, true
		}
		o, is_option, takes := option_find_cli(arg, command)
		if is_option && known && !takes {
			usage_error("%s does not take %s", command_cli_name(command), arg)
		}
		if !is_option {
			if strings.has_prefix(arg, "-") && len(arg) > 1 && !(arg[1] >= '0' && arg[1] <= '9') && arg[1] != '.' {
				usage_error("unknown option %s", arg)
			}
			append(&positional, arg)
			continue
		}
		v: Option_Value
		#partial switch _ in o.type.variant {
		case reflect.Type_Info_Boolean:
			v.on = true
		case:
			if i + 1 >= len(rest) {
				usage_error("%s needs a value", arg)
			}
			i += 1
			v.str = rest[i]
			#partial switch _ in o.type.variant {
			case reflect.Type_Info_Integer, reflect.Type_Info_Float:
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
	if o, ok := option_positional(command); ok {
		option_set(&rows, o, {str = strings.join(positional[:], ",", context.temp_allocator), list = positional[:]})
		_, list := o.type.variant.(reflect.Type_Info_Slice)
		if option_required(command, o) && (len(positional) == 0 if list else cmd.spec == "") {
			usage_error("%s needs %s", command_cli_name(command), COMMAND_KINDS[command].missing)
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
command_find :: proc(name: string) -> (Command_Kind, bool) {
	for d, kind in COMMAND_KINDS {
		if .Command_Line in d.flags && (command_cli_name(kind) == name || d.alias != "" && d.alias == name) {
			return kind, true
		}
	}
	return .None, false
}

// What follows `group` in the names of the commands it starts: "render,
// analyze, at or onsets" for audio.
command_group_words :: proc(group: string) -> string {
	prefix := fmt.tprintf("%s ", group)
	words := make([dynamic]string, context.temp_allocator)
	for d, kind in COMMAND_KINDS {
		if name := command_cli_name(kind); .Command_Line in d.flags && strings.has_prefix(name, prefix) {
			append(&words, name[len(prefix):])
		}
	}
	return words_text(words[:], ", ", " or ")
}

// The option spelled `arg` on the command line: command `kind`'s (`takes`),
// else any command's.
option_find_cli :: proc(arg: string, kind: Command_Kind) -> (o: Option, found, takes: bool) {
	for d, other in COMMAND_KINDS {
		if .Command_Line not_in d.flags {
			continue
		}
		for row in command_options(other) {
			if row.cli != "" && names_have(row.cli, arg) {
				if other == kind {
					return row, true, true
				}
				if !found {
					o, found = row, true
				}
			}
		}
	}
	return
}

// The command's positional argument, after the script.
option_positional :: proc(kind: Command_Kind) -> (Option, bool) {
	for o in command_options(kind) {
		if o.cli == "" && o.row == .Command {
			return o, true
		}
	}
	return {}, false
}

// Whether command `kind` can't do without option `o`: the script, a
// positional argument the command says is missing when it isn't given.
option_required :: proc(kind: Command_Kind, o: Option) -> bool {
	return o.cli == "" && (o.row == .Load || COMMAND_KINDS[kind].missing != "")
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

// The values an enum option takes: its enum's names in lower case.
option_choices :: proc(o: Option) -> []string {
	names := o.type.variant.(reflect.Type_Info_Enum).names
	choices := make([]string, len(names), context.temp_allocator)
	for name, i in names {
		choices[i] = strings.to_lower(name, context.temp_allocator)
	}
	return choices
}

// The values of an enum option: "error, warning or never".
option_values :: proc(o: Option, sep, last: string) -> string {
	return words_text(option_choices(o), sep, last)
}

// `words` separated by `sep`, the last two by `last`.
@(private = "file")
words_text :: proc(words: []string, sep, last: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for w, i in words {
		if i > 0 {
			strings.write_string(&b, last if i == len(words) - 1 else sep)
		}
		strings.write_string(&b, w)
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
	for d, kind in COMMAND_KINDS {
		if .Command_Line not_in d.flags {
			continue
		}
		head := command_cli_name(kind)
		if o, ok := option_positional(kind); ok {
			head = fmt.tprintf("%s %s", head, o.arg) if option_required(kind, o) else fmt.tprintf("%s [%s]", head, o.arg)
		}
		usage_line(&b, 2, head, d.about)
		for o in command_options(kind) {
			if o.cli != "" && !o.shared {
				usage_line(&b, 4, option_head(o), option_about(o, false))
			}
		}
	}
	usage_line(&b, 2, "mcp [--dir PATH] [--update-check false]", "serve the commands above as MCP tools on stdin/stdout (JSON-RPC 2.0, one message per line; frames come back as images), plus `guide`, the built-in skill; --dir: the folder relative paths resolve in; a release looks for a newer release as it starts (--update-check false or ONIMITE_NO_UPDATE_CHECK=1: it doesn't)")
	strings.write_string(&b, "\noptions:\n")
	shared := make([dynamic]Option, context.temp_allocator)
	options_append(&shared, Script_Options, true)
	for o in shared {
		usage_line(&b, 2, option_head(o), option_about(o, false))
	}
	strings.write_string(&b, USAGE_TAIL)
	return strings.to_string(b)
}

// The option as the help shows it: `-o PATH`, `--fail-on error|warning|never`.
@(private = "file")
option_head :: proc(o: Option) -> string {
	name, _, _ := strings.partition(o.cli, "|")
	if _, is_enum := o.type.variant.(reflect.Type_Info_Enum); is_enum {
		return fmt.tprintf("%s %s", name, option_values(o, "|", "|"))
	}
	if o.arg != "" {
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
