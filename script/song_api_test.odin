package onimite_script

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
  parts = { drums = { instrument = { "DrumKit" }, play = { { "drop", steps = { kick = "x...x...x...x..." } } } } },
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
local blip = sound { "blip", note = "E6", duration = "16n" }
assert(blip:match("^blip~%x+$"), blip)
assert(sound { "blip", note = "E6", duration = "16n" } == blip, "the same sound, the same name")
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
