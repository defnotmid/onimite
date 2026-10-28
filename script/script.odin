// Lua scripting for onimite: a video is a Lua file that declares the video
// and its scenes and builds each frame with the same builders the Odin API
// has. See README.md for the script API.
package onimite_script

import "base:runtime"
import "core:bytes"
import "core:c"
import "core:compress/gzip"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:math/ease"
import "core:math/noise"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:thread"
import om "../onimite"
import "../speech"
import vg "deps:ovg"
import lua "vendor:lua/5.4"

Script :: struct {
	L:            ^lua.State,
	path:         string,
	video:        om.Video,
	scenes:       [dynamic]om.Scene,
	slots:        [dynamic]Scene_Slot,
	video_render: c.int,
	// The context of the render call in progress; nil outside renders.
	ctx:          ^om.Context,
	// The frame that render call got (a scene's own, or the video's).
	frame:        om.Frame,
	odin_context: runtime.Context,
	// Borrowed for what the load draws (`bake{}`): its bands and shaders in
	// parallel; nil draws them on the loading thread.
	pool:         ^thread.Pool,
	// Why the last load failed.
	failure:      Failure,
	// Script arguments (`--set key=value` and positionals), owned; exposed
	// to Lua as the global `arg` table.
	args:         []string,
	// Props, owned: JSON objects merged in order (later keys win), then
	// the `key=value` arguments; exposed to Lua as the global `props` table.
	props:        []string,
	// The video's tracks (video{} and scene{} `audio`, `Video.audio`),
	// buses and their strings, freed on unload.
	tracks:        [dynamic]om.Audio_Track,
	owned_buses:   [dynamic][]om.Bus,
	owned_strings: [dynamic]string,
	owned_values:  [dynamic]json.Value, // tracks' effects
	// Duration and timestamp terms (media_api.odin), freed on unload.
	owned_terms:   [dynamic][]om.Time_Term,
	// Shader files read beside the script, by path (shader_api.odin).
	shader_files:  map[string]string,
	// The media `text_width` and co. measure with at load (renders use
	// their own).
	media:         ^om.Media,
	// Problems found while it loaded (unused fields, fonts the media lacks,
	// physics, spoken lines), owned (`load_problem`).
	load_problems: [dynamic]om.Diagnostic,
	// Sync points: `cue(id, t)` moments and the `id`s of animate keys seen
	// while rendering (scenes and tracks carry theirs). Owned.
	cues:          [dynamic]Cue,
	key_anchors:   [dynamic]Key_Anchor,
	// Clips audio_add will build from a function when they are needed
	// (`audio_build_clip`).
	pending_audio: [dynamic]Pending_Audio,
	// With `node_sources_on`, where each node of the frame being built came
	// from, by node index (`node_source`, `node_via`, `node_scene`); the
	// lines' text in `node_text`.
	node_sources_on: bool,
	// The preview: deferred clips are built by clip jobs, never by a frame.
	// A frame needing one that isn't here yet draws without it (silence)
	// and counts it in its context's `audio_pending`, to be drawn again.
	audio_later:     bool,
	// How many frames the command draws (frame, strip, onion, snapshot);
	// few enough, and a song's table is filled only at the rows they read
	// (0: tables are built whole).
	audio_frames:    int,
	node_sources:    [dynamic]Node_Source,
	node_text:       [dynamic]u8,
	// text_width's results by text and font (hashed).
	widths:        map[u64]f32,
	// Warm scratch of the outline booleans (outline_api.odin).
	bools:         vg.Bool_Scratch,
	// Load-time data shared with the other states of a render (shared.odin):
	// the render's, or `own_shared`.
	shared:        ^Shared,
	own_shared:    Shared,
	// The simulations physics{} ran in this load (physics_api.odin).
	physics:       [dynamic]Physics_Sim,
	// The lines `say` spoke (say_api.odin), by name (owned), and whether
	// it synthesized any in this load.
	said:          map[string]Said,
	spoke:         bool,
	// A load's first pass (say_defer) leaves the lines it misses to one
	// batch (say_misses, owned); the lines made wait in say_made for the
	// second pass (owned). Neither outlives the load.
	say_defer:     bool,
	say_misses:    [dynamic]Say_Miss,
	say_made:      map[speech.Key]Say_Made,
	// The songs and sounds this load made (song_api.odin).
	songs:         [dynamic]Script_Song,
}

// A named moment, seconds on the video clock. `hit` names a track whose
// sound should start there (`cue(id, t, { hit = "music.mp3" })`).
Cue :: struct {
	name:    string,
	seconds: f64,
	hit:     string,
	at:      string, // the script line
}

// An animate key with an `id`: where it starts on the video clock and the
// script line that animates it.
Key_Anchor :: struct {
	id:      string,
	seconds: f64,
	at:      string,
}

// A clip's build function (a registry reference) not run yet.
Pending_Audio :: struct {
	name: string,
	ref:  c.int,
}

@(private)
Scene_Slot :: struct {
	script: ^Script,
	ref:    c.int,
}

@(private)
STD_LUA :: #load("std.lua", string)

// Runs the script at `path`. On failure `s.failure` says why. `s` must stay at a stable address while the script is loaded.
// `media` (its fonts loaded) is what text is measured with at load; it must
// outlive the script. Scripts loaded with the same `shared` (the frame
// builders of a render) make their `path_data` and `shared` values once;
// it must outlive them. `props` are JSON objects (texts) merged into the
// `props` global. `say` synthesizes the lines neither `shared` nor the store
// has, on this thread, one at a time.
// The script a video file loads as (`onimite preview clip.mp4`): the clip
// at its own size (upright) and frame rate, its sound included, as one
// scene named by the file.
@(private = "file")
CLIP_SCRIPT :: `
local i = video_info(NAME) or error(NAME .. ": not a video onimite can read", 0)
local w, h = i.width, i.height
if i.rotation == 90 or i.rotation == 270 then w, h = h, w end
video { width = w, height = h, fps = math.max(1, math.floor(i.fps + 0.5)), background = "#000" }
scene { NAME, clip = NAME }
`

// The script an audio file loads as (`onimite audio analyze take.wav`): its
// sound over black, as long as the sound, 1280 x 720 at 30 fps.
@(private = "file")
SOUND_SCRIPT :: `
local i = audio_info(NAME) or error(NAME .. ": not a sound onimite can read", 0)
video { width = 1280, height = 720, fps = 30, duration = i.duration, background = "#000",
  audio = { { NAME } }, render = function(f) end }
`

// Loads the script. Its `say` lines are all made before it is used: a first
// pass notes the ones not made yet (a silent stand-in meanwhile), they are
// synthesized together (say_synthesize), and a second pass reads them all.
load :: proc(s: ^Script, path: string, args: []string = nil, media: ^om.Media = nil, shared: ^Shared = nil, props: []string = nil, pool: ^thread.Pool = nil) -> Error {
	// A load that synthesized lines lets go of the engine when it ends (the
	// lines own their memory; the next miss starts it again). Loads that
	// only read lines (frame builders, clip builds) never touch it.
	s.spoke = false
	defer if s.spoke {
		speech.release()
	}
	defer say_made_clear(s)
	s.say_defer = true
	err := load_pass(s, path, args, media, shared, props, pool)
	s.say_defer = false
	if err != nil || len(s.say_misses) == 0 {
		say_misses_clear(s)
		return err
	}
	say_synthesize(s)
	return load_pass(s, path, args, media, shared, props, pool)
}

@(private = "file")
load_pass :: proc(s: ^Script, path: string, args: []string, media: ^om.Media, shared: ^Shared, props: []string, pool: ^thread.Pool) -> Error {
	// what the load carries from pass to pass
	spoke, say_defer, say_made := s.spoke, s.say_defer, s.say_made
	unload(s)
	s.spoke, s.say_defer, s.say_made = spoke, say_defer, say_made
	s.odin_context = context
	s.media = media
	s.pool = pool
	s.shared = shared if shared != nil else &s.own_shared
	s.path = strings.clone(path)
	s.args = make([]string, len(args))
	for a, i in args {
		s.args[i] = strings.clone(a)
	}
	s.props = make([]string, len(props))
	for p, i in props {
		s.props[i] = strings.clone(p)
	}
	s.video_render = lua.NOREF
	s.scenes = make([dynamic]om.Scene)
	s.slots = make([dynamic]Scene_Slot)

	data: []u8
	if kind, is_media := om.media_kind_of(path); is_media && (kind == .Video || kind == .Audio) {
		// A video file is a video: itself, at its own size and rate. An
		// audio file is its sound over black.
		data = transmute([]u8)strings.concatenate({"local NAME = [==[", filepath.base(path), "]==]", CLIP_SCRIPT if kind == .Video else SOUND_SCRIPT})
	} else {
		err: os.Error
		data, err = os.read_entire_file(path, context.allocator)
		if err != nil {
			return set_error(s, {code = .Read, path = path, os = err})
		}
	}
	defer delete(data)

	s.L = lua.L_newstate()
	lua.L_openlibs(s.L)
	register_api(s)
	set_script_environment(s)
	set_props(s) or_return

	L := s.L
	lua.pushcfunction(L, message_handler)
	// The Lua standard library (std.lua): sequence, series, loop, freeze,
	// stagger, transition, beat_clock, scene transitions.
	if lua.L_loadbuffer(L, raw_data(STD_LUA), c.size_t(len(STD_LUA)), "=std.lua") != .OK || lua.pcall(L, 0, 0, -2) != 0 {
		return set_error(s, {code = .Lua, lua = string(lua.tostring(L, -1))})
	}
	if !load_chunk(L, s, path, data) {
		return set_error(s, {code = .Lua, lua = string(lua.tostring(L, -1))})
	}
	if lua.pcall(L, 0, 0, -2) != 0 {
		return set_error(s, {code = .Lua, lua = string(lua.tostring(L, -1))})
	}
	lua.settop(L, 0)
	say_default_buses(s)
	// Drop what loading left behind (decoded text, temporaries) before the
	// state lives through the render next to the other builders' states.
	lua.gc(L, .COLLECT)

	v := &s.video
	if v.width <= 0 || v.height <= 0 || v.fps <= 0 {
		return set_error(s, {code = .No_Video, path = path})
	}
	if len(s.scenes) == 0 && v.duration == nil {
		return set_error(s, {code = .No_Duration, path = path})
	}
	// Scenes point at their slots now that neither array grows any more.
	for &scene, i in s.scenes {
		scene.user = &s.slots[i]
		scene.render = scene_render
	}
	v.scenes = s.scenes[:]
	// The video's own tracks first, then each scene's in scene order.
	slice.stable_sort_by(s.tracks[:], proc(a, b: om.Audio_Track) -> bool {
		return (a.scene.? or_else -1) < (b.scene.? or_else -1)
	})
	v.audio = s.tracks[:]
	if s.video_render != lua.NOREF {
		v.render = video_render
		v.user = s
	}
	return nil
}

