package onimite_app

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import om "../onimite"
import platform "../platform"
import script "../script"
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
// items find it, and a failed file still unfolds into members.
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

	// A failed file has no view: its members. A sound has its own.
	r := preview_reader(app)
	bad := media_row(app, v, 0)
	_, bad_view := visualizer_of(&r, bad.value)
	testing.expect(t, !bad_view && bad.unfolds)
	lens, sound_view := visualizer_of(&r, media_row(app, v, 10).value)
	testing.expect(t, sound_view && lens == .Audio)
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
	testing.expect_value(t, len(pv.files_open), 0)
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
	testing.expect(t, len(pv.files_open) == 1 && pv.files_open[0] == file)
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
	testing.expect_value(t, rv.camera, picture_home(.Image))
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
	testing.expect(t, abs(rv.camera.center.x - f64(20 / (canvas.rect.max.x - canvas.rect.min.x)) / 0.8) < 0.001)
	testing.expect_value(t, rv.shown, rv.camera) // 1:1 with the pointer
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	test_frame(&tp, {kind = .Mouse_Press, button = .Left})
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	test_frame(&tp, {kind = .Mouse_Press, button = .Left})
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	testing.expect_value(t, rv.camera, picture_home(.Image))
	looking := Picture_Camera{{0.1, 0.2}, 0.8}
	rv.camera, rv.shown = looking, looking

	// The wheel over it is the list's: the rows move, the image doesn't zoom.
	scrolled := test_frame(&tp, {kind = .Scroll, position = tp.p.input.mouse, delta = {0, -platform.WHEEL_NOTCH}})
	testing.expect(t, test_has(scrolled, .View_Scroll))
	testing.expect_value(t, rv.camera, looking)
	// With Control it is the picture's, as over any picture.
	closer := test_frame(&tp, {kind = .Scroll, modifiers = {.Control}, position = tp.p.input.mouse, delta = {0, -platform.WHEEL_NOTCH}})
	testing.expect(t, test_has(closer, .Picture_Zoom) && !test_has(closer, .View_Scroll))
	testing.expect(t, abs(rv.camera.zoom - 0.8 * 1.25) < 1e-9)
	rv.camera, rv.shown = looking, looking

	// Scrolled off the window and back: still open, looking where it did, its
	// file asked for all the while.
	command_push(&app.commands, .View_Scroll, {view = id, count = 11, flag = true})
	for _ in 0 ..< 3 do test_frame(&tp)
	testing.expect(t, test_box(&tp.s, canvas_key) == nil, "scrolled off")
	testing.expect(t, row_view(pv, id, logo) != nil)
	testing.expect(t, len(pv.files_open) == 1 && pv.files_open[0] == file)
	command_push(&app.commands, .View_Scroll, {view = id, count = 0, flag = true})
	for _ in 0 ..< 3 do test_frame(&tp)
	testing.expect(t, test_box(&tp.s, canvas_key) != nil, "back")
	rv = row_view(pv, id, logo)
	testing.expect_value(t, rv.camera, looking)

	// A filter that hides it closes nothing.
	append(&v.filter, "music")
	for _ in 0 ..< 2 do test_frame(&tp)
	testing.expect(t, test_box(&tp.s, canvas_key) == nil, "filtered out")
	testing.expect(t, row_view(pv, id, logo) != nil && len(pv.files_open) == 1)
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
	testing.expect_value(t, len(pv.files_open), 0)
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
	testing.expect(t, len(pv.files_open) == 1 && pv.files_open[0] == file)

	// An expression Watch on the same file, open: the one row, and two views
	// that each look their own way.
	other := workspace_open(ws, workspace_view(ws, id).panel, .Watch)
	command_push(&app.commands, .Watch_Input_Add, {view = other, count = 0, spec = "media[\"logo.png\"]"})
	test_frame(&tp)
	top := media_row(app, workspace_view(ws, other), 0)
	command_push(&app.commands, .Watch_Expand, {view = other, spec = top.key})
	for _ in 0 ..< 3 do test_frame(&tp)
	testing.expect(t, len(pv.files_open) == 1 && pv.files_open[0] == file)
	testing.expect(t, row_view(pv, other, top) != nil && row_view(pv, id, logo) != nil)
	testing.expect(t, row_view(pv, other, top) != row_view(pv, id, logo))

	// Its expression edited to the same file: the row keeps its view, which
	// follows what the row now says.
	row_view(pv, other, top).camera.center = {7, 8}
	command_push(&app.commands, .Watch_Input_Set, {view = other, count = 0, spec = "media[1]"})
	for _ in 0 ..< 3 do test_frame(&tp)
	testing.expect_value(t, row_view(pv, other, top).inputs[0].source, "media[1]")
	testing.expect_value(t, row_view(pv, other, top).camera.center, [2]f64{7, 8})

	// (the first Watch's tab is hidden now: its row's view still stands)
	command_push(&app.commands, .Watch_Input_Remove, {view = other, count = 0})
	for _ in 0 ..< 2 do test_frame(&tp)
	testing.expect(t, row_view(pv, other, top) == nil)
	testing.expect_value(t, len(workspace_view(ws, other).expanded), 0)
	testing.expect(t, len(pv.files_open) == 1 && pv.files_open[0] == file)

	// Its Watch goes, and the file with it.
	command_push(&app.commands, .View_Close, {view = id})
	for _ in 0 ..< 2 do test_frame(&tp)
	testing.expect(t, workspace_row_view(ws, id, row_view_key(logo.key)) == 0)
	testing.expect_value(t, len(pv.files_open), 0)
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
	workspace_view(ws, pulled).camera.center = {0.25, 0.5}
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
	testing.expect_value(t, tab.camera.center, [2]f64{0.25, 0.5})
	title, _ := view_title(app, pulled)
	testing.expect_value(t, title, "logo.png")

	// The row is still open, with a view of its own, looking from the start.
	for _ in 0 ..< 3 do test_frame(&tp)
	fresh := workspace_row_view(ws, id, row_view_key(logo.key))
	testing.expect(t, fresh != 0 && fresh != pulled)
	testing.expect_value(t, workspace_view(ws, fresh).camera.center, [2]f64{0, 0})
	testing.expect(t, len(pv.files_open) == 1 && pv.files_open[0] == file)

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
	zoom := workspace_view(ws, pulled).camera.zoom
	test_frame(&tp, {kind = .Scroll, position = tp.p.input.mouse, delta = {0, -platform.WHEEL_NOTCH}})
	testing.expect(t, workspace_view(ws, pulled).camera.zoom != zoom)

	// The tab outlives the row and its Watch, and the file stays with it.
	command_push(&app.commands, .View_Close, {view = id})
	for _ in 0 ..< 2 do test_frame(&tp)
	testing.expect(t, workspace_view(ws, pulled) != nil)
	testing.expect(t, len(pv.files_open) == 1 && pv.files_open[0] == file)

	// Closed, nothing asks for it.
	command_push(&app.commands, .View_Close, {view = pulled})
	for _ in 0 ..< 2 do test_frame(&tp)
	testing.expect_value(t, len(pv.files_open), 0)
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
	testing.expect_value(t, len(pv.files_open), 1) // while it is dragged
	test_frame(&tp, key_press(.Escape, {}))
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	test_frame(&tp)
	testing.expect(t, workspace_view(ws, pulled) == nil)
	testing.expect_value(t, len(pv.files_open), 0)
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
	testing.expect_value(t, len(pv.files_open), 1)

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

	ws := &pv.workspace
	append(&ws.views, View_Record{live = true, kind = .Image, camera = picture_home(.Image), shown = picture_home(.Image)})
	id := View_Id(len(ws.views))
	dim := [2]f32{400, 300}
	frame :: proc(tp: ^Test_Preview, id: View_Id, file: u64, dim: [2]f32, events: ..platform.Event) {
		p := &tp.p
		clear(&p.input.events)
		for e in events do append(&p.input.events, e)
		preview_input(&tp.app, &tp.s, p)
		ui.build_begin(&tp.s)
		bitmap_view(&tp.app, &tp.s, id, file, "tab", dim, true)
		ui.build_end(&tp.s)
		dispatch(&tp.app)
		clear(&p.input.events)
	}
	tp.p.input.mouse = {5000, 5000}
	frame(&tp, id, file, dim)
	frame(&tp, id, file, dim)
	zoom := dim.y / 2 * 0.8
	image := test_box(&tp.s, "###bmp_image_tab")
	testing.expect(t, image != nil && abs(image.rect.max.y - image.rect.min.y - 2 * zoom) < 0.001)

	// The second row's second pixel: right of and below the middle (a tenth of a
	// texel in: by the fit alone it would still be the first).
	on_pixel := dim / 2 + [2]f32{zoom * 0.1, zoom * 0.1}
	tp.p.input.mouse = on_pixel
	frame(&tp, id, file, dim)
	frame(&tp, id, file, dim)
	testing.expect(t, test_box(&tp.s, "###bmp_pixel_tab") != nil)
	hex := test_box(&tp.s, "###color_tooltip_hex")
	testing.expect(t, hex != nil && hex.str == "Hex: #ffff0080")

	// The wheel zooms about the pointer.
	v := workspace_view(ws, id)
	at := [2]f64{f64(on_pixel.x / dim.x) - 0.5, f64(on_pixel.y / dim.y) - 0.5}
	under := at / v.camera.zoom + v.camera.center
	frame(&tp, id, file, dim, platform.Event{kind = .Scroll, position = on_pixel, delta = {0, -platform.WHEEL_NOTCH}})
	testing.expect(t, abs(v.camera.zoom - 0.8 * 1.25) < 1e-9)
	after := at / v.camera.zoom + v.camera.center
	testing.expect(t, abs(after.x - under.x) < 0.001 && abs(after.y - under.y) < 0.001)

	// A tab's drag and double press are its own camera's, wherever the focus is,
	// and it lies on whole pixels, as its border does.
	v.camera, v.shown = {{0.0123, 0.0456}, 1.17}, {{0.0123, 0.0456}, 1.17}
	video := workspace_view(ws, workspace_find(ws, .Video))
	video.camera = {{0.25, 0.25}, 2}
	tp.s.press_keys[.Left] = {}
	frame(&tp, id, file, dim)
	whole := (^Picture)(test_box(&tp.s, "###bmp_image_tab").custom_data)
	testing.expect(t, whole.lo.x == math.floor(whole.lo.x) && whole.lo.y == math.floor(whole.lo.y) && whole.hi.x == math.floor(whole.hi.x) && whole.hi.y == math.floor(whole.hi.y))
	before := v.camera.center
	frame(&tp, id, file, dim, platform.Event{kind = .Mouse_Press, button = .Left, position = on_pixel})
	tp.p.input.mouse += {40, 0}
	frame(&tp, id, file, dim)
	testing.expect(t, abs(v.camera.center.x - (before.x - f64(40 / dim.x) / 1.17)) < 1e-4)
	testing.expect_value(t, video.camera, Picture_Camera{{0.25, 0.25}, 2})
	frame(&tp, id, file, dim, platform.Event{kind = .Mouse_Release, button = .Left, position = tp.p.input.mouse})
	tp.p.input.mouse = on_pixel
	tp.s.press_keys[.Left] = {}
	frame(&tp, id, file, dim)
	for _ in 0 ..< 2 {
		frame(&tp, id, file, dim, platform.Event{kind = .Mouse_Press, button = .Left, position = on_pixel})
		frame(&tp, id, file, dim, platform.Event{kind = .Mouse_Release, button = .Left, position = on_pixel})
	}
	testing.expect_value(t, v.camera, picture_home(.Image))
	testing.expect_value(t, video.camera, Picture_Camera{{0.25, 0.25}, 2})
	v.camera, v.shown = picture_home(.Image), picture_home(.Image)

	// Its row taken out: nothing to read, and the texture still draws.
	clear(&mb.images)
	clear(&mb.image_pixels)
	frame(&tp, id, file, dim)
	frame(&tp, id, file, dim)
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
	defer delete(w.files_wanted)
	defer delete(w.image_views)
	defer delete(w.image_retired)
	defer video_tables_destroy(&w.tables)
	findings: Finding_Table
	defer finding_table_destroy(&findings)
	video_tables_build(&w.tables, {fps = 30, findings = &findings, media = &m})
	file := w.tables.media[0].id
	testing.expect(t, !files_pending(&w))

	want :: proc(mb: ^Mailbox, ids: ..u64) {
		table_copy(&mb.files_wanted, ids)
		mb.files_wanted_seq += 1
	}
	img := m.images["logo.png"]
	want(&mb, file)
	testing.expect(t, files_pending(&w))
	worker_files(&w)
	testing.expect(t, !files_pending(&w))
	testing.expect_value(t, img.held, 1)
	testing.expect(t, len(mb.images) == 1 && mb.images[0].id == file && mb.images[0].size == {2, 1})
	testing.expect(t, raw_data(mb.image_pixels[0]) == raw_data(img.pixels), "the store's own bytes, not a copy")
	testing.expect_value(t, mb.images_seq, 1)

	// Asked again, nothing changes.
	want(&mb, file)
	worker_files(&w)
	testing.expect_value(t, img.held, 1)
	testing.expect_value(t, mb.images_seq, 1)

	// A file nobody has: an empty row, not asked for again.
	want(&mb, file, file + 1)
	worker_files(&w)
	testing.expect_value(t, len(mb.images), 2)
	testing.expect(t, mb.images[1].id == file + 1 && mb.images[1].texture == nil && mb.image_pixels[1] == nil)
	testing.expect(t, !files_pending(&w))

	// A load: the table clear before the hold goes, then made again.
	worker_images_retire(&w)
	testing.expect_value(t, len(mb.images), 0)
	testing.expect_value(t, len(mb.image_pixels), 0)
	testing.expect_value(t, img.held, 0)
	testing.expect(t, files_pending(&w))
	worker_files(&w)
	worker_files(&w)
	testing.expect_value(t, len(mb.images), 2)
	testing.expect_value(t, img.held, 1)
	testing.expect(t, raw_data(mb.image_pixels[0]) == raw_data(img.pixels))

	// No longer asked for: out of the table, let go.
	want(&mb)
	worker_files(&w)
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
	defer delete(w.files_wanted)
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
		table_copy(&mb.files_wanted, []u64{file})
		mb.files_wanted_seq += 1
		worker_files(&w)
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

