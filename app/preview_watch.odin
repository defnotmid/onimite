package onimite_app

import "core:fmt"
import "core:math"
import om "../onimite"
import render "../render"
import ui "../ui"

// A Watch view: one section of the worker's Watch table (the scenes, the
// cues, the problems or the media) as rows of what each item is and says,
// its status as a colour, media thumbnails where the media table has them.
// A click on a row goes to its frame; N / Shift+N go to the next / previous
// row with a warning or an error (`Problem_Step`). Only the visible rows
// build boxes; the words are the table's (items.odin), never the view's.

WATCH_HEADER :: 28
WATCH_ROW :: 36

@(private = "file")
KIND_COLORS := [om.Media_Kind][4]u8 {
	.Image     = {58, 96, 160, 255},
	.Video     = {140, 90, 60, 255},
	.Audio     = {48, 120, 110, 255},
	.Font      = {92, 70, 150, 255},
	.Svg       = {60, 120, 150, 255},
	.Lottie    = {150, 110, 50, 255},
	.Shader    = {90, 100, 60, 255},
	.Subtitles = {120, 60, 100, 255},
	.Captions  = {150, 70, 90, 255},
}

@(private = "file")
STATUS_COLORS := [Watch_Status][4]u8 {
	.Ok      = {72, 160, 110, 255},
	.Info    = {110, 118, 132, 255},
	.Warning = COLOR_WARNING,
	.Error   = COLOR_ERROR,
}

// What a Watch section is called, what one of its rows is, what it says
// when empty, and whether its rows are places to go (the lister's).
Watch_Section_Descriptor :: struct {
	name:  string,
	noun:  string,
	empty: string,
	go_to: bool,
}

WATCH_SECTIONS := [Watch_Section]Watch_Section_Descriptor {
	.Scenes   = {"Scenes", "Scene", "No scenes.", true},
	.Cues     = {"Cues", "Cue", "No cues.", true},
	.Problems = {"Problems", "Problem", "No problems at load or in the frames shown since.", true},
	.Media    = {"Media", "Media file", "No media loaded.", false},
}

// What a click on a Watch row pushes: the playhead to its frame.
watch_row_click :: proc(app: ^App_State, row: Watch_Row) {
	if row.frame >= 0 {
		command_push(&app.commands, .Frame_Set, {count = row.frame})
	}
}

watch_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32, id: View_Id, area: Workspace_Rect) {
	pv := &app.preview
	c := &app.commands
	v := workspace_view(&pv.workspace, id)
	t := &pv.watch
	ui.set_next_bg_color(s, s.theme.background)
	ui.set_next_corner_radius(s, 0)
	place_box(s, area, {.Draw_Background}, fmt.tprintf("###watch_%d", id))

	// The sections as tabs, each with its rows' count in its worst status's
	// colour.
	header := WATCH_HEADER * dpi
	section_w := area.width / f32(len(Watch_Section))
	for section in Watch_Section {
		g := t.sections[section]
		ui.set_next_font_size(s, 12 * dpi)
		ui.set_next_bg_color(s, COLOR_TAB_SHOWN if section == v.section else COLOR_TABS)
		if g.count > 0 && g.worst >= .Warning {
			ui.set_next_text_color(s, STATUS_COLORS[g.worst])
		}
		r := Workspace_Rect{area.x + f32(int(section)) * section_w, area.y, section_w, header}
		if ui.clicked(place_button(s, r, fmt.tprintf("%s %d###watch_section_%d_%v", WATCH_SECTIONS[section].name, g.count, id, section))) {
			command_push(c, .Watch_Section_Set, {view = id, section = section})
		}
	}

	list := Workspace_Rect{area.x, area.y + header, area.width, max(area.height - header, 0)}
	box := place_box(s, list, {.Clip}, fmt.tprintf("###watch_rows_%d", id))
	if sig := ui.signal_from_box(s, box); sig.scroll != 0 {
		command_push(c, .Watch_Scroll, {view = id, count = -int(math.sign(sig.scroll)) * 2})
	}
	ui.push_parent(s, box)
	defer ui.pop_parent(s)
	g := t.sections[v.section]
	row_h := WATCH_ROW * dpi
	if g.count == 0 {
		ui.set_next_text_color(s, COLOR_TEXT_DIM)
		ui.set_next_font_size(s, 13 * dpi)
		ui.set_next_text_padding(s, 10 * dpi)
		place_box(s, {0, 0, list.width, 24 * dpi}, {.Draw_Text}, fmt.tprintf("%s###watch_none_%d", WATCH_SECTIONS[v.section].empty, id))
		return
	}
	// The row the playhead is in (the last one starting at or before it).
	current := -1
	for row, i in t.rows[g.first:][:g.count] {
		if row.frame >= 0 && row.frame <= pv.frame && (current < 0 || row.frame >= t.rows[g.first + current].frame) {
			current = i
		}
	}
	first := clamp(v.scroll, 0, max(g.count - 1, 0))
	for i in first ..< min(g.count, first + int(list.height / row_h) + 1) {
		watch_row_view(app, s, dpi, id, g.first + i, {0, f32(i - first) * row_h, list.width, row_h}, i == current)
	}
}