unload :: proc(s: ^Script) {
	if s.L != nil {
		lua.close(s.L)
	}
	for scene in s.scenes {
		delete(scene.name)
		delete(scene.cue)
		delete(scene.source)
	}
	for c in s.cues {
		delete(c.name)
		delete(c.hit)
		delete(c.at)
	}
	delete(s.cues)
	for k in s.key_anchors {
		delete(k.id)
		delete(k.at)
	}
	delete(s.key_anchors)
	for p in s.pending_audio {
		delete(p.name)
	}
	delete(s.pending_audio)
	say_unload(s)
	songs_unload(s)
	physics_unload(s)
	delete(s.widths)
	vg.bool_scratch_destroy(&s.bools)
	delete(s.node_sources)
	delete(s.node_text)
	delete(s.scenes)
	delete(s.slots)
	delete(s.tracks)
	for b in s.owned_buses {
		delete(b)
	}
	delete(s.owned_buses)
	for str in s.owned_strings {
		delete(str)
	}
	delete(s.owned_strings)
	for v in s.owned_values {
		json.destroy_value(v)
	}
	delete(s.owned_values)
	for t in s.owned_terms {
		delete(t)
	}
	delete(s.owned_terms)
	for path, src in s.shader_files {
		delete(path)
		delete(src)
	}
	delete(s.shader_files)
	for &d in s.load_problems {
		delete(d.name)
		delete(d.a)
		delete(d.b)
	}
	delete(s.load_problems)
	delete(s.path)
	failure_destroy(&s.failure)
	for a in s.args {
		delete(a)
	}
	delete(s.args)
	for p in s.props {
		delete(p)
	}
	delete(s.props)
	shared_destroy(&s.own_shared)
	s^ = {}
}

// `require` and `dofile` resolve next to the script, `SCRIPT_DIR` names its
// directory; `arg` holds the
// script arguments: `arg.key` for `--set key=value`, `arg[1..]` for
// positionals (strings; use tonumber).
@(private)
set_script_environment :: proc(s: ^Script) {
	L := s.L
	dir := filepath.dir(s.path)
	if dir == "" {
		dir = "." // a script named without a directory: the current one
	}
	// SCRIPT_DIR: the script's directory, for io.open / io.popen on files beside it.
	lua.pushstring(L, strings.clone_to_cstring(dir, context.temp_allocator))
	lua.setglobal(L, "SCRIPT_DIR")
	lua.getglobal(L, "package")
	pp := fmt.tprintf("%s/?.lua;%s/?/init.lua;", dir, dir)
	field(L, -1, "path")
	pp = fmt.tprintf("%s%s", pp, lua.tostring(L, -1))
	lua.pop(L, 1)
	lua.pushstring(L, strings.clone_to_cstring(pp, context.temp_allocator))
	lua.setfield(L, -2, "path")
	// Lua files load through `load_chunk`: package.searchers[2] (require's
	// file searcher) and dofile (API).
	lua.getfield(L, -1, "searchers")
	lua.pushlightuserdata(L, s)
	lua.pushcclosure(L, l_search_file, 1)
	lua.rawseti(L, -2, 2)
	lua.pop(L, 2)

	lua.createtable(L, i32(len(s.args)), 0)
	n := 0
	for a in s.args {
		if eq := strings.index_byte(a, '='); eq > 0 {
			lua.pushstring(L, strings.clone_to_cstring(a[eq + 1:], context.temp_allocator))
			lua.setfield(L, -2, strings.clone_to_cstring(a[:eq], context.temp_allocator))
		} else {
			n += 1
			lua.pushstring(L, strings.clone_to_cstring(a, context.temp_allocator))
			lua.rawseti(L, -2, lua.Integer(n))
		}
	}
	lua.setglobal(L, "arg")
}

// The `props` global: the JSON objects of `s.props` merged in order (top-level
// keys; later ones win), then every `key=value` argument (numbers when they
// look like JSON numbers, else strings). Always a table.
@(private)
set_props :: proc(s: ^Script) -> Error {
	L := s.L
	lua.createtable(L, 0, 0)
	for text in s.props {
		v, err := json.parse_string(text, .JSON5, parse_integers = true, allocator = context.temp_allocator)
		if err != nil {
			return set_error(s, {code = .Props_Json, json = err})
		}
		obj, is_object := v.(json.Object)
		if !is_object {
			return set_error(s, {code = .Props_Not_Object})
		}
		for key, value in obj {
			push_json(L, value)
			lua.setfield(L, -2, strings.clone_to_cstring(key, context.temp_allocator))
		}
	}
	for a in s.args {
		if eq := strings.index_byte(a, '='); eq > 0 {
			push_json(L, scalar_value(a[eq + 1:]))
			lua.setfield(L, -2, strings.clone_to_cstring(a[:eq], context.temp_allocator))
		}
	}
	lua.setglobal(L, "props")
	return nil
}

// Pushes a JSON value as Lua: objects as tables, arrays as sequences from 1,
// integers as integers, null as nil.
push_json :: proc(L: ^lua.State, v: json.Value) {
	switch x in v {
	case json.Null:
		lua.pushnil(L)
	case json.Integer:
		lua.pushinteger(L, lua.Integer(x))
	case json.Float:
		lua.pushnumber(L, lua.Number(x))
	case json.Boolean:
		lua.pushboolean(L, b32(x))
	case json.String:
		lua.pushlstring(L, cstring(raw_data(x)), c.size_t(len(x)))
	case json.Array:
		lua.createtable(L, i32(len(x)), 0)
		for item, i in x {
			push_json(L, item)
			lua.rawseti(L, -2, lua.Integer(i + 1))
		}
	case json.Object:
		lua.createtable(L, 0, i32(len(x)))
		for key, item in x {
			push_json(L, item)
			lua.setfield(L, -2, strings.clone_to_cstring(key, context.temp_allocator))
		}
	case:
		lua.pushnil(L)
	}
}

// A command-line or CSV value: a number when it reads as a JSON number
// (`42`, `-1.5`, `2e3`; not `007` or `1_000`), else the string itself.
scalar_value :: proc(s: string) -> json.Value {
	i := 0
	digits :: proc(s: string, i: ^int) -> int {
		n := 0
		for i^ < len(s) && s[i^] >= '0' && s[i^] <= '9' {
			i^ += 1
			n += 1
		}
		return n
	}
	if i < len(s) && s[i] == '-' {
		i += 1
	}
	start := i
	n := digits(s, &i)
	if n == 0 || (n > 1 && s[start] == '0') {
		return json.String(s)
	}
	integer := true
	if i < len(s) && s[i] == '.' {
		i += 1
		integer = false
		if digits(s, &i) == 0 {
			return json.String(s)
		}
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		i += 1
		integer = false
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			i += 1
		}
		if digits(s, &i) == 0 {
			return json.String(s)
		}
	}
	if i != len(s) {
		return json.String(s)
	}
	if integer {
		if v, ok := strconv.parse_i64_of_base(s, 10); ok {
			return json.Integer(v)
		}
	}
	v, _ := strconv.parse_f64(s)
	return json.Float(v)
}

// Keeps `f` (its strings cloned) as the load's failure; returns its code.
@(private)
set_error :: proc(s: ^Script, f: Failure) -> Error {
	failure_destroy(&s.failure)
	s.failure = failure_clone(f)
	return f.code
}

// ---- render trampolines ----------------------------------------------------------

@(private)
scene_render :: proc(f: om.Frame, ctx: ^om.Context) {
	slot := (^Scene_Slot)(f.scene.scene.user)
	call_render(slot.script, slot.ref, f, ctx)
}

@(private)
video_render :: proc(f: om.Frame, ctx: ^om.Context) {
	s := (^Script)(ctx.video.user)
	call_render(s, s.video_render, f, ctx)
}

@(private)
call_render :: proc(s: ^Script, ref: c.int, f: om.Frame, ctx: ^om.Context) {
	if ref == lua.NOREF {
		return // a scene without render: a label
	}
	L := s.L
	outer := s.ctx
	s.ctx = ctx
	defer s.ctx = outer
	outer_frame := s.frame
	s.frame = f
	defer s.frame = outer_frame
	// Callbacks run with the calling thread's context (its temp allocator):
	// builders call render procs from pool threads.
	outer_context := s.odin_context
	s.odin_context = context
	defer s.odin_context = outer_context
	top := lua.gettop(L)
	defer lua.settop(L, top)
	lua.pushcfunction(L, message_handler)
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(ref))
	push_frame(s, f)
	if lua.pcall(L, 1, 0, -3) != 0 {
		om.report(ctx, .Error, {code = .Script_Error, a = string(lua.tostring(L, -1))})
	}
}

@(private)
message_handler :: proc "c" (L: ^lua.State) -> c.int {
	msg := lua.tostring(L, 1)
	if msg == nil {
		msg = "error object is not a string"
	}
	lua.L_traceback(L, L, msg, 1)
	return 1
}

// The frame as a Lua table: index, global_index, fps, seconds,
// global_seconds, width, height and, inside a scene, `scene`.
@(private)
push_frame :: proc(s: ^Script, f: om.Frame) {
	L := s.L
	lua.createtable(L, 0, 8)
	set_int(L, "index", f.index)
	set_int(L, "global_index", f.global_index)
	set_int(L, "fps", f.fps)
	// In double precision: Lua sums and compares these.
	lua.pushnumber(L, lua.Number(f.index) / lua.Number(f.fps) + lua.Number(f.shift))
	lua.setfield(L, -2, "seconds")
	lua.pushnumber(L, lua.Number(f.global_index) / lua.Number(f.fps) + lua.Number(f.shift))
	lua.setfield(L, -2, "global_seconds")
	set_int(L, "width", s.video.width)
	set_int(L, "height", s.video.height)
	if f.scene != nil {
		push_scene_info(L, f.scene^, f.fps)
		lua.setfield(L, -2, "scene")
	}
}

@(private)
push_scene_info :: proc(L: ^lua.State, info: om.Scene_Info, fps: int) {
	lua.createtable(L, 0, 7)
	name := strings.clone_to_cstring(info.scene.name, context.temp_allocator)
	lua.pushstring(L, name)
	lua.setfield(L, -2, "name")
	set_int(L, "index", info.index)
	set_int(L, "start_frame", info.start_frame)
	set_int(L, "end_frame", info.end_frame)
	set_int(L, "frames", info.end_frame - info.start_frame)
	set_num(L, "duration", f32(info.duration) / f32(fps))
	lua.pushboolean(L, b32(info.is_last))
	lua.setfield(L, -2, "is_last")
}

@(private)
set_int :: proc(L: ^lua.State, key: cstring, v: int) {
	lua.pushinteger(L, lua.Integer(v))
	lua.setfield(L, -2, key)
}

@(private)
set_num :: proc(L: ^lua.State, key: cstring, v: f32) {
	lua.pushnumber(L, lua.Number(v))
	lua.setfield(L, -2, key)
}

// ---- Lua files ---------------------------------------------------------------------

// Loads the Lua source `data` read from `path` as a chunk named by the
// file's path relative to the script's folder, cleaned ("scenes/race.lua",
// "../common/pip.lua"), whatever the working directory: the name every
// script position (Lua's errors, `caller_where`, node sources) goes by.
// False with Lua's message on the stack when it doesn't parse.
@(private)
load_chunk :: proc(L: ^lua.State, s: ^Script, path: string, data: []u8) -> bool {
	script, _ := filepath.abs(s.path, context.temp_allocator)
	file, _ := filepath.abs(path, context.temp_allocator)
	name, err := filepath.rel(filepath.dir(script), file, context.temp_allocator)
	if err != nil {
		name = file // on another volume
	}
	// One spelling on every system: `show` paths and scripts' own
	// debug.getinfo lookups split on "/".
	when ODIN_OS == .Windows {
		name, _ = strings.replace_all(name, "\\", "/", context.temp_allocator)
	}
	chunk := strings.clone_to_cstring(strings.concatenate({"@", name}, context.temp_allocator), context.temp_allocator)
	return lua.L_loadbuffer(L, raw_data(data), c.size_t(len(data)), chunk) == .OK
}

