package onimite_app

import "core:fmt"
import "core:math"
import render "../render"
import ui "../ui"

// The media panel (fframes' MediaList): the script's media from the
// worker's published table, as a list or a grid. Only the visible rows
// build boxes. A click on audio or video used on the timeline goes to its
// first use.

MEDIA_HEADER :: 34
MEDIA_ROW :: 46
MEDIA_CELL :: 104

@(private = "file")
KIND_TAGS := [Media_Kind]string {
	.Image     = "IMG",
	.Video     = "VID",
	.Audio     = "AUD",
	.Font      = "FNT",
	.Subtitles = "SUB",
	.Shader    = "SHD",
}

@(private = "file")
KIND_COLORS := [Media_Kind][4]u8 {
	.Image     = {58, 96, 160, 255},
	.Video     = {140, 90, 60, 255},
	.Audio     = {48, 120, 110, 255},
	.Font      = {92, 70, 150, 255},
	.Subtitles = {120, 60, 100, 255},
	.Shader    = {90, 100, 60, 255},
}

media_view :: proc(app: ^App_State, s: ^ui.State, dpi, width, h: f32) {
	pv := &app.preview
	c := &app.commands
	ui.set_next_pref_width(s, ui.px(width))
	ui.set_next_pref_height(s, ui.px(h))
	ui.set_next_bg_color(s, s.theme.background)
	ui.set_next_child_layout_axis(s, .Y)
	ui.set_next_corner_radius(s, 0)
	panel := ui.build_box(s, {.Draw_Background}, "###media_panel")
	ui.push_parent(s, panel)
	defer ui.pop_parent(s)

	ui.set_next_pref_width(s, ui.fill())
	ui.set_next_pref_height(s, ui.px(MEDIA_HEADER * dpi))
	ui.set_next_child_layout_axis(s, .X)
	header := ui.build_box(s, {}, "###media_header")
	ui.push_parent(s, header)
	ui.set_next_pref_width(s, ui.fill())
	ui.set_next_pref_height(s, ui.fill())
	ui.set_next_text_padding(s, 10 * dpi)
	ui.build_box(s, {.Draw_Text}, fmt.tprintf("Media · %d###media_title", len(pv.media.rows)))
	ui.set_next_fixed_y(s, 4 * dpi)
	ui.set_next_pref_width(s, ui.px(56 * dpi))
	ui.set_next_pref_height(s, ui.px((MEDIA_HEADER - 8) * dpi))
	if ui.clicked(ui.button(s, "List###media_layout" if pv.media_grid else "Grid###media_layout")) {
		command_push(c, .Media_Layout_Toggle)
	}
	ui.spacer(s, ui.px(8 * dpi))
	ui.pop_parent(s)

	content_h := h - MEDIA_HEADER * dpi
	ui.set_next_pref_width(s, ui.fill())
	ui.set_next_pref_height(s, ui.px(content_h))
	ui.set_next_child_layout_axis(s, .Y)
	content := ui.build_box(s, {.Clip}, "###media_content")
	if sig := ui.signal_from_box(s, content); sig.scroll != 0 {
		command_push(c, .Media_Scroll, {count = -int(math.sign(sig.scroll)) * (1 if pv.media_grid else 2)})
	}
	ui.push_parent(s, content)
	defer ui.pop_parent(s)

	n := len(pv.media.rows)
	if n == 0 {
		ui.set_next_pref_width(s, ui.fill())
		ui.set_next_pref_height(s, ui.px(24 * dpi))
		ui.set_next_text_color(s, COLOR_TEXT_DIM)
		ui.set_next_text_padding(s, 10 * dpi)
		ui.build_box(s, {.Draw_Text}, "No media loaded.###media_none")
		return
	}
	if !pv.media_grid {
		visible := int(content_h / (MEDIA_ROW * dpi)) + 1
		first := clamp(pv.media_scroll, 0, max(n - visible + 1, 0))
		for i in first ..< min(n, first + visible) {
			media_item(app, s, dpi, i, ui.fill(), MEDIA_ROW * dpi, false)
		}
		return
	}
	cols := max(int(width / (MEDIA_CELL * dpi)), 1)
	cell_w := (width - 8 * dpi) / f32(cols)
	cell_h := cell_w + 30 * dpi
	rows := (n + cols - 1) / cols
	visible := int(content_h / cell_h) + 1
	first := clamp(pv.media_scroll, 0, max(rows - visible + 1, 0))
	for row in first ..< min(rows, first + visible) {
		ui.set_next_pref_width(s, ui.fill())
		ui.set_next_pref_height(s, ui.px(cell_h))
		ui.set_next_child_layout_axis(s, .X)
		line := ui.build_box(s, {}, fmt.tprintf("###media_row%d", row))
		ui.push_parent(s, line)
		ui.spacer(s, ui.px(4 * dpi))
		for i in row * cols ..< min(n, row * cols + cols) {
			media_item(app, s, dpi, i, ui.px(cell_w), cell_h, true)
		}
		ui.pop_parent(s)
	}
}

