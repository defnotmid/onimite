package onimite_app

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import om "../onimite"
import platform "../platform"
import ui "../ui"
import odimg "deps:oicut/image"
import sdl "vendor:sdl3"

// The fixture's media files, in their order: bad.png (failed), logo.png,
// music.wav and unused.wav. The row at `at`, the Watch's whole window frames
// having laid it out.
@(private = "file")
media_row :: proc(app: ^App_State, v: ^View_Record, at: int) -> View_Row {
	blocks := watch_blocks(app, v)
	rows := make([dynamic]View_Row, context.temp_allocator)
	blocks_window(&blocks, at, 1, &rows)
	return rows[0]
}

// A press and release on a box, the pointer on it the frames before.
@(private = "file")
press_box :: proc(tp: ^Test_Preview, box: ^ui.Box) {
	tp.p.input.mouse = (box.rect.min + box.rect.max) / 2
	test_frame(tp)
	test_frame(tp)
	test_frame(tp, {kind = .Mouse_Press, button = .Left})
	test_frame(tp, {kind = .Mouse_Release, button = .Left})
}

@(private = "file")
open_row :: proc(t: ^testing.T, tp: ^Test_Preview, id: View_Id, row: View_Row) -> bool {
	expander := test_box(&tp.s, fmt.tprintf("###watch_expander_%d_%s", id, row.key))
	testing.expect(t, expander != nil)
	if expander == nil do return false
	press_box(tp, expander)
	return true
}

// An image's row unfolds into one item across eight rows (RAD's single
// item): windows of it say how much of it is above and below them, keys and
// items find it, and a failed file or a sound still unfolds into members.
@(test)
test_image_row_unfolds_into_one_item :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	tp: Test_Preview
	testing.expect(t, test_preview_make(&tp))
	defer test_preview_destroy(&tp)
	app := &tp.app
	pv := &app.preview
	watch_show(app, "video:media")
	id := workspace_find_watch(&pv.workspace, "video:media")
	v := workspace_view(&pv.workspace, id)
	for _ in 0 ..< 3 do test_frame(&tp)
	logo := media_row(app, v, 1)
	testing.expect_value(t, logo.label, "logo.png")
	if !open_row(t, &tp, id, logo) do return

	blocks := watch_blocks(app, v)
	testing.expect_value(t, blocks.total, 4 + 8)
	rows := make([dynamic]View_Row, context.temp_allocator)
	blocks_window(&blocks, 1, 3, &rows)
	testing.expect_value(t, len(rows), 2)
	testing.expect(t, rows[0].expanded && rows[0].size == 0)
	testing.expect(t, rows[1].size == 8 && rows[1].skip == 0 && rows[1].chop == 6)
	testing.expect_value(t, rows[1].key, visualizer_key(logo.key))
	clear(&rows)
	blocks_window(&blocks, 4, 2, &rows)
	testing.expect(t, len(rows) == 1 && rows[0].skip == 2 && rows[0].chop == 4)
	clear(&rows)
	blocks_window(&blocks, 9, 3, &rows)
	testing.expect(t, len(rows) == 3 && rows[0].skip == 7 && rows[0].chop == 0)
	testing.expect_value(t, rows[1].label, "music.wav")
	testing.expect_value(t, blocks_index(&blocks, visualizer_key(logo.key)), 2)

	for row, item in ([?]int{0, 1, 2, 10, 11, 12}) {
		testing.expect_value(t, blocks_row_from_item(&blocks, item), row)
		testing.expect_value(t, blocks_item_from_row(&blocks, row), item)
	}
	testing.expect_value(t, blocks_item_from_row(&blocks, 9), 2) // the view's last row

	// A failed file and a sound have no view: their members.
	r := preview_reader(app)
	bad := media_row(app, v, 0)
	_, bad_view := visualizer_of(&r, bad.value)
	testing.expect(t, !bad_view && bad.unfolds)
	_, sound_view := visualizer_of(&r, media_row(app, v, 10).value)
	testing.expect(t, !sound_view)
}

// The view of `row` of Watch `id` (nil: none yet).
@(private = "file")
row_view :: proc(pv: ^Preview_State, id: View_Id, row: View_Row) -> ^View_Record {
	return workspace_view(&pv.workspace, workspace_row_view(&pv.workspace, id, row_view_key(row.key)))
}

// The worker's table has the file, in two by two pixels. (The canvas is nil in
// these tests: nothing draws, so the texture is only a name.)
@(private = "file")
table_has :: proc(pv: ^Preview_State, mb: ^Mailbox, file: u64) {
	@(static) pixels := [16]u8{255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 0, 128}
	append(&mb.images, Image_Shown{file, (^sdl.GPUTexture)(uintptr(8)), {2, 2}})
	append(&mb.image_pixels, pixels[:])
	mb.images_seq += 1
	images_take(pv, mb)
}