// package.searchers[2]: finds module `name` on package.path as Lua's own
// file searcher does and loads it with `load_chunk`.
@(private)
l_search_file :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	name := lua.L_checkstring(L, 1)
	lua.getglobal(L, "package")
	lua.getfield(L, -1, "searchpath")
	lua.pushvalue(L, 1)
	lua.getfield(L, -3, "path")
	lua.call(L, 2, 2)
	if lua.isnil(L, -2) {
		return 1 // the files tried
	}
	file := lua.tostring(L, -2)
	data, err := os.read_entire_file(string(file), context.temp_allocator)
	if err != nil {
		lua.L_error(L, "error loading module '%s' from file '%s'", name, file)
	}
	if !load_chunk(L, s, string(file), data) {
		lua.L_error(L, "error loading module '%s' from file '%s':\n\t%s", name, file, lua.tostring(L, -1))
	}
	lua.pushstring(L, file)
	return 2
}

// dofile(path) -> what the file returns: runs the Lua file at `path`,
// beside the script when relative.
@(private)
l_dofile :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	path := string(lua.L_checkstring(L, 1))
	if !filepath.is_abs(path) {
		path, _ = filepath.join({filepath.dir(s.path), path}, context.temp_allocator)
	}
	lua.settop(L, 1)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		lua.L_error(L, "cannot open %s", lua.tostring(L, 1))
	}
	if !load_chunk(L, s, path, data) {
		lua.error(L)
	}
	lua.call(L, 0, lua.MULTRET)
	return lua.gettop(L) - 1
}

// ---- API registration --------------------------------------------------------------

// When a Lua function works: while the script loads (it sets the video up:
// its scenes, tracks, cues, media), while a frame renders (it draws, or
// reads the frame being built), or both.
Api_Domain :: enum u8 {
	Both,
	Load,
	Render,
}

Api_Function :: struct {
	name:   cstring,
	fn:     lua.CFunction,
	domain: Api_Domain,
}

// Every global function the host gives a script. Each is called through
// `l_api`, which checks its domain first: the function itself never runs
// at the wrong time.
@(private, rodata)
API := [?]Api_Function {
	// The video: declared at load.
	{"video", l_video, .Load},
	{"scene", l_scene, .Load},
	{"cue", l_cue, .Load},
	{"say", l_say, .Load},
	{"song", l_song, .Load},
	{"sound", l_sound, .Load},
	{"physics", l_physics, .Load},
	{"physics3d", l_physics3d, .Load},
	{"sky", l_sky, .Load},
	{"bake", l_bake, .Load},
	{"audio_add", l_audio_add, .Load},
	{"captions_load", l_captions_load, .Load},
	// Nodes and what the frame being built knows.
	{"render_scenes", l_render_scenes, .Render},
	{"scene_info", l_scene_info, .Render},
	{"group", l_group, .Render},
	{"rect", l_rect, .Render},
	{"circle", l_circle, .Render},
	{"ellipse", l_ellipse, .Render},
	{"line", l_line, .Render},
	{"path", l_path, .Render},
	{"text", l_text, .Render},
	{"image", l_image, .Render},
	{"polygon", l_polygon, .Render},
	{"polyline", l_polyline, .Render},
	{"pattern", l_pattern, .Render},
	{"svg", l_svg, .Render},
	{"svg_bbox", l_svg_bbox, .Render},
	{"lottie", l_lottie, .Render},
	{"lottie_info", l_lottie_info, .Render},
	{"shader", l_shader, .Render},
	{"view3d", l_view3d, .Render},
	{"video_frame", l_video_frame, .Render},
	{"video_info", l_video_info, .Both},
	{"audio_info", l_audio_info, .Both},
	{"model_info", l_model_info, .Both},
	{"view3d_project", l_view3d_project, .Both},
	{"subtitle_at", l_subtitle_at, .Render},
	{"subtitles", l_subtitles, .Render},
	{"caption_words", l_caption_words, .Render},
	{"audio_spectrum", l_audio_spectrum, .Render},
	{"audio_energy", l_audio_energy, .Render},
	// Values: any time.
	{"animate", l_animate, .Both},
	{"animate_loop", l_animate_loop, .Both},
	{"ease", l_ease, .Both},
	{"cubic_bezier", l_cubic_bezier, .Both},
	{"spring", l_spring, .Both},
	{"noise", l_noise, .Both},
	{"mix_color", l_mix_color, .Both},
	{"rgb", l_rgb, .Both},
	{"rgba", l_rgba, .Both},
	{"linear_gradient", l_linear_gradient, .Both},
	{"radial_gradient", l_radial_gradient, .Both},
	{"translate", l_translate, .Both},
	{"scale", l_scale, .Both},
	{"rotate", l_rotate, .Both},
	{"skew", l_skew, .Both},
	{"text_width", l_text_width, .Both},
	{"text_fit", l_text_fit, .Both},
	{"text_lines", l_text_lines, .Both},
	{"caption_pages", l_caption_pages, .Both},
	{"path_data", l_path_data, .Both},
	{"outline", l_outline, .Both},
	{"outline_bounds", l_outline_bounds, .Both},
	{"morph", l_morph, .Both},
	{"morph_at", l_morph_at, .Both},
	{"outline_union", l_outline_union, .Both},
	{"outline_subtract", l_outline_subtract, .Both},
	{"outline_intersect", l_outline_intersect, .Both},
	{"outline_exclude", l_outline_exclude, .Both},
	{"outline_divide", l_outline_divide, .Both},
	{"shared", l_shared, .Both},
	{"physics_at", l_physics_at, .Both},
	{"physics3d_at", l_physics3d_at, .Both},
	{"physics3d_instances", l_physics3d_instances, .Both},
	{"audio_buffer", l_audio_buffer, .Both},
	{"audio_onsets", l_audio_onsets, .Both},
	{"spectrum_centered", l_spectrum_centered, .Both},
	{"gunzip", l_gunzip, .Both},
	{"json_decode", l_json_decode, .Both},
	{"check_fields", l_check_fields, .Both},
	{"dofile", l_dofile, .Both},
	{"print", l_print, .Both},
}

@(private)
register_api :: proc(s: ^Script) {
	L := s.L
	lua.pushlightuserdata(L, s)
	lua.setfield(L, lua.REGISTRYINDEX, "onimite.script")
	// Upvalues: the script (`host`), the function's row.
	for &f in API {
		lua.pushlightuserdata(L, s)
		lua.pushlightuserdata(L, &f)
		lua.pushcclosure(L, l_api, 2)
		lua.setglobal(L, f.name)
	}
	register_audio_buffer_methods(s)
	easings := [?]struct {
		name: cstring,
		e:    om.Easing,
	}{{"linear", om.LINEAR}, {"ease_in", om.EASE_IN}, {"ease_out", om.EASE_OUT}, {"ease_in_out", om.EASE_IN_OUT}}
	for e in easings {
		push_easing(L, e.e)
		lua.setglobal(L, e.name)
	}
	// `easing.bounce_out`, `easing.elastic_in_out`, ...: Odin's core:math/ease curves.
	lua.createtable(L, 0, len(ease.Ease))
	for e in ease.Ease {
		push_easing(L, om.named(e))
		name := strings.to_lower(fmt.tprint(e), context.temp_allocator)
		lua.setfield(L, -2, strings.clone_to_cstring(name, context.temp_allocator))
	}
	lua.setglobal(L, "easing")
}

// The script of a state, for functions without the upvalue (the registry
// keeps it under "onimite.script").
@(private)
host_of_state :: proc "c" (L: ^lua.State) -> ^Script {
	lua.getfield(L, lua.REGISTRYINDEX, "onimite.script")
	s := (^Script)(lua.touserdata(L, -1))
	lua.pop(L, 1)
	return s
}

@(private)
host :: #force_inline proc "c" (L: ^lua.State) -> ^Script {
	return (^Script)(lua.touserdata(L, lua.REGISTRYINDEX - 1))
}

// Calls the API function of its upvalue when its domain allows: a load
// function while rendering raises an error naming the script's line (also
// through the standard library's wrappers, `scene`), a render function
// outside a render an error too.
@(private)
l_api :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	f := (^Api_Function)(lua.touserdata(L, lua.REGISTRYINDEX - 2))
	switch f.domain {
	case .Both:
	case .Load:
		if s.ctx != nil {
			context = s.odin_context
			lua.pushstring(L, fmt.ctprintf("%s: %s() works at load, not while rendering a frame", caller_where(L), f.name))
			lua.error(L)
		}
	case .Render:
		if s.ctx == nil {
			lua.L_error(L, "%s() can only be called while rendering a frame", f.name)
		}
	}
	return f.fn(L)
}

// The context of the render in progress (l_api lets a render function run
// only in one), the node the call makes recorded where it came from.
@(private)
render_ctx :: proc(L: ^lua.State, s: ^Script) -> ^om.Context {
	if s.node_sources_on {
		node_source_record(s, L)
	}
	return s.ctx
}

// Where a node came from: the script line that made it, the line that
// called into the helper that made it (`via`, "" if none), both in
// `node_text`, and the scene being rendered ("" at video level; borrowed).
Node_Source :: struct {
	at, via: Text_Range,
	scene:   string,
}

Text_Range :: struct {
	offset, length: u32,
}

// Records where the node the current call makes (the next in the tree)
// comes from. The rows from its index on are an earlier frame's.
@(private)
node_source_record :: proc(s: ^Script, L: ^lua.State) {
	i := len(s.ctx.tree.nodes)
	if i < len(s.node_sources) {
		resize(&s.node_text, s.node_sources[i].at.offset)
		resize(&s.node_sources, i)
	}
	// Nodes made without a call here (none known) come from nowhere.
	nowhere := Text_Range{u32(len(s.node_text)), 0}
	for len(s.node_sources) < i {
		append(&s.node_sources, Node_Source{at = nowhere, via = nowhere})
	}
	text_add :: proc(s: ^Script, str: string) -> Text_Range {
		r := Text_Range{u32(len(s.node_text)), u32(len(str))}
		append(&s.node_text, str)
		return r
	}
	at, via := caller_where_via(L)
	source := Node_Source {
		at  = text_add(s, at),
		via = text_add(s, via),
	}
	if s.frame.scene != nil {
		source.scene = s.frame.scene.scene.name
	}
	append(&s.node_sources, source)
}

// Where node `i` of the last frame built while `node_sources_on` came from
// (zero when unknown).
@(private)
node_source_row :: proc(s: ^Script, i: int) -> Node_Source {
	return s.node_sources[i] if i >= 0 && i < len(s.node_sources) else {}
}

@(private)
node_text_of :: proc(s: ^Script, r: Text_Range) -> string {
	return string(s.node_text[r.offset:][:r.length])
}

