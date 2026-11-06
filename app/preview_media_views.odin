package onimite_app

import "core:fmt"
import "core:math"
import "core:slice"
import "core:sync"
import om "../onimite"
import platform "../platform"
import render "../render"
import ui "../ui"
import vg "deps:ovg"
import sdl "vendor:sdl3"

// What a media row unfolds into (RAD's view rules, picked by the value's
// type; `Visualizer`): a view, the row's (`View_Record.owner`) until it is
// dragged out as a tab. Its data is shared, named by the file's durable id
// (`Media_File_Row.id`), as the timeline's thumbnails and bands are: an image
// view asks for the id (`images_open`, through the mailbox), and the worker
// holds that file's one decoded image in the media (it stays out of the
// cache's way until no view is on it) and makes one texture of it, which the
// UI borrows. Nothing is copied. The pixels are read in the mailbox's table,
// under its lock: the worker takes a row out there before it lets go of them.
// A row scrolled away keeps its view, until it is shut or its Watch goes.

// A shown file: its id and the worker's texture of it (nil: no such file, or
// it can't be read), never written again while published.
Image_Shown :: struct {
	id:      u64,
	texture: ^sdl.GPUTexture,
	size:    [2]u32,
}

// A shown file on the worker: the image it holds, and the texture.
Image_View :: struct {
	using shown: Image_Shown,
	image:       ^om.Media_Image,
}

// ---- the worker ------------------------------------------------------------------------

@(private = "file")
worker_image_next :: proc(w: ^Render_Worker) -> int {
	next: for id, i in w.images_wanted {
		for v in w.image_views do if v.id == id do continue next
		return i
	}
	return -1
}

// Whether a request is new, or a file asked for has no view yet.
@(private)
images_pending :: proc(w: ^Render_Worker) -> bool {
	return w.mb.images_wanted_seq != w.images_wanted_seq || worker_image_next(w) >= 0
}

// One step: the latest ids taken, what they no longer name let go, the next
// one's view made, the table published when it changed.
@(private)
worker_images :: proc(w: ^Render_Worker) {
	sync.mutex_lock(&w.mb.mutex)
	if seq := w.mb.images_wanted_seq; seq != w.images_wanted_seq {
		w.images_wanted_seq = seq
		table_copy(&w.images_wanted, w.mb.images_wanted[:])
	}
	sync.mutex_unlock(&w.mb.mutex)
	gone := make([dynamic]Image_View, context.temp_allocator)
	kept := 0
	for v in w.image_views {
		if slice.contains(w.images_wanted[:], v.id) {
			w.image_views[kept] = v
			kept += 1
		} else {
			append(&gone, v)
		}
	}
	resize(&w.image_views, kept)
	changed := len(gone) > 0
	if i := worker_image_next(w); i >= 0 {
		append(&w.image_views, image_view_make(w, w.images_wanted[i]))
		changed = true
	}
	if changed do images_publish(w)
	// (published first: nothing reads what goes from here on)
	for v in gone do image_view_retire(w, v)
}

// The view of file `id`: held in the media, and its texture made once (the
// premultiplied pixels are what draws, and an opaque image's own are those).
@(private = "file")
image_view_make :: proc(w: ^Render_Worker, id: u64) -> (v: Image_View) {
	v.id = id
	for m in w.tables.media {
		if m.id != id do continue
		name := text_of(w.tables.text[:], m.name)
		img, ok := om.media_image_hold(w.media, name)
		if !ok do break
		v.image = img
		v.size = {u32(img.width), u32(img.height)}
		v.texture = sdl.CreateGPUTexture(w.device, {type = .D2, format = .R8G8B8A8_UNORM, usage = {.SAMPLER}, width = v.size.x, height = v.size.y, layer_count_or_depth = 1, num_levels = 1})
		if v.texture != nil {
			pixels := om.media_premultiplied(w.media, name)
			upload_rgba(w.device, v.texture, v.size, pixels if pixels != nil else img.pixels)
		}
		break
	}
	return
}