// Sound file `file`'s pyramid in the UI's waveforms, as the worker publishes it:
// a ramp, louder as it goes. Its samples, the caller's to free.
@(private = "file")
sound_has_pyramid :: proc(pv: ^Preview_State, b: ^Wave_Builder, file: u64, frames: int) -> []f32 {
	samples := make([]f32, frames * 2)
	for i in 0 ..< frames do samples[i * 2], samples[i * 2 + 1] = f32(i) / f32(frames), -f32(i) / f32(frames)
	video: om.Video
	files := []Wave_File{{file, om.Audio_Clip{samples = samples, frames = frames}}}
	wave_builder_lanes(b, nil, nil, &video, 0, nil, files)
	for wave_builder_pending(b) do wave_builder_step(b)
	wave_table_copy(&pv.waves, &b.table)
	return samples
}

// Whether the audio thread has been told to play.
@(private = "file")
audio_plays :: proc(a: ^Audio_Shared) -> bool {
	return .Playing in transmute(bit_set[Audio_State;u32])a.state
}

// A sound's row unfolds into four rows, a view of its own asking for the file by
// id, drawn from a pyramid; a press on its waveform plays the file from there,
// alone, the video pausing. Nothing plays until the worker has swapped the sound
// in, then it plays from where it was asked, never looping; the button pauses and
// plays on, a drag follows the pointer, Accept on its cursor does as the button
// does, and the video's own seeks leave the file alone. The file ending, the
// video's sound comes back: not playing, where the picture is. Every transport
// of the video takes over the same way, and so does shutting the row, but not a
// load landing. A tab of it does the same. With no audio device it does nothing.
@(test)
test_sound_view_plays_alone :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	tp: Test_Preview
	testing.expect(t, test_preview_make(&tp))
	defer test_preview_destroy(&tp)
	a: Audio_Shared
	app := &tp.app
	pv := &app.preview
	pv.audio = &a
	pv.audio_stream = (^sdl.AudioStream)(uintptr(8)) // (a name: nothing opens it in a test)
	defer {pv.audio, pv.audio_stream = nil, nil}
	tp.p.frame_dt = 1
	ws := &pv.workspace
	watch_show(app, "video:media")
	id := workspace_find_watch(ws, "video:media")
	for _ in 0 ..< 3 do test_frame(&tp)
	music := media_row(app, workspace_view(ws, id), 2)
	testing.expect_value(t, music.label, "music.wav")
	if !open_row(t, &tp, id, music) do return
	test_frame(&tp)
	file := pv.tables.media[music.value.ref.row].id
	rv := row_view(pv, id, music)
	testing.expect(t, rv != nil && rv.kind == .Audio)
	testing.expect(t, len(pv.files_open) == 1 && pv.files_open[0] == file)
	blocks := watch_blocks(app, workspace_view(ws, id))
	testing.expect_value(t, blocks.total, 4 + 4)

	key := fmt.tprintf("watch_%d_%s", id, visualizer_key(music.key))
	wave := test_box(&tp.s, fmt.tprintf("###audio_wave_%s", key))
	testing.expect(t, wave != nil)
	if wave == nil do return
	testing.expect_value(t, wave.rect.max.y - wave.rect.min.y, 4 * list_row_height(&tp.s))

	// With no pyramid yet a press on the waveform has nowhere to go.
	press_at :: proc(tp: ^Test_Preview, at: [2]f32) -> []Command_Row {
		tp.p.input.mouse = at
		test_frame(tp)
		test_frame(tp)
		rows := test_frame(tp, {kind = .Mouse_Press, button = .Left})
		return rows
	}
	x_of :: proc(wave: ^ui.Box, along: f32) -> [2]f32 {
		return {wave.rect.min.x + along * (wave.rect.max.x - wave.rect.min.x), wave.rect.max.y - 4}
	}
	testing.expect(t, !test_has(press_at(&tp, x_of(wave, 0.75)), .Solo_Set))
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})

	b: Wave_Builder
	defer wave_builder_destroy(&b)
	samples := sound_has_pyramid(pv, &b, file, 96000)
	defer delete(samples)

	// With no device to hear it on, nothing happens.
	stream := pv.audio_stream
	pv.audio_stream = nil
	solo_set(app, file, 100, true)
	testing.expect_value(t, pv.solo.file, u64(0))
	pv.audio_stream = stream

	// A press plays from there, alone; the video pauses; nothing is heard until
	// the worker says the swap is done.
	pv.playing = true
	pv.loop = true
	rows := press_at(&tp, x_of(wave, 0.75))
	sent: Command_Row
	for r in rows do if r.kind == .Solo_Set do sent = r
	testing.expect_value(t, sent.kind, Command_Kind.Solo_Set)
	testing.expect_value(t, sent.regs.row, file)
	testing.expect(t, abs(sent.regs.count - 72000) < 200)
	testing.expect_value(t, pv.solo.file, file)
	testing.expect(t, pv.solo.playing && !pv.playing && !solo_settled(pv))
	testing.expect(t, !audio_plays(&a))
	gen := a.seek_gen
	solo_take(app, pv.solo.file)
	testing.expect(t, solo_settled(pv) && audio_plays(&a))
	testing.expect_value(t, a.seek_gen, gen + 1)
	testing.expect_value(t, a.seek_to, i64(sent.regs.count))
	// (the same answer every frame after: it seeks once)
	solo_take(app, pv.solo.file)
	testing.expect_value(t, a.seek_gen, gen + 1)
	testing.expect(t, .Looping not_in transmute(bit_set[Audio_State;u32])a.state)

	// A drag follows the pointer; held still, it asks nothing.
	tp.p.input.mouse = x_of(wave, 0.5)
	dragged := test_frame(&tp)
	testing.expect(t, test_has(dragged, .Solo_Set))
	testing.expect(t, abs(a.seek_to - 48000) < 200)
	testing.expect(t, !test_has(test_frame(&tp), .Solo_Set))
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})

	// The playhead is what the audio thread hears (the seek taken).
	a.applied_gen = a.seek_gen
	a.heard, a.advancing = 50000, true
	solo_update(app)
	testing.expect_value(t, pv.solo.at, i64(50000))
	test_frame(&tp)

	// The button shows what it does, pauses it where it is, and plays it on from
	// there.
	button := box_under(&tp.s, wave, fmt.tprintf("###audio_play_%s", key))
	testing.expect(t, button != nil)
	if button == nil do return
	icons := PREVIEW_ICONS
	testing.expect_value(t, button.icon, icons[.Pause])
	on_button := (button.rect.min + button.rect.max) / 2
	testing.expect(t, !test_has(press_at(&tp, on_button), .Solo_Set), "a click, not a press")
	paused := test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	testing.expect(t, test_has(paused, .Solo_Set))
	testing.expect(t, !pv.solo.playing && pv.solo.file == file && !audio_plays(&a))
	testing.expect_value(t, pv.solo.at, i64(50000))
	test_frame(&tp)
	testing.expect_value(t, box_under(&tp.s, wave, fmt.tprintf("###audio_play_%s", key)).icon, icons[.Play])
	gen = a.seek_gen
	press_at(&tp, on_button)
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	testing.expect(t, pv.solo.playing && audio_plays(&a))
	testing.expect_value(t, a.seek_to, i64(50000))
	testing.expect_value(t, a.seek_gen, gen + 1)

	// Accept on its cursor is the button.
	tp.p.input.mouse = {-1, -1}
	for _ in 0 ..< 2 do test_frame(&tp)
	view_list(pv, id).cursor = blocks_item_from_row(&blocks, 3)
	test_frame(&tp)
	test_frame(&tp, key_press(.Space, {}))
	testing.expect(t, !pv.solo.playing && pv.solo.file == file)
	test_frame(&tp, key_press(.Space, {}))
	testing.expect(t, pv.solo.playing)

	// Another file's button: that one, from its start, once the worker has it.
	unused := media_row(app, workspace_view(ws, id), 2 + 1 + 4)
	testing.expect_value(t, unused.label, "unused.wav")
	if !open_row(t, &tp, id, unused) do return
	for _ in 0 ..< 2 do test_frame(&tp)
	other := pv.tables.media[unused.value.ref.row].id
	testing.expect(t, other != file && len(pv.files_open) == 2)
	solo_toggle(app, other)
	test_frame(&tp)
	testing.expect(t, pv.solo.file == other && pv.solo.playing && pv.solo.at == 0)
	testing.expect(t, !solo_settled(pv) && !audio_plays(&a))
	solo_take(app, pv.solo.file)
	testing.expect(t, audio_plays(&a))
	testing.expect_value(t, a.seek_to, i64(0))
	// (the playhead is on the file heard, not on this one)
	test_frame(&tp)
	testing.expect_value(t, (^Audio_Wave)(wave.custom_data).at, i64(-1))
	// (it draws by the id its lane goes by, so in that lane's colour)
	testing.expect_value(t, (^Audio_Wave)(wave.custom_data).file, media_file_id(.Audio, "music.wav"))
	command_push(&app.commands, .Solo_Set, {row = file, count = 50000, flag = true})
	test_frame(&tp)
	solo_take(app, pv.solo.file)
	command_push(&app.commands, .Watch_Expand, {view = id, spec = unused.key})
	for _ in 0 ..< 3 do test_frame(&tp)
	testing.expect_value(t, pv.solo.file, file)
	testing.expect_value(t, (^Audio_Wave)(wave.custom_data).at, i64(50000))

	// A seek of the video's own (a song's samples landing) leaves it alone.
	gen = a.seek_gen
	preview_seek(app, 7)
	testing.expect_value(t, a.seek_gen, gen)

	// The file ends: the video's sound comes back, not playing, where it was.
	a.applied_gen = a.seek_gen
	a.advancing = false
	pv.frame = 7
	solo_update(app)
	testing.expect_value(t, pv.solo.file, u64(0))
	testing.expect(t, !solo_settled(pv) && !pv.playing && !audio_plays(&a))
	gen = a.seek_gen
	solo_take(app, pv.solo.file)
	testing.expect_value(t, a.seek_gen, gen + 1)
	testing.expect_value(t, a.seek_to, i64(7 * om.MIX_RATE / preview_fps(app)))
	testing.expect(t, !audio_plays(&a))
	testing.expect(t, .Looping in transmute(bit_set[Audio_State;u32])a.state)

	// Whatever moves the video: the file gives way, its sound back at the ack.
	for kind in ([]Command_Kind{.Playback_Set, .Frame_Set, .Frame_Step, .Frame_Start, .Seconds_Step, .Scene_Step, .Problem_Step, .Present_Next, .Present_Previous, .Go_To}) {
		solo_set(app, file, 100, true)
		solo_take(app, pv.solo.file)
		testing.expectf(t, audio_plays(&a), "%v: the file plays", kind)
		preview_apply(app, kind, {count = pv.frame + 1})
		testing.expectf(t, pv.solo.file == 0 && !solo_settled(pv), "%v: the file gives way", kind)
		solo_take(app, pv.solo.file)
		preview_apply(app, .Playback_Set, {flag = false})
	}

	// A load landing keeps the frame it is on: the file plays on.
	solo_set(app, file, 100, true)
	solo_take(app, pv.solo.file)
	command_push(&app.commands, .Frame_Set, {count = pv.frame})
	test_frame(&tp)
	testing.expect(t, pv.solo.file == file && solo_settled(pv) && audio_plays(&a))

	// Shut, its row takes the file with it (it would have nothing to stop it).
	command_push(&app.commands, .Watch_Expand, {view = id, spec = music.key})
	test_frame(&tp)
	shut := test_frame(&tp)
	testing.expect(t, test_has(shut, .Solo_Set))
	testing.expect_value(t, pv.solo.file, u64(0))
	solo_take(app, pv.solo.file)
	for _ in 0 ..< 3 do test_frame(&tp)
	if !open_row(t, &tp, id, music) do return
	for _ in 0 ..< 3 do test_frame(&tp)

	// Played by the video's own transport: the file gives way, the video plays
	// only once its sound is back, and its clock waits for that.
	solo_set(app, file, 100, true)
	solo_take(app, pv.solo.file)
	testing.expect(t, audio_plays(&a))
	command_push(&app.commands, .Playback_Toggle)
	test_frame(&tp)
	testing.expect_value(t, pv.solo.file, u64(0))
	testing.expect(t, pv.playing && !solo_settled(pv) && !audio_plays(&a))
	clock := pv.clock
	preview_playback_advance(app, 0.1)
	testing.expect_value(t, pv.clock, clock)
	solo_take(app, pv.solo.file)
	testing.expect(t, audio_plays(&a))
	command_push(&app.commands, .Playback_Set, {flag = false})
	test_frame(&tp)

	// Dragged out, a tab of it shows the same waveform and plays it.
	row_box := test_box(&tp.s, fmt.tprintf("###watch_row_%d_%s", id, music.key))
	testing.expect(t, row_box != nil)
	if row_box == nil do return
	video := workspace_view(ws, workspace_find(ws, .Video)).panel
	area := ws.areas[video - 1].content
	press_at(&tp, (row_box.rect.min + row_box.rect.max) / 2)
	tp.p.input.mouse = {area.x + area.width / 2, area.y + area.height / 2}
	for _ in 0 ..< 3 do test_frame(&tp)
	pulled := pv.drag_view
	testing.expect(t, pulled != 0)
	if pulled == 0 do return
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	for _ in 0 ..< 3 do test_frame(&tp)
	testing.expect_value(t, workspace_view(ws, pulled).kind, View_Kind.Audio)
	testing.expect_value(t, workspace_view(ws, pulled).panel, video)
	title, _ := view_title(app, pulled)
	testing.expect_value(t, title, "music.wav")
	testing.expect(t, len(pv.files_open) == 1 && pv.files_open[0] == file)
	tab_wave := test_box(&tp.s, fmt.tprintf("###audio_wave_tab_%d", pulled))
	testing.expect(t, tab_wave != nil)
	if tab_wave == nil do return
	played := press_at(&tp, x_of(tab_wave, 0.25))
	testing.expect(t, test_has(played, .Solo_Set))
	test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	testing.expect(t, pv.solo.file == file && pv.solo.playing)
	// Space with the tab's panel focused plays and pauses it, not the video.
	solo_take(app, pv.solo.file)
	tp.p.input.mouse = {-1, -1}
	for _ in 0 ..< 2 do test_frame(&tp)
	testing.expect_value(t, ws.focused, video)
	test_frame(&tp, key_press(.Space, {}))
	testing.expect(t, !pv.solo.playing && pv.solo.file == file)
}

