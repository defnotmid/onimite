package onimite_app

import "core:fmt"
import "core:math"
import om "../onimite"
import ui "../ui"
import vg "deps:ovg"

// A Watch view: one section of the worker's Watch table (the scenes, the
// cues, the problems, the media or the marks), fixed when it opens, as rows
// of what each item is and says, its status as a colour, media thumbnails
// where the media table has them. Each section is a tab of its own, titled
// by `watch_title`. A click on a row goes to its frame; N / Shift+N go to
// the next / previous row with a warning or an error (`Problem_Step`). Only
// the visible rows build boxes; the words are the table's (items.odin),
// never the view's.

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

// A Watch section's tab title: its name and its rows' count, in its worst
// status's colour when that is a warning or an error (alpha 0: the theme's).
watch_title :: proc(t: ^Watch_Table, section: Watch_Section) -> (title: string, color: [4]u8) {
	g := t.sections[section]
	if g.count > 0 && g.worst >= .Warning {
		color = STATUS_COLORS[g.worst]
	}
	return fmt.tprintf("%s %d", WATCH_SECTIONS[section].name, g.count), color
}

// What a click on a Watch row pushes: the playhead to its frame.
watch_row_click :: proc(app: ^App_State, row: Watch_Row) {
	if row.frame >= 0 {
		command_push(&app.commands, .Frame_Set, {count = row.frame})
	}
}