// One row at `r` (inside the list): its status strip, its thumbnail or
// kind for media, its label over its detail.
@(private = "file")
watch_row_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32, id: View_Id, index: int, r: Workspace_Rect, current: bool) {
	pv := &app.preview
	row := pv.watch.rows[index]
	text := pv.watch.text[:]
	ui.set_next_bg_color(s, {40, 46, 58, 255} if current else {0, 0, 0, 0})
	ui.set_next_corner_radius(s, 0)
	item := place_box(s, r, {.Clickable, .Draw_Background, .Draw_Hot_Effects}, fmt.tprintf("###watch_row_%d_%d", id, index))
	if ui.clicked(ui.signal_from_box(s, item)) {
		watch_row_click(app, row)
	}
	ui.push_parent(s, item)
	defer ui.pop_parent(s)
	ui.set_next_bg_color(s, STATUS_COLORS[row.status])
	ui.set_next_corner_radius(s, 0)
	place_box(s, {0, 4 * dpi, 3 * dpi, r.height - 8 * dpi}, {.Draw_Background}, fmt.tprintf("###watch_status_%d", index))
	x := 10 * dpi
	if row.section == .Media && row.media >= 0 && int(row.media) < len(pv.media.rows) {
		// The media table's row, while it is the same item (the tables are
		// published separately).
		m := pv.media.rows[row.media]
		icon := Workspace_Rect{x, 3 * dpi, r.height - 6 * dpi, r.height - 6 * dpi}
		image := &pv.media_images[row.media] if int(row.media) < len(pv.media_images) else nil
		if text_of(pv.media.text[:], m.name) != text_of(text, row.label) {
			image = nil
		}
		if image != nil && render.image_loaded(image) {
			b := place_box(s, icon, {.Draw_Image}, fmt.tprintf("###watch_icon_%d", index))
			b.image = image
		} else {
			ui.set_next_bg_color(s, KIND_COLORS[m.kind])
			ui.set_next_text_align(s, .Center)
			ui.set_next_font_size(s, 10 * dpi)
			ui.set_next_corner_radius(s, 4 * dpi)
			place_box(s, icon, {.Draw_Background, .Draw_Text}, fmt.tprintf("%s###watch_icon_%d", om.MEDIA_KINDS[m.kind].tag, index))
		}
		x += icon.width + 6 * dpi
	}
	width := max(r.width - x - 4 * dpi, 0)
	ui.set_next_font_size(s, 13 * dpi)
	ui.set_next_text_padding(s, 0)
	place_box(s, {x, 2 * dpi, width, r.height * 0.5}, {.Draw_Text, .Clip}, fmt.tprintf("%s###watch_label_%d", text_of(text, row.label), index))
	ui.set_next_font_size(s, 11 * dpi)
	ui.set_next_text_padding(s, 0)
	ui.set_next_text_color(s, COLOR_TEXT_DIM)
	place_box(s, {x, r.height * 0.5, width, r.height * 0.45}, {.Draw_Text, .Clip}, fmt.tprintf("%s###watch_detail_%d", text_of(text, row.detail), index))
}
