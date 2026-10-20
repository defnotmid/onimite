package onimite_script

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import om "../onimite"
import osong "deps:odawg/song"
import ospec "deps:odawg/spec"
import otempo "deps:odawg/tempo"
import otheory "deps:odawg/theory"
import lua "vendor:lua/5.4"

// Songs: `song { "score", ... }` composes music with odawg (its spec, in
// Tone.js's vocabulary: odawg's API.md §3) and makes it a sound tracks play
// by name, like a clip; its sections and markers become cues. It returns
// the song as an object whose dot-functions answer on the video clock
// (beat_clock's signatures):
//
//     score.time("drop@1m"), score.time(8)      -- seconds (a number is a beat)
//     score.beat(f), score.bar(f), score.frame("drop", fps)
//     score.seconds("2m", "drop")               -- a length, measured where
//     score.snap(t, "8n"), score.pulse(f, 9), score.pulse(f, { part, note, decay })
//     score.section(f)                          -- { name, progress, bar, beat, index }
//     score.hits { part, note, range }          -- seconds
//     score.events { part, note, range }        -- { time, note, duration, velocity, part }
//     score.note("5", "drop@2m")                -- an in-key note name
//     score.name, score.start, score.duration, score.key, score.sections, score.markers
//
// `sound { "whoosh", duration = 0.5 }` and
// `sound { { "Synth", oscillator = { type = "sine" } }, note = "E6", duration = "16n" }`
// are one-note songs, named by their content, returned as that name.
//
// The Lua table becomes a spec value (json.Value) generically: a table with
// string keys an object (its [1] the "name"), a sequence an array, a lone
// name where a record goes (`{ "intro" }` as a section) that record;
// onimite's time forms (`{ audio = "intro", plus = { seconds = 1 } }`,
// `{ frame = n }`) are resolved to seconds where odawg takes seconds: the
// song's `start`, a section's `duration` and `start`. What odawg finds
// reading and composing it is a warning or error at the script line.

// A song or sound this load made: its name (owned), the media's song, the
// key of the spec it was made from (value_key: the clip's own adds its
// files'), and the line that made it.
Script_Song :: struct {
	name:  string,
	clip:  ^om.Song_Clip,
	key:   u64,
	sound: bool,
	at:    string,
}

// The song or sound `name` this load made, or nil.
script_song :: proc(s: ^Script, name: string) -> ^om.Song_Clip {
	for x in s.songs {
		if x.name == name {
			return x.clip
		}
	}
	return nil
}

@(private)
songs_unload :: proc(s: ^Script) {
	for x in s.songs {
		delete(x.name)
		delete(x.at)
	}
	delete(s.songs)
}

// ---- the table as a spec value -------------------------------------------------------

// Where a value sits in the spec, by its path there ("" the song,
// "sections/2" a section): which of its keys take onimite's time forms.
@(private = "file")
Spec_Level :: enum u8 {
	Other,
	Song,
	Section,
}

@(private = "file")
spec_level :: proc(at: string) -> Spec_Level {
	if at == "" {
		return .Song
	}
	if strings.has_prefix(at, "sections/") && strings.count(at, "/") == 1 {
		return .Section
	}
	return .Other
}

// The keys at a level that take a time form (resolved to seconds).
@(private = "file")
is_time_key :: proc(level: Spec_Level, key: string) -> bool {
	switch level {
	case .Song:
		return key == "start"
	case .Section:
		return key == "duration" || key == "start"
	case .Other:
	}
	return false
}

// Where a table's positional entries go at `at`: odawg's rows (the one
// owner of the shorthand), and the song's own name at the root.
@(private = "file", rodata)
NAME_FIELD := [?]string{"name"}

@(private = "file")
lua_text :: proc(L: ^lua.State, idx: c.int) -> string {
	n: c.size_t
	p := lua.tolstring(L, idx, &n)
	return string((cast([^]u8)p)[:n])
}