// A file's peaks are the clip's one pyramid, placed or not: the view of a placed
// sound and the timeline's regions of it read the same one, an unplaced sound
// gets its own, and the peaks are right. Asked for no more, a file's row goes;
// its pyramid stays with the media's. Laid out again, nothing is made twice.
// Where a picture lies: fitted in its box, letterboxed either way, then moved and
// scaled by its camera.
// The worker's GPU memory goes back on the UI's thread: a release during its
// present writes to freed memory.
@(test)
test_worker_lets_go_through_the_table :: proc(t: ^testing.T) {
	mb: Mailbox
	defer mailbox_destroy(&mb)
	w := Render_Worker {
		mb = &mb,
	}
	defer delete(w.image_retired)
	// (Never a real texture: it mustn't reach SDL here, and a release would.)
	texture := (^sdl.GPUTexture)(uintptr(0x1000))
	append(&w.image_retired, texture)
	images_retired_release(&w)
	testing.expect_value(t, len(w.image_retired), 0)
	testing.expect_value(t, len(mb.retired.textures), 1)
	clear(&mb.retired.textures)
}

@(test)
test_picture_rect :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, size, dim: [2]f32, cam: Picture_Camera, lo, hi: [2]f32, loc := #caller_location) {
		a, b := picture_rect(size, dim, cam)
		testing.expectf(t, a == lo && b == hi, "%v %v %v: %v..%v", size, dim, cam, a, b, loc = loc)
	}
	fit := Picture_Camera{zoom = 1}
	check(t, {200, 100}, {800, 200}, fit, {200, 0}, {600, 200})
	check(t, {200, 100}, {200, 800}, fit, {0, 350}, {200, 450})
	// Twice as big, about the box's middle.
	check(t, {200, 100}, {800, 200}, {zoom = 2}, {0, -100}, {800, 300})
	// The point a quarter of the box right of its centre at the middle.
	check(t, {200, 100}, {800, 200}, {{0.25, 0}, 1}, {0, 0}, {400, 200})
	// (zoomed, the same point: the picture has moved twice as far)
	check(t, {200, 100}, {800, 200}, {{0.25, 0}, 2}, {-400, -100}, {400, 300})
	// With no camera, contained.
	a, b := picture_rect({200, 100}, {800, 200})
	testing.expect(t, a == [2]f32{200, 0} && b == [2]f32{600, 200})
}