// The row through whole frames: its view is a view record, made by a command,
// which asks for its file by id; the worker's table gives it the file's size
// and texture, opening at four fifths of its rows' height; a drag pans and a
// double press puts it back; the wheel is the list's; it has no tooltip, as it
// would cover the picture; Down steps over it as one item. Scrolled away and
// back it is still open: it looks where it did and its file is still asked
// for. Shut, its view goes.
@(test)
test_image_view_through_the_pipeline :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	tp: Test_Preview
	testing.expect(t, test_preview_make(&tp))
	defer test_preview_destroy(&tp)
	mb: Mailbox
	defer mailbox_destroy(&mb)
	app := &tp.app
	pv := &app.preview
	pv.mailbox = &mb
	defer pv.mailbox = nil
	tp.p.frame_dt = 1 // what fades in is there at once
	watch_show(app, "video:media")
	id := workspace_find_watch(&pv.workspace, "video:media")
	v := workspace_view(&pv.workspace, id)
	for _ in 0 ..< 3 do test_frame(&tp)
	testing.expect_value(t, len(pv.images_open), 0)
	logo := media_row(app, v, 1)
	if !open_row(t, &tp, id, logo) do return
	v = workspace_view(&pv.workspace, id) // (the row's view has been added)

	// Its view is in no panel, on the row's expression, and asks for its file
	// by its id, once.
	file := pv.tables.media[logo.value.ref.row].id
	test_frame(&tp)
	rv := row_view(pv, id, logo)
	testing.expect(t, rv != nil && rv.kind == .Image && rv.panel == 0 && rv.owner == id)
	if rv == nil do return
	testing.expect_value(t, rv.inputs[0].source, logo.source)
	testing.expect(t, len(pv.images_open) == 1 && pv.images_open[0] == file)
	key := fmt.tprintf("watch_%d_%s", id, visualizer_key(logo.key))
	image_key := fmt.tprintf("###bmp_image_%s", key)
	canvas_key := fmt.tprintf("###bmp_canvas_%s", key)
	canvas := test_box(&tp.s, canvas_key)
	testing.expect(t, canvas != nil)
	if canvas == nil do return
	row_h := list_row_height(&tp.s)
	testing.expect_value(t, canvas.rect.max.y - canvas.rect.min.y, 8 * row_h)
	testing.expect(t, test_box(&tp.s, image_key) == nil, "nothing to show until it is made")

	table_has(pv, &mb, file)
	testing.expect_value(t, mb.images_ack, mb.images_seq)
	testing.expect_value(t, len(pv.images), 1)
	test_frame(&tp)
	test_frame(&tp)
	image := test_box(&tp.s, image_key)
	testing.expect(t, image != nil)
	if image == nil do return
	zoom := 8 * row_h / 2 * 0.8
	testing.expect(t, abs(rv.bitmap.zoom - zoom) < 0.001)
	testing.expect(t, abs((image.rect.max.x - image.rect.min.x) - 2 * zoom) <= 1)

	// Over the picture in a row: no outline, no tooltip.
	tp.p.input.mouse = (image.rect.min + image.rect.max) / 2
	test_frame(&tp)
	test_frame(&tp)
	testing.expect(t, test_box(&tp.s, fmt.tprintf("###bmp_pixel_%s", key)) == nil)
	testing.expect(t, test_box(&tp.s, "###color_tooltip_hex") == nil)

	// A drag pans it from where it was pressed; a double press puts it back.
	tp.p.input.mouse = canvas.rect.max - {10, 10}
	test_frame(&tp)
	test_frame(&tp)
	test_frame(&tp, {kind = .Mouse_Press, button = .Left})
	testing.expect_value(t, view_list(pv, id).cursor, 2) // a press puts the cursor on it
	tp.p.input.mouse -= {20, 0}
	test_frame(&tp)
	testing.expect(t, abs(rv.bitmap.center.x - 20 / zoom) < 0.001)
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	test_frame(&tp, {kind = .Mouse_Press, button = .Left})
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	test_frame(&tp, {kind = .Mouse_Press, button = .Left})
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	testing.expect(t, rv.bitmap.center == {} && rv.bitmap.zoom == 1)
	rv.bitmap.center, rv.bitmap.zoom = {3, 4}, zoom

	// The wheel over it is the list's: the rows move, the image doesn't zoom.
	scrolled := test_frame(&tp, {kind = .Scroll, position = tp.p.input.mouse, delta = {0, -platform.WHEEL_NOTCH}})
	testing.expect(t, test_has(scrolled, .View_Scroll))
	testing.expect_value(t, rv.bitmap.zoom, zoom)

	// Scrolled off the window and back: still open, looking where it did, its
	// file asked for all the while.
	command_push(&app.commands, .View_Scroll, {view = id, count = 11, flag = true})
	for _ in 0 ..< 3 do test_frame(&tp)
	testing.expect(t, test_box(&tp.s, canvas_key) == nil, "scrolled off")
	testing.expect(t, row_view(pv, id, logo) != nil)
	testing.expect(t, len(pv.images_open) == 1 && pv.images_open[0] == file)
	command_push(&app.commands, .View_Scroll, {view = id, count = 0, flag = true})
	for _ in 0 ..< 3 do test_frame(&tp)
	testing.expect(t, test_box(&tp.s, canvas_key) != nil, "back")
	rv = row_view(pv, id, logo)
	testing.expect(t, rv.bitmap.center == {3, 4} && rv.bitmap.zoom == zoom)

	// A filter that hides it closes nothing.
	append(&v.filter, "music")
	for _ in 0 ..< 2 do test_frame(&tp)
	testing.expect(t, test_box(&tp.s, canvas_key) == nil, "filtered out")
	testing.expect(t, row_view(pv, id, logo) != nil && len(pv.images_open) == 1)
	clear(&v.filter)
	for _ in 0 ..< 2 do test_frame(&tp)

	// Down steps over its rows as one item.
	view_list(pv, id).cursor = 1
	test_frame(&tp, key_press(.Down, {}))
	testing.expect_value(t, view_list(pv, id).cursor, 2)
	test_frame(&tp, key_press(.Down, {}))
	testing.expect_value(t, view_list(pv, id).cursor, 3)
	blocks := watch_blocks(app, v)
	testing.expect_value(t, media_row(app, v, blocks_row_from_item(&blocks, 3)).label, "music.wav")

	// Shut: its view goes, and nothing asks for the file.
	view_list(pv, id).cursor = 1
	command_push(&app.commands, .View_Scroll, {view = id, count = 0, flag = true})
	tp.p.input.mouse = {-1, -1}
	for _ in 0 ..< 3 do test_frame(&tp)
	if !open_row(t, &tp, id, media_row(app, v, 1)) do return
	test_frame(&tp)
	testing.expect(t, row_view(pv, id, logo) == nil)
	testing.expect_value(t, len(pv.images_open), 0)
}

// A file is asked for once however many views are on it, in hidden tabs too; a
// row's view goes with its expression, and every row's with its Watch.
@(test)
test_row_views_name_their_files :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	tp: Test_Preview
	testing.expect(t, test_preview_make(&tp))
	defer test_preview_destroy(&tp)
	app := &tp.app
	pv := &app.preview
	ws := &pv.workspace
	watch_show(app, "video:media")
	id := workspace_find_watch(ws, "video:media")
	for _ in 0 ..< 3 do test_frame(&tp)
	logo := media_row(app, workspace_view(ws, id), 1)
	file := pv.tables.media[logo.value.ref.row].id
	command_push(&app.commands, .Watch_Expand, {view = id, spec = logo.key})
	for _ in 0 ..< 3 do test_frame(&tp)
	testing.expect(t, len(pv.images_open) == 1 && pv.images_open[0] == file)

	// An expression Watch on the same file, open: the one row, and two views
	// that each look their own way.
	other := workspace_open(ws, workspace_view(ws, id).panel, .Watch)
	command_push(&app.commands, .Watch_Input_Add, {view = other, count = 0, spec = "media[\"logo.png\"]"})
	test_frame(&tp)
	top := media_row(app, workspace_view(ws, other), 0)
	command_push(&app.commands, .Watch_Expand, {view = other, spec = top.key})
	for _ in 0 ..< 3 do test_frame(&tp)
	testing.expect(t, len(pv.images_open) == 1 && pv.images_open[0] == file)
	testing.expect(t, row_view(pv, other, top) != nil && row_view(pv, id, logo) != nil)
	testing.expect(t, row_view(pv, other, top) != row_view(pv, id, logo))

	// Its expression edited to the same file: the row keeps its view, which
	// follows what the row now says.
	row_view(pv, other, top).bitmap.center = {7, 8}
	command_push(&app.commands, .Watch_Input_Set, {view = other, count = 0, spec = "media[1]"})
	for _ in 0 ..< 3 do test_frame(&tp)
	testing.expect_value(t, row_view(pv, other, top).inputs[0].source, "media[1]")
	testing.expect_value(t, row_view(pv, other, top).bitmap.center, [2]f32{7, 8})

	// (the first Watch's tab is hidden now: its row's view still stands)
	command_push(&app.commands, .Watch_Input_Remove, {view = other, count = 0})
	for _ in 0 ..< 2 do test_frame(&tp)
	testing.expect(t, row_view(pv, other, top) == nil)
	testing.expect_value(t, len(workspace_view(ws, other).expanded), 0)
	testing.expect(t, len(pv.images_open) == 1 && pv.images_open[0] == file)

	// Its Watch goes, and the file with it.
	command_push(&app.commands, .View_Close, {view = id})
	for _ in 0 ..< 2 do test_frame(&tp)
	testing.expect(t, workspace_row_view(ws, id, row_view_key(logo.key)) == 0)
	testing.expect_value(t, len(pv.images_open), 0)
}