// The Lua value at `idx` as a spec value (temp memory), `fn` and `path`
// naming it in errors, `at` its path in the spec ("": the song; a clip's
// effects: "effects").
@(private)
value_from_lua :: proc(L: ^lua.State, s: ^Script, idx: c.int, fn, path, at: string) -> json.Value {
	idx := lua.absindex(L, idx)
	ta := context.temp_allocator
	#partial switch lua.type(L, idx) {
	case .NIL:
		return json.Null{}
	case .BOOLEAN:
		return json.Boolean(lua.toboolean(L, idx))
	case .NUMBER:
		if lua.isinteger(L, idx) {
			return json.Integer(lua.tointeger(L, idx))
		}
		return json.Float(lua.tonumber(L, idx))
	case .STRING:
		return json.String(strings.clone(lua_text(L, idx), ta))
	case .TABLE:
	case:
		lua.L_error(L, "%s: %s is a %s, not data (numbers, strings, booleans, tables)", strings.clone_to_cstring(fn, ta), strings.clone_to_cstring(path, ta), lua.L_typename(L, idx))
	}
	n := int(lua.rawlen(L, idx))
	keys := sorted_keys(L, idx)
	fields, rest := ospec.positional_fields(at)
	list := ospec.positional_list(at, n, n > 0 && lua_is_string(L, idx, 1))
	if at == "" {
		fields, list = NAME_FIELD[:], false
	}
	if len(keys) == 0 && n > 0 && list {
		a := make(json.Array, 0, n, ta)
		for i in 1 ..= n {
			lua.rawgeti(L, idx, lua.Integer(i))
			append(&a, value_from_lua(L, s, -1, fn, fmt.tprintf("%s[%d]", path, i), spec_index(at, i)))
			lua.pop(L, 1)
		}
		return a
	}
	if n > len(fields) && rest == "" {
		if len(fields) == 0 {
			lua.L_error(L, "%s: %s: entries and keys together (found %d entries; a list or keys, not both)", strings.clone_to_cstring(fn, ta), strings.clone_to_cstring(path, ta), c.int(n))
		}
		lua.L_error(L, "%s: %s: only the first entry is its %s, the rest are keys (found %d entries)", strings.clone_to_cstring(fn, ta), strings.clone_to_cstring(path, ta), strings.clone_to_cstring(fields[0], ta), c.int(n))
	}
	o := make(json.Object, len(keys) + len(fields) + 1, ta)
	for i in 1 ..= min(n, len(fields)) {
		lua.rawgeti(L, idx, lua.Integer(i))
		k := fields[i - 1]
		o[k] = value_from_lua(L, s, -1, fn, fmt.tprintf("%s[%d]", path, i), spec_join(at, k))
		lua.pop(L, 1)
	}
	if n > len(fields) {
		a := make(json.Array, 0, n - len(fields), ta)
		for i in len(fields) + 1 ..= n {
			lua.rawgeti(L, idx, lua.Integer(i))
			append(&a, value_from_lua(L, s, -1, fn, fmt.tprintf("%s[%d]", path, i), spec_index(spec_join(at, rest), i - len(fields))))
			lua.pop(L, 1)
		}
		o[rest] = a
	}
	level := spec_level(at)
	for k in keys {
		push_key(L, idx, k)
		key_path := fmt.tprintf("%s.%s", path, k)
		if is_time_key(level, k) && lua.istable(L, -1) {
			o[k] = json.Float(seconds_from_terms(L, s, -1, fn, key_path))
		} else {
			o[k] = value_from_lua(L, s, -1, fn, key_path, spec_join(at, k))
		}
		lua.pop(L, 1)
	}
	return o
}

@(private = "file")
spec_join :: proc(at, key: string) -> string {
	return at == "" ? key : fmt.tprintf("%s/%s", at, key)
}

@(private = "file")
spec_index :: proc(at: string, i: int) -> string {
	return fmt.tprintf("%s/%d", at, i)
}

@(private = "file")
lua_is_string :: proc(L: ^lua.State, t: c.int, i: int) -> bool {
	lua.rawgeti(L, t, lua.Integer(i))
	defer lua.pop(L, 1)
	return lua.type(L, -1) == .STRING
}

