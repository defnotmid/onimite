package onimite_app

import "core:testing"
import om "../onimite"

// A group is checked against its cue: rows within a frame (a sound within
// 30 ms) pass; a family off by one amount is one finding; an id only one
// row carries is reported, a lone cue is not.
@(test)
test_sync_check :: proc(t: ^testing.T) {
	anchors := []Anchor {
		{"beat[0]", 1.0, .Cue, "cue", ""},
		{"beat[0]", 0.5, .Key, "animate key (a.lua:3)", ""},
		{"beat[1]", 2.0, .Cue, "cue", ""},
		{"beat[1]", 1.5, .Key, "animate key (a.lua:3)", ""},
		{"beat[2]", 3.0, .Cue, "cue", ""},
		{"beat[2]", 2.5, .Key, "animate key (a.lua:3)", ""},
		{"drop", 4.0, .Cue, "cue", ""},
		{"drop", 4.02, .Track, "audio boom.wav", ""},
		{"drop", 4.01, .Scene, "scene Title", ""},
		{"drop", 4.2, .Key, "animate key (a.lua:9)", ""},
		{"lonely", 6.0, .Scene, "scene Lonely", ""},
		{"solo", 7.0, .Cue, "cue", ""},
	}
	got := sync_check(nil, nil, 30, anchors)
	testing.expect_value(t, len(got), 3)
	if len(got) != 3 {
		return
	}
	testing.expect_value(t, got[0].code, om.Diagnostic_Code.Cue_Alone)
	testing.expect_value(t, got[0].name, "lonely")
	testing.expect_value(t, om.diagnostic_message(got[1], context.temp_allocator), `cue "beat[*]": 3 of 3 animate keys: -0.500s off their cues`)
	testing.expect_value(t, om.diagnostic_message(got[2], context.temp_allocator), `cue "drop": animate key (a.lua:9) at 4.200s: +0.200s off cue at 4.000s`)
}

// The ottis demo's six lines as measured: marius (the third) 7 LU under the
// rest is the one told; george, 1 LU under the median, is not.
@(test)
test_voice_level_outliers :: proc(t: ^testing.T) {
	median, outliers := voice_level_outliers({-13.0, -12.5, -21.3, -13.9, -15.1, -14.4})
	testing.expect(t, abs(median - -14.15) < 1e-9)
	testing.expect(t, len(outliers) == 1 && outliers[0] == 2)
	_, none := voice_level_outliers({-14.0})
	testing.expect(t, len(none) == 0)
}