// A row's view is a view in no panel: nothing that looks for tabs finds it, a
// selection of it does nothing, and it closes like any other.
@(test)
test_row_view_is_in_no_panel :: proc(t: ^testing.T) {
	ws: Workspace
	defer workspace_destroy(&ws)
	workspace_init(&ws)
	timeline := workspace_find(&ws, .Timeline)
	focused := ws.focused
	workspace_apply(&ws, .Row_View_Open, {view = timeline, row = 5, view_kind = .Watch, spec = "tracks.kick", flags = {.Scoped}})
	id := workspace_row_view(&ws, timeline, 5)
	testing.expect(t, id != 0)
	testing.expect_value(t, workspace_view(&ws, id).panel, Panel_Id(0))
	testing.expect_value(t, workspace_view(&ws, id).scoped, true)
	testing.expect_value(t, workspace_find(&ws, .Watch), View_Id(0))
	testing.expect_value(t, workspace_shown(&ws, .Watch), View_Id(0))
	testing.expect_value(t, workspace_find_watch(&ws, "tracks.kick"), View_Id(0))
	workspace_select(&ws, id)
	testing.expect_value(t, ws.focused, focused)

	// Opened again: the same one. A second row: its own. No view: none.
	workspace_apply(&ws, .Row_View_Open, {view = timeline, row = 5, view_kind = .Watch, spec = "tracks.kick"})
	testing.expect_value(t, workspace_row_view(&ws, timeline, 5), id)
	workspace_apply(&ws, .Row_View_Open, {view = timeline, row = 6, view_kind = .Watch, spec = "tracks.snare", flags = {.Scoped}})
	other := workspace_row_view(&ws, timeline, 6)
	testing.expect(t, other != 0 && other != id)
	views := len(ws.views)
	workspace_apply(&ws, .Row_View_Open, {view = 999, row = 7, view_kind = .Watch, spec = "tracks.hat"})
	testing.expect_value(t, len(ws.views), views)

	// Row_View_Close closes a row's view, and leaves a tab alone.
	workspace_apply(&ws, .Row_View_Close, {view = id})
	testing.expect(t, workspace_view(&ws, id) == nil)
	workspace_apply(&ws, .Row_View_Close, {view = timeline})
	testing.expect(t, workspace_view(&ws, timeline) != nil)

	// Landed, it is a tab; the view it came from no longer owns it.
	video := workspace_view(&ws, workspace_find(&ws, .Video)).panel
	workspace_apply(&ws, .View_Move, {view = other, panel = video, previous = workspace_panel(&ws, video).last})
	testing.expect_value(t, workspace_view(&ws, other).panel, video)
	testing.expect_value(t, workspace_view(&ws, other).owner, View_Id(0))
	testing.expect_value(t, workspace_find_watch(&ws, "tracks.snare"), other)
	workspace_apply(&ws, .Row_View_Close, {view = other})
	testing.expect(t, workspace_view(&ws, other) != nil)

	// The owner's panel closes: its rows' views with it, a tab it made not.
	workspace_apply(&ws, .Row_View_Open, {view = timeline, row = 8, view_kind = .Watch, spec = "tracks.tom"})
	last := workspace_row_view(&ws, timeline, 8)
	workspace_apply(&ws, .Panel_Close, {panel = workspace_view(&ws, timeline).panel})
	testing.expect(t, workspace_view(&ws, last) == nil)
	testing.expect(t, workspace_view(&ws, other) != nil)
}