// Every picture view takes the same gestures on its own camera, as commands with
// its id: the video, and an image in a tab. A left drag starts past a few pixels,
// so a click stays the video's; a double press fits; Z fits the focused picture,
// or else the video. The video's camera places its frame.
@(test)
test_pictures_share_their_camera :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	tp: Test_Preview
	testing.expect(t, test_preview_make(&tp))
	defer test_preview_destroy(&tp)
	app := &tp.app
	pv := &app.preview
	ws := &pv.workspace
	tp.p.frame_dt = 1
	pv.video_texture, pv.video_size = (^sdl.GPUTexture)(uintptr(8)), {1280, 720}
	defer pv.video_texture = nil
	for _ in 0 ..< 3 do test_frame(&tp)
	id := workspace_find(ws, .Video)
	v := workspace_view(ws, id)
	box := test_box(&tp.s, "###video")
	picture := test_box(&tp.s, "###video_picture")
	if !testing.expect(t, box != nil && picture != nil) do return
	testing.expect_value(t, v.camera, picture_home(.Video))
	dim := box.rect.max - box.rect.min
	placed :: proc(t: ^testing.T, tp: ^Test_Preview, v: ^View_Record, dim: [2]f32, loc := #caller_location) {
		// (to the fraction of a pixel: it eases smoothly)
		d := (^Picture)(test_box(&tp.s, "###video_picture").custom_data)
		lo, hi := picture_rect({1280, 720}, dim, v.shown)
		testing.expectf(t, d.lo == lo && d.hi == hi, "%v..%v, want %v..%v", d.lo, d.hi, lo, hi, loc = loc)
	}
	placed(t, &tp, v, dim)

	// The wheel, and the frame follows the shown camera.
	middle := box.rect.min + dim / 2
	tp.p.input.mouse = middle
	test_frame(&tp)
	rows := test_frame(&tp, {kind = .Scroll, position = middle, delta = {0, -platform.WHEEL_NOTCH}})
	testing.expect(t, test_has(rows, .Picture_Zoom))
	testing.expect(t, abs(v.camera.zoom - 1.25) < 1e-9)
	for _ in 0 ..< 60 do preview_motion_advance(app, 1)
	testing.expect(t, abs(video_zoom(pv) - 1.25) < 1e-6)
	test_frame(&tp)
	test_frame(&tp)
	placed(t, &tp, v, dim)

	// A press without a drag is the video's click; two pixels is still a click.
	test_frame(&tp)
	test_frame(&tp, {kind = .Mouse_Press, button = .Left})
	tp.p.input.mouse += {2, 0}
	rows = test_frame(&tp)
	testing.expect(t, !test_has(rows, .Picture_Pan))
	rows = test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	testing.expect(t, test_has(rows, .Playback_Toggle))

	// Past a few pixels it pans 1:1, and is no click. (This press is not a double.)
	tp.p.input.mouse = middle
	before := v.camera.center
	tp.s.press_keys[.Left] = {}
	test_frame(&tp)
	test_frame(&tp, {kind = .Mouse_Press, button = .Left})
	tp.p.input.mouse += {40, 0}
	rows = test_frame(&tp)
	testing.expect(t, test_has(rows, .Picture_Pan))
	testing.expect(t, abs(v.camera.center.x - (before.x - f64(40 / dim.x) / 1.25)) < 1e-4)
	testing.expect_value(t, v.shown, v.camera)
	rows = test_frame(&tp, {kind = .Mouse_Release, button = .Left})
	testing.expect(t, !test_has(rows, .Playback_Toggle))

	// The other buttons pan at once, past no threshold.
	v.camera, v.shown = picture_home(.Video), picture_home(.Video)
	test_frame(&tp)
	test_frame(&tp, {kind = .Mouse_Press, button = .Middle})
	tp.p.input.mouse += {2, 0}
	rows = test_frame(&tp)
	testing.expect(t, test_has(rows, .Picture_Pan))
	test_frame(&tp, {kind = .Mouse_Release, button = .Middle})
	v.camera, v.shown = {{}, 1.25}, {{}, 1.25}

	// A live board takes none of it.
	pv.live = true
	tp.p.input.mouse = middle
	rows = test_frame(&tp, {kind = .Scroll, position = middle, delta = {0, -platform.WHEEL_NOTCH}})
	testing.expect(t, !test_has(rows, .Picture_Zoom))
	pv.live = false

	// Nothing is asked of the worker's renderer before the film's size is known,
	// so a first frame isn't drawn at a guess and then all over again.
	pv.timeline.width, pv.timeline.height = 0, 0
	pv.asked_scale = 0
	testing.expect_value(t, preview_asked_scale(app, pv), f32(0))
	{
		mb: Mailbox
		defer mailbox_destroy(&mb)
		sc: script.Script
		w := Render_Worker {
			mb     = &mb,
			script = &sc,
		}
		testing.expect(t, worker_renderer(&w, 0) == nil)
		// (Nothing was opened to find that out.)
		testing.expect(t, !w.renderer_ok && !w.gpu_ok && !w.software)
	}
	pv.timeline.width, pv.timeline.height = 1280, 720
	testing.expect(t, preview_asked_scale(app, pv) > 0)

	// What the worker renders at follows the zoom, up to twice the video's size.
	v.shown.zoom = 1
	testing.expect_value(t, video_scale(pv, {width = 640, height = 360}), f32(0.5))
	v.shown.zoom = 2
	testing.expect_value(t, video_scale(pv, {width = 640, height = 360}), f32(1))
	v.shown.zoom = 16
	testing.expect_value(t, video_scale(pv, {width = 640, height = 360}), f32(2))
	v.shown.zoom = 1.25

	// A double press fits it, and each click stays a click.
	tp.p.input.mouse = middle
	tp.s.press_keys[.Left] = {}
	test_frame(&tp)
	toggles := 0
	for _ in 0 ..< 2 {
		rows = test_frame(&tp, {kind = .Mouse_Press, button = .Left})
		rows2 := test_frame(&tp, {kind = .Mouse_Release, button = .Left})
		if test_has(rows2, .Playback_Toggle) do toggles += 1
		if test_has(rows, .Picture_Fit) do testing.expect_value(t, v.camera, picture_home(.Video))
	}
	testing.expect_value(t, toggles, 2)
	testing.expect_value(t, v.camera, picture_home(.Video))

	// Z fits the focused picture; with none focused, the video.
	append(&ws.views, View_Record{live = true, kind = .Image, camera = {{0.1, 0.1}, 3}, shown = {{0.1, 0.1}, 3}, panel = ws.focused})
	image := View_Id(len(ws.views))
	v = workspace_view(ws, id) // (the views have moved)
	shown := workspace_panel(ws, ws.focused).shown
	workspace_panel(ws, ws.focused).shown = image
	v.camera = {{0.2, 0.2}, 2}
	preview_apply(app, .Picture_Fit, {})
	testing.expect_value(t, workspace_view(ws, image).camera, picture_home(.Image))
	testing.expect_value(t, v.camera, Picture_Camera{{0.2, 0.2}, 2})
	workspace_view(ws, image).camera = {{0.1, 0.1}, 3}
	workspace_panel(ws, ws.focused).shown = workspace_find(ws, .Timeline)
	preview_apply(app, .Picture_Fit, {})
	testing.expect_value(t, workspace_view(ws, image).camera.zoom, 3)
	testing.expect_value(t, v.camera, picture_home(.Video))
	// The timeline's fit is the video's too, and a blackout shows no frame.
	v.camera = {{0.2, 0.2}, 2}
	preview_apply(app, .Timeline_Fit, {})
	testing.expect_value(t, v.camera, picture_home(.Video))
	// A command with an id is that view's, whatever has the focus.
	preview_apply(app, .Picture_Zoom, {view = image, scalar = 2, at_xy = {0.5, 0.5}})
	testing.expect_value(t, workspace_view(ws, image).camera.zoom, 6)
	testing.expect_value(t, v.camera, picture_home(.Video))
	workspace_panel(ws, ws.focused).shown = shown
	workspace_view(ws, image).live = false
	pv.blackout = true
	for _ in 0 ..< 2 do test_frame(&tp)
	testing.expect(t, test_box(&tp.s, "###video_picture") == nil)
	pv.blackout = false
	// While it eases, the frame lies where the shown camera is, not the target.
	v.camera, v.shown = {{}, 2}, {{}, 1.5}
	for _ in 0 ..< 2 do test_frame(&tp)
	placed(t, &tp, v, dim)
}