// An onimite time form at `idx` (`{ audio = "intro", plus = { seconds = 1 } }`,
// `{ frame = n }`, a list summed) in seconds.
@(private = "file")
seconds_from_terms :: proc(L: ^lua.State, s: ^Script, idx: c.int, fn, path: string) -> f64 {
	terms := make([dynamic]om.Time_Term, context.temp_allocator)
	read_time_terms(s, L, idx, 1, &terms)
	ta := context.temp_allocator
	for t in terms {
		if t.kind == .Frames && s.video.fps <= 0 {
			lua.L_error(L, "%s: %s counts frames: call video{} first (its fps)", strings.clone_to_cstring(fn, ta), strings.clone_to_cstring(path, ta))
		}
	}
	secs, missing, ok := om.terms_seconds(terms[:], s.video.fps, measure_media(L, s, "song"))
	if !ok {
		lua.L_error(L, "%s: %s is timed by the length of %s, which is not in the media", strings.clone_to_cstring(fn, ta), strings.clone_to_cstring(path, ta), strings.clone_to_cstring(missing, ta))
	}
	return secs
}

// ---- song{} and sound{} ---------------------------------------------------------------

@(private)
l_song :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	v := value_from_lua(L, s, 1, "song", "song", "")
	o := v.(json.Object)
	name, named := o["name"].(json.String)
	if !named || name == "" {
		lua.L_error(L, "song{}: give it a name first: song { \"score\", ... }")
	}
	if strings.contains_any(name, "/~") {
		lua.L_error(L, "song %s: a name without / or ~ (its parts are named score/drums)", strings.clone_to_cstring(name, context.temp_allocator))
	}
	sc := compose(L, s, name, v, false)
	push_song(L, s, sc)
	return 1
}

// Where each of sound{}'s keys goes in the one-part song it makes: the
// note's (when, how long, how hard), the part's (its mix, as a song's part
// takes them), the song's (its level).
@(private = "file")
Sound_Into :: enum u8 {
	Event,
	Part,
	Song,
}

@(private = "file", rodata)
SOUND_KEYS := [?]struct {
	key:  cstring,
	into: Sound_Into,
	at:   string, // its path in the spec
} {
	{"note", .Event, "parts/sound/play/1/events/1/note"},
	{"duration", .Event, "parts/sound/play/1/events/1/duration"},
	{"velocity", .Event, "parts/sound/play/1/events/1/velocity"},
	{"effects", .Part, "parts/sound/effects"},
	{"sends", .Part, "parts/sound/sends"},
	{"pan", .Part, "parts/sound/pan"},
	{"sidechain", .Part, "parts/sound/sidechain"},
	{"gain_db", .Song, "gain_db"},
	{"instruments", .Song, "instruments"},
}

// sound{ instrument, note, duration = "8n", velocity = 1, effects, sends, pan, sidechain, gain_db, instruments }
// -> its name: a one-part song (no note: the instrument's own pitch)
@(private)
l_sound :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	ta := context.temp_allocator
	lua.rawgeti(L, 1, 1)
	if lua.isnil(L, -1) {
		lua.L_error(L, "sound{}: give the instrument first: sound { \"whoosh\" } or sound { { \"Synth\", ... } }")
	}
	instrument := value_from_lua(L, s, -1, "sound", "sound[1]", "parts/sound/instrument")
	lua.pop(L, 1)
	// each key into the note, its part or the song (SOUND_KEYS)
	event := make(json.Object, 4, ta)
	event["time"] = json.Float(0)
	event["duration"] = json.String("8n")
	event["velocity"] = json.Float(1)
	part := make(json.Object, 4, ta)
	part["instrument"] = instrument
	spec := make(json.Object, 5, ta)
	spec["bpm"] = json.Float(120)
	into := [Sound_Into]^json.Object{.Event = &event, .Part = &part, .Song = &spec}
	fields_begin(L, 1)
	for row in SOUND_KEYS {
		field(L, 1, row.key)
		if !lua.isnil(L, -1) {
			into[row.into][string(row.key)] = value_from_lua(L, s, -1, "sound", fmt.tprintf("sound.%s", row.key), row.at)
		}
		lua.pop(L, 1)
	}
	fields_end(L, s, 1, "sound")
	// One section as long as the note (whole bars), one part playing it; no
	// note: the instrument's own pitch.
	section := make(json.Object, 2, ta)
	section["name"] = json.String("sound")
	#partial switch d in event["duration"] {
	case json.Float:
		section["duration"] = json.Float(max(d, 0.01))
	case json.Integer:
		section["duration"] = json.Float(max(f64(d), 0.01))
	case:
		section["duration"] = json.String("1m")
	}
	play := make(json.Object, 2, ta)
	play["name"] = json.String("sound")
	events := make(json.Array, 0, 1, ta)
	append(&events, event)
	play["events"] = events
	plays := make(json.Array, 0, 1, ta)
	append(&plays, play)
	part["play"] = plays
	parts := make(json.Object, 1, ta)
	parts["sound"] = part
	sections := make(json.Array, 0, 1, ta)
	append(&sections, section)
	spec["sections"] = sections
	spec["parts"] = parts
	// named by its content: the instrument, then the content key
	what := "sound"
	#partial switch x in instrument {
	case json.String:
		what = x
	case json.Object:
		if n, ok := x["name"].(json.String); ok {
			what = n
		}
	}
	name := fmt.tprintf("%s~%08x", what, u32(om.value_key(spec)))
	spec["name"] = json.String(name)
	compose(L, s, name, spec, true)
	lua.pushlstring(L, cstring(raw_data(name)), c.size_t(len(name)))
	return 1
}

