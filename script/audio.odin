package onimite_script

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import obase "deps:odawg/base"
import ospec "deps:odawg/spec"
import om "../onimite"
import lua "vendor:lua/5.4"

// `audio = { {"music.ogg", start = 0, gain_db = -18, fade_in = 1.5, fade_out = 2.5,
//             curve = "equal_power", ducked = true},
//            {"vo.wav", start = 0.6, voice = true} }`
//
// Track fields: the file (first entry or `src`: a clip, or a song or sound
// by name), `start` (a song on video{} without one: its own start), `stop`
// (omitted: to the end of the file, a song's end and tail), `offset` (seconds into the file), `gain_db`,
// `pan` (-1..1), `fade_in`, `fade_out`, `curve` ("linear" or
// "equal_power"), `voice`, `ducked` (true for fframes' duck_under_voice, or
// a table `{depth_db, attack, hold, release, merge_gap}`), `mono` (a stereo
// file as 0.707 * (L + R) on both sides, like fframes' embedded media),
// `effects` (a clip's, as a song part's: `{ { "Filter", type = "highpass",
// frequency = 200 }, { "Reverb", wet = 0.2 } }`).

// Reads field `audio` of the table at `t` into the video's tracks, placed
// by `scene` (an index into the scenes, or none for video{}). The strings
// are owned by the script and freed on unload.
@(private)
read_audio :: proc(s: ^Script, L: ^lua.State, t: c.int, scene: Maybe(int)) {
	field(L, t, "audio")
	defer lua.pop(L, 1)
	if !lua.istable(L, -1) {
		return
	}
	list := lua.absindex(L, -1)
	n := int(lua.rawlen(L, list))
	// Joined once all are read: a Lua error halfway leaves none.
	tracks := make([]om.Audio_Track, n, context.temp_allocator)
	source := strings.clone(caller_where(L))
	append(&s.owned_strings, source)
	for &tr, i in tracks {
		lua.rawgeti(L, list, lua.Integer(i + 1))
		e := lua.absindex(L, -1)
		outer := fields_push(L, e)
		src := text_arg(L, e)
		if src == "" {
			// a song itself (song{} returns its object): played by its name
			lua.rawgeti(L, e, 1)
			if lua.istable(L, -1) {
				src = get_str(L, lua.absindex(L, -1), "name", "")
			}
			lua.pop(L, 1)
		}
		if src == "" {
			src = get_str(L, e, "src", "")
		}
		tr.src = strings.clone(src)
		append(&s.owned_strings, tr.src)
		tr.source = source
		tr.scene = scene
		if cue := get_str(L, e, "cue", ""); cue != "" {
			tr.cue = strings.clone(cue)
			append(&s.owned_strings, tr.cue)
		}
		if bus := get_str(L, e, "bus", ""); bus != "" {
			tr.bus = strings.clone(bus)
			append(&s.owned_strings, tr.bus)
		}
		tr.start = get_num(L, e, "start", 0)
		// A song on the video starts where it says (its own `start`).
		if sc := script_song(s, tr.src); sc != nil && scene == nil && !has_field(L, e, "start") {
			tr.start = f32(sc.song.start)
		}
		tr.stop = get_num(L, e, "stop", 0)
		// Frames, minutes, audio lengths and sums (fframes' AudioTimestamp).
		tr.start_terms = read_terms_field(s, L, e, "start")
		tr.stop_terms = read_terms_field(s, L, e, "stop")
		tr.offset = get_num(L, e, "offset", 0)
		tr.gain_db = get_num(L, e, "gain_db", 0)
		tr.pan = clamp(get_num(L, e, "pan", 0), -1, 1)
		tr.fade_in = get_num(L, e, "fade_in", 0)
		tr.fade_out = get_num(L, e, "fade_out", 0)
		if get_str(L, e, "curve", "linear") == "equal_power" {
			tr.curve = .Equal_Power
		}
		field(L, e, "voice")
		tr.voice = bool(lua.toboolean(L, -1))
		lua.pop(L, 1)
		field(L, e, "mono")
		tr.mono = bool(lua.toboolean(L, -1))
		lua.pop(L, 1)
		field(L, e, "ducked")
		if lua.istable(L, -1) {
			track_fields := fields_push(L, -1)
			tr.ducked = true
			tr.duck = {
				depth_db  = get_num(L, -1, "depth_db", 0),
				attack    = get_num(L, -1, "attack", 0),
				hold      = get_num(L, -1, "hold", 0),
				release   = get_num(L, -1, "release", 0),
				merge_gap = get_num(L, -1, "merge_gap", 0),
			}
			fields_pop(L, s, -1, "ducked", track_fields)
		} else {
			tr.ducked = bool(lua.toboolean(L, -1))
		}
		lua.pop(L, 1)
		field(L, e, "effects")
		if !lua.isnil(L, -1) {
			if script_song(s, tr.src) != nil {
				lua.L_error(L, "audio track %s: a song's effects go on its parts (or its sound{}'s effects)", strings.clone_to_cstring(tr.src, context.temp_allocator))
			}
			tr.effects = json.clone_value(value_from_lua(L, s, -1, "audio track", "effects", "effects"))
			append(&s.owned_values, tr.effects)
			effects_check(L, s, tr.src, tr.effects)
		}
		lua.pop(L, 1)
		fields_pop(L, s, e, "audio track", outer)
		lua.pop(L, 1)
	}
	append(&s.tracks, ..tracks)
}

