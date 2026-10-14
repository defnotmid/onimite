package onimite_app

import "core:testing"

// The default arrangement is the video over the timeline at its natural
// height; a split, a move into the new panel and a drop on an edge change
// the tree as their commands say, and a panel left empty closes.
@(test)
test_workspace :: proc(t: ^testing.T) {
	ws: Workspace
	defer workspace_destroy(&ws)
	workspace_init(&ws)
	video, timeline := workspace_find(&ws, .Video), workspace_find(&ws, .Timeline)
	vp := workspace_view(&ws, video).panel
	tp := workspace_view(&ws, timeline).panel
	natural := [View_Kind]f32{.Video = -1, .Timeline = 100, .Watch = -1}
	workspace_measure(&ws, {0, 0, 1000, 800}, 1, natural)
	testing.expect_value(t, ws.areas[tp - 1].rect.height, 100 + PANEL_TABS)
	testing.expect_value(t, ws.areas[vp - 1].content.y, PANEL_TABS)
	testing.expect_value(t, ws.areas[vp - 1].rect.height, 800 - PANEL_SPLITTER - 100 - PANEL_TABS)

	// A split leaves an empty panel on the right; moving the timeline there
	// closes the panel it leaves.
	workspace_apply(&ws, .Panel_Split, {panel = vp, direction = .Right})
	empty := ws.focused
	testing.expect(t, empty != vp && workspace_leaf(&ws, empty).first == 0)
	workspace_apply(&ws, .View_Move, {view = timeline, panel = empty})
	testing.expect(t, workspace_panel(&ws, tp) == nil)
	testing.expect_value(t, workspace_view(&ws, timeline).panel, empty)
	root := workspace_panel(&ws, ws.root)
	testing.expect_value(t, root.axis, Split_Axis.X)
	testing.expect_value(t, root.children, [2]Panel_Id{vp, empty})

	// A drop of the timeline on the video's left edge: one View_Move; a drop
	// of the video on its own lone panel's edge is refused.
	row, ok := workspace_drop_command(&ws, timeline, {kind = .Panel_Split, panel = vp, direction = .Left})
	testing.expect(t, ok)
	testing.expect_value(t, row.kind, Command_Kind.View_Move)
	_, ok = workspace_drop_command(&ws, video, {kind = .Panel_Split, panel = vp, direction = .Left})
	testing.expect(t, !ok)
	workspace_apply(&ws, row.kind, row.regs)
	testing.expect(t, workspace_panel(&ws, empty) == nil)
	left := workspace_view(&ws, timeline).panel
	parent := workspace_panel(&ws, workspace_panel(&ws, vp).parent)
	testing.expect_value(t, parent.children, [2]Panel_Id{left, vp})

	// Tabs: a Watch joins the video's panel and shows; closing it shows the
	// video again. The video, already open, moves where it is opened.
	workspace_apply(&ws, .View_Open, {panel = vp, view_kind = .Watch, previous = video})
	watch := workspace_find(&ws, .Watch)
	testing.expect_value(t, workspace_panel(&ws, vp).shown, watch)
	testing.expect_value(t, workspace_view(&ws, video).next, watch)
	workspace_apply(&ws, .View_Close, {view = watch})
	testing.expect_value(t, workspace_panel(&ws, vp).shown, video)
	workspace_apply(&ws, .View_Open, {panel = left, view_kind = .Video})
	testing.expect_value(t, workspace_find(&ws, .Video), video)
	testing.expect_value(t, workspace_view(&ws, video).panel, left)
	testing.expect_value(t, ws.root, left)
}

// The timeline runs down only in a panel beside another and taller than
// wide: across the bottom, or alone, it runs along whatever its shape.
@(test)
test_timeline_vertical :: proc(t: ^testing.T) {
	ws: Workspace
	defer workspace_destroy(&ws)
	workspace_init(&ws)
	timeline := workspace_view(&ws, workspace_find(&ws, .Timeline)).panel
	tall := Workspace_Rect{0, 0, 300, 700}
	testing.expect(t, !timeline_vertical(&ws, timeline, tall))
	video := workspace_view(&ws, workspace_find(&ws, .Video)).panel
	workspace_apply(&ws, .Panel_Split, {panel = video, direction = .Right})
	workspace_apply(&ws, .View_Move, {view = workspace_find(&ws, .Timeline), panel = ws.focused})
	beside := workspace_view(&ws, workspace_find(&ws, .Timeline)).panel
	testing.expect(t, timeline_vertical(&ws, beside, tall))
	testing.expect(t, !timeline_vertical(&ws, beside, {0, 0, 700, 300}))
	workspace_apply(&ws, .Panel_Close, {panel = video})
	testing.expect_value(t, ws.root, beside)
	testing.expect(t, !timeline_vertical(&ws, beside, tall))
}