// Composes song `name` from spec `v` in the media (the media's when it has
// it), reports what odawg found at the script line, registers the song in
// this load and (a song, not a sound) its sections and markers as cues.
@(private = "file")
compose :: proc(L: ^lua.State, s: ^Script, name: string, v: json.Value, sound: bool) -> ^om.Song_Clip {
	m := measure_media(L, s, "song")
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	if name in m.audio {
		lua.L_error(L, "song %s: the media has a clip of that name: give the song another", cname)
	}
	key := om.value_key(v)
	for x in s.songs {
		if x.name == name {
			if x.key == key {
				return x.clip // the same song again (a module required twice)
			}
			lua.L_error(L, "song %s is already made differently (%s): give each song its own name", cname, strings.clone_to_cstring(x.at, context.temp_allocator))
		}
	}
	sc, _ := om.media_song_put(m, name, v, key)
	first_error := ""
	for f in sc.findings {
		severity := om.Severity.Warning
		switch f.severity {
		case .Info:
			severity = .Info
		case .Warning:
		case .Error:
			severity = .Error
			if first_error == "" {
				first_error = f.message
			}
		}
		report_warning(L, s, {code = .Song_Finding, a = name, b = fmt.tprintf("%s (%s)", f.message, f.code)}, severity)
	}
	if !sc.ok {
		lua.L_error(L, "song %s can not be composed: %s", cname, strings.clone_to_cstring(first_error, context.temp_allocator))
	}
	at := caller_where(L)
	if !sound {
		// Section and marker names are cues: unique across the songs.
		check :: proc(L: ^lua.State, s: ^Script, song, cue: string) {
			for x in s.songs {
				if x.sound || x.name == song {
					continue
				}
				clash := osong.section_from_name(&x.clip.song, cue) >= 0
				for mk in x.clip.song.markers {
					clash ||= mk.name == cue
				}
				if clash {
					ta := context.temp_allocator
					lua.L_error(L, "song %s: %s is also a section or marker of song %s: they are cues, so their names are unique across the video's songs", strings.clone_to_cstring(song, ta), strings.clone_to_cstring(cue, ta), strings.clone_to_cstring(x.name, ta))
				}
			}
		}
		for sec in sc.song.sections {
			check(L, s, name, sec.name)
			add_cue(L, s, sec.name, om.song_video_seconds(sc, sec.start), "", at)
		}
		for mk in sc.song.markers {
			check(L, s, name, mk.name)
			add_cue(L, s, mk.name, om.song_video_seconds(sc, mk.seconds), "", at)
		}
	}
	append(&s.songs, Script_Song{strings.clone(name), sc, key, sound, strings.clone(at)})
	return sc
}

