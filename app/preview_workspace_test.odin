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