// The script line that made node `i` ("" when unknown).
node_source :: proc(s: ^Script, i: int) -> string {
	return node_text_of(s, node_source_row(s, i).at)
}

// The line that called into the helper that made node `i` ("" if none).
node_via :: proc(s: ^Script, i: int) -> string {
	return node_text_of(s, node_source_row(s, i).via)
}

// The scene that was rendering when node `i` was made ("" at video level).
node_scene :: proc(s: ^Script, i: int) -> string {
	return node_source_row(s, i).scene
}

// Forgets the recorded nodes.
node_sources_reset :: proc(s: ^Script) {
	clear(&s.node_sources)
	clear(&s.node_text)
}

// ---- video and scenes -----------------------------------------------------------------

// video{ width, height, fps, background, duration (seconds or {frames=n}), render }
@(private)
l_video :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	fields_begin(L, 1)
	v := &s.video
	v.width = int(get_num(L, 1, "width", 0))
	v.height = int(get_num(L, 1, "height", 0))
	v.fps = int(get_num(L, 1, "fps", 30))
	v.background = om.BLACK
	field(L, 1, "background")
	if paint, ok := read_paint(L, -1, nil).(om.Color); ok {
		v.background = paint
	}
	lua.pop(L, 1)
	v.duration = read_duration(s, L, 1)
	read_audio(s, L, 1, nil)
	// The master bus (fframes' AudioMixOptions): `master_gain_db = 3.5`,
	// `limiter = { ceiling_db = -1.3 }` or `limiter = false`.
	v.buses = read_buses(s, L, 1)
	v.mix.master_gain_db = get_num(L, 1, "master_gain_db", 0)
	field(L, 1, "limiter")
	if lua.istable(L, -1) {
		video_fields := fields_push(L, -1)
		v.mix.ceiling_db = get_num(L, -1, "ceiling_db", 0)
		fields_pop(L, s, -1, "limiter", video_fields)
	} else if lua.isboolean(L, -1) && !lua.toboolean(L, -1) {
		v.mix.no_limiter = true
	}
	lua.pop(L, 1)
	// `motion_blur = { shutter = 180 }`: the shutter's angle, in degrees of a frame.
	field(L, 1, "motion_blur")
	if lua.istable(L, -1) {
		blur_fields := fields_push(L, -1)
		v.shutter = get_num(L, -1, "shutter", 180)
		fields_pop(L, s, -1, "motion_blur", blur_fields)
		if v.shutter <= 0 || v.shutter > 360 {
			lua.L_error(L, "video: motion_blur.shutter is an angle in degrees, above 0 and up to 360")
		}
	}
	lua.pop(L, 1)
	field(L, 1, "render")
	if lua.isfunction(L, -1) {
		s.video_render = lua.L_ref(L, lua.REGISTRYINDEX)
	} else {
		lua.pop(L, 1)
	}
	fields_end(L, s, 1, "video")
	return 0
}

// scene{ "Name", duration = 2, overlap = {previous = 0.5, next = 0}, render = function(f) end }
@(private)
l_scene :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	fields_begin(L, 1)
	sc: om.Scene
	// `hold`: what a presentation does at the scene's end (om.Hold): "alive"
	// (true, the default), "loop", "freeze", or false to play on into the
	// next scene. Read before anything is cloned, so its error leaks nothing.
	field(L, 1, "hold")
	#partial switch lua.type(L, -1) {
	case .NIL:
	case .BOOLEAN:
		sc.hold = .Alive if lua.toboolean(L, -1) else .Flow
	case .STRING:
		switch string(lua.tostring(L, -1)) {
		case "alive":
			sc.hold = .Alive
		case "loop":
			sc.hold = .Loop
		case "freeze":
			sc.hold = .Freeze
		case:
			lua.L_error(L, "scene: hold is \"alive\", \"loop\", \"freeze\" or false (play on into the next scene), not \"%s\"", lua.tostring(L, -1))
		}
	case:
		lua.L_error(L, "scene: hold is \"alive\", \"loop\", \"freeze\" or false (play on into the next scene)")
	}
	lua.pop(L, 1)
	lua.rawgeti(L, 1, 1)
	if lua.type(L, -1) != .STRING {
		field(L, 1, "name")
		lua.remove(L, -2)
	}
	sc.name = strings.clone(string(lua.tostring(L, -1)) if lua.isstring(L, -1) else fmt.tprintf("Scene%d", len(s.scenes) + 1))
	lua.pop(L, 1)
	sc.duration = read_duration(s, L, 1)
	if cue := get_str(L, 1, "cue", ""); cue != "" {
		sc.cue = strings.clone(cue)
	}
	if at, ok := get_opt_num(L, 1, "start"); ok {
		sc.start = at
	}
	sc.source = strings.clone(caller_where(L))
	if sc.duration == nil && sc.start == nil {
		delete(sc.name)
		delete(sc.cue)
		delete(sc.source)
		lua.L_error(L, "scene needs a duration (or a start: it then lasts until the next scene's start)")
	}
	read_audio(s, L, 1, len(s.scenes))
	field(L, 1, "overlap")
	if lua.istable(L, -1) {
		scene_fields := fields_push(L, -1)
		sc.overlap = {get_num(L, -1, "previous", 0), get_num(L, -1, "next", 0)}
		fields_pop(L, s, -1, "overlap", scene_fields)
	}
	lua.pop(L, 1)
	ref: c.int = lua.NOREF
	field(L, 1, "render")
	if lua.isfunction(L, -1) {
		ref = lua.L_ref(L, lua.REGISTRYINDEX)
	} else {
		lua.pop(L, 1)
	}
	fields_end(L, s, 1, "scene")
	append(&s.scenes, sc)
	append(&s.slots, Scene_Slot{s, ref})
	return 0
}

@(private)
read_duration :: proc(s: ^Script, L: ^lua.State, t: c.int) -> om.Duration {
	if terms := read_terms_duration(s, L, t); terms != nil {
		return om.Duration_Terms(terms)
	}
	field(L, t, "duration")
	defer lua.pop(L, 1)
	if lua.isnumber(L, -1) {
		return om.Seconds(lua.tonumber(L, -1))
	}
	if lua.istable(L, -1) {
		owner_fields := fields_push(L, -1)
		frames, secs := get_num(L, -1, "frames", -1), get_num(L, -1, "seconds", -1)
		fields_pop(L, s, -1, "duration", owner_fields)
		if frames >= 0 {
			return om.Frames(int(frames))
		}
		if secs >= 0 {
			return om.Seconds(secs)
		}
	}
	return nil
}

// cue(id, seconds[, { hit = "music.mp3" }]) or cue(id, { seconds, ... }) ->
// the time(s) given: names moments on the video clock. A list names its
// moments id[0], id[1], ... Scenes, audio tracks and animate keys tagged
// with the same `id` should meet there (`inspect` reports the ones that
// don't); `hit` also expects a sound of that track to start there. Ids
// work as times on the command line (`frame video.lua drop`).
@(private)
l_cue :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	id := string(lua.L_checkstring(L, 1))
	hit := ""
	if lua.istable(L, 3) {
		fields_begin(L, 3)
		hit = get_str(L, 3, "hit", "")
		fields_end(L, s, 3, "cue")
	}
	at := caller_where(L)
	if lua.isnumber(L, 2) {
		add_cue(L, s, id, f64(lua.tonumber(L, 2)), hit, at)
	} else if lua.istable(L, 2) {
		n := int(lua.rawlen(L, 2))
		for i in 1 ..= n {
			lua.rawgeti(L, 2, lua.Integer(i))
			if !lua.isnumber(L, -1) {
				lua.L_error(L, "cue(%s, list): entry %d is not a number of seconds", lua.tostring(L, 1), c.int(i))
			}
			add_cue(L, s, fmt.tprintf("%s[%d]", id, i - 1), f64(lua.tonumber(L, -1)), hit, at)
			lua.pop(L, 1)
		}
	} else {
		lua.L_error(L, "cue(id, seconds) or cue(id, { seconds, ... })")
	}
	lua.settop(L, 2)
	return 1
}

@(private)
add_cue :: proc(L: ^lua.State, s: ^Script, id: string, seconds: f64, hit, at: string) {
	for c in s.cues {
		if c.name == id {
			if abs(c.seconds - seconds) > 1e-6 {
				lua.L_error(L, "cue %s is already at %.3fs", strings.clone_to_cstring(id, context.temp_allocator), c.seconds)
			}
			return
		}
	}
	append(&s.cues, Cue{strings.clone(id), seconds, strings.clone(hit), strings.clone(at)})
}

@(private)
l_render_scenes :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	ctx := render_ctx(L, s)
	om.render_scenes(ctx.frame, ctx)
	return 0
}

// scene_info("Name") -> {name, index, start_frame, end_frame, frames, duration, is_last} or nil
@(private)
l_scene_info :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	ctx := render_ctx(L, s)
	info, ok := om.scene_info(ctx, string(lua.L_checkstring(L, 1)))
	if !ok {
		lua.pushnil(L)
		return 1
	}
	push_scene_info(L, info, ctx.video.fps)
	return 1
}

// ---- nodes ---------------------------------------------------------------------------------

// group({transform, opacity, clip = {x, y, w, h}}, function() ... end)
@(private)
l_group :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	ctx := render_ctx(L, s)
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	lua.L_checktype(L, 2, i32(lua.Type.FUNCTION))
	fields_begin(L, 1)
	g: om.Group
	field(L, 1, "transform")
	if lua.istable(L, -1) || lua.type(L, -1) == .STRING {
		g.transform = read_transform(L, -1)
	}
	lua.pop(L, 1)
	if o, ok := get_opt_num(L, 1, "opacity"); ok {
		g.opacity = o
	}
	field(L, 1, "clip")
	if lua.istable(L, -1) {
		if has_field(L, -1, "x") || has_field(L, -1, "w") {
			r := vg.Rect{get_num(L, -1, "x", 0), get_num(L, -1, "y", 0), get_num(L, -1, "w", get_num(L, -1, "width", 0)), get_num(L, -1, "h", get_num(L, -1, "height", 0))}
			outer := fields_push(L, -1)
			rx := get_num(L, -1, "rx", 0)
			field_used("x"); field_used("y"); field_used("w"); field_used("h"); field_used("width"); field_used("height")
			fields_pop(L, s, -1, "group clip", outer)
			if rx > 0 {
				// Rounded corners: the rectangle as a clip path.
				rx = min(rx, r.w / 2, r.h / 2)
				x, y, w, h := r.x, r.y, r.w, r.h
				g.clip_path = fmt.tprintf("M%v %v H%v A%v %v 0 0 1 %v %v V%v A%v %v 0 0 1 %v %v H%v A%v %v 0 0 1 %v %v V%v A%v %v 0 0 1 %v %v Z",
					x + rx, y, x + w - rx, rx, rx, x + w, y + rx, y + h - rx, rx, rx, x + w - rx, y + h, x + rx, rx, rx, x, y + h - rx, y + rx, rx, rx, x + rx, y)
			} else {
				g.clip = r
			}
		} else if lua.rawlen(L, -1) == 4 {
			v: [4]f32
			for k in 0 ..< 4 {
				lua.rawgeti(L, -1, lua.Integer(k + 1))
				v[k] = f32(lua.tonumber(L, -1))
				lua.pop(L, 1)
			}
			g.clip = vg.Rect{v[0], v[1], v[2], v[3]}
		} else {
			lua.L_error(L, "group clip takes {x, y, w, h} or {x = .., y = .., w = .., h = ..}")
		}
	}
	lua.pop(L, 1)
	g.crisp = get_str(L, 1, "shape_rendering", "") == "crispEdges"
	if cp := get_str(L, 1, "clip_path", ""); cp != "" {
		g.clip_path = cp
	}
	if get_str(L, 1, "clip_rule", "") == "evenodd" {
		g.clip_rule = .Even_Odd
	}
	g.blur = get_num(L, 1, "blur", 0)
	g.blend = read_blend(L, 1)
	// box = { x, y, w, h, name }: what the children should stay in (checked
	// by inspect, not clipped).
	field(L, 1, "box")
	if lua.istable(L, -1) {
		outer := fields_push(L, -1)
		g.box = vg.Rect{get_num(L, -1, "x", 0), get_num(L, -1, "y", 0), get_num(L, -1, "w", 0), get_num(L, -1, "h", 0)}
		g.box_name = get_str(L, -1, "name", "box")
		fields_pop(L, s, -1, "group box", outer)
	}
	lua.pop(L, 1)
	if f, images, ok := read_filter(L, 1); ok {
		g.filter = f
		g.filter_images = images
	}
	field(L, 1, "mask")
	g.masked = lua.isfunction(L, -1)
	lua.pop(L, 1)
	g.mask_alpha = get_str(L, 1, "mask_type", "luminance") == "alpha"
	fields_end(L, s, 1, "group")

	om.group_begin(ctx, g)
	status: c.int = 0
	if g.masked {
		om.mask_begin(ctx)
		field(L, 1, "mask")
		status = lua.pcall(L, 0, 0, 0)
		om.group_end(ctx)
	}
	if status == 0 {
		lua.pushvalue(L, 2)
		status = lua.pcall(L, 0, 0, 0)
	}
	om.group_end(ctx)
	if status != 0 {
		// Re-raise with the group closed.
		return c.int(lua.error(L))
	}
	return 0
}