// ---- the song object ------------------------------------------------------------------

@(private = "file")
SONG_FUNCTIONS := [?]struct {
	name: cstring,
	fn:   lua.CFunction,
} {
	{"time", l_song_time},
	{"beat", l_song_beat},
	{"bar", l_song_bar},
	{"seconds", l_song_seconds},
	{"frame", l_song_frame},
	{"pulse", l_song_pulse},
	{"section", l_song_section},
	{"hits", l_song_hits},
	{"events", l_song_events},
	{"note", l_song_note},
	{"snap", l_song_snap},
}

@(private = "file")
push_song :: proc(L: ^lua.State, s: ^Script, sc: ^om.Song_Clip) {
	g := &sc.song
	lua.createtable(L, 0, 20)
	push_text :: proc(L: ^lua.State, key: cstring, v: string) {
		lua.pushlstring(L, cstring(raw_data(v)), c.size_t(len(v)))
		lua.setfield(L, -2, key)
	}
	push_text(L, "name", sc.name)
	lua.pushnumber(L, lua.Number(g.start))
	lua.setfield(L, -2, "start")
	lua.pushnumber(L, lua.Number(g.duration))
	lua.setfield(L, -2, "duration")
	push_text(L, "key", sc.spec.key)
	lua.createtable(L, c.int(len(g.sections)), 0)
	for sec, i in g.sections {
		lua.createtable(L, 0, 8)
		push_text(L, "name", sec.name)
		lua.pushnumber(L, lua.Number(g.start + sec.start))
		lua.setfield(L, -2, "start")
		lua.pushnumber(L, lua.Number(g.start + sec.stop))
		lua.setfield(L, -2, "stop")
		lua.pushnumber(L, lua.Number(sec.bpm0))
		lua.setfield(L, -2, "bpm")
		if sec.bpm1 != sec.bpm0 {
			lua.pushnumber(L, lua.Number(sec.bpm1))
			lua.setfield(L, -2, "bpm_to")
		}
		set_int(L, "bars", sec.bars)
		set_int(L, "beats_per_bar", sec.beats_per_bar)
		lua.pushnumber(L, lua.Number(sec.energy))
		lua.setfield(L, -2, "energy")
		push_text(L, "style", osong.style_name(g, sec.style))
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	lua.setfield(L, -2, "sections")
	lua.createtable(L, c.int(len(g.markers)), 0)
	for mk, i in g.markers {
		lua.createtable(L, 0, 2)
		push_text(L, "name", mk.name)
		lua.pushnumber(L, lua.Number(g.start + mk.seconds))
		lua.setfield(L, -2, "time")
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	lua.setfield(L, -2, "markers")
	for f in SONG_FUNCTIONS {
		lua.pushlightuserdata(L, s)
		lua.pushlightuserdata(L, sc)
		lua.pushcclosure(L, f.fn, 2)
		lua.setfield(L, -2, f.name)
	}
}

// The song of a song function (its second upvalue).
@(private = "file")
song_of :: proc "contextless" (L: ^lua.State) -> ^om.Song_Clip {
	return (^om.Song_Clip)(lua.touserdata(L, lua.REGISTRYINDEX - 2))
}

// A time on the video at `idx`: seconds, or a frame (its global_seconds).
@(private = "file")
video_seconds_arg :: proc(L: ^lua.State, idx: c.int, fn: cstring) -> f64 {
	if lua.istable(L, idx) {
		lua.getfield(L, idx, "global_seconds")
		defer lua.pop(L, 1)
		if lua.isnumber(L, -1) {
			return f64(lua.tonumber(L, -1))
		}
		lua.L_error(L, "%s: give a frame or seconds on the video", fn)
	}
	return f64(lua.L_checknumber(L, idx))
}

// Song seconds of the position at `idx`: a beat number, or a position
// string ("drop", "drop@1m", "drop@-0.5s", "2:0:0", "end").
@(private = "file")
position_arg :: proc(L: ^lua.State, sc: ^om.Song_Clip, idx: c.int, fn: cstring) -> f64 {
	if lua.isnumber(L, idx) {
		return otempo.seconds_from_beat(&sc.song.tempo, f64(lua.tonumber(L, idx)))
	}
	text := string(lua.L_checkstring(L, idx))
	t, ok := osong.seconds_from_position(&sc.song, text)
	if !ok {
		lua.L_error(L, "%s: %s is not a position of song %s (%s)", fn, lua.tostring(L, idx), strings.clone_to_cstring(sc.name, context.temp_allocator), strings.clone_to_cstring(song_names(sc), context.temp_allocator))
	}
	return t
}

// The names a position can start from, for errors.
@(private = "file")
song_names :: proc(sc: ^om.Song_Clip) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "sections")
	for sec, i in sc.song.sections {
		fmt.sbprintf(&b, "%s %s", i == 0 ? ":" : ",", sec.name)
	}
	for mk, i in sc.song.markers {
		fmt.sbprintf(&b, "%s %s", i == 0 ? "; markers:" : ",", mk.name)
	}
	strings.write_string(&b, "; or start, end")
	return strings.to_string(b)
}