// Dragging an open image's row out is a tab's drag of its view, through whole
// frames: held on the row nothing happens until the pointer leaves it; then the
// drag is the row's view's, every panel offers its sites, and the drop is
// View_Move. The picture's own drag only pans it. The view is
// then a tab, looking where it did, its title the file's name, zooming with the
// wheel and showing the colour under the pointer; the row stays open with a
// fresh view of its own. The tab outlives the row and the Watch; closing it
// lets the file go.
@(test)
test_image_row_pulls_out_as_a_tab :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	tp: Test_Preview
	testing.expect(t, test_preview_make(&tp))
	defer test_preview_destroy(&tp)
	mb: Mailbox
	defer mailbox_destroy(&mb)
	app := &tp.app
	pv := &app.preview
	ws := &pv.workspace
	pv.mailbox = &mb
	defer pv.mailbox = nil
	tp.p.frame_dt = 1
	watch_show(app, "video:media")
	id := workspace_find_watch(ws, "video:media")
	for _ in 0 ..< 3 do test_frame(&tp)
	logo := media_row(app, workspace_view(ws, id), 1)
	if !open_row(t, &tp, id, logo) do return
	for _ in 0 ..< 2 do test_frame(&tp)
	file := pv.tables.media[logo.value.ref.row].id
	table_has(pv, &mb, file)
	for _ in 0 ..< 2 do test_frame(&tp)
	pulled := workspace_row_view(ws, id, row_view_key(logo.key))
	testing.expect(t, pulled != 0)
	if pulled == 0 do return
	workspace_view(ws, pulled).bitmap.center = {0.25, 0.5}
	row_key := fmt.tprintf("###watch_row_%d_%s", id, logo.key)
	video := workspace_view(ws, workspace_find(ws, .Video)).panel
	over_video := ws.areas[video - 1].content
	on_video := [2]f32{over_video.x + over_video.width / 2, over_video.y + over_video.height / 2}

	press :: proc(tp: ^Test_Preview, row: ^ui.Box) {
		tp.p.input.mouse = (row.rect.min + row.rect.max) / 2
		test_frame(tp)
		test_frame(tp)
		test_frame(tp, {kind = .Mouse_Press, button = .Left})
	}
	row_box := test_box(&tp.s, row_key)
	testing.expect(t, row_box != nil)
	if row_box == nil do return

	// Esc drops the drag: the row keeps its view, no tab.
	press(&tp, row_box)
	test_frame(&tp)
	testing.expect_value(t, pv.drag, Drag_State.Null) // still on the row
	tp.p.input.mouse = on_video
	test_frame(&tp)
	testing.expect_value(t, pv.drag, Drag_State.Dragging)
	testing.expect_value(t, pv.drag_view, pulled)
	test_frame(&tp, key_press(.Escape, {}))
	testing.expect_value(t, pv.drag, Drag_State.Null)
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	testing.expect_value(t, workspace_view(ws, pulled).panel, Panel_Id(0))
	testing.expect_value(t, workspace_row_view(ws, id, row_view_key(logo.key)), pulled)

	// Released over nothing (the controls under the panels): the same.
	press(&tp, row_box)
	tp.p.input.mouse = {on_video.x, f32(tp.p.height) - 2}
	test_frame(&tp)
	test_frame(&tp)
	testing.expect_value(t, pv.drag, Drag_State.Dragging)
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	testing.expect_value(t, pv.drag, Drag_State.Null)
	testing.expect_value(t, workspace_view(ws, pulled).panel, Panel_Id(0))

	// Onto the video's panel: View_Move, a tab's.
	press(&tp, row_box)
	tp.p.input.mouse = on_video
	test_frame(&tp)
	test_frame(&tp)
	testing.expect_value(t, pv.drag_view, pulled)
	dropped := test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	testing.expect(t, test_has(dropped, .View_Move))
	testing.expect(t, !test_has(dropped, .Row_View_Close))
	testing.expect(t, !test_has(dropped, .Go_To), "a drag is no click on its row")
	testing.expect_value(t, pv.drag, Drag_State.Null)
	tab := workspace_view(ws, pulled)
	testing.expect(t, tab != nil && tab.panel == video && tab.owner == 0 && tab.kind == .Image)
	if tab == nil do return
	testing.expect_value(t, workspace_panel(ws, video).shown, pulled)
	testing.expect_value(t, tab.bitmap.center, [2]f32{0.25, 0.5})
	title, _ := view_title(app, pulled)
	testing.expect_value(t, title, "logo.png")

	// The row is still open, with a view of its own, looking from the start.
	for _ in 0 ..< 3 do test_frame(&tp)
	fresh := workspace_row_view(ws, id, row_view_key(logo.key))
	testing.expect(t, fresh != 0 && fresh != pulled)
	testing.expect_value(t, workspace_view(ws, fresh).bitmap.center, [2]f32{0, 0})
	testing.expect(t, len(pv.images_open) == 1 && pv.images_open[0] == file)

	// The tab shows the file, with the wheel and the tooltip a row hasn't.
	tab_key := fmt.tprintf("tab_%d", pulled)
	canvas := test_box(&tp.s, fmt.tprintf("###bmp_canvas_%s", tab_key))
	testing.expect(t, canvas != nil && .Scroll in canvas.flags)
	if canvas == nil do return
	image := test_box(&tp.s, fmt.tprintf("###bmp_image_%s", tab_key))
	testing.expect(t, image != nil)
	if image == nil do return
	tp.p.input.mouse = image.rect.min + 2
	test_frame(&tp)
	test_frame(&tp)
	hex := test_box(&tp.s, "###color_tooltip_hex")
	testing.expect(t, hex != nil && hex.str == "Hex: #ff0000ff")
	zoom := workspace_view(ws, pulled).bitmap.zoom
	test_frame(&tp, {kind = .Scroll, position = tp.p.input.mouse, delta = {0, -platform.WHEEL_NOTCH}})
	testing.expect(t, workspace_view(ws, pulled).bitmap.zoom != zoom)

	// The tab outlives the row and its Watch, and the file stays with it.
	command_push(&app.commands, .View_Close, {view = id})
	for _ in 0 ..< 2 do test_frame(&tp)
	testing.expect(t, workspace_view(ws, pulled) != nil)
	testing.expect(t, len(pv.images_open) == 1 && pv.images_open[0] == file)

	// Closed, nothing asks for it.
	command_push(&app.commands, .View_Close, {view = pulled})
	for _ in 0 ..< 2 do test_frame(&tp)
	testing.expect_value(t, len(pv.images_open), 0)
}

// The box keyed `key` under `parent` this frame.
@(private = "file")
box_under :: proc(s: ^ui.State, parent: ^ui.Box, key: string) -> ^ui.Box {
	for k, b in s.box_table {
		if b.parent == parent && b.last_build_index == s.build_index && ui.key_from_string(parent.key, key) == k do return b
	}
	return nil
}