// Its hold goes; its texture retires until the UI has taken a table without it.
@(private = "file")
image_view_retire :: proc(w: ^Render_Worker, v: Image_View) {
	if v.image != nil do om.media_image_release(w.media, v.image)
	if v.texture != nil do append(&w.image_retired, v.texture)
}

// The table the UI reads, with each row's pixels beside it.
@(private = "file")
images_publish :: proc(w: ^Render_Worker) {
	mb := w.mb
	sync.guard(&mb.mutex)
	clear(&mb.images)
	clear(&mb.image_pixels)
	for v in w.image_views {
		append(&mb.images, v.shown)
		append(&mb.image_pixels, v.image.pixels if v.image != nil else nil)
	}
	mb.images_seq += 1
}

// Every view goes, as a load may replace what they read: the table first, so
// nothing reads the pixels, and made again after it as the ids still stand.
@(private)
worker_images_retire :: proc(w: ^Render_Worker) {
	views := slice.clone(w.image_views[:], context.temp_allocator)
	clear(&w.image_views)
	images_publish(w)
	for v in views do image_view_retire(w, v)
}

// With the mailbox locked: the textures the UI's table no longer names.
@(private)
images_retired_release :: proc(w: ^Render_Worker) {
	if w.mb.images_ack != w.mb.images_seq do return
	for t in w.image_retired do sdl.ReleaseGPUTexture(w.device, t)
	clear(&w.image_retired)
}

// The worker is going, and the UI's table with it.
@(private)
worker_images_release :: proc(w: ^Render_Worker) {
	for v in w.image_views {
		if v.image != nil && w.media != nil do om.media_image_release(w.media, v.image)
		if v.texture != nil do sdl.ReleaseGPUTexture(w.device, v.texture)
	}
	for t in w.image_retired do sdl.ReleaseGPUTexture(w.device, t)
	delete(w.image_views)
	delete(w.image_retired)
	delete(w.images_wanted)
}

// ---- the UI ----------------------------------------------------------------------------

// With the mailbox locked: the worker's latest table, whose textures the UI
// draws from here on (those it no longer names may now go).
@(private)
images_take :: proc(pv: ^Preview_State, mb: ^Mailbox) {
	if mb.images_seq == pv.seen_images do return
	pv.seen_images = mb.images_seq
	table_copy(&pv.images, mb.images[:])
	mb.images_ack = mb.images_seq
}

// The files of every image view, each once: a row's, wherever its row is
// (scrolled away, filtered out, in a hidden tab), and a tab's.
images_open_update :: proc(app: ^App_State) {
	pv := &app.preview
	clear(&pv.images_open)
	r := preview_reader(app)
	for &v in pv.workspace.views {
		if !v.live || v.kind != .Image do continue
		value, error := evaluate(&r, v.inputs[0].source)
		if error != "" do continue
		if _, ok := visualizer_of(&r, value); !ok do continue
		id := pv.tables.media[value.ref.row].id
		if !slice.contains(pv.images_open[:], id) do append(&pv.images_open, id)
	}
}

// An image's tab: its file's name, or its expression when it no longer names
// a file.
image_title :: proc(app: ^App_State, v: ^View_Record) -> (title: string, color: [4]u8) {
	r := preview_reader(app)
	value, error := evaluate(&r, v.inputs[0].source)
	if error != "" do return v.inputs[0].source, COLOR_ERROR
	return row_label(&r, value), {}
}