// score.time(x) -> video seconds of a beat number or a position
@(private = "file")
l_song_time :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	sc := song_of(L)
	lua.pushnumber(L, lua.Number(sc.song.start + position_arg(L, sc, 1, "time")))
	return 1
}

// score.beat(f or t) -> beats from the song's start
@(private = "file")
l_song_beat :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	sc := song_of(L)
	t := video_seconds_arg(L, 1, "beat") - sc.song.start
	lua.pushnumber(L, lua.Number(otempo.beat_from_seconds(&sc.song.tempo, t)))
	return 1
}

// score.bar(f or t) -> bars from the song's start (fractional; each bar
// its section's meter long)
@(private = "file")
l_song_bar :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	sc := song_of(L)
	g := &sc.song
	b := otempo.beat_from_seconds(&g.tempo, video_seconds_arg(L, 1, "bar") - g.start)
	bars := 0.0
	if len(g.sections) > 0 && b >= 0 {
		i := osong.section_from_beat(g, b)
		for sec in g.sections[:i] {
			bars += f64(sec.bars)
		}
		bars += (b - g.sections[i].beat) / f64(g.sections[i].beats_per_bar)
	} else if len(g.sections) > 0 {
		bars = b / f64(g.sections[0].beats_per_bar)
	}
	lua.pushnumber(L, lua.Number(bars))
	return 1
}

// score.seconds(length, at) -> how long a length lasts (a number: beats; a
// Tone length "2m"), from `at` (a position, or video seconds; the start)
@(private = "file")
l_song_seconds :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	sc := song_of(L)
	g := &sc.song
	from: f64
	switch {
	case lua.isnoneornil(L, 2):
	case lua.type(L, 2) == .NUMBER:
		from = otempo.beat_from_seconds(&g.tempo, f64(lua.tonumber(L, 2)) - g.start)
	case:
		ok: bool
		if from, ok = osong.beat_from_position(g, string(lua.L_checkstring(L, 2))); !ok {
			lua.L_error(L, "seconds: %s is not a position of song %s (%s)", lua.tostring(L, 2), strings.clone_to_cstring(sc.name, context.temp_allocator), strings.clone_to_cstring(song_names(sc), context.temp_allocator))
		}
	}
	beats: f64
	if lua.type(L, 1) == .NUMBER {
		beats = f64(lua.tonumber(L, 1))
	} else {
		bpb := len(g.sections) > 0 ? g.sections[osong.section_from_beat(g, from)].beats_per_bar : 4
		l, ok := otempo.length_from_string(string(lua.L_checkstring(L, 1)), bpb)
		if !ok {
			lua.L_error(L, "seconds: %s is not a length (\"2m\", \"8n.\", \"1:2:0\", \"0.5s\")", lua.tostring(L, 1))
		}
		if l.in_seconds {
			lua.pushnumber(L, lua.Number(l.value))
			return 1
		}
		beats = l.value
	}
	lua.pushnumber(L, lua.Number(otempo.seconds_from_beat(&g.tempo, from + beats) - otempo.seconds_from_beat(&g.tempo, from)))
	return 1
}