// Every row drags out the same way: the view of its value, by RAD's rule, made
// by a command as the pointer leaves the row and dragged from the next frame. A
// scene: a Watch whose top-level rows are its members, named for it; dragged
// again, that tab moves. Landing nowhere, what was made goes. A closed image: the
// picture, in a tab, the row staying closed. A plain value: a Watch of one row.
// Let go before the drag starts, what was made goes too.
@(test)
test_any_row_drags_out :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	tp: Test_Preview
	testing.expect(t, test_preview_make(&tp))
	defer test_preview_destroy(&tp)
	app := &tp.app
	pv := &app.preview
	ws := &pv.workspace
	tp.p.frame_dt = 1
	watch_show(app, "video:scenes")
	id := workspace_find_watch(ws, "video:scenes")
	for _ in 0 ..< 3 do test_frame(&tp)
	video := workspace_view(ws, workspace_find(ws, .Video)).panel
	area := ws.areas[video - 1].content
	on_video := [2]f32{area.x + area.width / 2, area.y + area.height / 2}
	row_box :: proc(tp: ^Test_Preview, id: View_Id, row: View_Row) -> ^ui.Box {
		return test_box(&tp.s, fmt.tprintf("###watch_row_%d_%s", id, row.key))
	}
	press :: proc(tp: ^Test_Preview, box: ^ui.Box) {
		tp.p.input.mouse = (box.rect.min + box.rect.max) / 2
		test_frame(tp)
		test_frame(tp)
		test_frame(tp, {kind = .Mouse_Press, button = .Left})
	}

	// A scene: out of the row, a command makes its view; the next frame drags it.
	outro := media_row(app, workspace_view(ws, id), 1)
	testing.expect_value(t, outro.label, "Outro")
	box := row_box(&tp, id, outro)
	testing.expect(t, box != nil)
	if box == nil do return
	press(&tp, box)
	tp.p.input.mouse = on_video
	made := test_frame(&tp)
	testing.expect(t, test_has(made, .Row_View_Open))
	testing.expect_value(t, pv.drag, Drag_State.Null)
	test_frame(&tp)
	testing.expect_value(t, pv.drag, Drag_State.Dragging)
	pulled := workspace_row_view(ws, id, row_view_key(outro.key))
	testing.expect_value(t, pv.drag_view, pulled)
	testing.expect(t, workspace_view(ws, pulled).kind == .Watch && workspace_view(ws, pulled).transient)

	// Esc: it goes, and nothing is left.
	test_frame(&tp, key_press(.Escape, {}))
	testing.expect_value(t, pv.drag, Drag_State.Null)
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	testing.expect(t, workspace_view(ws, pulled) == nil)
	testing.expect_value(t, workspace_row_view(ws, id, row_view_key(outro.key)), View_Id(0))

	// Released over nothing: it goes too.
	press(&tp, box)
	tp.p.input.mouse = {on_video.x, f32(tp.p.height) - 2}
	for _ in 0 ..< 3 do test_frame(&tp)
	testing.expect_value(t, pv.drag, Drag_State.Dragging)
	pulled = pv.drag_view
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	test_frame(&tp)
	testing.expect(t, workspace_view(ws, pulled) == nil)

	// Let go in the frame between the command and the drag: it goes too.
	press(&tp, box)
	tp.p.input.mouse = on_video
	test_frame(&tp)
	pulled = workspace_row_view(ws, id, row_view_key(outro.key))
	testing.expect(t, pulled != 0)
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	testing.expect_value(t, pv.drag, Drag_State.Null)
	test_frame(&tp)
	testing.expect(t, workspace_view(ws, pulled) == nil)

	// Dragged out and let go back on its own row: the drop, no click on the row.
	press(&tp, box)
	tp.p.input.mouse = on_video
	for _ in 0 ..< 2 do test_frame(&tp)
	testing.expect_value(t, pv.drag, Drag_State.Dragging)
	pulled = pv.drag_view
	tp.p.input.mouse = (box.rect.min + box.rect.max) / 2
	test_frame(&tp)
	back := test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	testing.expect(t, !test_has(back, .Go_To))
	for _ in 0 ..< 2 do test_frame(&tp)
	if back_tab := workspace_view(ws, pulled); back_tab != nil && back_tab.panel != 0 {
		command_push(&app.commands, .View_Close, {view = pulled})
		for _ in 0 ..< 2 do test_frame(&tp)
	}
	box = row_box(&tp, id, outro)
	if box == nil {testing.expect(t, false, "the row gone"); return}

	// Onto the video's panel: a tab on the row's expression, named for it.
	press(&tp, box)
	tp.p.input.mouse = on_video
	for _ in 0 ..< 3 do test_frame(&tp)
	dropped := test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	testing.expect(t, test_has(dropped, .View_Move))
	test_frame(&tp)
	tab := workspace_find_watch(ws, outro.source)
	testing.expect(t, tab != 0)
	if tab == 0 do return
	testing.expect(t, workspace_view(ws, tab).panel == video && workspace_view(ws, tab).owner == 0 && workspace_view(ws, tab).scoped)
	testing.expect(t, !workspace_view(ws, tab).transient)
	title, _ := view_title(app, tab)
	testing.expect_value(t, title, "Outro")
	blocks := watch_blocks(app, workspace_view(ws, tab))
	testing.expect_value(t, blocks.total, 8) // its eight members

	// Dragged again: that tab moves, no second one.
	workspace_select(ws, id)
	for _ in 0 ..< 2 do test_frame(&tp)
	box = row_box(&tp, id, outro)
	if box == nil {testing.expect(t, false, "the row's Watch hidden"); return}
	press(&tp, box)
	tp.p.input.mouse = on_video
	for _ in 0 ..< 2 do test_frame(&tp)
	testing.expect_value(t, pv.drag_view, tab)
	test_frame(&tp, key_press(.Escape, {}))
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	testing.expect(t, workspace_view(ws, tab) != nil)

	// A plain value: a Watch of one row, not a list of nothing.
	command_push(&app.commands, .Watch_Expand, {view = id, spec = outro.key})
	for _ in 0 ..< 3 do test_frame(&tp)
	name := media_row(app, workspace_view(ws, id), 2)
	testing.expect_value(t, name.label, "name")
	box = row_box(&tp, id, name)
	testing.expect(t, box != nil)
	if box == nil do return
	press(&tp, box)
	tp.p.input.mouse = on_video
	for _ in 0 ..< 3 do test_frame(&tp)
	pulled = pv.drag_view
	testing.expect(t, pulled != 0)
	if pulled == 0 do return
	testing.expect_value(t, workspace_view(ws, pulled).scoped, false)
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	for _ in 0 ..< 2 do test_frame(&tp)
	testing.expect_value(t, workspace_view(ws, pulled).panel, video)

	// A closed image: its picture in a tab, the row staying closed.
	watch_show(app, "video:media")
	images := workspace_find_watch(ws, "video:media")
	for _ in 0 ..< 3 do test_frame(&tp)
	logo := media_row(app, workspace_view(ws, images), 1)
	box = row_box(&tp, images, logo)
	testing.expect(t, box != nil)
	if box == nil do return

	// Opened while it is dragged, the row shows that view: Esc doesn't close it.
	press(&tp, box)
	tp.p.input.mouse = on_video
	for _ in 0 ..< 3 do test_frame(&tp)
	pulled = pv.drag_view
	testing.expect(t, pulled != 0 && workspace_view(ws, pulled).transient)
	command_push(&app.commands, .Watch_Expand, {view = images, spec = logo.key})
	for _ in 0 ..< 2 do test_frame(&tp)
	testing.expect(t, !workspace_view(ws, pulled).transient)
	test_frame(&tp, key_press(.Escape, {}))
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	test_frame(&tp)
	testing.expect(t, workspace_view(ws, pulled) != nil)
	testing.expect_value(t, workspace_row_view(ws, images, row_view_key(logo.key)), pulled)
	command_push(&app.commands, .Watch_Expand, {view = images, spec = logo.key})
	for _ in 0 ..< 2 do test_frame(&tp)
	testing.expect(t, workspace_view(ws, pulled) == nil)
	box = row_box(&tp, images, logo)
	if box == nil {testing.expect(t, false, "the media row gone"); return}
	press(&tp, box)
	tp.p.input.mouse = on_video
	for _ in 0 ..< 3 do test_frame(&tp)
	pulled = pv.drag_view
	testing.expect(t, pulled != 0 && workspace_view(ws, pulled).kind == .Image)
	testing.expect_value(t, len(pv.images_open), 1) // while it is dragged
	test_frame(&tp, key_press(.Escape, {}))
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	test_frame(&tp)
	testing.expect(t, workspace_view(ws, pulled) == nil)
	testing.expect_value(t, len(pv.images_open), 0)
	box = row_box(&tp, images, logo)
	if box == nil {testing.expect(t, false, "the media row gone"); return}
	press(&tp, box)
	tp.p.input.mouse = on_video
	for _ in 0 ..< 3 do test_frame(&tp)
	pulled = pv.drag_view
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	for _ in 0 ..< 2 do test_frame(&tp)
	testing.expect(t, workspace_view(ws, pulled) != nil && workspace_view(ws, pulled).owner == 0 && workspace_view(ws, pulled).panel == video)
	testing.expect_value(t, len(workspace_view(ws, images).expanded), 0)
	testing.expect_value(t, len(pv.images_open), 1)

	// A row being edited doesn't drag: its press is the line edit's.
	other := workspace_open(ws, video, .Watch)
	command_push(&app.commands, .Watch_Input_Add, {view = other, count = 0, spec = "scenes"})
	for _ in 0 ..< 3 do test_frame(&tp)
	top := media_row(app, workspace_view(ws, other), 0)
	box = row_box(&tp, other, top)
	testing.expect(t, box != nil)
	if box == nil do return
	tp.p.input.mouse = (box.rect.min + box.rect.max) / 2
	test_frame(&tp)
	test_frame(&tp)
	test_frame(&tp, {kind = .Mouse_Press, button = .Left})
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	testing.expect_value(t, pv.watch_edit.view, other)
	test_frame(&tp, {kind = .Mouse_Press, button = .Left})
	tp.p.input.mouse = {on_video.x, f32(tp.p.height) - 2}
	for _ in 0 ..< 3 do test_frame(&tp)
	testing.expect_value(t, pv.drag, Drag_State.Null)
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
}