// What odawg finds reading a track's effects (as the mix will), at the
// script line: a misspelled effect or key is found at load, not heard.
@(private = "file")
effects_check :: proc(L: ^lua.State, s: ^Script, src: string, effects: json.Value) {
	// odawg's reading in an arena of its own; the findings as load problems
	// (cloned) after it
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	findings: obase.Findings
	{
		context.allocator = virtual.arena_allocator(&arena)
		fx: ospec.Spec
		ospec.spec_init(&fx)
		findings = make(obase.Findings)
		ospec.effects_from_value(&fx, effects, "effects", &findings)
	}
	for f in findings {
		severity := om.Severity.Warning
		switch f.severity {
		case .Info:
			severity = .Info
		case .Warning:
		case .Error:
			severity = .Error
		}
		report_warning(L, s, {code = .Effect_Finding, a = src, b = fmt.tprintf("%s (%s)", f.message, f.code)}, severity)
	}
}

// `buses = { sfx = { gain_db = -4 }, music = { gain_db = 0 } }` on video{}:
// the gain of each group of tracks (a track joins one with `bus = "sfx"`),
// sorted by name (a Lua table's order changes from run to run).
@(private)
read_buses :: proc(s: ^Script, L: ^lua.State, t: c.int) -> []om.Bus {
	field(L, t, "buses")
	defer lua.pop(L, 1)
	if !lua.istable(L, -1) {
		return nil
	}
	list := make([dynamic]om.Bus)
	tbl := lua.absindex(L, -1)
	for key in sorted_keys(L, tbl) {
		push_key(L, tbl, key)
		if lua.istable(L, -1) {
			e := lua.absindex(L, -1)
			outer := fields_push(L, e)
			name := strings.clone(key)
			append(&s.owned_strings, name)
			// The kind: `kind`, else the name when it names one.
			kind_name := get_str(L, e, "kind", name)
			kind := om.Bus_Kind.Other
			switch strings.to_lower(kind_name, context.temp_allocator) {
			case "music":
				kind = .Music
			case "sfx":
				kind = .Sfx
			case "voice":
				kind = .Voice
			case "other":
			case:
				if kind_name != name {
					lua.L_error(L, "bus %s: kind must be \"music\", \"sfx\", \"voice\" or \"other\", got %s",
						strings.clone_to_cstring(name, context.temp_allocator), strings.clone_to_cstring(kind_name, context.temp_allocator))
				}
			}
			append(&list, om.Bus{name, get_num(L, e, "gain_db", 0), kind})
			fields_pop(L, s, e, "bus", outer)
		}
		lua.pop(L, 1)
	}
	append(&s.owned_buses, list[:])
	return list[:]
}