// score.frame(x, fps = the video's) -> the frame of a beat number or position
@(private = "file")
l_song_frame :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	sc := song_of(L)
	t := sc.song.start + position_arg(L, sc, 1, "frame")
	fps := f64(lua.L_optnumber(L, 2, lua.Number(s.video.fps)))
	if fps <= 0 {
		lua.L_error(L, "frame: give the fps (or call video{} first)")
	}
	lua.pushinteger(L, lua.Integer(math.floor(t * fps + 0.5)))
	return 1
}

// The note filter of the table at `idx`: part, note, range.
@(private = "file")
filter_arg :: proc(L: ^lua.State, s: ^Script, idx: c.int, fn: string) -> osong.Note_Filter {
	if !lua.istable(L, idx) {
		return {}
	}
	fields_begin(L, idx)
	f := osong.Note_Filter {
		part  = strings.clone(get_str(L, idx, "part", ""), context.temp_allocator),
		note  = strings.clone(get_str(L, idx, "note", ""), context.temp_allocator),
		range = strings.clone(get_str(L, idx, "range", ""), context.temp_allocator),
	}
	field_used("decay")
	fields_end(L, s, idx, fn)
	return f
}

// The notes a filter matches, in time order (temp memory); a filter
// matching none is a `no_events` warning (a part the style doesn't have).
@(private = "file")
filtered_notes :: proc(L: ^lua.State, s: ^Script, sc: ^om.Song_Clip, f: osong.Note_Filter, fn: string) -> []i32 {
	out := make([dynamic]i32, context.temp_allocator)
	if !osong.notes_from_filter(&sc.song, f, &out) {
		if f.range != "" {
			if _, _, ok := osong.beats_from_range(&sc.song, f.range); !ok {
				lua.L_error(L, "%s: %s is not a range of song %s", strings.clone_to_cstring(fn, context.temp_allocator), strings.clone_to_cstring(f.range, context.temp_allocator), strings.clone_to_cstring(sc.name, context.temp_allocator))
			}
		}
	}
	if len(out) == 0 {
		what := f.part if f.part != "" else "the song"
		report_warning(L, s, {code = .Song_Finding, a = sc.name, b = fmt.tprintf("%s reads %s%s%s, where nothing plays (parts: %s) (no_events)", fn, what, f.note != "" ? fmt.tprintf(" %s", f.note) : "", f.range != "" ? fmt.tprintf(" in %s", f.range) : "", strings.join(sc.song.parts[:], ", ", context.temp_allocator))})
	}
	return out[:]
}

// score.pulse(f or t, sharpness = 8) -> beat_clock's pulse on every beat;
// score.pulse(f or t, { part, note, decay = 8 }) -> 1 at each of those
// notes, decaying by beats since
@(private = "file")
l_song_pulse :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	sc := song_of(L)
	g := &sc.song
	t := video_seconds_arg(L, 1, "pulse") - g.start
	if lua.istable(L, 2) {
		f := filter_arg(L, s, 2, "pulse")
		decay := f64(get_num(L, 2, "decay", 8))
		v := osong.pulse_from_seconds(g, t, f, decay)
		if v == 0 {
			filtered_notes(L, s, sc, f, "pulse") // nothing to pulse on: say so
		}
		lua.pushnumber(L, lua.Number(v))
		return 1
	}
	x := otempo.beat_from_seconds(&g.tempo, t)
	sharp := f64(lua.L_optnumber(L, 2, 8))
	v := 0.0 if x < 0 else math.exp(-(x - math.floor(x)) * sharp)
	lua.pushnumber(L, lua.Number(v))
	return 1
}

// score.section(f or t) -> { name, progress, bar, beat, index } (bar and
// beat counted from 0), nil outside the song
@(private = "file")
l_song_section :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	sc := song_of(L)
	p, inside := om.song_place(sc, video_seconds_arg(L, 1, "section") - sc.song.start)
	if !inside {
		lua.pushnil(L)
		return 1
	}
	lua.createtable(L, 0, 5)
	lua.pushlstring(L, cstring(raw_data(p.name)), c.size_t(len(p.name)))
	lua.setfield(L, -2, "name")
	lua.pushnumber(L, lua.Number(p.progress))
	lua.setfield(L, -2, "progress")
	set_int(L, "bar", p.bar)
	lua.pushnumber(L, lua.Number(p.beat))
	lua.setfield(L, -2, "beat")
	set_int(L, "index", p.section + 1)
	return 1
}

