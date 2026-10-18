package onimite_script

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import om "../onimite"

@(private = "file")
load_source :: proc(t: ^testing.T, src: string, s: ^Script, media: ^om.Media) -> bool {
	dir, derr := os.make_directory_temp("", "onimite_song_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	defer os.remove_all(dir)
	return load(s, path, nil, media) == nil
}

// song{}: the Lua table becomes odawg's spec (a lone name as a record,
// onimite's time forms resolved: a section as long as a clip plus a
// second, the start a time table), what odawg finds is a warning at the
// script line, sections and markers are cues on the video, the song
// object answers on the video clock, sound{} is a one-note song named by
// its content, and a song's track starts where the song does.
@(test)
test_song_binding :: proc(t: ^testing.T) {
	src := `
audio_add("vo", audio_buffer(1.5))
local score = song { "score", start = { seconds = 0.5 }, bpm = 120,
  sections = {
    { "intro", duration = { audio = "vo", plus = { seconds = 1 } } },
    { "drop", duration = "2m", bmp = 128 },
  },
  parts = { drums = { instrument = { pads = { kick = { "MembraneSynth" } } }, play = { { "drop", steps = { kick = "x...x...x...x..." } } } } },
  markers = { { "logo", at = "drop@1m" } },
}
local function near(a, b, what) assert(math.abs(a - b) < 1e-6, what .. ": " .. tostring(a) .. ", not " .. tostring(b)) end
near(score.start, 0.5, "start")
near(score.time("intro"), 0.5, "intro")
near(score.time("drop"), 4.5, "drop: 2.5 s rounded up to whole bars")
near(score.time(4), 2.5, "a beat number")
near(score.seconds("1m", "drop"), 2, "a bar")
near(score.seconds(2), 1, "two beats")
near(score.beat(4.5), 8, "beat")
near(score.bar(4.5), 2, "bar")
assert(score.frame("drop", 10) == 45, "frame")
near(score.snap(4.7, "4n"), 4.5, "snap")
near(score.duration, 8, "duration")
assert(score.section(5.5).name == "drop" and score.section(5.5).bar == 0, "section")
assert(score.section(100) == nil, "outside")
local kicks = score.hits { part = "drums", note = "kick", range = "drop" }
assert(#kicks == 8, "kicks: " .. #kicks)
near(kicks[1], 4.5, "the first kick")
local ev = score.events { part = "drums", range = "drop@1m.." }
assert(#ev == 4 and ev[1].note == "kick", "events")
assert(score.pulse(4.5, { part = "drums", note = "kick" }) == 1, "pulse on a kick")
assert(score.sections[2].name == "drop" and score.sections[2].bars == 2, "sections")
assert(type(score.note("5", "drop")) == "string", "note")
assert(not pcall(score.time, "chorus"), "no such position")
local blip = sound { "Synth", note = "E6", duration = "16n" }
assert(blip:match("^Synth~%x+$"), blip)
assert(sound { "Synth", note = "E6", duration = "16n" } == blip, "the same sound, the same name")
video { width = 40, height = 40, fps = 10, duration = 9,
  audio = { { "score", bus = "music" }, { blip, start = score.time("drop") } } }
`
	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	s: Script
	defer unload(&s)
	testing.expectf(t, load_source(t, src, &s, &media), "load failed: %s", error_message(s.failure, context.temp_allocator))
	found := false
	for d in s.load_problems {
		msg := om.diagnostic_message(d, context.temp_allocator)
		if strings.contains(msg, "bmp") {
			found = true
			testing.expectf(t, strings.has_prefix(msg, "video.lua:3: song \"score\": ") && strings.contains(msg, "unknown_key"), "finding: %s", msg)
		}
	}
	testing.expect(t, found, "the misspelled key is a warning")
	want := [?]struct {
		name:    string,
		seconds: f64,
	}{{"intro", 0.5}, {"drop", 4.5}, {"logo", 6.5}}
	testing.expect_value(t, len(s.cues), 3)
	for c, i in s.cues {
		testing.expectf(t, c.name == want[i].name && abs(c.seconds - want[i].seconds) < 1e-9, "cue %s at %f", c.name, c.seconds)
	}
	testing.expect_value(t, len(s.tracks), 2)
	testing.expectf(t, abs(s.tracks[0].start - 0.5) < 1e-6, "the song's track starts with it: %f", s.tracks[0].start)
	// The song and the sound play in the mix.
	r: om.Renderer
	testing.expect_value(t, om.renderer_init(&r, &s.video, &media), om.Error.None)
	defer om.renderer_destroy(&r)
	placed := om.placed_audio(&r.ctx).tracks[:]
	testing.expect_value(t, len(placed), 2)
	mix, _ := om.mix_tracks(placed, 0, 9 * om.MIX_RATE, {no_limiter = true}, context.temp_allocator)
	peak_in :: proc(x: []f32, a, b: f64) -> f32 {
		p: f32
		for v in x[int(a * om.MIX_RATE) * 2:int(b * om.MIX_RATE) * 2] {
			p = max(p, abs(v))
		}
		return p
	}
	testing.expect(t, peak_in(mix, 0, 0.5) == 0, "silence before the song")
	testing.expect(t, peak_in(mix, 4.5, 4.6) > 0.01, "the kick and the blip at the drop")
}

// Section and marker names are cues, so two songs sharing one is an error
// at load.
@(test)
test_song_names_unique :: proc(t: ^testing.T) {
	src := `
song { "a", sections = { { "x", duration = "1m" } } }
song { "b", sections = { { "x", duration = "1m" } } }
video { width = 40, height = 40, fps = 10, duration = 1 }
`
	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	s: Script
	defer unload(&s)
	testing.expect(t, !load_source(t, src, &s, &media), "a clash loads")
	msg := error_message(s.failure, context.temp_allocator)
	testing.expectf(t, strings.contains(msg, "video.lua:3") && strings.contains(msg, "unique"), "error: %s", msg)
}

// A song written in Lua (entries for names, a node's kind and inputs, a
// field's base, an option's path) is the spec the same song in JSON is:
// what each shorthand fills is odawg's (positional_fields) and onimite's
// (an option's targets).
@(test)
test_song_lua_is_json :: proc(t: ^testing.T) {
	src := `
song { "same", bpm = 124,
  sections = { { "intro", duration = "2m" }, { "drop", duration = "4m" } },
  markers = { { "hit", at = "drop@1m" } },
  instruments = {
    lead = {
      nodes = {
        osc = { "Osc", wave = "sawtooth", frequency = { by = "lfo", octaves = 0.02 } },
        noise = { "Noise" },
        mix = { "Mix", "osc", "noise" },
        env = { "Env", attack = 0.01, release = 0.3 },
        lfo = { "Lfo", rate = "4n" },
        out = { "Filter", "mix", frequency = { 300, by = "env", octaves = 3 }, q = { { by = "env", amount = 2 }, { by = "velocity", amount = 1 } }, amp = "env" },
      },
      out = "out",
      options = { cutoff = "out/frequency", drive = { "out/q", op = "mul", scale = 2 },
                  decay = { { "env/decay" }, { "env/release", op = "mul", scale = 2 } } },
    },
  },
  parts = {
    lead = { instrument = { "lead", cutoff = 600 }, effects = { { "Reverb", wet = 0.2 } },
             play = { { "drop", notes = "C4 E4 G4" } } },
    drums = { instrument = { pads = { kick = { "MembraneSynth", key = 36 } } },
              play = { { "drop", steps = { kick = "x...x..." } } }, sidechain = { "lead" } },
  },
}
video { width = 40, height = 40, fps = 10, duration = 1 }
`
	text := `{
  "name": "same", "bpm": 124,
  "sections": [ { "name": "intro", "duration": "2m" }, { "name": "drop", "duration": "4m" } ],
  "markers": [ { "name": "hit", "at": "drop@1m" } ],
  "instruments": {
    "lead": {
      "nodes": {
        "osc": { "class": "Osc", "wave": "sawtooth", "frequency": { "by": "lfo", "octaves": 0.02 } },
        "noise": { "class": "Noise" },
        "mix": { "class": "Mix", "inputs": [ "osc", "noise" ] },
        "env": { "class": "Env", "attack": 0.01, "release": 0.3 },
        "lfo": { "class": "Lfo", "rate": "4n" },
        "out": { "class": "Filter", "inputs": [ "mix" ], "frequency": { "base": 300, "by": "env", "octaves": 3 }, "q": [ { "by": "env", "amount": 2 }, { "by": "velocity", "amount": 1 } ], "amp": "env" }
      },
      "out": "out",
      "options": { "cutoff": "out/frequency", "drive": { "path": "out/q", "op": "mul", "scale": 2 },
                   "decay": [ { "path": "env/decay" }, { "path": "env/release", "op": "mul", "scale": 2 } ] }
    }
  },
  "parts": {
    "lead": { "instrument": { "name": "lead", "cutoff": 600 }, "effects": [ { "name": "Reverb", "wet": 0.2 } ],
              "play": [ { "name": "drop", "notes": "C4 E4 G4" } ] },
    "drums": { "instrument": { "pads": { "kick": { "instrument": "MembraneSynth", "key": 36 } } },
               "play": [ { "name": "drop", "steps": { "kick": "x...x..." } } ], "sidechain": { "name": "lead" } }
  }
}`
	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	s: Script
	defer unload(&s)
	testing.expectf(t, load_source(t, src, &s, &media), "load failed: %s", error_message(s.failure, context.temp_allocator))
	v, err := json.parse_string(text, .JSON5, true, context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	testing.expect_value(t, len(s.songs), 1)
	if len(s.songs) == 1 {
		testing.expect_value(t, s.songs[0].clip.key, om.value_key(v))
		for f in s.songs[0].clip.findings {
			testing.expectf(t, f.severity == .Info, "%s: %s", f.code, f.message)
		}
	}
}