// A Watch view, laid out in its panel's content (`area`, from the panel
// tree): the filter row (Search), then its section's rows in the one scroll
// list, its rows a row tall (list_row_height), with RAD's list keyboard model
// while its panel is focused: the keys move its cursor row (focus hot: the
// focus overlay), and Enter on it, as a click, goes to its frame. A press
// on any of it focuses its panel (RAD's table-wide press).
watch_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32, id: View_Id, area: Workspace_Rect) {
	pv := &app.preview
	v := workspace_view(&pv.workspace, id)
	t := &pv.watch
	ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_pref_height(s, ui.pct(1)); ui.set_next_child_layout_axis(s, .Y)
	ui.set_next_bg_color(s, COLOR_PANEL_BG)
	ui.set_next_corner_radius(s, 0)
	mark := view_press_mark(s)
	content := ui.build_box(s, {.Clickable, .Draw_Background}, fmt.tprintf("###watch_%d", id))
	ui.push_parent(s, content)
	defer {
		ui.pop_parent(s)
		ui.signal_from_box(s, content)
		view_press_focus(app, s, id, mark)
	}

	// The filter row (Search), then the rows: the section's, read in place;
	// a filter reads every label and keeps the matches in the Watch's order.
	filter_h := view_header(app, s, id, dpi)
	g := t.sections[v.section]
	filter := string(v.filter[:])
	matched := make([dynamic]int, context.temp_allocator)
	if filter != "" {
		for k in g.first ..< g.first + g.count {
			if fuzzy_find(text_of(t.text[:], t.rows[k].label), filter) do append(&matched, k)
		}
	}
	count := len(matched) if filter != "" else g.count
	row_of :: proc(g: Watch_Group, matched: []int, filtered: bool, i: int) -> int {return matched[i] if filtered else g.first + i}
	if count == 0 {
		empty := "No rows match." if filter != "" else WATCH_SECTIONS[v.section].empty
		text_box(s, ui.pct(1), ui.px(24 * dpi), fmt.tprintf("%s###watch_none_%d", empty, id), 13 * dpi, 10 * dpi, COLOR_TEXT_DIM)
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
	row_h := list_row_height(s)
	l := view_list(pv, id)
	l.cursor = clamp(l.cursor, 0, count - 1)
	ui.push_focus(s, .On)
	first, last := view_list_begin(app, s, {area.width, area.height - filter_h}, id, fmt.tprintf("###watch_rows_%d", id), count, row_h, &l.cursor)
	for i in first ..< last {
		// A press puts the cursor on its row (RAD's).
		if ui.pressed(watch_row_view(app, s, dpi, id, row_of(g, matched[:], filter != "", i), row_h, i == current, i == l.cursor, filter)) do l.cursor = i
	}
	view_list_end(app, s, id)
	ui.pop_focus(s)
}

// One row, `h` tall, laid out in the list: a clickable box (keyboard
// clickable: the cursor row's Enter is its click; focus hot, it lights the
// focus overlay: a known difference from RAD, whose row disables it for its
// selected cell to draw, until C8's rows have cells) holding its status strip,
// its thumbnail or kind for media, its label (the filter's letters lit)
// and its detail. It fades in as it appears (RAD Debugger's alive_t, at its
// entity-alive rate), keyed by what it is.
@(private = "file")
watch_row_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32, id: View_Id, index: int, h: f32, current, cursor: bool, filter: string) -> ui.Signal {
	pv := &app.preview
	row := pv.watch.rows[index]
	text := pv.watch.text[:]
	label := text_of(text, row.label)
	alive := ui.anim_f32(s, ui.key_from_string(0, fmt.tprintf("watch_%d_%x_alive", id, row.key)), 1, {initial = 0, rate = ALIVE_RATE})
	ui.push_opacity(s, alive)
	defer ui.pop_opacity(s)
	ui.push_focus_hot(s, cursor ? .On : .Off); ui.push_focus_active(s, .Off)
	defer ui.pop_focus(s)
	ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_child_layout_axis(s, .X)
	ui.set_next_bg_color(s, {40, 46, 58, 255} if current else {0, 0, 0, 0})
	ui.set_next_corner_radius(s, 0)
	box := ui.build_box(s, {.Clickable, .Keyboard_Clickable, .Draw_Background, .Draw_Hot_Effects, .Draw_Active_Effects}, fmt.tprintf("###watch_row_%d_%x", id, row.key))
	sig := ui.signal_from_box(s, box)
	if ui.clicked(sig) {
		watch_row_click(app, row)
	}
	ui.push_parent(s, box)
	defer ui.pop_parent(s)
	ui.push_pref_height(s, ui.pct(1))
	defer ui.pop_pref_height(s)
	// The status strip, inset 4 points above and below.
	ui.set_next_pref_width(s, ui.px(3 * dpi)); ui.set_next_child_layout_axis(s, .Y)
	ui.push_parent(s, ui.build_box(s, {}, ""))
	ui.spacer(s, ui.px(4 * dpi))
	ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_pref_height(s, ui.pct(1, 0))
	ui.set_next_bg_color(s, STATUS_COLORS[row.status]); ui.set_next_corner_radius(s, 0)
	ui.build_box(s, {.Draw_Background}, fmt.tprintf("###watch_status_%x", row.key))
	ui.spacer(s, ui.px(4 * dpi))
	ui.pop_parent(s)
	ui.spacer(s, ui.px(7 * dpi))
	if row.section == .Media && row.media >= 0 && int(row.media) < len(pv.media.rows) {
		// The media table's row, while it is the same item (the tables are
		// published separately), inset 3 points above and below.
		m := pv.media.rows[row.media]
		side := h - 6 * dpi
		image := pv.media_images[row.media] if int(row.media) < len(pv.media_images) else {}
		if text_of(pv.media.text[:], m.name) != label {
			image = {}
		}
		ui.set_next_pref_width(s, ui.px(side)); ui.set_next_child_layout_axis(s, .Y)
		ui.push_parent(s, ui.build_box(s, {}, ""))
		ui.spacer(s, ui.px(3 * dpi))
		ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_pref_height(s, ui.px(side))
		if vg.image_id_valid(image) {
			b := ui.build_box(s, {}, fmt.tprintf("###watch_icon_%x", row.key))
			draw := new(Image_Draw, context.temp_allocator)
			draw^ = {image, {u32(m.thumb_size.x), u32(m.thumb_size.y)}}
			ui.box_equip_custom_draw(b, image_contain_draw, draw)
		} else {
			ui.set_next_bg_color(s, KIND_COLORS[m.kind])
			ui.set_next_text_align(s, .Center)
			ui.set_next_font_size(s, 10 * dpi)
			ui.set_next_corner_radius(s, 4 * dpi)
			ui.build_box(s, {.Draw_Background, .Draw_Text}, fmt.tprintf("%s###watch_icon_%x", om.MEDIA_KINDS[m.kind].tag, row.key))
		}
		ui.pop_parent(s)
		ui.spacer(s, ui.px(6 * dpi))
	}
	// Its label and detail as RAD's lister cell: at a row's height on one
	// line, the label filling what the detail (at its text's width) leaves,
	// cut before it as RAD cuts a name before its value; in a row taller
	// than 3.5 ems the detail under the label (RAD's description). Both at
	// the window's font size, the detail in the weak colour, with RAD's text
	// padding (three tenths of the font), so the detail's right padding is
	// the slack its cut, which runs to its box's end, leaves whole.
	px := s.theme.default_font_px
	pad := math.floor(ui.top_font_size(s) * 0.3)
	detail := text_of(text, row.detail)
	label_key := fmt.tprintf("%s###watch_label_%x", label, row.key)
	detail_key := fmt.tprintf("%s###watch_detail_%x", detail, row.key)
	if h > 3.5 * ui.top_font_size(s) {
		ui.set_next_pref_width(s, ui.pct(1, 0)); ui.set_next_child_layout_axis(s, .Y)
		ui.push_parent(s, ui.build_box(s, {}, ""))
		label_box := text_box(s, ui.pct(1), ui.pct(0.5), label_key, px, pad)
		ui.box_equip_fuzzy_match_ranges(label_box, fuzzy_ranges(label, filter))
		text_box(s, ui.pct(1), ui.pct(0.5), detail_key, px, pad, COLOR_TEXT_DIM)
		ui.pop_parent(s)
	} else {
		label_box := text_box(s, ui.pct(1, 0), ui.pct(1), label_key, px, pad)
		ui.box_equip_fuzzy_match_ranges(label_box, fuzzy_ranges(label, filter))
		ui.spacer(s, ui.px(ui.top_font_size(s)))
		text_box(s, ui.text_content(0, 1), ui.pct(1), detail_key, px, pad, COLOR_TEXT_DIM)
	}
	ui.spacer(s, ui.px(4 * dpi))
	return sig
}
// An image a box shows contained in it (letterboxed), drawn with ovg.
Image_Draw :: struct {
	image: vg.Image_Id,
	size:  [2]u32,
}

image_contain_draw :: proc(s: ^ui.State, box: ^ui.Box, c: ^vg.Canvas) {
	d := (^Image_Draw)(box.custom_data)
	x, y := box.rect.min.x, box.rect.min.y
	w, h := box.rect.max.x - x, box.rect.max.y - y
	if d.size.x == 0 || d.size.y == 0 || w <= 0 || h <= 0 do return
	scale := min(w / f32(d.size.x), h / f32(d.size.y))
	dw, dh := f32(d.size.x) * scale, f32(d.size.y) * scale
	dx, dy := x + (w - dw) * 0.5, y + (h - dh) * 0.5
	vg.path_reset(&s.path)
	vg.path_rect(&s.path, dx, dy, dw, dh)
	vg.fill_path(c, &s.path, vg.paint_image(d.image, dx, dy, dw, dh, 0, box.opacity))
}