// One item: its thumbnail (or kind tag) beside (list) or above (grid) its
// name and details.
@(private = "file")
media_item :: proc(app: ^App_State, s: ^ui.State, dpi: f32, i: int, width: ui.Size, height: f32, grid: bool) {
	pv := &app.preview
	row := pv.media.rows[i]
	text := pv.media.text[:]
	ui.set_next_pref_width(s, width)
	ui.set_next_pref_height(s, ui.px(height))
	ui.set_next_child_layout_axis(s, .Y if grid else .X)
	ui.set_next_bg_color(s, {0, 0, 0, 0})
	item := ui.build_box(s, {.Clickable, .Draw_Background, .Draw_Hot_Effects}, fmt.tprintf("###media%d", i))
	if ui.clicked(ui.signal_from_box(s, item)) && row.first_frame >= 0 {
		command_push(&app.commands, .Frame_Set, {count = row.first_frame})
	}
	ui.push_parent(s, item)
	defer ui.pop_parent(s)

	icon := height - 30 * dpi if grid else height - 10 * dpi
	ui.spacer(s, ui.px(5 * dpi))
	if !grid {
		// In a row the spacer above went along X: centre the icon vertically.
		ui.set_next_fixed_y(s, 5 * dpi)
	}
	ui.set_next_pref_width(s, ui.px(icon) if !grid else ui.fill())
	ui.set_next_pref_height(s, ui.px(icon))
	image := &pv.media_images[i] if i < len(pv.media_images) else nil
	if image != nil && render.image_loaded(image) {
		b := ui.build_box(s, {.Draw_Image}, fmt.tprintf("###media_icon%d", i))
		b.image = image
	} else {
		ui.set_next_bg_color(s, KIND_COLORS[row.kind])
		ui.set_next_text_align(s, .Center)
		ui.set_next_font_size(s, 11 * dpi)
		ui.set_next_corner_radius(s, 6 * dpi)
		b := ui.build_box(s, {.Draw_Background, .Draw_Text}, fmt.tprintf("%s###media_icon%d", KIND_TAGS[row.kind], i))
		b.image = nil
	}
	ui.set_next_pref_width(s, ui.fill())
	ui.set_next_pref_height(s, ui.fill() if !grid else ui.px(26 * dpi))
	ui.set_next_child_layout_axis(s, .Y)
	words := ui.build_box(s, {.Clip}, fmt.tprintf("###media_words%d", i))
	ui.push_parent(s, words)
	defer ui.pop_parent(s)
	detail := text_of(text, row.detail)
	if row.first_frame >= 0 {
		detail = fmt.tprintf("%s · at %s", detail, clock_label(app, row.first_frame))
	}
	ui.set_next_pref_width(s, ui.fill())
	ui.set_next_pref_height(s, ui.px(height * 0.5 if !grid else 14 * dpi))
	ui.set_next_font_size(s, 13 * dpi if !grid else 11 * dpi)
	ui.set_next_text_padding(s, 8 * dpi if !grid else 2 * dpi)
	ui.build_box(s, {.Draw_Text}, fmt.tprintf("%s###media_name%d", text_of(text, row.name), i))
	ui.set_next_pref_width(s, ui.fill())
	ui.set_next_pref_height(s, ui.px(height * 0.35 if !grid else 12 * dpi))
	ui.set_next_font_size(s, 11 * dpi if !grid else 10 * dpi)
	ui.set_next_text_padding(s, 8 * dpi if !grid else 2 * dpi)
	ui.set_next_text_color(s, COLOR_TEXT_DIM)
	ui.build_box(s, {.Draw_Text}, fmt.tprintf("%s###media_detail%d", detail, i))
}