// A placed file's lane goes by the id its media row and its view go by, whatever
// its place among the rows, so a sound has one colour wherever it is drawn.
@(test)
test_sound_keeps_its_colour :: proc(t: ^testing.T) {
	frames := 4800
	samples := make([]f32, frames * 2)
	defer delete(samples)
	clip := om.Audio_Clip{samples = samples, frames = frames}
	placed := []om.Placed_Track{{track = {src = "a.wav"}, clip = &clip, start = 0, end = frames}, {track = {src = "b.wav", bus = "sfx"}, clip = &clip, start = 100, end = frames}}
	video: om.Video
	video.buses = []om.Bus{{name = "sfx"}}
	b: Wave_Builder
	defer wave_builder_destroy(&b)
	lane_id :: proc(t: ^Wave_Table, name: string) -> u64 {
		for l in t.lanes do if text_of(t.text[:], l.name) == name do return l.id
		return 0
	}
	wave_builder_lanes(&b, placed, {0, 1}, &video, 1, nil)
	a, other := lane_id(&b.table, "a.wav"), lane_id(&b.table, "b.wav")
	testing.expect_value(t, a, media_file_id(.Audio, "a.wav"))
	testing.expect_value(t, other, media_file_id(.Audio, "b.wav"))
	testing.expect(t, a != other)
	// Rows in another order: each keeps its own.
	wave_builder_lanes(&b, placed, {1, 0}, &video, 1, nil)
	testing.expect_value(t, lane_id(&b.table, "a.wav"), a)
	testing.expect_value(t, lane_id(&b.table, "b.wav"), other)
	// A bus's lane has one too, from its own name.
	testing.expect_value(t, lane_id(&b.table, "bus sfx"), media_file_id(.Audio, "bus sfx"))
}