// An image's tab, in its panel's content: its file, or why not.
image_tab_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32, id: View_Id, area: Workspace_Rect) {
	v := workspace_view(&app.preview.workspace, id)
	mark := view_press_mark(s)
	defer view_press_focus(app, s, id, mark)
	ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_pref_height(s, ui.pct(1)); ui.set_next_child_layout_axis(s, .Y)
	ui.set_next_bg_color(s, COLOR_PANEL_BG); ui.set_next_corner_radius(s, 0)
	ui.push_parent(s, ui.build_box(s, {.Draw_Background}, fmt.tprintf("###image_tab_%d", id)))
	defer ui.pop_parent(s)
	r := preview_reader(app)
	value, error := evaluate(&r, v.inputs[0].source)
	if error == "" {
		if _, ok := visualizer_of(&r, value); ok {
			bitmap_view(app, s, &v.bitmap, r.tables.media[value.ref.row].id, fmt.tprintf("tab_%d", id), {area.width, area.height}, true)
			return
		}
		error = value_text(&r, value)
	}
	text_box(s, ui.pct(1), ui.px(24 * dpi), fmt.tprintf("%s###image_tab_error_%d", error, id), 13 * dpi, 10 * dpi, COLOR_ERROR)
}

// File `id` as the worker has made it so far.
@(private = "file")
image_made :: proc(pv: ^Preview_State, id: u64) -> Image_Shown {
	for row in pv.images do if row.id == id do return row
	return {}
}

// The pixel at (x, y) of file `id`: straight RGBA, read where it lies.
@(private)
image_pixel :: proc(mb: ^Mailbox, id: u64, x, y: int) -> (rgba: [4]u8, ok: bool) {
	sync.guard(&mb.mutex)
	for row, i in mb.images {
		if row.id != id do continue
		pixels := mb.image_pixels[i]
		at := (y * int(row.size.x) + x) * 4
		if at < 0 || at + 4 > len(pixels) do return
		return {pixels[at], pixels[at + 1], pixels[at + 2], pixels[at + 3]}, true
	}
	return
}

// ---- the image view --------------------------------------------------------------------

// RAD Debugger's bitmap view (raddbg_views.c:4885-5140), after onib's: the
// file's pixels on a canvas, nearest-sampled, with a border and a shadow,
// over a grid every ten ems. A drag pans it from where it was pressed and a
// double press puts it back. It opens at four fifths of its rows' height.
// In a tab, where it is looked into, the wheel zooms it about the pointer
// (1/256 to 256) and the pixel under the pointer is outlined, its colour in
// the tooltip. In a Watch's row it is the picture: the wheel is the list's, as
// RAD's row denies its views the Y scroll (UI_PermissionFlags,
// raddbg_core.c:4079), and the tooltip, which RAD's row has, would cover it.
Bitmap_View :: struct {
	zoom:   f32, // 0 until it first shows
	center: [2]f32, // the canvas point at the middle, in pixels from the image's centre
}