// score.hits { part, note, range } -> the video seconds those notes start
// (one per time)
@(private = "file")
l_song_hits :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	sc := song_of(L)
	f := filter_arg(L, s, 1, "hits")
	notes := filtered_notes(L, s, sc, f, "hits")
	lua.createtable(L, c.int(len(notes)), 0)
	k := 0
	last := math.inf_f64(-1)
	for i in notes {
		t := sc.song.notes.time[i]
		if t - last < 0.5e-3 {
			continue
		}
		last = t
		k += 1
		lua.pushnumber(L, lua.Number(sc.song.start + t))
		lua.rawseti(L, -2, lua.Integer(k))
	}
	return 1
}

// score.events { part, note, range } -> { time, note, duration, velocity,
// part } per note, time on the video
@(private = "file")
l_song_events :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	sc := song_of(L)
	g := &sc.song
	f := filter_arg(L, s, 1, "events")
	notes := filtered_notes(L, s, sc, f, "events")
	lua.createtable(L, c.int(len(notes)), 0)
	for i, k in notes {
		n := g.notes[i]
		lua.createtable(L, 0, 5)
		lua.pushnumber(L, lua.Number(g.start + n.time))
		lua.setfield(L, -2, "time")
		name := om.note_name(g, n.pad, n.pitch)
		lua.pushlstring(L, cstring(raw_data(name)), c.size_t(len(name)))
		lua.setfield(L, -2, "note")
		lua.pushnumber(L, lua.Number(n.duration))
		lua.setfield(L, -2, "duration")
		lua.pushnumber(L, lua.Number(n.velocity))
		lua.setfield(L, -2, "velocity")
		part := g.parts[g.tracks[n.track].part]
		lua.pushlstring(L, cstring(raw_data(part)), c.size_t(len(part)))
		lua.setfield(L, -2, "part")
		lua.rawseti(L, -2, lua.Integer(k + 1))
	}
	return 1
}

// score.note(degree, at = "start", octave = 5) -> an in-key note name: the
// degree of the chord sounding there
@(private = "file")
l_song_note :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	sc := song_of(L)
	g := &sc.song
	degree: int
	if lua.type(L, 1) == .NUMBER {
		degree = int(lua.tointeger(L, 1))
	} else {
		ok: bool
		if degree, ok = strconv.parse_int(string(lua.L_checkstring(L, 1))); !ok {
			lua.L_error(L, "note: %s is not a degree (1..7, 8 the octave)", lua.tostring(L, 1))
		}
	}
	at := 0.0
	if !lua.isnoneornil(L, 2) {
		at = lua.type(L, 2) == .NUMBER ? f64(lua.tonumber(L, 2)) - g.start : position_arg(L, sc, 2, "note")
	}
	octave := int(lua.L_optinteger(L, 3, 5))
	chord := osong.chord_from_beat(g, otempo.beat_from_seconds(&g.tempo, at))
	midi := otheory.pitch_from_degree(g.key, chord, degree, octave)
	name := otheory.string_from_pitch(midi)
	lua.pushlstring(L, cstring(raw_data(name)), c.size_t(len(name)))
	return 1
}

// score.snap(f or t, grid = "8n") -> the nearest grid point, video seconds
@(private = "file")
l_song_snap :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	sc := song_of(L)
	t := video_seconds_arg(L, 1, "snap") - sc.song.start
	grid := string(lua.L_optstring(L, 2, "8n"))
	snapped, ok := osong.seconds_snapped(&sc.song, t, grid)
	if !ok {
		lua.L_error(L, "snap: %s is not a grid (\"8n\", \"4n\", \"1m\")", lua.tostring(L, 2))
	}
	lua.pushnumber(L, lua.Number(sc.song.start + snapped))
	return 1
}