// A drawn node's `transform` (SVG's attribute, in any form read_transform
// reads): the node is drawn in a group with it, ended at the end of the
// caller's scope.
@(private, deferred_in_out = leaf_transform_end)
leaf_transform :: proc(L: ^lua.State, ctx: ^om.Context) -> (grouped: bool) {
	field(L, 1, "transform")
	defer lua.pop(L, 1)
	if !lua.istable(L, -1) && lua.type(L, -1) != .STRING {
		return false
	}
	om.group_begin(ctx, om.Group{transform = read_transform(L, -1)})
	return true
}

@(private)
leaf_transform_end :: proc(L: ^lua.State, ctx: ^om.Context, grouped: bool) {
	if grouped {
		om.group_end(ctx)
	}
}

// rect{x, y, w, h, rx, fill, stroke, stroke_width, line_cap, line_join, opacity}
@(private)
l_rect :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	ctx := render_ctx(L, s)
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	fields_begin(L, 1)
	leaf_transform(L, ctx)
	om.rect(
		ctx,
		{
			x = get_num(L, 1, "x", 0),
			y = get_num(L, 1, "y", 0),
			w = get_num(L, 1, "w", get_num(L, 1, "width", 0)),
			h = get_num(L, 1, "h", get_num(L, 1, "height", 0)),
			rx = get_num(L, 1, "rx", 0),
			ry = get_num(L, 1, "ry", 0),
			style = read_style(L, 1, ctx),
		},
	)
	fields_end(L, s, 1, "rect")
	return 0
}

@(private)
l_circle :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	ctx := render_ctx(L, s)
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	fields_begin(L, 1)
	leaf_transform(L, ctx)
	om.circle(
		ctx,
		{
			cx = get_num(L, 1, "cx", get_num(L, 1, "x", 0)),
			cy = get_num(L, 1, "cy", get_num(L, 1, "y", 0)),
			r = get_num(L, 1, "r", 0),
			style = read_style(L, 1, ctx),
		},
	)
	fields_end(L, s, 1, "circle")
	return 0
}

@(private)
l_ellipse :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	ctx := render_ctx(L, s)
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	fields_begin(L, 1)
	leaf_transform(L, ctx)
	om.ellipse(
		ctx,
		{
			cx = get_num(L, 1, "cx", 0),
			cy = get_num(L, 1, "cy", 0),
			rx = get_num(L, 1, "rx", 0),
			ry = get_num(L, 1, "ry", 0),
			style = read_style(L, 1, ctx),
		},
	)
	fields_end(L, s, 1, "ellipse")
	return 0
}

@(private)
l_line :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	ctx := render_ctx(L, s)
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	fields_begin(L, 1)
	leaf_transform(L, ctx)
	om.line(
		ctx,
		{
			x1 = get_num(L, 1, "x1", 0),
			y1 = get_num(L, 1, "y1", 0),
			x2 = get_num(L, 1, "x2", 0),
			y2 = get_num(L, 1, "y2", 0),
			style = read_style(L, 1, ctx, fill = false),
		},
	)
	fields_end(L, s, 1, "line")
	return 0
}

// path{ d = "M0 0 L10 0 Z" or a path_data handle, fill, fill_rule = "evenodd", stroke, ... }
@(private)
l_path :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	ctx := render_ctx(L, s)
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	fields_begin(L, 1)
	leaf_transform(L, ctx)
	field(L, 1, "d")
	asset := (^om.Path_Asset)(lua.touserdata(L, -1)) if lua.type(L, -1) == .LIGHTUSERDATA else nil
	lua.pop(L, 1)
	rule := asset.fill_rule if asset != nil else vg.Fill_Rule.Non_Zero
	switch get_str(L, 1, "fill_rule", "") {
	case "evenodd":
		rule = .Even_Odd
	case "nonzero":
		rule = .Non_Zero
	}
	om.path(
		ctx,
		{
			d = get_str(L, 1, "d", ""),
			asset = asset,
			fill_rule = rule,
			style = read_style(L, 1, ctx),
		},
	)
	fields_end(L, s, 1, "path")
	return 0
}

// text{ "Hello", x, y, font, size, weight, align = "left"|"center"|"right", letter_spacing, features, fill, stroke, opacity }
@(private)
l_text :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	ctx := render_ctx(L, s)
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	fields_begin(L, 1)
	leaf_transform(L, ctx)
	align := om.Text_Align.Left
	switch get_str(L, 1, "align", "left") {
	case "center", "middle":
		align = .Center
	case "right", "end":
		align = .Right
	}
	fill := get_paint(L, 1, "fill", ctx)
	if !has_field(L, 1, "fill") {
		fill = om.BLACK
	}
	om.text(
		ctx,
		{
			text = text_arg(L, 1),
			x = get_num(L, 1, "x", 0),
			y = get_num(L, 1, "y", 0),
			font = get_str(L, 1, "font", ""),
			size = get_num(L, 1, "size", 16),
			weight = int(get_num(L, 1, "weight", 400)),
			italic = read_italic(L, 1),
			align = align,
			baseline = read_baseline(L, 1),
			letter_spacing = get_num(L, 1, "letter_spacing", 0),
			features = read_features(L, 1),
			variations = read_variations(L, 1),
			line_height = get_num(L, 1, "line_height", 0),
			fill = fill,
			fill_opacity = get_maybe(L, 1, "fill_opacity"),
			stroke = read_stroke(L, 1, ctx),
			opacity = get_maybe(L, 1, "opacity"),
			spans = read_spans(L, 1, ctx),
		},
	)
	fields_end(L, s, 1, "text")
	return 0
}

// image{ src = "logo.png", x, y, w, h, opacity }
@(private)
l_image :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	ctx := render_ctx(L, s)
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	fields_begin(L, 1)
	leaf_transform(L, ctx)
	om.image(
		ctx,
		{
			src = get_str(L, 1, "src", ""),
			x = get_num(L, 1, "x", 0),
			y = get_num(L, 1, "y", 0),
			w = get_num(L, 1, "w", get_num(L, 1, "width", 0)),
			h = get_num(L, 1, "h", get_num(L, 1, "height", 0)),
			fit = read_fit(L, 1),
			align = read_align(L, 1),
			opacity = get_maybe(L, 1, "opacity"),
		},
	)
	fields_end(L, s, 1, "image")
	return 0
}

// `fit = "contain"|"cover"|"fill"`, or SVG `preserve_aspect_ratio =
// "none"|"... meet"|"... slice"`.
@(private)
read_fit :: proc(L: ^lua.State, t: c.int) -> om.Image_Fit {
	switch get_str(L, t, "fit", "") {
	case "cover", "slice":
		return .Cover
	case "fill", "none", "stretch":
		return .Fill
	case "contain", "meet":
		return .Contain
	}
	par := get_str(L, t, "preserve_aspect_ratio", "")
	switch {
	case par == "none":
		return .Fill
	case strings.has_suffix(par, "slice"):
		return .Cover
	}
	return .Contain
}

// `align = {x, y}` (0..1), or the SVG preserveAspectRatio alignment
// (`xMinYMid` ...).
@(private)
read_align :: proc(L: ^lua.State, t: c.int) -> Maybe(om.Vec2) {
	field(L, t, "align")
	if lua.istable(L, -1) {
		v := read_vec2(L, -1)
		lua.pop(L, 1)
		return v
	}
	lua.pop(L, 1)
	par := get_str(L, t, "preserve_aspect_ratio", "")
	if len(par) < 8 {
		return nil
	}
	axis :: proc(s: string) -> f32 {
		switch s {
		case "Min":
			return 0
		case "Max":
			return 1
		}
		return 0.5
	}
	return om.Vec2{axis(par[1:4]), axis(par[5:8])}
}

// ---- animation --------------------------------------------------------------------------

@(private)
l_animate :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	return animate_impl(L, s, false)
}

@(private)
l_animate_loop :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	return animate_impl(L, s, true)
}

Value_Kind :: enum {
	Number,
	Color,
	Vec2,
	Transform,
}