// File `file_id` laid out at its parent's top left, `dim` big; its canvas's
// signal.
bitmap_view :: proc(app: ^App_State, s: ^ui.State, state: ^Bitmap_View, file_id: u64, id: string, dim: [2]f32, tab: bool) -> ui.Signal {
	pv := &app.preview
	file := image_made(pv, file_id)
	size := [2]f32{f32(file.size.x), f32(file.size.y)}
	if state.zoom == 0 && size.y > 0 do state.zoom = dim.y / size.y * 0.8
	zoom := state.zoom if state.zoom > 0 else 1

	flags: ui.Box_Flags = {.Clip, .Clickable}
	if tab do flags += {.Scroll}
	ui.set_next_fixed_x(s, 0); ui.set_next_fixed_y(s, 0); ui.set_next_fixed_width(s, dim.x); ui.set_next_fixed_height(s, dim.y)
	canvas := ui.build_box(s, flags, fmt.tprintf("###bmp_canvas_%s", id))
	sig := ui.signal_from_box(s, canvas)
	middle := dim / 2
	mouse := platform.mouse_pos(s.p)
	mouse_canvas := mouse - canvas.rect.min
	if ui.dragging(sig) {
		if ui.pressed(sig) do ui.store_drag_struct(s, &state.center)
		state.center = ui.drag_struct(s, [2]f32)^ - sig.drag_delta / zoom
	}
	if sig.scroll.y != 0 {
		next := clamp(zoom - zoom * sig.scroll.y / 10, 1.0 / 256, 256)
		at := (mouse_canvas - middle) / zoom + state.center
		state.center += (middle + (at - state.center) * next - mouse_canvas) / next
		state.zoom, zoom = next, next
	}
	if ui.double_clicked(sig) {
		ui.kill_action(s)
		state.center = {}
		state.zoom, zoom = 1, 1
	}
	fs := ui.top_font_size(s)
	grid := new_clone(Bitmap_Grid{state.center, zoom, fs * 10, max(2, fs * 0.1)}, context.temp_allocator)
	ui.box_equip_custom_draw(canvas, bitmap_grid_draw, grid)
	if file.texture == nil do return sig

	ui.push_parent(s, canvas)
	defer ui.pop_parent(s)
	lo := middle + (-size / 2 - state.center) * zoom
	hi := middle + (size / 2 - state.center) * zoom
	// The pixel under the pointer, outlined, its colour in the tooltip.
	if tab && ui.hovering(sig) && !ui.dragging(sig) {
		p := (mouse_canvas - middle) / zoom + state.center + size / 2
		if p.x >= 0 && p.y >= 0 && p.x < size.x && p.y < size.y {
			px, py := int(p.x), int(p.y)
			if c, ok := image_pixel(pv.mailbox, file_id, px, py); ok {
				color_tooltip(s, {f64(c.r) / 255, f64(c.g) / 255, f64(c.b) / 255, f64(c.a) / 255}, mouse)
			}
			ui.set_next_border_color(s, {255, 255, 255, 255})
			ui.set_next_fixed_x(s, lo.x + f32(px) * zoom); ui.set_next_fixed_y(s, lo.y + f32(py) * zoom)
			ui.set_next_fixed_width(s, zoom); ui.set_next_fixed_height(s, zoom)
			ui.build_box(s, {.Draw_Border}, fmt.tprintf("###bmp_pixel_%s", id))
		}
	}
	ui.set_next_fixed_x(s, lo.x); ui.set_next_fixed_y(s, lo.y)
	ui.set_next_fixed_width(s, hi.x - lo.x); ui.set_next_fixed_height(s, hi.y - lo.y)
	image := ui.build_box(s, {.Draw_Border, .Draw_Drop_Shadow}, fmt.tprintf("###bmp_image_%s", id))
	ui.box_equip_custom_draw(image, bitmap_image_draw, new_clone(Bitmap_Image{pv.renderer, file.texture, file.size}, context.temp_allocator))
	return sig
}

@(private = "file")
Bitmap_Grid :: struct {
	center:     [2]f32,
	zoom:       f32,
	cell, line: f32,
}

// RAD's canvas draw: its grid lines, a cell every ten ems of the canvas.
@(private = "file")
bitmap_grid_draw :: proc(s: ^ui.State, box: ^ui.Box, c: ^vg.Canvas) {
	g := (^Bitmap_Grid)(box.custom_data)
	middle := (box.rect.min + box.rect.max) / 2
	lo := (box.rect.min - middle) / g.zoom + g.center
	hi := (box.rect.max - middle) / g.zoom + g.center
	paint := vg.paint_color(ui.color(COLOR_TEXT_DIM, 0.5 * box.opacity))
	for axis in 0 ..< 2 {
		for v := lo[axis] - math.mod(lo[axis], g.cell); v < hi[axis]; v += g.cell {
			at := middle[axis] + (v - g.center[axis]) * g.zoom
			x, y, w, h := at - g.line / 2, box.rect.min.y, g.line, box.rect.max.y - box.rect.min.y
			if axis == 1 do x, y, w, h = box.rect.min.x, at - g.line / 2, box.rect.max.x - box.rect.min.x, g.line
			ui.box_path(&s.path, x, y, w, h, {})
			vg.fill_path(c, &s.path, paint)
		}
	}
}

// The worker's texture, borrowed for the frame, nearest-sampled.
@(private = "file")
Bitmap_Image :: struct {
	r:       ^render.Renderer,
	texture: ^sdl.GPUTexture,
	size:    [2]u32,
}

