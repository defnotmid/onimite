package onimite

import "core:encoding/json"
import "core:testing"

// onimite_test's video: Intro [0, 60), Main [45, 150), Outro [150, 180).
@(private = "file")
spec_video :: proc() -> Video {
	@(static) scenes: [3]Scene
	scenes = [3]Scene{
		{name = "Intro", duration = Seconds(2)},
		{name = "Main", duration = Frames(90), overlap = {previous = 0.5}},
		{name = "Outro", duration = Seconds(1)},
	}
	return {width = 320, height = 180, fps = 30, scenes = scenes[:]}
}

// A song's sections and markers take Tone's lengths on its tempo (240 BPM
// in 4/4: a bar is 1 s, a beat 0.25 s); a scene sharing a section's name
// keeps its seconds and `m:ss` offsets.
@(test)
test_time_specs_musical :: proc(t: ^testing.T) {
	v := spec_video()
	tl, _ := resolve_timeline(&v)
	defer timeline_destroy(&tl)
	m: Media
	media_init(&m)
	defer media_destroy(&m)
	sv, jerr := json.parse_string(`{ name: "s", bpm: 240, sections: [ { name: "verse", duration: "2m" }, { name: "main", duration: "2m" } ],
		markers: [ { name: "hit", at: "main@1m" } ] }`, .JSON5, true, context.temp_allocator)
	testing.expect(t, jerr == nil)
	sc, _ := media_song_put(&m, "s", sv, value_key(sv))
	testing.expect(t, sc.ok)
	// A sound (sorted first) with a section `main` at 0 s: not the cue.
	nv, nerr := json.parse_string(`{ name: "a", bpm: 120, sections: [ { name: "main", duration: "1m" } ] }`, .JSON5, true, context.temp_allocator)
	testing.expect(t, nerr == nil)
	nc, _ := media_song_put(&m, "a", nv, value_key(nv))
	testing.expect(t, nc.ok)
	names := []Named_Time{{"verse", 0}, {"main", 2}, {"hit", 3}}
	check :: proc(t: ^testing.T, tl: Timeline, m: ^Media, names: []Named_Time, spec: string, want: int, loc := #caller_location) {
		f, err := parse_frame(tl, 30, spec, names, m)
		testing.expectf(t, err == nil && f == want, "%q -> %d, %v (want %d)", spec, f, err, want, loc = loc)
	}
	check(t, tl, &m, names, "verse@1m", 30)
	check(t, tl, &m, names, "verse@2n", 15)
	check(t, tl, &m, names, "verse@2n.", 22) // 3 beats: 0.75 s
	check(t, tl, &m, names, "main@8t", 62) // a third of a beat: 2.083 s
	check(t, tl, &m, names, "main@-4n", 52)
	check(t, tl, &m, names, "main@+1m", 90)
	check(t, tl, &m, names, "hit@1m", 120) // a marker
	check(t, tl, &m, names, "verse@0.5s", 15) // seconds: from the cue, as before
	check(t, tl, &m, names, "verse@3", 3) // frames
	// Main is a scene (from frame 45) and a section (from 2 s): three
	// fields are bars:quarters:sixteenths of the section, the rest the
	// scene's offsets.
	check(t, tl, &m, names, "Main@1:1:0", 97)
	check(t, tl, &m, names, "main@0:0:2", 63) // two sixteenths: 2.125 s
	check(t, tl, &m, names, "Main@1m", 90)
	check(t, tl, &m, names, "Main@0:01", 75)
	check(t, tl, &m, names, "Main@1s", 75)
	check(t, tl, &m, names, "Main@30", 75)
	check(t, tl, &m, names, "Main", 45)
	// No song section: `h:mm:ss` into a scene.
	check(t, tl, &m, names, "Intro@0:00:01", 30)

	a, b, rerr := parse_range(tl, 30, "verse@1m..main@1m", names, &m)
	testing.expect(t, rerr == nil && a == 30 && b == 90)
	a, b, rerr = parse_range(tl, 30, "Intro..hit@1m", names, &m)
	testing.expect(t, rerr == nil && a == 0 && b == 120)

	// Not lengths, or no songs to measure them by.
	_, err := parse_frame(tl, 30, "verse@1x", names, &m)
	testing.expect_value(t, err, Error.Invalid_Time_Spec)
	_, err = parse_frame(tl, 30, "verse@500ms", names, &m)
	testing.expect_value(t, err, Error.Invalid_Time_Spec)
	_, err = parse_frame(tl, 30, "verse@-1m", names, &m)
	testing.expect_value(t, err, Error.Out_Of_Range)
	_, err = parse_frame(tl, 30, "verse@1m", names)
	testing.expect_value(t, err, Error.Invalid_Time_Spec)
	_, err = parse_frame(tl, 30, "Main@1m", names)
	testing.expect_value(t, err, Error.Invalid_Time_Spec)
	_, err = parse_frame(tl, 30, "verse@1m", nil, &m)
	testing.expect_value(t, err, Error.Unknown_Scene)
}