// animate(f, keys): `f` is a frame (or a time in seconds), `keys` a list of
// {start, stop, from, to, easing} (positional or named). The value type
// follows the first key's `from`: number, color, {x, y} or transform.
@(private)
animate_impl :: proc(L: ^lua.State, s: ^Script, looped: bool) -> c.int {
	lua.L_checktype(L, 2, i32(lua.Type.TABLE))
	t: f32
	if lua.isnumber(L, 1) {
		t = f32(lua.tonumber(L, 1))
	} else {
		lua.L_checktype(L, 1, i32(lua.Type.TABLE))
		t = get_num(L, 1, "seconds", 0)
	}
	// Video time minus the animation's clock: where tagged keys start on
	// the video (any clock running at the video's rate).
	clock_offset := f64(s.frame.global_index) / f64(max(s.frame.fps, 1)) + s.frame.shift - f64(t)
	n := int(lua.rawlen(L, 2))
	if n == 0 {
		lua.pushnil(L)
		return 1
	}
	lua.rawgeti(L, 2, 1)
	key_field(L, -1, "from", 3)
	kind := value_kind(L, -1)
	lua.pop(L, 2)

	arena := context.temp_allocator
	has_stop: bool // the last key read gave a stop
	switch kind {
	case .Number:
		keys := make([]om.Key(f32), n, arena)
		for &k, i in keys {
			k = read_key(L, s, i, f32, read_number_value, &has_stop, clock_offset)
		}
		check_last_stop(L, s, keys[n - 1], has_stop, looped)
		lua.pushnumber(L, lua.Number(sample_keys(keys, t, looped)))
	case .Color:
		keys := make([]om.Key(om.Color), n, arena)
		for &k, i in keys {
			k = read_key(L, s, i, om.Color, read_color_value, &has_stop, clock_offset)
		}
		check_last_stop(L, s, keys[n - 1], has_stop, looped)
		push_color(L, sample_keys(keys, t, looped))
	case .Vec2:
		keys := make([]om.Key(om.Vec2), n, arena)
		for &k, i in keys {
			k = read_key(L, s, i, om.Vec2, read_vec2, &has_stop, clock_offset)
		}
		check_last_stop(L, s, keys[n - 1], has_stop, looped)
		push_vec2(L, sample_keys(keys, t, looped))
	case .Transform:
		keys := make([]om.Key(om.Transform), n, arena)
		for &k, i in keys {
			k = read_key(L, s, i, om.Transform, read_transform, &has_stop, clock_offset)
		}
		check_last_stop(L, s, keys[n - 1], has_stop, looped)
		push_transform(L, sample_keys(keys, t, looped))
	}
	return 1
}

@(private)
sample_keys :: proc(keys: []om.Key($T), t: f32, looped: bool) -> T {
	return loop_sample(keys, t) if looped else om.sample(keys, t)
}

@(private)
loop_sample :: proc(keys: []om.Key($T), t: f32) -> T {
	first := keys[0].start
	last := keys[len(keys) - 1]
	total := (last.end if last.end > last.start else last.start) - first
	tt := t
	if total > 0 {
		r := (t - first) - total * f32(int((t - first) / total))
		if r < 0 {r += total}
		tt = first + r
	}
	return om.sample(keys, tt)
}

// Pushes field `name` of the key table at `t`, or its positional entry.
@(private)
key_field :: proc(L: ^lua.State, t: c.int, name: cstring, pos: lua.Integer) {
	field(L, t, name)
	if lua.isnoneornil(L, -1) {
		lua.pop(L, 1)
		lua.rawgeti(L, t, pos)
	}
}

@(private)
read_key :: proc(L: ^lua.State, s: ^Script, i: int, $T: typeid, read: proc(L: ^lua.State, idx: c.int) -> T, has_stop: ^bool, clock_offset: f64) -> (k: om.Key(T)) {
	lua.rawgeti(L, 2, lua.Integer(i + 1))
	key := lua.absindex(L, -1)
	fields_begin(L, key)
	defer {
		fields_end(L, s, key, "animate key")
		lua.pop(L, 1)
	}
	key_field(L, -1, "start", 1)
	k.start = f32(lua.tonumber(L, -1))
	lua.pop(L, 1)
	key_field(L, -1, "stop", 2)
	has_stop^ = bool(lua.isnumber(L, -1))
	k.end = f32(lua.tonumber(L, -1)) if has_stop^ else 0
	lua.pop(L, 1)
	key_field(L, -1, "from", 3)
	k.from = read(L, -1)
	lua.pop(L, 1)
	key_field(L, -1, "to", 4)
	k.to = read(L, -1)
	lua.pop(L, 1)
	key_field(L, -1, "easing", 5)
	k.easing = read_easing(L, -1)
	lua.pop(L, 1)
	if cue := get_str(L, key, "cue", ""); cue != "" && s.ctx != nil {
		key_anchor(L, s, cue, f64(k.start) + clock_offset)
	}
	return
}

// Notes where a tagged key starts (once per id and script line).
@(private)
key_anchor :: proc(L: ^lua.State, s: ^Script, id: string, seconds: f64) {
	at := caller_where(L)
	for a in s.key_anchors {
		if a.id == id && a.at == at {
			return
		}
	}
	append(&s.key_anchors, Key_Anchor{strings.clone(id), seconds, strings.clone(at)})
}

// The last key of an animate list without a stop jumps to its `to` at its
// start unless its easing is a spring: almost always a forgotten stop.
@(private)
check_last_stop :: proc(L: ^lua.State, s: ^Script, last: om.Key($T), has_stop, looped: bool) {
	if !has_stop && !looped && last.easing.kind != .Spring && last.from != last.to {
		report_warning(L, s, {code = .Animate_No_Stop, x = last.start})
	}
}

@(private)
value_kind :: proc(L: ^lua.State, idx: c.int) -> Value_Kind {
	#partial switch lua.type(L, idx) {
	case .STRING:
		return .Color
	case .TABLE:
		if has_field(L, idx, "r") {
			return .Color
		}
		if has_field(L, idx, "translate") || has_field(L, idx, "scale") || has_field(L, idx, "rotate") || has_field(L, idx, "origin") || has_field(L, idx, "skew") || has_field(L, idx, "matrix") {
			return .Transform
		}
		return .Vec2
	}
	return .Number
}

@(private)
read_number_value :: proc(L: ^lua.State, idx: c.int) -> f32 {
	return f32(lua.tonumber(L, idx))
}

@(private)
read_color_value :: proc(L: ^lua.State, idx: c.int) -> om.Color {
	if c, ok := read_paint(L, idx, nil).(om.Color); ok {
		return c
	}
	return om.TRANSPARENT
}

// ---- value helpers -----------------------------------------------------------------------

@(private)
l_translate :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	push_transform(L, om.translate(f32(lua.L_checknumber(L, 1)), f32(lua.L_optnumber(L, 2, 0))))
	return 1
}

// scale(s) or scale(sx, sy[, ox, oy])
@(private)
l_scale :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	sx := f32(lua.L_checknumber(L, 1))
	sy := f32(lua.L_optnumber(L, 2, lua.Number(sx)))
	push_transform(L, om.scale(sx, sy, {f32(lua.L_optnumber(L, 3, 0)), f32(lua.L_optnumber(L, 4, 0))}))
	return 1
}

// rotate(degrees[, ox, oy])
@(private)
l_rotate :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	push_transform(L, om.rotate(f32(lua.L_checknumber(L, 1)), {f32(lua.L_optnumber(L, 2, 0)), f32(lua.L_optnumber(L, 3, 0))}))
	return 1
}

// rgb(r, g, b) with 0..255 channels.
@(private)
l_rgb :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	push_color(L, {f32(lua.L_checknumber(L, 1)) / 255, f32(lua.L_checknumber(L, 2)) / 255, f32(lua.L_checknumber(L, 3)) / 255, 1})
	return 1
}

// rgba(r, g, b, a) with 0..255 channels and 0..1 alpha (CSS).
@(private)
l_rgba :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	push_color(
		L,
		{
			f32(lua.L_checknumber(L, 1)) / 255,
			f32(lua.L_checknumber(L, 2)) / 255,
			f32(lua.L_checknumber(L, 3)) / 255,
			f32(lua.L_optnumber(L, 4, 1)),
		},
	)
	return 1
}

// linear_gradient{ x1, y1, x2, y2, stops = {{0, "#f00"}, {1, "#00f"}} }
@(private)
l_linear_gradient :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	lua.pushvalue(L, 1)
	lua.pushstring(L, "linear")
	lua.setfield(L, -2, "kind")
	return 1
}

// radial_gradient{ cx, cy, r, inner_r, stops = {...} }
@(private)
l_radial_gradient :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	lua.pushvalue(L, 1)
	lua.pushstring(L, "radial")
	lua.setfield(L, -2, "kind")
	return 1
}

@(private)
l_cubic_bezier :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	e := om.cubic_bezier(f32(lua.L_checknumber(L, 1)), f32(lua.L_checknumber(L, 2)), f32(lua.L_checknumber(L, 3)), f32(lua.L_checknumber(L, 4)))
	push_easing(L, e)
	return 1
}

// spring{ mass = 1, stiffness = 100, damping = 10 } or spring(mass, stiffness, damping)
// ease(easing, t, duration): eased progress 0..1 at `t` seconds into a tween
// that starts at runtime (fframes' `animate_runtime`). Springs ignore `duration`.
@(private)
l_ease :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	e := read_easing(L, 1)
	lua.pushnumber(L, lua.Number(om.ease(e, f32(lua.L_checknumber(L, 2)), f32(lua.L_optnumber(L, 3, 1)))))
	return 1
}

// noise(x [, y [, z]] [, seed]): smooth OpenSimplex2 noise in -1..1 (Odin's
// core:math/noise). One or two coordinates give 2D noise, three give 3D.
@(private)
l_noise :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	x := f64(lua.L_checknumber(L, 1))
	y := f64(lua.L_optnumber(L, 2, 0))
	v: f32
	if lua.isnumber(L, 3) {
		seed := i64(lua.L_optinteger(L, 4, 0))
		v = noise.noise_3d_improve_xy(seed, {x, y, f64(lua.tonumber(L, 3))})
	} else {
		seed := i64(lua.L_optinteger(L, 4, 0))
		v = noise.noise_2d(seed, {x, y})
	}
	lua.pushnumber(L, lua.Number(v))
	return 1
}

// mix_color(a, b, t [, space]): colour between a and b, mixed in "oklab"
// (default: perceptually even), "linear" (light) or "srgb" (as stored).
// Returns a colour table usable anywhere a colour is.
@(private)
l_mix_color :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	a, b := read_color_value(L, 1), read_color_value(L, 2)
	t := f32(lua.L_checknumber(L, 3))
	space := string(lua.L_optstring(L, 4, "oklab"))
	push_color(L, mix_color(a, b, t, space))
	return 1
}

@(private)
mix_color :: proc(a, b: om.Color, t: f32, space: string) -> om.Color {
	lerp3 :: proc(p, q: [3]f32, t: f32) -> [3]f32 {return p + (q - p) * t}
	alpha := a.a + (b.a - a.a) * t
	pa, pb := [3]f32{a.r, a.g, a.b}, [3]f32{b.r, b.g, b.b}
	out: [3]f32
	switch space {
	case "srgb":
		out = lerp3(pa, pb, t)
	case "linear":
		out = linear_to_srgb(lerp3(srgb_to_linear(pa), srgb_to_linear(pb), t))
	case:
		out = linear_to_srgb(oklab_to_linear(lerp3(linear_to_oklab(srgb_to_linear(pa)), linear_to_oklab(srgb_to_linear(pb)), t)))
	}
	return {clamp(out.r, 0, 1), clamp(out.g, 0, 1), clamp(out.b, 0, 1), alpha}
}

@(private)
srgb_to_linear :: proc(c: [3]f32) -> (l: [3]f32) {
	for v, i in c {
		l[i] = v / 12.92 if v <= 0.04045 else math.pow((v + 0.055) / 1.055, 2.4)
	}
	return
}

@(private)
linear_to_srgb :: proc(l: [3]f32) -> (c: [3]f32) {
	for x, i in l {
		v := max(x, 0)
		c[i] = v * 12.92 if v <= 0.0031308 else 1.055 * math.pow(v, 1 / 2.4) - 0.055
	}
	return
}

// Björn Ottosson's OKLab.
@(private)
linear_to_oklab :: proc(c: [3]f32) -> [3]f32 {
	l := math.cbrt(0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b)
	m := math.cbrt(0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b)
	s := math.cbrt(0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b)
	return {
		0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
		1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
		0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
	}
}

