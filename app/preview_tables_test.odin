package onimite_app

import "core:testing"
import om "../onimite"

@(test)
test_wave_pyramid :: proc(t: ^testing.T) {
	// A clip silent but for one loud sample pair at 3000 and a quiet run.
	frames := 10_000
	samples := make([]f32, frames * 2)
	defer delete(samples)
	samples[3000 * 2] = 0.9
	samples[3000 * 2 + 1] = -0.5
	for i in 6000 ..< 6100 {
		samples[i * 2] = 0.1
	}
	clip := om.Audio_Clip{samples = samples, frames = frames}
	b: Wave_Builder
	defer wave_builder_destroy(&b)
	placed := []om.Placed_Track{{track = {src = "a.wav"}, clip = &clip, start = 480, end = 480 + frames}}
	video: om.Video
	wave_builder_lanes(&b, placed, {0}, &video, 0, nil)
	testing.expect(t, wave_builder_pending(&b))
	for wave_builder_pending(&b) {
		wave_builder_step(&b)
	}
	c := &b.table.clips[0]
	testing.expect_value(t, int(c.count[0]), (frames + WAVE_BUCKET - 1) / WAVE_BUCKET)
	testing.expect(t, c.levels > 3)
	// Any span over the loud pair finds it, whichever level answers.
	for span in ([]int{1, 300, 2000, 9000}) {
		lo, hi, ok := wave_peak(&b.table, c, 3000 - span / 2, 3000 + span / 2 + 1)
		testing.expect(t, ok)
		testing.expectf(t, hi > 0.85 && lo < -0.45, "span %d: %v..%v", span, lo, hi)
	}
	lo, hi, _ := wave_peak(&b.table, c, 6000, 6100)
	testing.expect(t, hi > 0.09 && hi < 0.2 && lo == 0)
	testing.expect_value(t, text_of(b.table.text[:], b.table.lanes[0].name), "a.wav")
}

// A bus's tracks are one group item (with a lane of their sound together)
// followed by a track item each, in time order; a lone track on no bus is
// an item of its own. Paths are what `onimite show` takes.
@(test)
test_timeline_items :: proc(t: ^testing.T) {
	frames := 4800
	samples := make([]f32, frames * 2)
	defer delete(samples)
	samples[100 * 2] = 0.8
	clip := om.Audio_Clip{samples = samples, frames = frames}
	placed := []om.Placed_Track {
		{track = {src = "late", bus = "sfx"}, clip = &clip, start = 20_000, end = 20_000 + frames},
		{track = {src = "music"}, clip = &clip, start = 0, end = frames},
		{track = {src = "early", bus = "sfx"}, clip = &clip, start = 1000, end = 1000 + frames},
	}
	buses := []om.Bus{{name = "sfx", gain_db = -6}}
	video := om.Video{buses = buses}
	b: Wave_Builder
	defer wave_builder_destroy(&b)
	wave_builder_lanes(&b, placed, {1, 2, 0}, &video, 3, nil)
	items := b.table.items[:]
	path :: proc(b: ^Wave_Builder, i: int) -> string {return text_of(b.table.text[:], b.table.items[i].path)}
	testing.expect_value(t, len(items), 5)
	testing.expect_value(t, items[0].kind, Timeline_Kind.Scenes)
	testing.expect_value(t, items[1].kind, Timeline_Kind.Group)
	testing.expect_value(t, path(&b, 1), "bus/sfx")
	testing.expect_value(t, items[1].children, 2)
	// Its tracks in time order, named by their place in time.
	testing.expect_value(t, path(&b, 2), "track/1")
	testing.expect_value(t, path(&b, 3), "track/2")
	testing.expect_value(t, items[2].parent, 1)
	testing.expect_value(t, path(&b, 4), "track/0")
	testing.expect_value(t, items[4].parent, -1)
	for wave_builder_pending(&b) {
		wave_builder_step(&b)
	}
	// The group's sound has both tracks' loud sample at their places.
	g := b.table.lanes[items[1].lane]
	testing.expect_value(t, g.start, 1000)
	c := &b.table.clips[g.clip]
	for at in ([]int{1000 + 100, 20_000 + 100}) {
		_, hi, ok := wave_peak(&b.table, c, at - g.start, at - g.start + 1)
		testing.expectf(t, ok && hi > 0.7, "the group's peak at %d: %v", at, hi)
	}
}

@(test)
test_problems_grouped :: proc(t: ^testing.T) {
	findings: Finding_Table
	defer finding_table_destroy(&findings)
	table: Problem_Table
	defer problem_table_destroy(&table)
	d := om.Diagnostic{severity = .Warning, code = .Text_Clipped, scene = "Intro", name = "title", x = 10}
	testing.expect(t, finding_add(&findings, nil, 12, d))
	// The same finding at another place in a later frame extends the range;
	// one inside it changes nothing.
	d2 := om.Diagnostic{severity = .Warning, code = .Text_Clipped, scene = "Intro", name = "title", x = 14}
	testing.expect(t, finding_add(&findings, nil, 20, d2))
	testing.expect(t, !finding_add(&findings, nil, 15, d2))
	// What the load found is its own finding, seen in no frame.
	load := om.Diagnostic{severity = .Error, code = .Missing_Track, name = "video.lua:3", a = "music.mp3"}
	testing.expect(t, finding_add(&findings, nil, LOAD_FRAME, load))
	problem_table_set(&table, &findings, nil)
	testing.expect_value(t, len(table.rows), 2)
	testing.expect_value(t, table.rows[0].first, 12)
	testing.expect_value(t, table.rows[0].last, 20)
	testing.expect_value(t, findings.rows[0].frames, 3)
	testing.expect_value(t, text_of(table.text[:], table.rows[0].message), `text "title" is cut off by the canvas edge (x=10 y=0 w=0 h=0)`)
	testing.expect_value(t, table.rows[1].first, LOAD_FRAME)
	testing.expect_value(t, text_of(table.text[:], table.rows[1].message), `video.lua:3: the track plays "music.mp3", which is not in the media`)
	worst, _ := findings_worst(&findings)
	testing.expect_value(t, worst, om.Severity.Error)
}