// A timeline row drags out by its name, the one path every row takes, and the
// rest of it still scrubs: a press on its name doesn't scrub, a press elsewhere
// does and never drags out however far it wanders. Out of the row by its name, a
// Watch on the row's value, a tab's drag; landing nowhere it goes, onto a panel it
// is a tab on the row's expression. Dragged again, that tab moves: one Watch on
// it. A group's name opens it on a click, not when it is dragged out.
@(test)
test_timeline_row_drags_out :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	tp: Test_Preview
	testing.expect(t, test_preview_make(&tp))
	defer test_preview_destroy(&tp)
	app := &tp.app
	pv := &app.preview
	ws := &pv.workspace
	tp.p.frame_dt = 1
	frames := 4800
	samples := make([]f32, frames * 2)
	defer delete(samples)
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
	wave_table_copy(&pv.waves, &b.table)
	timeline := workspace_find(ws, .Timeline)
	for _ in 0 ..< 3 do test_frame(&tp)

	// Every row of the tracks writes itself as the expression that names it.
	r := preview_reader(app)
	for _, i in pv.waves.tracks {
		value, error := evaluate(&r, track_source(&r, i32(i)))
		testing.expectf(t, error == "", "%s: %s", track_source(&r, i32(i)), error)
		testing.expect_value(t, value.ref.row, i32(i))
	}

	// The lone track: music's row, the last one.
	it := pv.waves.items[len(pv.waves.items) - 1]
	testing.expect_value(t, it.kind, Timeline_Kind.Track)
	row_box := test_box(&tp.s, fmt.tprintf("###timeline_row_%x_%d", it.key, int(it.kind)))
	testing.expect(t, row_box != nil)
	if row_box == nil do return
	on_name := [2]f32{row_box.rect.min.x + 20, (row_box.rect.min.y + row_box.rect.max.y) / 2}
	on_lane := [2]f32{row_box.rect.min.x + 400, on_name.y}
	on_video := workspace_view(ws, workspace_find(ws, .Video)).panel
	area := ws.areas[on_video - 1].content
	to := [2]f32{area.x + area.width / 2, area.y + area.height / 2}

	// On the lane a press scrubs, and however far it wanders it only scrubs.
	tp.p.input.mouse = on_lane
	test_frame(&tp)
	test_frame(&tp)
	scrub := test_frame(&tp, {kind = .Mouse_Press, button = .Left})
	testing.expect(t, test_has(scrub, .Frame_Set))
	tp.p.input.mouse = to
	for _ in 0 ..< 2 do test_frame(&tp)
	testing.expect_value(t, pv.drag, Drag_State.Null)
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})

	// On its name a press doesn't scrub; out of the row, the view made by a
	// command, then a tab's drag of it.
	press_name :: proc(tp: ^Test_Preview, at: [2]f32) -> []Command_Row {
		tp.p.input.mouse = at
		test_frame(tp)
		test_frame(tp)
		return test_frame(tp, {kind = .Mouse_Press, button = .Left})
	}
	pressed := press_name(&tp, on_name)
	testing.expect(t, !test_has(pressed, .Frame_Set))
	tp.p.input.mouse = to
	made := test_frame(&tp)
	testing.expect(t, test_has(made, .Row_View_Open))
	testing.expect(t, !test_has(made, .Frame_Set))
	test_frame(&tp)
	testing.expect_value(t, pv.drag, Drag_State.Dragging)
	row_id := pv.waves.tracks[it.row].id
	pulled := workspace_row_view(ws, timeline, row_id)
	testing.expect_value(t, pv.drag_view, pulled)
	testing.expect_value(t, workspace_view(ws, pulled).kind, View_Kind.Watch)

	// Esc: it goes, and the release ends the press.
	test_frame(&tp, key_press(.Escape, {}))
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	testing.expect(t, workspace_view(ws, pulled) == nil)
	testing.expect_value(t, workspace_row_view(ws, timeline, row_id), View_Id(0))
	testing.expect_value(t, tp.s.active[.Left], ui.Key(0))

	// Again, onto the video's panel: a tab on the row's expression, named for it.
	source := track_source(&r, it.row)
	pull :: proc(tp: ^Test_Preview, at, to: [2]f32) {
		press_name(tp, at)
		tp.p.input.mouse = to
		for _ in 0 ..< 3 do test_frame(tp)
		test_frame(tp, {kind = .Mouse_Release, button = .Left})
	}
	pull(&tp, on_name, to)
	tab := workspace_find_watch(ws, source)
	testing.expect(t, tab != 0)
	if tab == 0 do return
	testing.expect_value(t, workspace_view(ws, tab).panel, on_video)
	testing.expect_value(t, workspace_view(ws, tab).owner, View_Id(0))
	title, _ := view_title(app, tab)
	testing.expect_value(t, title, "music")
	testing.expect_value(t, workspace_row_view(ws, timeline, row_id), View_Id(0))
	for _ in 0 ..< 2 do test_frame(&tp)

	// Dragged again, onto the timeline's own panel: that tab moves, no second one.
	views := 0
	for v in ws.views do if v.live do views += 1
	own := ws.areas[workspace_view(ws, timeline).panel - 1].content
	pull(&tp, on_name, {own.x + own.width / 2, own.y + 8})
	after := 0
	for v in ws.views do if v.live do after += 1
	testing.expect_value(t, after, views)
	testing.expect_value(t, workspace_find_watch(ws, source), tab)
	testing.expect_value(t, workspace_view(ws, tab).panel, workspace_view(ws, timeline).panel)

	// A group's name: dragged out, it stays as it is; a click opens it.
	workspace_select(ws, timeline)
	for _ in 0 ..< 2 do test_frame(&tp)
	group := pv.waves.items[1]
	testing.expect_value(t, group.kind, Timeline_Kind.Group)
	group_box := test_box(&tp.s, fmt.tprintf("###timeline_row_%x_%d", group.key, int(group.kind)))
	testing.expect(t, group_box != nil)
	if group_box == nil do return
	on_group := [2]f32{group_box.rect.min.x + 20, (group_box.rect.min.y + group_box.rect.max.y) / 2}
	press_name(&tp, on_group)
	tp.p.input.mouse = to
	test_frame(&tp)
	test_frame(&tp)
	testing.expect_value(t, pv.drag, Drag_State.Dragging)
	test_frame(&tp, key_press(.Escape, {}))
	released := test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	testing.expect(t, !test_has(released, .Timeline_Row_Toggle))
	// Dragged out and let go back on its name: no click on it either.
	press_name(&tp, on_group)
	tp.p.input.mouse = to
	test_frame(&tp)
	test_frame(&tp)
	testing.expect_value(t, pv.drag, Drag_State.Dragging)
	dragged := pv.drag_view
	tp.p.input.mouse = on_group
	test_frame(&tp)
	back := test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	testing.expect(t, !test_has(back, .Timeline_Row_Toggle))
	for _ in 0 ..< 2 do test_frame(&tp)
	if v := workspace_view(ws, dragged); v != nil && v.panel != 0 {
		command_push(&app.commands, .View_Close, {view = dragged})
		for _ in 0 ..< 2 do test_frame(&tp)
	}
	for _ in 0 ..< 3 do test_frame(&tp) // (the timeline back in its panel, its rows settle)
	group_box = test_box(&tp.s, fmt.tprintf("###timeline_row_%x_%d", group.key, int(group.kind)))
	if group_box == nil {testing.expect(t, false, "the group's row gone"); return}
	on_group = {group_box.rect.min.x + 20, (group_box.rect.min.y + group_box.rect.max.y) / 2}
	press_name(&tp, on_group)
	clicked := test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	testing.expect(t, test_has(clicked, .Timeline_Row_Toggle))
}