@(private)
oklab_to_linear :: proc(c: [3]f32) -> [3]f32 {
	l := c.x + 0.3963377774 * c.y + 0.2158037573 * c.z
	m := c.x - 0.1055613458 * c.y - 0.0638541728 * c.z
	s := c.x - 0.0894841775 * c.y - 1.2914855480 * c.z
	l, m, s = l * l * l, m * m * m, s * s * s
	return {
		4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
		-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
		-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
	}
}

@(private)
l_spring :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	e: om.Easing
	if lua.istable(L, 1) {
		fields_begin(L, 1)
		e = om.spring(get_num(L, 1, "mass", 1), get_num(L, 1, "stiffness", 100), get_num(L, 1, "damping", 10))
		fields_end(L, s, 1, "spring")
	} else {
		e = om.spring(f32(lua.L_optnumber(L, 1, 1)), f32(lua.L_optnumber(L, 2, 100)), f32(lua.L_optnumber(L, 3, 10)))
	}
	push_easing(L, e)
	return 1
}

// ---- text measuring -----------------------------------------------------------------------

@(private)
font_query :: proc(L: ^lua.State, t: c.int) -> om.Font_Query {
	return {
		family = get_str(L, t, "font", ""),
		size = get_num(L, t, "size", 16),
		weight = int(get_num(L, t, "weight", 400)),
		italic = read_italic(L, t),
		letter_spacing = get_num(L, t, "letter_spacing", 0),
		features = read_features(L, t),
		variations = read_variations(L, t),
	}
}

// The media text is measured with: the render's, or at load the script's.
@(private)
measure_media :: proc(L: ^lua.State, s: ^Script, fn: cstring) -> ^om.Media {
	if s.ctx != nil {
		return s.ctx.media
	}
	if s.media == nil {
		lua.L_error(L, "%s() needs the media: the script was loaded without it", fn)
	}
	return s.media
}

// A measured family that isn't in the media: the warning drawing gives, on
// the frame being rendered, or one of the load's problems (not when no
// fonts are loaded at all: a script loaded without its media measures with
// the fallback font).
@(private)
measured :: proc(s: ^Script, q: om.Font_Query, ok: bool) {
	if ok || q.family == "" {
		return
	}
	if s.ctx != nil {
		om.report_missing_font(s.ctx, q.family)
		return
	}
	if len(om.media_font_faces(s.media)) == 0 {
		return
	}
	load_problem(s, .Warning, {code = .Missing_Font, name = q.family})
}

// text_width{ "text", font, size, weight, letter_spacing } -> pixels
// print(...): Lua's, on stderr: stdout carries the command's output (one
// JSON document with --json, the MCP server's messages).
@(private)
l_print :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	n := lua.gettop(L)
	b := strings.builder_make(context.temp_allocator)
	for i in 1 ..= n {
		if i > 1 {
			strings.write_byte(&b, '\t')
		}
		size: c.size_t
		str := lua.L_tostring(L, i, &size)
		strings.write_string(&b, string((cast([^]u8)str)[:size]))
		lua.pop(L, 1)
	}
	strings.write_byte(&b, '\n')
	os.write_string(os.stderr, strings.to_string(b))
	return 0
}

@(private)
l_text_width :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	m := measure_media(L, s, "text_width")
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	q := font_query(L, 1)
	str := text_arg(L, 1)
	// Shaping costs: widths are kept by text and font, so scripts can measure
	// every frame without keeping their own memo.
	key := hash.fnv64a(transmute([]u8)str) ~ hash.fnv64a(transmute([]u8)q.family) * 31 ~
		u64(transmute(u32)q.size) << 20 ~ u64(q.weight) << 7 ~ u64(q.italic) ~ u64(transmute(u32)q.letter_spacing) * 1099511628211
	for f in q.features {
		key = key * 1099511628211 ~ hash.fnv64a(transmute([]u8)f.tag) ~ u64(f.value) << 40
	}
	for v in q.variations {
		key = key * 1099511628211 ~ hash.fnv64a(transmute([]u8)v.tag) ~ u64(transmute(u32)v.value) << 24
	}
	w, cached := s.widths[key]
	if !cached {
		ok: bool
		w, ok = om.text_width(m, q, str)
		measured(s, q, ok)
		if len(s.widths) > 1 << 16 {
			clear(&s.widths)
		}
		s.widths[key] = w
	}
	lua.pushnumber(L, lua.Number(w))
	return 1
}

// gunzip(path) -> string: the decompressed contents of a gzip file (a path
// relative to the script's directory, or absolute), e.g. data archives read
// when the script loads. Raises a Lua error when the file can't be read.
@(private)
l_gunzip :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	name := string(lua.L_checkstring(L, 1))
	path := name
	if !filepath.is_abs(name) {
		path, _ = filepath.join({filepath.dir(s.path), name}, context.temp_allocator)
	}
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	if err := gzip.load_from_file(path, &buf); err != nil {
		msg := fmt.tprintf("gunzip(%q): %v", name, err)
		lua.pushlstring(L, cstring(raw_data(msg)), c.size_t(len(msg)))
		return c.int(lua.error(L))
	}
	data := bytes.buffer_to_bytes(&buf)
	lua.pushlstring(L, cstring(raw_data(data)), c.size_t(len(data)))
	return 1
}

// json_decode(text) -> value: JSON (or JSON5: comments, unquoted keys,
// trailing commas) as Lua, the way `props` reads it (objects as tables,
// arrays as sequences from 1, integers as integers, null as nil),
// e.g. a design-tokens file read at load. Raises a Lua error on invalid JSON.
@(private)
l_json_decode :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	n: c.size_t
	p := lua.L_checkstring(L, 1, &n)
	v, err := json.parse_string(strings.string_from_ptr((^u8)(p), int(n)), .JSON5, parse_integers = true)
	if err != nil {
		json.destroy_value(v)
		msg := fmt.tprintf("json_decode: invalid JSON (%v)", err)
		lua.pushlstring(L, cstring(raw_data(msg)), c.size_t(len(msg)))
		return c.int(lua.error(L))
	}
	push_json(L, v)
	json.destroy_value(v)
	return 1
}

// text_fit{ "text", font, size, weight, max_width, ellipsis = "…" } -> string
@(private)
l_text_fit :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	m := measure_media(L, s, "text_fit")
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	q := font_query(L, 1)
	fitted, ok := om.text_fit(m, q, text_arg(L, 1), get_num(L, 1, "max_width", 1e9), get_str(L, 1, "ellipsis", "…"))
	measured(s, q, ok)
	lua.pushlstring(L, cstring(raw_data(fitted)), c.size_t(len(fitted)))
	return 1
}

// text_lines{ "text", font, size, weight, max_width } -> {lines}
@(private)
l_text_lines :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	m := measure_media(L, s, "text_lines")
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	q := font_query(L, 1)
	lines, ok := om.text_break_lines(m, q, text_arg(L, 1), get_num(L, 1, "max_width", 1e9))
	measured(s, q, ok)
	lua.createtable(L, c.int(len(lines)), 0)
	for l, i in lines {
		lua.pushlstring(L, cstring(raw_data(l)), c.size_t(len(l)))
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	return 1
}

// ---- table readers --------------------------------------------------------------------------

@(private)
has_field :: proc(L: ^lua.State, t: c.int, key: cstring) -> bool {
	field(L, t, key)
	defer lua.pop(L, 1)
	return !lua.isnoneornil(L, -1)
}

@(private)
get_num :: proc(L: ^lua.State, t: c.int, key: cstring, def: f32) -> f32 {
	field(L, t, key)
	defer lua.pop(L, 1)
	if lua.isnumber(L, -1) {
		return f32(lua.tonumber(L, -1))
	}
	return def
}

@(private)
get_opt_num :: proc(L: ^lua.State, t: c.int, key: cstring) -> (f32, bool) {
	field(L, t, key)
	defer lua.pop(L, 1)
	if lua.isnumber(L, -1) {
		return f32(lua.tonumber(L, -1)), true
	}
	return 0, false
}

@(private)
get_maybe :: proc(L: ^lua.State, t: c.int, key: cstring) -> Maybe(f32) {
	if v, ok := get_opt_num(L, t, key); ok {
		return v
	}
	return nil
}

// A string field; the result borrows Lua's string, which stays alive while
// the table does (builders copy it).
@(private)
get_str :: proc(L: ^lua.State, t: c.int, key: cstring, def: string) -> string {
	field(L, t, key)
	defer lua.pop(L, 1)
	if lua.type(L, -1) == .STRING {
		n: c.size_t
		p := lua.tolstring(L, -1, &n)
		return string((cast([^]u8)p)[:n])
	}
	return def
}

// The text of a text-like table: its first entry or its `text` field.
@(private)
text_arg :: proc(L: ^lua.State, t: c.int) -> string {
	lua.rawgeti(L, t, 1)
	defer lua.pop(L, 1)
	if lua.isstring(L, -1) {
		n: c.size_t
		p := lua.tolstring(L, -1, &n)
		return string((cast([^]u8)p)[:n])
	}
	return get_str(L, t, "text", "")
}

@(private)
get_paint :: proc(L: ^lua.State, t: c.int, key: cstring, ctx: ^om.Context) -> om.Paint {
	field(L, t, key)
	defer lua.pop(L, 1)
	return read_paint(L, -1, ctx)
}

// A shape's style: `fill`, `fill_opacity`, the stroke (`read_stroke`),
// `opacity` and `shape_rendering = "crispEdges"`; a line has no fill.
@(private)
read_style :: proc(L: ^lua.State, t: c.int, ctx: ^om.Context, fill := true) -> om.Shape_Style {
	return {
		fill = get_paint(L, t, "fill", ctx) if fill else nil,
		fill_opacity = get_maybe(L, t, "fill_opacity") if fill else nil,
		stroke = read_stroke(L, t, ctx),
		opacity = get_maybe(L, t, "opacity"),
		crisp = get_str(L, t, "shape_rendering", "") == "crispEdges",
	}
}

@(private)
read_stroke :: proc(L: ^lua.State, t: c.int, ctx: ^om.Context) -> (s: om.Stroke) {
	s.paint = get_paint(L, t, "stroke", ctx)
	s.width = get_num(L, t, "stroke_width", 1 if s.paint != nil else 0)
	switch get_str(L, t, "line_cap", "butt") {
	case "round":
		s.cap = .Round
	case "square":
		s.cap = .Square
	}
	switch get_str(L, t, "line_join", "miter") {
	case "round":
		s.join = .Round
	case "bevel":
		s.join = .Bevel
	}
	field(L, t, "stroke_dasharray")
	if lua.isnumber(L, -1) {
		d := make([]f32, 1, ctx.tree.arena if ctx != nil else context.temp_allocator)
		d[0] = f32(lua.tonumber(L, -1))
		s.dash = d
	} else if lua.istable(L, -1) {
		n := int(lua.rawlen(L, -1))
		d := make([]f32, n, ctx.tree.arena if ctx != nil else context.temp_allocator)
		for &v, i in d {
			lua.rawgeti(L, -1, lua.Integer(i + 1))
			v = f32(lua.tonumber(L, -1))
			lua.pop(L, 1)
		}
		s.dash = d
	}
	lua.pop(L, 1)
	s.dash_offset = get_num(L, t, "stroke_dashoffset", 0)
	s.path_length = get_num(L, t, "path_length", 0)
	s.miter_limit = get_num(L, t, "miter_limit", 0)
	s.opacity = get_maybe(L, t, "stroke_opacity")
	return
}