@(private = "file")
bitmap_image_draw :: proc(s: ^ui.State, box: ^ui.Box, c: ^vg.Canvas) {
	d := (^Bitmap_Image)(box.custom_data)
	id := render.image_borrow(d.r, c, d.texture, d.size.x, d.size.y, {.Nearest, .Premultiplied})
	x, y := box.rect.min.x, box.rect.min.y
	w, h := box.rect.max.x - x, box.rect.max.y - y
	ui.box_path(&s.path, x, y, w, h, {})
	vg.fill_path(c, &s.path, vg.paint_image(id, x, y, w, h, 0, box.opacity))
}

// RAD's colour tooltip (ui_do_color_tooltip_hsva), after onib's: beside the
// pointer and kept inside the window, a swatch, the hex and the numbers.
@(private = "file")
color_tooltip :: proc(s: ^ui.State, rgba: [4]f64, mouse: [2]f32) {
	em := ui.top_font_size(s)
	hsv := hsv_from_rgb(rgba.rgb)
	width, height := 26 * em, 19.8 * em
	ui.tooltip_begin(s)
	defer ui.tooltip_end(s)
	left := clamp(mouse.x + 14, 0, max(0, f32(s.p.width) - width))
	top := clamp(mouse.y + 16, 0, max(0, f32(s.p.height) - height))
	ui.set_next_bg_color(s, {22, 27, 35, 245})
	place(s, {left, top, width, height})
	panel := ui.build_box(s, {.Draw_Background, .Draw_Border}, "###color_tooltip")
	ui.push_parent(s, panel)
	defer ui.pop_parent(s)
	x, y := left + 2 * em, top + 2 * em
	byte_of :: proc(v: f64) -> u8 {return u8(clamp(v, 0, 1) * 255 + 0.5)}
	ui.set_next_bg_color(s, {byte_of(rgba.r), byte_of(rgba.g), byte_of(rgba.b), byte_of(rgba.a)})
	ui.set_next_corner_radius(s, 4)
	place(s, {x + 8 * em, y, 6 * em, 6 * em})
	ui.build_box(s, {.Draw_Background, .Draw_Border}, "###color_tooltip_swatch")
	y += 6.3 * em
	ui.set_next_text_align(s, .Center)
	place(s, {x, y, 22 * em, 1.8 * em})
	ui.build_box(s, {.Draw_Text}, fmt.tprintf("Hex: #%02x%02x%02x%02x###color_tooltip_hex", byte_of(rgba.r), byte_of(rgba.g), byte_of(rgba.b), byte_of(rgba.a)))
	y += 2.1 * em
	NAMES := [8]string{"Red", "Green", "Blue", "Alpha", "Hue", "Sat", "Val", "Alpha"}
	numbers := [8]f64{rgba.r, rgba.g, rgba.b, rgba.a, hsv[0], hsv[1], hsv[2], rgba.a}
	for column in 0 ..< 2 {
		for i in 0 ..< 4 {
			k := column * 4 + i
			place(s, {x + f32(column) * 11 * em, y + f32(i) * 1.8 * em, 11 * em, 1.8 * em})
			ui.build_box(s, {.Draw_Text}, fmt.tprintf("%s: %.2f###color_tooltip_%d", NAMES[k], numbers[k], k))
		}
	}
}

@(private = "file")
hsv_from_rgb :: proc(c: [3]f64) -> [3]f64 {
	hi, lo := max(c.r, c.g, c.b), min(c.r, c.g, c.b)
	d := hi - lo
	h: f64
	switch {
	case d == 0:
	case hi == c.r:
		h = math.mod((c.g - c.b) / d + 6, 6)
	case hi == c.g:
		h = (c.b - c.r) / d + 2
	case:
		h = (c.r - c.g) / d + 4
	}
	return {h / 6, hi > 0 ? d / hi : 0, hi}
}
