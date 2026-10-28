package onimite_app

import "core:testing"
import om "../onimite"
import platform "../platform"
import ui "../ui"

// A presentation holds at each scene's end, where the next scene comes in
// (its overlap) and past scenes that flow on; Next plays on from a hold (the
// next scene's first frame of its own), Previous goes back to the end of the
// scene before, and a looping hold plays its scene again.
@(test)
test_present_stops :: proc(t: ^testing.T) {
	app: App_State
	pv := &app.preview
	defer preview_timeline_destroy(&pv.timeline)
	pv.present = true
	pv.timeline.fps, pv.timeline.frames = 10, 40
	// A [0, 10); B [8, 20) coming in over A's last 2 frames, looping; C [20, 30)
	// flowing on into D [30, 40), still
	append(&pv.timeline.scenes,
		Preview_Scene{start_frame = 0, end_frame = 10, hold = .Alive},
		Preview_Scene{start_frame = 8, end_frame = 20, hold = .Loop},
		Preview_Scene{start_frame = 20, end_frame = 30, hold = .Flow},
		Preview_Scene{start_frame = 30, end_frame = 40, hold = .Freeze})
	stop, scene := present_stop(&app, 0)
	testing.expect_value(t, stop, 7)
	testing.expect_value(t, scene, 0)
	stop, scene = present_stop(&app, 12)
	testing.expect_value(t, stop, 19)
	testing.expect_value(t, scene, 1)
	stop, scene = present_stop(&app, 25)
	testing.expect_value(t, stop, 39)
	testing.expect_value(t, scene, 3)

	// playing from the start holds at A's end, its clock running on
	pv.playing = true
	preview_playback_advance(&app, 0.9)
	testing.expect(t, pv.holding && !pv.playing)
	testing.expect_value(t, pv.frame, 7)
	preview_playback_advance(&app, 0.5)
	testing.expect_value(t, pv.hold_time, 0.5)
	testing.expect_value(t, present_scene_hold(&app), om.Hold.Alive)
	// P stops the held clock
	preview_apply(&app, .Playback_Toggle, {})
	preview_playback_advance(&app, 0.5)
	testing.expect_value(t, pv.hold_time, 0.5)
	// on: from the held frame (the sound paused there), toward B's end...
	preview_apply(&app, .Present_Next, {})
	testing.expect(t, pv.playing && !pv.holding)
	testing.expect_value(t, pv.frame, 7)
	testing.expect_value(t, pv.toward, 19)
	// A leaves from where its hold left it: 0.5 s on, the scenes up to its stop
	testing.expect_value(t, pv.carry, 0.5)
	testing.expect_value(t, pv.carry_through, 7)
	// a clock steered back a frame doesn't hold at A's end again
	pv.clock = 0.6
	preview_playback_advance(&app, 0)
	testing.expect(t, pv.playing && !pv.holding)
	// ...then from B's start again (Hold.Loop)
	preview_playback_advance(&app, 1.35)
	testing.expect(t, pv.holding && pv.playing)
	testing.expect_value(t, pv.frame, 8)
	// on from the loop: B leaves from where its loop was (1.1 s before its end)
	saved := pv^
	preview_apply(&app, .Present_Next, {})
	testing.expect_value(t, pv.frame, 20)
	testing.expect_value(t, pv.carry, -1.1)
	testing.expect_value(t, pv.carry_through, 19)
	pv.frame, pv.clock, pv.holding, pv.playing, pv.toward, pv.toward_scene, pv.aimed = saved.frame, saved.clock, saved.holding, saved.playing, saved.toward, saved.toward_scene, saved.aimed
	// back: A's end, held
	preview_apply(&app, .Present_Previous, {})
	testing.expect(t, pv.holding && !pv.playing)
	testing.expect_value(t, pv.frame, 7)
	// before the first scene: its start, still, and Next plays it
	preview_apply(&app, .Present_Previous, {})
	testing.expect_value(t, pv.frame, 0)
	preview_apply(&app, .Present_Next, {})
	testing.expect(t, pv.playing && !pv.holding)
	// B blacks the screen out and back
	preview_apply(&app, .Blackout_Toggle, {})
	testing.expect(t, pv.blackout)
}

// A presentation's keys replace the preview's: on, back, black, pause.
@(test)
test_present_keys :: proc(t: ^testing.T) {
	app: App_State
	app.commands = command_storage_make()
	defer command_storage_destroy(&app.commands)
	app.preview.present = true
	press :: proc(app: ^App_State, key: platform.Key) -> Command_Kind {
		actions := []ui.Action_Row{{kind = .Key, key = key}}
		clear(&app.commands.pending.rows)
		preview_keys(app, actions, false)
		return app.commands.pending.rows[0].row.kind if len(app.commands.pending.rows) == 1 else .None
	}
	testing.expect_value(t, press(&app, .Right), Command_Kind.Present_Next)
	testing.expect_value(t, press(&app, .Page_Down), Command_Kind.Present_Next)
	testing.expect_value(t, press(&app, .Space), Command_Kind.Present_Next)
	testing.expect_value(t, press(&app, .Left), Command_Kind.Present_Previous)
	testing.expect_value(t, press(&app, .Page_Up), Command_Kind.Present_Previous)
	testing.expect_value(t, press(&app, .B), Command_Kind.Blackout_Toggle)
	testing.expect_value(t, press(&app, .P), Command_Kind.Playback_Toggle)
	testing.expect_value(t, press(&app, .Escape), Command_Kind.Dismiss)
}

// A render's chapters: one per stop a presentation makes (a scene that
// flows on joins the next one's, named after the scene it stops on), on the
// rendered range's clock; none for a single one.
@(test)
test_render_chapters :: proc(t: ^testing.T) {
	a := om.Scene{name = "Intro"}
	b := om.Scene{name = "Build", hold = .Flow}
	c := om.Scene{name = "Built"}
	d := om.Scene{name = "End"}
	scenes := []om.Scene_Info {
		{scene = &a, start_frame = 0, end_frame = 10},
		{scene = &b, start_frame = 10, end_frame = 20},
		{scene = &c, start_frame = 20, end_frame = 30},
		{scene = &d, start_frame = 30, end_frame = 40},
	}
	tl := om.Timeline{scenes = scenes, duration_frames = 40}
	whole := render_chapters(&tl, 10, 0, 40)
	testing.expect_value(t, len(whole), 3)
	if len(whole) == 3 {
		testing.expect_value(t, whole[0].title, "Intro")
		testing.expect_value(t, whole[1].title, "Built")
		testing.expect_value(t, whole[1].start, 1.0)
		testing.expect_value(t, whole[2].title, "End")
		testing.expect_value(t, whole[2].start, 3.0)
	}
	part := render_chapters(&tl, 10, 15, 40)
	testing.expect_value(t, len(part), 2)
	if len(part) == 2 {
		testing.expect_value(t, part[0].title, "Built")
		testing.expect_value(t, part[0].start, 0.0)
		testing.expect_value(t, part[1].start, 1.5)
	}
	testing.expect(t, render_chapters(&tl, 10, 0, 10) == nil)
}