@(test)
test_sound_pyramid_is_shared :: proc(t: ^testing.T) {
	frames := 48000
	placed_samples := make([]f32, frames * 2)
	defer delete(placed_samples)
	alone_samples := make([]f32, frames * 2)
	defer delete(alone_samples)
	placed_samples[100 * 2] = 0.5
	alone_samples[100 * 2] = -0.25
	placed_clip := om.Audio_Clip{samples = placed_samples, frames = frames}
	alone_clip := om.Audio_Clip{samples = alone_samples, frames = frames}
	placed := []om.Placed_Track{{track = {src = "placed"}, clip = &placed_clip, start = 0, end = frames}}
	video: om.Video
	b: Wave_Builder
	defer wave_builder_destroy(&b)
	files := []Wave_File{{1, placed_clip}, {2, alone_clip}}
	wave_builder_lanes(&b, placed, {0}, &video, 1, nil, files)
	for wave_builder_pending(&b) do wave_builder_step(&b)
	t_ := &b.table
	testing.expect_value(t, len(t_.sounds), 2)
	testing.expect_value(t, len(t_.clips), 2)
	var_region := t_.regions[t_.lanes[0].regions[0]]
	testing.expect_value(t, var_region.clip, int(t_.sounds[0].clip))
	testing.expect(t, t_.sounds[1].clip != t_.sounds[0].clip)
	lo, hi, ok := wave_peak(t_, wave_sound(t_, 1), 0, 200)
	testing.expect(t, ok && hi > 0.45 && hi < 0.55 && lo == 0)
	lo, hi, ok = wave_peak(t_, wave_sound(t_, 2), 0, 200)
	testing.expect(t, ok && lo < -0.2 && lo > -0.3 && hi == 0)
	testing.expect(t, wave_sound(t_, 3) == nil)

	// Asked for one fewer: its row goes, the pyramids stay, nothing is made again.
	wave_builder_lanes(&b, placed, {0}, &video, 1, nil, files[:1])
	testing.expect_value(t, len(t_.sounds), 1)
	testing.expect_value(t, len(t_.clips), 2)
	testing.expect(t, !wave_builder_pending(&b))
	testing.expect(t, wave_sound(t_, 2) == nil)
	wave_builder_lanes(&b, placed, {0}, &video, 1, nil, files)
	testing.expect_value(t, len(t_.clips), 2)
	testing.expect(t, !wave_builder_pending(&b))
}