// In a tab, where it is looked into: the wheel zooms it about the pointer
// (what lies under the pointer stays there), the pixel under the pointer is
// outlined and its colour read from the shared pixels into the tooltip. A row
// taken out of the table (a load, before any pixels go) leaves none to read,
// while its texture still draws until the next table.
@(test)
test_image_view_in_a_tab :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	tp: Test_Preview
	testing.expect(t, test_preview_make(&tp))
	defer test_preview_destroy(&tp)
	mb: Mailbox
	defer mailbox_destroy(&mb)
	app := &tp.app
	pv := &app.preview
	pv.mailbox = &mb
	defer pv.mailbox = nil
	tp.p.frame_dt = 1
	file := u64(77)
	pixels := []u8{255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 0, 128}
	append(&mb.images, Image_Shown{file, (^sdl.GPUTexture)(uintptr(8)), {2, 2}})
	append(&mb.image_pixels, pixels)
	mb.images_seq += 1
	images_take(pv, &mb)

	state: Bitmap_View
	dim := [2]f32{400, 300}
	frame :: proc(tp: ^Test_Preview, state: ^Bitmap_View, file: u64, dim: [2]f32, events: ..platform.Event) {
		p := &tp.p
		clear(&p.input.events)
		for e in events do append(&p.input.events, e)
		preview_input(&tp.app, &tp.s, p)
		ui.build_begin(&tp.s)
		bitmap_view(&tp.app, &tp.s, state, file, "tab", dim, true)
		ui.build_end(&tp.s)
		clear(&p.input.events)
	}
	tp.p.input.mouse = {5000, 5000}
	frame(&tp, &state, file, dim)
	frame(&tp, &state, file, dim)
	zoom := dim.y / 2 * 0.8
	testing.expect(t, abs(state.zoom - zoom) < 0.001)

	// The second row's second pixel: right of and below the middle.
	on_pixel := dim / 2 + [2]f32{zoom * 0.5, zoom * 0.5}
	tp.p.input.mouse = on_pixel
	frame(&tp, &state, file, dim)
	frame(&tp, &state, file, dim)
	testing.expect(t, test_box(&tp.s, "###bmp_pixel_tab") != nil)
	hex := test_box(&tp.s, "###color_tooltip_hex")
	testing.expect(t, hex != nil && hex.str == "Hex: #ffff0080")

	// The wheel zooms about the pointer.
	under := (on_pixel - dim / 2) / state.zoom + state.center
	frame(&tp, &state, file, dim, platform.Event{kind = .Scroll, position = on_pixel, delta = {0, -platform.WHEEL_NOTCH}})
	testing.expect(t, state.zoom != zoom)
	after := (on_pixel - dim / 2) / state.zoom + state.center
	testing.expect(t, abs(after.x - under.x) < 0.001 && abs(after.y - under.y) < 0.001)

	// Its row taken out: nothing to read, and the texture still draws.
	clear(&mb.images)
	clear(&mb.image_pixels)
	frame(&tp, &state, file, dim)
	frame(&tp, &state, file, dim)
	testing.expect(t, test_box(&tp.s, "###color_tooltip_hex") == nil)
	testing.expect(t, test_box(&tp.s, "###bmp_image_tab") != nil)
}