// nil / "none" -> no paint; "#rrggbb[aa]" or a color table -> color; a
// gradient table -> gradient (stops copied into the frame arena).
@(private)
read_paint :: proc(L: ^lua.State, at: c.int, ctx: ^om.Context) -> om.Paint {
	idx := lua.absindex(L, at)
	#partial switch lua.type(L, idx) {
	case .STRING:
		str := string(lua.tostring(L, idx))
		if str == "none" || str == "" {
			return nil
		}
		// Any CSS colour: hex, rgb()/rgba(), hsl()/hsla(), names, transparent.
		col, ok := vg.css_color_parse(str)
		if !ok {
			bad_string(L, "colour", str, "a CSS colour (#rgb, #rrggbb[aa], rgb(), hsl(), a name), or none")
		}
		return col
	case .TABLE:
		kind := get_str(L, idx, "kind", "")
		// Gradient and pattern tables are read here, where they are used.
		checking := kind == "linear" || kind == "radial" || kind == "pattern"
		outer: Field_Log
		if checking {
			outer = fields_push(L, idx)
			field_used("kind")
			field_used("node")
			field_used("content")
		}
		defer if checking {
			fields_pop(L, host(L), idx, "linear_gradient" if kind == "linear" else "radial_gradient" if kind == "radial" else "pattern", outer)
		}
		switch kind {
		case "linear":
			return om.Linear_Gradient {
				x1 = get_num(L, idx, "x1", 0),
				y1 = get_num(L, idx, "y1", 0),
				x2 = get_num(L, idx, "x2", 0),
				y2 = get_num(L, idx, "y2", 0),
				stops = read_stops(L, idx, ctx),
				space = read_paint_space(L, idx),
			}
		case "radial":
			g := om.Radial_Gradient {
				cx = get_num(L, idx, "cx", 0),
				cy = get_num(L, idx, "cy", 0),
				inner_r = get_num(L, idx, "inner_r", get_num(L, idx, "fr", 0)),
				r = get_num(L, idx, "r", 0),
				stops = read_stops(L, idx, ctx),
				space = read_paint_space(L, idx),
			}
			// SVG fx / fy (either defaults to the center).
			if has_field(L, idx, "fx") || has_field(L, idx, "fy") {
				g.focal = om.Vec2{get_num(L, idx, "fx", g.cx), get_num(L, idx, "fy", g.cy)}
			}
			return g
		case "pattern":
			return om.Pattern {
				content = i32(get_num(L, idx, "node", -1)),
				x = get_num(L, idx, "x", 0),
				y = get_num(L, idx, "y", 0),
				w = get_num(L, idx, "w", get_num(L, idx, "width", 0)),
				h = get_num(L, idx, "h", get_num(L, idx, "height", 0)),
				space = read_paint_space(L, idx),
			}
		}
		if has_field(L, idx, "r") {
			return om.Color{get_num(L, idx, "r", 0), get_num(L, idx, "g", 0), get_num(L, idx, "b", 0), get_num(L, idx, "a", 1)}
		}
	}
	return nil
}

// An unparseable colour or transform string: an Error diagnostic while
// rendering (it draws black / untransformed), a Lua error while the script
// loads.
@(private)
bad_string :: proc(L: ^lua.State, what, str, want: string) {
	ctx := host(L).ctx
	if ctx == nil {
		msg := fmt.ctprintf("invalid %s %q (want %s)", what, str, want)
		lua.L_error(L, "%s", msg)
	}
	om.report(ctx, .Error, {code = .Invalid_Value, name = what, a = str, b = want})
}

@(private)
read_stops :: proc(L: ^lua.State, t: c.int, ctx: ^om.Context) -> []vg.Gradient_Stop {
	field(L, t, "stops")
	defer lua.pop(L, 1)
	if !lua.istable(L, -1) {
		return nil
	}
	n := int(lua.rawlen(L, -1))
	alloc := ctx.tree.arena if ctx != nil else context.temp_allocator
	stops := make([]vg.Gradient_Stop, n, alloc)
	for &st, i in stops {
		lua.rawgeti(L, -1, lua.Integer(i + 1))
		lua.rawgeti(L, -1, 1)
		st.offset = f32(lua.tonumber(L, -1))
		lua.pop(L, 1)
		lua.rawgeti(L, -1, 2)
		if col, ok := read_paint(L, -1, nil).(om.Color); ok {
			st.color = col
		}
		lua.pop(L, 2)
	}
	return stops
}

// {x, y} or {x = .., y = ..}
@(private)
read_vec2 :: proc(L: ^lua.State, at: c.int) -> om.Vec2 {
	idx := lua.absindex(L, at)
	if lua.isnumber(L, idx) {
		v := f32(lua.tonumber(L, idx))
		return {v, v}
	}
	if !lua.istable(L, idx) {
		return {}
	}
	if has_field(L, idx, "x") {
		return {get_num(L, idx, "x", 0), get_num(L, idx, "y", 0)}
	}
	lua.rawgeti(L, idx, 1)
	lua.rawgeti(L, idx, 2)
	defer lua.pop(L, 2)
	return {f32(lua.tonumber(L, -2)), f32(lua.tonumber(L, -1))}
}

// {translate = {x, y}, scale = s | {sx, sy}, rotate = degrees, skew = {x, y},
// origin = {x, y}}, or a full matrix: {matrix = {a, b, c, d, e, f}},
// {matrix = "rotate(45) translate(10)"}, {a, b, c, d, e, f}, or an SVG
// transform list string.
@(private)
read_transform :: proc(L: ^lua.State, at: c.int) -> om.Transform {
	idx := lua.absindex(L, at)
	if !lua.istable(L, idx) || is_matrix_array(L, idx) {
		return read_matrix(L, idx)
	}
	field(L, idx, "matrix")
	if !lua.isnoneornil(L, -1) {
		defer lua.pop(L, 1)
		return read_matrix(L, -1)
	}
	lua.pop(L, 1)
	t := om.IDENTITY
	field(L, idx, "translate")
	if !lua.isnoneornil(L, -1) {t.translate = read_vec2(L, -1)}
	lua.pop(L, 1)
	field(L, idx, "scale")
	if !lua.isnoneornil(L, -1) {t.scale = read_vec2(L, -1)}
	lua.pop(L, 1)
	t.rotate = get_num(L, idx, "rotate", 0)
	field(L, idx, "skew")
	if !lua.isnoneornil(L, -1) {t.skew = read_vec2(L, -1)}
	lua.pop(L, 1)
	if v, ok := get_opt_num(L, idx, "skew_x"); ok {t.skew.x = v}
	if v, ok := get_opt_num(L, idx, "skew_y"); ok {t.skew.y = v}
	field(L, idx, "origin")
	if !lua.isnoneornil(L, -1) {t.origin = read_vec2(L, -1)}
	lua.pop(L, 1)
	return t
}

// {a, b, c, d, e, f} or an SVG transform list ("translate(10 20) scale(2)",
// applied left to right as in SVG) as a matrix transform.
@(private)
read_matrix :: proc(L: ^lua.State, at: c.int) -> om.Transform {
	idx := lua.absindex(L, at)
	if lua.type(L, idx) == .STRING {
		str := string(lua.tostring(L, idx))
		if m, ok := vg.transform_svg(str); ok {
			return om.affine(m)
		}
		bad_string(L, "transform", str, "matrix(a b c d e f), translate, scale, rotate, skewX or skewY")
		return om.IDENTITY
	}
	if !is_matrix_array(L, idx) {
		return om.IDENTITY
	}
	m: vg.Transform2D
	for i in 0 ..< 6 {
		lua.rawgeti(L, idx, lua.Integer(i + 1))
		m[i] = f32(lua.tonumber(L, -1))
		lua.pop(L, 1)
	}
	return om.affine(m)
}

@(private)
is_matrix_array :: proc(L: ^lua.State, idx: c.int) -> bool {
	if !lua.istable(L, idx) {
		return false
	}
	lua.rawgeti(L, idx, 6)
	defer lua.pop(L, 1)
	return bool(lua.isnumber(L, -1))
}

@(private)
read_easing :: proc(L: ^lua.State, at: c.int) -> om.Easing {
	idx := lua.absindex(L, at)
	if !lua.istable(L, idx) {
		return om.LINEAR
	}
	e: om.Easing
	switch get_str(L, idx, "kind", "linear") {
	case "cubic":
		e.kind = .Cubic_Bezier
	case "spring":
		e.kind = .Spring
	case "named":
		e.kind = .Named
	}
	field(L, idx, "p")
	for i in 0 ..< 4 {
		lua.rawgeti(L, -1, lua.Integer(i + 1))
		e.p[i] = f32(lua.tonumber(L, -1))
		lua.pop(L, 1)
	}
	lua.pop(L, 1)
	return e
}

// ---- pushers -------------------------------------------------------------------------------

@(private)
push_color :: proc(L: ^lua.State, col: om.Color) {
	lua.createtable(L, 0, 4)
	set_num(L, "r", col.r)
	set_num(L, "g", col.g)
	set_num(L, "b", col.b)
	set_num(L, "a", col.a)
}

@(private)
push_vec2 :: proc(L: ^lua.State, v: om.Vec2) {
	lua.createtable(L, 2, 2)
	lua.pushnumber(L, lua.Number(v.x))
	lua.rawseti(L, -2, 1)
	lua.pushnumber(L, lua.Number(v.y))
	lua.rawseti(L, -2, 2)
	set_num(L, "x", v.x)
	set_num(L, "y", v.y)
}

@(private)
push_transform :: proc(L: ^lua.State, t: om.Transform) {
	lua.createtable(L, 0, 4)
	push_vec2(L, t.translate)
	lua.setfield(L, -2, "translate")
	push_vec2(L, t.scale)
	lua.setfield(L, -2, "scale")
	set_num(L, "rotate", t.rotate)
	push_vec2(L, t.skew)
	lua.setfield(L, -2, "skew")
	push_vec2(L, t.origin)
	lua.setfield(L, -2, "origin")
	if m, ok := t.affine.?; ok {
		lua.createtable(L, 6, 0)
		for v, i in m {
			lua.pushnumber(L, lua.Number(v))
			lua.rawseti(L, -2, lua.Integer(i + 1))
		}
		lua.setfield(L, -2, "matrix")
	}
}

@(private)
push_easing :: proc(L: ^lua.State, e: om.Easing) {
	lua.createtable(L, 0, 2)
	switch e.kind {
	case .Linear:
		lua.pushstring(L, "linear")
	case .Cubic_Bezier:
		lua.pushstring(L, "cubic")
	case .Spring:
		lua.pushstring(L, "spring")
	case .Named:
		lua.pushstring(L, "named")
	}
	lua.setfield(L, -2, "kind")
	lua.createtable(L, 4, 0)
	for v, i in e.p {
		lua.pushnumber(L, lua.Number(v))
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	lua.setfield(L, -2, "p")
}