// The worker swaps in a one-track mix of the file, which sounds exactly as the
// file does, from its start to its own length; a file that isn't there is
// silence, of no length; and it says it is done either way. Back to the video's
// sound, the same.
@(test)
test_worker_plays_a_file_alone :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	m: om.Media
	om.media_init(&m)
	defer om.media_destroy(&m)
	frames := om.MIX_RATE
	samples := make([]f32, frames * 2)
	defer delete(samples)
	for i in 0 ..< frames {
		v := 0.99 * math.sin(f32(i) * 0.05)
		samples[i * 2], samples[i * 2 + 1] = v, -v
	}
	om.media_add_audio_samples(&m, "tone.wav", samples, om.MIX_RATE, 2)
	id := media_file_id(.Audio, "tone.wav")
	mb: Mailbox
	defer mailbox_destroy(&mb)
	a: Audio_Shared
	defer audio_shared_destroy(&a)
	sc: script.Script
	w := Render_Worker {
		mb     = &mb,
		media  = &m,
		audio  = &a,
		script = &sc,
	}
	// (asked of the worker as any idle work is)
	mb.solo_file = id
	worker_idle(&w, false)
	testing.expect_value(t, mb.solo_heard, id)
	testing.expect(t, a.stream != nil)
	testing.expect_value(t, a.total, i64(frames))
	if a.stream == nil do return
	// Asked again, unchanged: nothing is built.
	stream := a.stream
	worker_solo(&w)
	testing.expect(t, a.stream == stream)

	// What it plays is the file: no gain, no limiter, no fade.
	block := make([]f32, 4096 * 2)
	defer delete(block)
	worst: f32
	for at := 0; at + 4096 <= 96000 && at + 4096 <= frames; at += 4096 {
		om.mix_block(a.stream, at, block)
		for x, i in block do worst = max(worst, abs(x - samples[at * 2 + i]))
	}
	testing.expectf(t, worst < 0.001, "differs from the file by %f", worst)
	// A seek plays from there, the same.
	om.mix_block(a.stream, 20000, block)
	worst = 0
	for x, i in block do worst = max(worst, abs(x - samples[20000 * 2 + i]))
	testing.expectf(t, worst < 0.001, "after a seek, differs from the file by %f", worst)

	// A file that isn't there: silence, of no length, and an answer.
	mb.solo_file = id + 1
	worker_solo(&w)
	testing.expect_value(t, mb.solo_heard, id + 1)
	testing.expect(t, a.stream == nil)
	testing.expect_value(t, a.total, i64(0))

	// Back to the video's sound (this script has none) and an answer.
	mb.solo_file = id
	worker_solo(&w)
	testing.expect(t, a.stream != nil)
	mb.solo_file = 0
	worker_solo(&w)
	testing.expect_value(t, mb.solo_heard, u64(0))
	testing.expect(t, a.stream == nil)
}

