package onimite_app

import "core:fmt"
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
	.Model     = {70, 130, 90, 255},
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
	.Marks    = {"Marks", "Mark", "No marks: [ and ] mark a range, P a moment; the agent reads them.", true},
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
	cell(s, area, fmt.tprintf("###watch_%d", id), {.Draw_Background})

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
		place(s, {area.x + f32(int(section)) * section_w, area.y, section_w, header})
		ui.set_next_corner_radius(s, 0)
		if ui.clicked(ui.button(s, fmt.tprintf("%s %d###watch_section_%d_%v", WATCH_SECTIONS[section].name, g.count, id, section))) {
			command_push(c, .Watch_Section_Set, {view = id, section = section})
		}
	}

	// The filter row (Ctrl+F), then the rows: the section's, read in place;
	// a filter reads every label and keeps the matches in the Watch's order.
	body := view_header(app, s, {area.x, area.y + header, area.width, max(area.height - header, 0)}, id, dpi)
	g := t.sections[v.section]
	filter := string(v.filter[:])
	matched := make([dynamic]int, context.temp_allocator)
	if filter != "" {
		for k in g.first ..< g.first + g.count {
			if _, ok := fuzzy_score(text_of(t.text[:], t.rows[k].label), filter); ok do append(&matched, k)
		}
	}
	count := len(matched) if filter != "" else g.count
	row_of :: proc(g: Watch_Group, matched: []int, filtered: bool, i: int) -> int {return matched[i] if filtered else g.first + i}
	if count == 0 {
		ui.set_next_font_size(s, 13 * dpi)
		ui.set_next_text_padding(s, 10 * dpi)
		empty := "No rows match." if filter != "" else WATCH_SECTIONS[v.section].empty
		cell(s, {body.x, body.y, body.width, 24 * dpi}, fmt.tprintf("%s###watch_none_%d", empty, id), {.Draw_Text}, COLOR_TEXT_DIM)
		return
	}
	// The row the playhead is in (the last shown starting at or before it).
	current := -1
	for i in 0 ..< count {
		row := t.rows[row_of(g, matched[:], filter != "", i)]
		if row.frame >= 0 && row.frame <= pv.frame && (current < 0 || row.frame >= t.rows[row_of(g, matched[:], filter != "", current)].frame) {
			current = i
		}
	}
	row_h := WATCH_ROW * dpi
	first, fraction := view_list_begin(app, s, body, id, fmt.tprintf("###watch_rows_%d", id), 3)
	limit := max(1, int(body.height / row_h))
	for i in first ..< min(count, first + limit + 1) {
		watch_row_view(app, s, dpi, id, row_of(g, matched[:], filter != "", i), {body.x, body.y + (f32(i - first) - fraction) * row_h, body.width, row_h}, i == current, filter)
	}
	ui.pop_parent(s)
	list_limit(view_list(pv, id), count, limit)
}

// One row at `r`: its status strip, its thumbnail or kind for media, its
// label (the filter's letters lit) over its detail. It fades in as it
// appears (RAD Debugger's alive_t, as onib's rows), keyed by what it is.
@(private = "file")
watch_row_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32, id: View_Id, index: int, r: Workspace_Rect, current: bool, filter: string) {
	pv := &app.preview
	row := pv.watch.rows[index]
	text := pv.watch.text[:]
	label := text_of(text, row.label)
	alive := ui.anim_f32(s, ui.key_from_string(0, fmt.tprintf("watch_%d_%x_alive", id, row.key)), 1, {initial = 0, duration = 0.14, easing = .Cubic_Out})
	ui.push_opacity(s, alive)
	defer ui.pop_opacity(s)
	ui.set_next_bg_color(s, {40, 46, 58, 255} if current else {0, 0, 0, 0})
	ui.set_next_corner_radius(s, 0)
	if ui.clicked(cell(s, r, fmt.tprintf("###watch_row_%d_%x", id, row.key), {.Clickable, .Draw_Background, .Draw_Hot_Effects})) {
		watch_row_click(app, row)
	}
	ui.set_next_bg_color(s, STATUS_COLORS[row.status])
	ui.set_next_corner_radius(s, 0)
	cell(s, {r.x, r.y + 4 * dpi, 3 * dpi, r.height - 8 * dpi}, fmt.tprintf("###watch_status_%x", row.key), {.Draw_Background})
	x := r.x + 10 * dpi
	if row.section == .Media && row.media >= 0 && int(row.media) < len(pv.media.rows) {
		// The media table's row, while it is the same item (the tables are
		// published separately).
		m := pv.media.rows[row.media]
		icon := Workspace_Rect{x, r.y + 3 * dpi, r.height - 6 * dpi, r.height - 6 * dpi}
		image := &pv.media_images[row.media] if int(row.media) < len(pv.media_images) else nil
		if text_of(pv.media.text[:], m.name) != label {
			image = nil
		}
		if image != nil && render.image_loaded(image) {
			place(s, icon)
			b := ui.build_box(s, {.Draw_Image}, fmt.tprintf("###watch_icon_%x", row.key))
			b.image = image
		} else {
			ui.set_next_bg_color(s, KIND_COLORS[m.kind])
			ui.set_next_text_align(s, .Center)
			ui.set_next_font_size(s, 10 * dpi)
			ui.set_next_corner_radius(s, 4 * dpi)
			place(s, icon)
			ui.build_box(s, {.Draw_Background, .Draw_Text}, fmt.tprintf("%s###watch_icon_%x", om.MEDIA_KINDS[m.kind].tag, row.key))
		}
		x += icon.width + 6 * dpi
	}
	width := max(r.x + r.width - x - 4 * dpi, 0)
	top := Workspace_Rect{x, r.y + 2 * dpi, width, r.height * 0.5}
	match_marks(s, top, label, filter, 13 * dpi, 0, fmt.tprintf("watch_%d_%x", id, row.key))
	ui.set_next_font_size(s, 13 * dpi)
	ui.set_next_text_padding(s, 0)
	cell(s, top, fmt.tprintf("%s###watch_label_%x", label, row.key), {.Draw_Text, .Clip})
	ui.set_next_font_size(s, 11 * dpi)
	ui.set_next_text_padding(s, 0)
	cell(s, {x, r.y + r.height * 0.5, width, r.height * 0.45}, fmt.tprintf("%s###watch_detail_%x", text_of(text, row.detail), row.key), {.Draw_Text, .Clip}, COLOR_TEXT_DIM)
}