// Running down, the timeline's space swaps its axes about the box's
// corner: time along x lands down y, and the pointer maps back the same way.
@(test)
test_time_axis :: proc(t: ^testing.T) {
	a := Time_Axis{vertical = true, corner = {100, 20}, ruler = RULER_WIDTH, across = 1}
	testing.expect_value(t, axis_point(a, {130, 25}), [2]f32{105, 50})
	testing.expect_value(t, axis_point(a, axis_point(a, {130, 25})), [2]f32{130, 25})
	x, y, w, h := axis_rect(a, 130, 25, 40, 10)
	testing.expect_value(t, [4]f32{x, y, w, h}, [4]f32{105, 50, 10, 40})
	along := TIME_ALONG
	along.corner = {100, 20}
	testing.expect_value(t, axis_point(along, {130, 25}), [2]f32{130, 25})
	testing.expect_value(t, axis_label_along(a, 80, 14), f32(14))
}

// Wheel zoom on the timeline and video keeps the point under the cursor
// fixed on every eased frame; manual zoom/pan detaches follow until a seek
// or Timeline_Follow reattaches it.
@(test)
test_timeline_and_video_camera :: proc(t: ^testing.T) {
	app: App_State
	pv := &app.preview
	pv.timeline.frames = 1000
	pv.timeline.fps = 30
	pv.zoom = 1
	pv.zoom_track.target = 1
	pv.video_zoom = 1
	pv.video_zoom_track.target = 1

	// Zoom timeline around cursor ratio 0.25 (frame 250): across every
	// eased step, the frame at ratio 0.25 stays pinned to 250.
	ratio := 0.25
	expected_frame := pv.view_first + ratio * view_frames(&app)
	preview_apply(&app, .Timeline_Zoom, {scalar = 2.0, ratio = ratio, flag = true})
	preview_apply(&app, .Timeline_Zoom, {scalar = 2.0, ratio = ratio, flag = true})
	testing.expect(t, pv.detached)
	for _ in 0 ..< 60 {
		preview_motion_advance(&app, 1.0 / 60.0)
		at_cursor := pv.view_first + ratio * view_frames(&app)
		testing.expect(t, abs(at_cursor - expected_frame) < 1e-4)
	}
	testing.expect(t, abs(pv.zoom - 4.0) < 1e-3)

	// While detached, advancing the playhead past the visible window does not
	// yank view_first; seeking reattaches follow.
	before_first := pv.view_first
	pv.frame = 900
	preview_view_follow(&app)
	testing.expect_value(t, pv.view_first, before_first)
	preview_apply(&app, .Frame_Set, {count = 900})
	testing.expect(t, !pv.detached)
	preview_view_follow(&app)
	testing.expect(t, pv.view_first > before_first)

	// Video 2D zoom around cursor at_xy = {0.75, 0.25} keeps the underlying
	// point fixed across every eased frame.
	at_xy := [2]f32{0.75, 0.25}
	at := [2]f64{f64(at_xy.x) - 0.5, f64(at_xy.y) - 0.5}
	pt0 := [2]f64{(at.x - pv.video_pan.x) / pv.video_zoom, (at.y - pv.video_pan.y) / pv.video_zoom}
	preview_apply(&app, .Video_Zoom, {scalar = 3.0, at_xy = at_xy})
	for _ in 0 ..< 60 {
		preview_motion_advance(&app, 1.0 / 60.0)
		pt := [2]f64{(at.x - pv.video_pan.x) / pv.video_zoom, (at.y - pv.video_pan.y) / pv.video_zoom}
		testing.expect(t, abs(pt.x - pt0.x) < 1e-4 && abs(pt.y - pt0.y) < 1e-4)
	}
	testing.expect(t, abs(pv.video_zoom - 3.0) < 1e-3)
}