// The worker holds the file an id names and publishes its pixels where they
// lie, not a copy; what is no longer asked for is let go, the table clear of
// it first; a file nobody has answers with an empty row, so it isn't asked
// for again; a load takes every row out, and they are made again from what it
// leaves as the ids still stand. A retired texture waits for the UI to have
// taken a table without it.
@(test)
test_worker_shares_what_the_views_show :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	dir, derr := os.make_directory_temp("", "onimite_media_views_*", context.temp_allocator)
	testing.expectf(t, derr == nil, "temp directory: %v", derr)
	if derr != nil do return
	defer os.remove_all(dir)
	source := [8]u8{1, 2, 3, 255, 5, 6, 7, 255}
	odimg.write_png(fmt.tprintf("%s/logo.png", dir), source[:], 2, 1)
	m: om.Media
	om.media_init(&m)
	defer om.media_destroy(&m)
	testing.expect_value(t, om.media_load_dir(&m, dir), om.Error.None)
	mb: Mailbox
	defer mailbox_destroy(&mb)
	w := Render_Worker {
		mb    = &mb,
		media = &m,
	}
	defer delete(w.images_wanted)
	defer delete(w.image_views)
	defer delete(w.image_retired)
	defer video_tables_destroy(&w.tables)
	findings: Finding_Table
	defer finding_table_destroy(&findings)
	video_tables_build(&w.tables, {fps = 30, findings = &findings, media = &m})
	file := w.tables.media[0].id
	testing.expect(t, !images_pending(&w))

	want :: proc(mb: ^Mailbox, ids: ..u64) {
		table_copy(&mb.images_wanted, ids)
		mb.images_wanted_seq += 1
	}
	img := m.images["logo.png"]
	want(&mb, file)
	testing.expect(t, images_pending(&w))
	worker_images(&w)
	testing.expect(t, !images_pending(&w))
	testing.expect_value(t, img.held, 1)
	testing.expect(t, len(mb.images) == 1 && mb.images[0].id == file && mb.images[0].size == {2, 1})
	testing.expect(t, raw_data(mb.image_pixels[0]) == raw_data(img.pixels), "the store's own bytes, not a copy")
	testing.expect_value(t, mb.images_seq, 1)

	// Asked again, nothing changes.
	want(&mb, file)
	worker_images(&w)
	testing.expect_value(t, img.held, 1)
	testing.expect_value(t, mb.images_seq, 1)

	// A file nobody has: an empty row, not asked for again.
	want(&mb, file, file + 1)
	worker_images(&w)
	testing.expect_value(t, len(mb.images), 2)
	testing.expect(t, mb.images[1].id == file + 1 && mb.images[1].texture == nil && mb.image_pixels[1] == nil)
	testing.expect(t, !images_pending(&w))

	// A load: the table clear before the hold goes, then made again.
	worker_images_retire(&w)
	testing.expect_value(t, len(mb.images), 0)
	testing.expect_value(t, len(mb.image_pixels), 0)
	testing.expect_value(t, img.held, 0)
	testing.expect(t, images_pending(&w))
	worker_images(&w)
	worker_images(&w)
	testing.expect_value(t, len(mb.images), 2)
	testing.expect_value(t, img.held, 1)
	testing.expect(t, raw_data(mb.image_pixels[0]) == raw_data(img.pixels))

	// No longer asked for: out of the table, let go.
	want(&mb)
	worker_images(&w)
	testing.expect_value(t, len(mb.images), 0)
	testing.expect_value(t, img.held, 0)
	testing.expect_value(t, len(w.image_views), 0)

	// A retired texture waits for the UI's ack (the device is nil: SDL's
	// release does nothing, the list is what this reads).
	append(&w.image_retired, (^sdl.GPUTexture)(uintptr(8)))
	images_retired_release(&w)
	testing.expect_value(t, len(w.image_retired), 1)
	mb.images_ack = mb.images_seq
	images_retired_release(&w)
	testing.expect_value(t, len(w.image_retired), 0)
}

// An allocator that overwrites what it frees, so a read of it is seen.
@(private = "file")
poison_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	inner := (^runtime.Allocator)(data)
	if mode == .Free && old_memory != nil && old_size > 0 do mem.set(old_memory, 0xDD, old_size)
	return inner.procedure(inner.data, mode, size, alignment, old_memory, old_size, loc)
}

// The UI reads the shared pixels flat out while loads take them away: the
// media made, its file shown, then let go and destroyed, in a load's order.
// A read finds the row and its pixels, or no row, never freed memory (which
// the media's allocator has overwritten, so it would read the wrong colour).
@(test)
test_reads_survive_loads :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	dir, derr := os.make_directory_temp("", "onimite_media_reads_*", context.temp_allocator)
	testing.expectf(t, derr == nil, "temp directory: %v", derr)
	if derr != nil do return
	defer os.remove_all(dir)
	source := [8]u8{1, 2, 3, 255, 5, 6, 7, 255}
	odimg.write_png(fmt.tprintf("%s/logo.png", dir), source[:], 2, 1)
	mb: Mailbox
	defer mailbox_destroy(&mb)
	w := Render_Worker {
		mb = &mb,
	}
	defer delete(w.images_wanted)
	defer delete(w.image_views)
	defer video_tables_destroy(&w.tables)
	findings: Finding_Table
	defer finding_table_destroy(&findings)

	Reader :: struct {
		mb:   ^Mailbox,
		file: u64,
		done: bool,
		hits: int,
		bad:  int,
	}
	r := Reader {
		mb = &mb,
	}
	first := true
	reader: ^thread.Thread
	inner := context.allocator
	poison := runtime.Allocator{poison_proc, &inner}
	for _ in 0 ..< 200 {
		m := new(om.Media)
		{
			context.allocator = poison
			om.media_init(m)
		}
		testing.expect_value(t, om.media_load_dir(m, dir), om.Error.None)
		w.media = m
		video_tables_build(&w.tables, {fps = 30, findings = &findings, media = m})
		file := w.tables.media[0].id
		if first {
			first = false
			r.file = file
			reader = thread.create_and_start_with_poly_data(&r, proc(r: ^Reader) {
				for !sync.atomic_load(&r.done) {
					if c, ok := image_pixel(r.mb, r.file, 1, 0); ok {
						if c != {5, 6, 7, 255} do sync.atomic_add(&r.bad, 1)
						sync.atomic_add(&r.hits, 1)
					}
				}
			})
		}
		table_copy(&mb.images_wanted, []u64{file})
		mb.images_wanted_seq += 1
		worker_images(&w)
		// the reader has this media's row at least once
		at := sync.atomic_load(&r.hits)
		for sync.atomic_load(&r.hits) == at do thread.yield()
		worker_images_retire(&w)
		{
			context.allocator = poison
			om.media_destroy(m)
		}
		free(m)
	}
	sync.atomic_store(&r.done, true)
	thread.join(reader)
	thread.destroy(reader)
	testing.expect(t, r.hits >= 200)
	testing.expect_value(t, r.bad, 0)
}