// The file through the audio thread's own callback: from where it is asked to its
// last sample, the very samples of the file, the playhead following what is
// heard; paused and played on from there; a callback while paused doesn't read as
// the file's end. At its end, the video's sound is asked back, and nothing plays.
@(test)
test_file_plays_to_its_end :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	tp: Test_Preview
	testing.expect(t, test_preview_make(&tp))
	defer test_preview_destroy(&tp)
	app := &tp.app
	pv := &app.preview
	spec := sdl.AudioSpec{format = .F32, channels = 2, freq = om.MIX_RATE}
	stream := sdl.CreateAudioStream(&spec, &spec)
	testing.expect(t, stream != nil)
	if stream == nil do return
	defer sdl.DestroyAudioStream(stream)
	a: Audio_Shared
	defer audio_shared_destroy(&a)
	pv.volume = 1
	pv.audio, pv.audio_stream = &a, stream
	defer {pv.audio, pv.audio_stream = nil, nil}
	// (as the worker hands it over: worker_publish_solo)
	frames := 20000
	samples := make([]f32, frames * 2)
	defer delete(samples)
	for i in 0 ..< frames do samples[i * 2], samples[i * 2 + 1] = 0.9 * f32(i) / f32(frames), -0.9 * f32(i) / f32(frames)
	clip := om.Audio_Clip{samples = samples, frames = frames}
	placed := [1]om.Placed_Track{{track = {src = "tone"}, clip = &clip, end = frames}}
	audio_set_tracks(&a, placed[:], i64(frames), {no_limiter = true})
	file := u64(77)

	BLOCK :: 1024
	heard := make([]f32, BLOCK * 2)
	defer delete(heard)
	// A request of the device's: what it hands over, drained at once so the
	// heard position is the fed one.
	request :: proc(a: ^Audio_Shared, stream: ^sdl.AudioStream, out: []f32) {
		audio_callback(a, stream, i32(len(out) * size_of(f32)), i32(len(out) * size_of(f32)))
		got := sdl.GetAudioStreamData(stream, raw_data(out), i32(len(out) * size_of(f32)))
		assert(int(got) == len(out) * size_of(f32))
	}

	// (the device runs from before anything is asked)
	request(&a, stream, heard)
	solo_set(app, file, 1000, true)
	testing.expect(t, !audio_plays(&a), "not until the worker has swapped it in")
	// (the device isn't advancing until then, and that isn't its end)
	request(&a, stream, heard)
	preview_playback_advance(app, 0)
	testing.expect(t, pv.solo.file == file && pv.solo.playing)
	solo_take(app, pv.solo.file)
	testing.expect(t, audio_plays(&a))

	at := 1000
	worst: f32
	check :: proc(heard: []f32, samples: []f32, at: int, worst: ^f32) {
		for x, i in heard do worst^ = max(worst^, abs(x - samples[at * 2 + i]))
	}
	for _ in 0 ..< 5 {
		request(&a, stream, heard)
		check(heard, samples, at, &worst)
		// (the playhead is what is heard: what it just handed over is still to come)
		preview_playback_advance(app, 0)
		testing.expect_value(t, pv.solo.at, i64(at))
		at += BLOCK
		testing.expect(t, pv.solo.file == file && pv.solo.playing)
	}

	// Paused: the device's requests go on, silent, and it isn't over; played on,
	// from where it was.
	solo_set(app, file, -1, false)
	request(&a, stream, heard)
	for x in heard do testing.expect_value(t, x, 0)
	solo_update(app)
	testing.expect(t, pv.solo.file == file && !pv.solo.playing)
	at -= BLOCK
	testing.expect_value(t, pv.solo.at, i64(at))
	solo_set(app, file, -1, true)
	solo_update(app)
	testing.expect(t, pv.solo.file == file && pv.solo.playing, "played on, it isn't over before the device is asked")
	testing.expect_value(t, pv.solo.at, i64(at))

	// To its last sample, then silence, and over.
	for at + BLOCK <= frames {
		request(&a, stream, heard)
		check(heard, samples, at, &worst)
		at += BLOCK
		solo_update(app)
		testing.expect(t, pv.solo.file == file)
	}
	testing.expectf(t, worst < 0.001, "differs from the file by %f", worst)
	left := frames - at
	testing.expect(t, left > 0 && left < BLOCK)
	request(&a, stream, heard)
	check(heard[:left * 2], samples, at, &worst)
	for x in heard[left * 2:] do testing.expect_value(t, x, 0)
	testing.expectf(t, worst < 0.001, "its last samples differ by %f", worst)
	preview_playback_advance(app, 0)
	testing.expect_value(t, pv.solo.file, u64(0))
	testing.expect(t, !solo_settled(pv) && !audio_plays(&a))
}

// What the worker does for a sound's view: its id asked for, the pyramid made and
// published with the waveforms, no image view of it; asked again unchanged,
// nothing published; asked no more, its row goes. It wakes for a file to swap in.
@(test)
test_worker_makes_a_sounds_pyramid :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	m: om.Media
	om.media_init(&m)
	defer om.media_destroy(&m)
	samples := make([]f32, 9600)
	defer delete(samples)
	samples[2000] = 0.5
	om.media_add_audio_samples(&m, "tone.wav", samples, om.MIX_RATE, 2)
	om.media_add_audio_samples(&m, "other.wav", samples[:4800], om.MIX_RATE, 2)
	mb: Mailbox
	defer mailbox_destroy(&mb)
	a: Audio_Shared
	defer audio_shared_destroy(&a)
	sc: script.Script
	w := Render_Worker {
		mb     = &mb,
		media  = &m,
		audio  = &a,
		script = &sc,
	}
	defer delete(w.files_wanted)
	defer delete(w.image_views)
	defer delete(w.image_retired)
	defer video_tables_destroy(&w.tables)
	defer wave_builder_destroy(&w.waves)
	findings: Finding_Table
	defer finding_table_destroy(&findings)
	video_tables_build(&w.tables, {fps = 30, findings = &findings, media = &m})
	file := media_file_id(.Audio, "tone.wav")
	testing.expect(t, w.tables.media[0].id == file || w.tables.media[1].id == file)

	want :: proc(mb: ^Mailbox, ids: ..u64) {
		table_copy(&mb.files_wanted, ids)
		mb.files_wanted_seq += 1
	}
	want(&mb, file)
	testing.expect(t, files_pending(&w))
	worker_files(&w)
	testing.expect(t, !files_pending(&w))
	testing.expect_value(t, len(w.image_views), 0)
	testing.expect_value(t, mb.waves_seq, 1)
	testing.expect(t, len(mb.waves.sounds) == 1 && mb.waves.sounds[0].id == file)
	for wave_builder_pending(&w.waves) do wave_builder_step(&w.waves)
	_, hi, ok := wave_peak(&w.waves.table, wave_sound(&w.waves.table, file), 0, 4800)
	testing.expect(t, ok && hi > 0.45 && hi < 0.55)

	want(&mb, file)
	worker_files(&w)
	testing.expect_value(t, mb.waves_seq, 1)

	// Another as many: that one's.
	other := media_file_id(.Audio, "other.wav")
	want(&mb, other)
	worker_files(&w)
	testing.expect_value(t, mb.waves_seq, 2)
	testing.expect(t, len(mb.waves.sounds) == 1 && mb.waves.sounds[0].id == other)
	for wave_builder_pending(&w.waves) do wave_builder_step(&w.waves)

	want(&mb)
	worker_files(&w)
	testing.expect_value(t, mb.waves_seq, 3)
	testing.expect_value(t, len(mb.waves.sounds), 0)

	// Idle with nothing to do, it sleeps; a file to swap in wakes it.
	ready, _ := worker_idle_ready(&w)
	testing.expect(t, !ready)
	mb.solo_file = file
	ready, _ = worker_idle_ready(&w)
	testing.expect(t, ready)
	worker_solo(&w)
	ready, _ = worker_idle_ready(&w)
	testing.expect(t, !ready)
}
