package onimite_app

import "core:fmt"
import "core:strings"
import ui "../ui"

// The preview's lister, after paf's (data/state.odin Lister, workflow and
// view lister.odin) and oasic's view picker: one modal list of options
// filtered as you type, one row shape and one accept rule. An option is a
// group, a label, a summary and the command row accepting it pushes;
// what a lister lists is its mode's row in LISTER_MODES (its catalogs, in
// order, preview_lister_catalogs.odin), built on demand from the tables the
// preview already has. The state is the mode, the panel it was opened for
// and the filter; the view keeps only a draft of the filter, the
// selection and the scroll, and pushes rows: the filter, the option
// accepted, closing.

Lister :: struct {
	// The leaf it was opened for (0: closed).
	panel: Panel_Id,
	mode:  Lister_Mode,
	query: [dynamic]u8,
}

// One option: its group (what kind of thing it is) and label, which the
// filter matches, a summary, and the row accepting it pushes. Strings are
// the catalog's tables' or on the temp allocator.
Lister_Option :: struct {
	group, label, summary: string,
	row:                   Command_Row,
}

lister_open :: proc(l: ^Lister, panel: Panel_Id, mode: Lister_Mode) {
	lister_close(l)
	l.panel, l.mode = panel, mode
}

lister_filter_set :: proc(l: ^Lister, query: string) {
	if l.panel != 0 {
		clear(&l.query)
		append(&l.query, query)
	}
}

lister_close :: proc(l: ^Lister) {
	l.panel = 0
	clear(&l.query)
}

// One option by where it lives: its catalog and its place there.
Lister_Ref :: struct {
	catalog: Lister_Catalog,
	index:   int,
}

// A mode's options as the list shows them, after onib's rows: unfiltered,
// every option of its catalogs in order, counted where they live and read
// by place (lister_ref); filtered, every option's group and label read and
// the matches ranked best first by the one matcher (fuzzy_score,
// fuzzy_rank), equal scores in their catalogs' order.
Lister_Rows :: struct {
	src:      Lister_Source,
	catalogs: []Lister_Catalog,
	counts:   [Lister_Catalog]int,
	matches:  []Lister_Ref, // with a filter
	filtered: bool,
	count:    int, // the rows shown
	total:    int, // every option
}

lister_rows :: proc(src: Lister_Source, mode: Lister_Mode, query: string) -> (r: Lister_Rows) {
	r.src, r.catalogs = src, LISTER_MODES[mode].catalogs
	for catalog in r.catalogs {
		r.counts[catalog] = LISTER_CATALOGS[catalog].count(src)
		r.total += r.counts[catalog]
	}
	r.count = r.total
	if query == "" {
		return
	}
	r.filtered = true
	found := make([dynamic]Lister_Ref, context.temp_allocator)
	scores := make([dynamic]f64, context.temp_allocator)
	for catalog in r.catalogs {
		for i in 0 ..< r.counts[catalog] {
			o := LISTER_CATALOGS[catalog].option(src, i)
			if score, ok := fuzzy_score(fmt.tprintf("%s %s", o.group, o.label), query); ok {
				append(&found, Lister_Ref{catalog, i})
				append(&scores, score)
			}
		}
	}
	order := make([]int, len(found), context.temp_allocator)
	for &o, i in order do o = i
	fuzzy_rank(scores[:], order)
	matches := make([]Lister_Ref, len(found), context.temp_allocator)
	for o, i in order do matches[i] = found[o]
	r.matches, r.count = matches, len(matches)
	return
}

// Where row `row` lives.
lister_ref :: proc(r: ^Lister_Rows, row: int) -> Lister_Ref {
	if r.filtered {
		return r.matches[row]
	}
	at := row
	for catalog in r.catalogs {
		if at < r.counts[catalog] {
			return {catalog, at}
		}
		at -= r.counts[catalog]
	}
	return {}
}

// Row `row`'s option, made now.
lister_option :: proc(r: ^Lister_Rows, row: int) -> Lister_Option {
	ref := lister_ref(r, row)
	return LISTER_CATALOGS[ref.catalog].option(r.src, ref.index)
}

// ---- the view ---------------------------------------------------------------------------

// What the lister shows that is not state: whether it was shown last
// frame, the filter being typed and the cursor in it, the selected row
// and the list it scrolls in (an overlay's: its own scroll).
Lister_View :: struct {
	shown:            bool,
	query:            [dynamic]u8,
	cursor, selected: int,
	list:             List,
}

LISTER_WIDTH :: 560
LISTER_HEIGHT :: 440
LISTER_ROW :: 28
COLOR_LISTER :: [4]u8{28, 31, 38, 255}
COLOR_LISTER_SELECTED :: [4]u8{52, 70, 104, 255}

// The open lister as a modal, as onib's query: its title, the filter, the
// rows (only those shown are made) with the filter's letters lit, and
// their count. Typing filters (Lister_Filter), Up/Down select, Enter or a
// click pushes the selected option's row and Lister_Close; Escape closes
// it (preview_keys).
lister_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32) {
	pv := &app.preview
	l := &pv.workspace.lister
	v := &pv.lister
	c := &app.commands
	if l.panel == 0 {
		v.shown = false
		return
	}
	opened := !v.shown
	if opened || string(v.query[:]) != string(l.query[:]) {
		clear(&v.query)
		append(&v.query, ..l.query[:])
		v.cursor, v.selected, v.list = len(v.query), 0, {}
	}
	v.shown = true
	mode := LISTER_MODES[l.mode]
	query := string(l.query[:])
	rows := lister_rows({&pv.watch, preview_fps(app), l.panel}, l.mode, query)

	pad := 10 * dpi
	row_h := LISTER_ROW * dpi
	title_h, field_h, footer_h := 30 * dpi, 32 * dpi, 26 * dpi
	width := min(LISTER_WIDTH * dpi, f32(s.p.width) - 24 * dpi)
	height := min(LISTER_HEIGHT * dpi, f32(s.p.height) - 24 * dpi)
	surface := ui.modal_surface_begin(s, "###lister", {open = true, width = width, height = height, background = COLOR_LISTER, border = {92, 100, 116, 255}, backdrop = {0, 0, 0, 150}, corner_radius = 6 * dpi, vertical_squish = 0.1})
	defer ui.modal_surface_end(s)
	corner := surface.panel.fixed_pos
	x, w := corner.x + pad, width - 2 * pad
	y := corner.y

	ui.set_next_font_size(s, 13 * dpi)
	cell(s, {x, y, w, title_h}, fmt.tprintf("%s###lister_title", mode.title), {.Draw_Text}, COLOR_TEXT_DIM)
	y += title_h

	before := strings.clone(string(v.query[:]), context.temp_allocator)
	place(s, {x, y, w, field_h})
	ui.set_next_font_size(s, 14 * dpi)
	field := ui.line_edit(s, &v.query, &v.cursor)
	if opened {
		s.keyboard_focus = field.box.key
	}
	changed := before != string(v.query[:])
	if changed {
		command_push(c, .Lister_Filter, {spec = string(v.query[:])})
		v.selected = 0
		list_show(&v.list, 0)
	}
	y += field_h + pad

	accept :: proc(c: ^Command_Storage, o: Lister_Option) {
		command_push(c, o.row.kind, o.row.regs)
		command_push(c, .Lister_Close)
	}
	if nav := ui.action_navigation_delta(s); nav.y != 0 {
		v.selected = clamp(v.selected + int(nav.y), 0, max(rows.count - 1, 0))
		list_show(&v.list, v.selected)
	}
	v.selected = clamp(v.selected, 0, max(rows.count - 1, 0))
	// Typing and Enter in one frame: the list is still the last filter's.
	if !changed && rows.count > 0 && ui.action_pressed(s, .Accept) {
		accept(c, lister_option(&rows, v.selected))
	}

	// The list's room at the surface's full height (it unsquishes as it
	// opens: the rows a show keeps in view are those it will have).
	list := Workspace_Rect{x, y, w, max(corner.y + height - footer_h - pad * 0.5 - y, row_h)}
	visible := max(1, int(list.height / row_h))
	first, fraction, wheel := list_begin(s, &v.list, list, "###lister_options")
	list_wheel(&v.list, wheel)
	for i in first ..< min(rows.count, first + visible + 1) {
		o := lister_option(&rows, i)
		r := Workspace_Rect{x, list.y + (f32(i - first) - fraction) * row_h, w, row_h}
		if ui.clicked(option_view(s, dpi, o, i, i == v.selected, r, query)) {
			accept(c, o)
		}
	}
	ui.pop_parent(s)
	list_limit(&v.list, rows.count, visible)

	ui.set_next_font_size(s, 11 * dpi)
	cell(s, {x, list.y + list.height, w, footer_h}, fmt.tprintf("%d of %d · Enter picks · Esc closes###lister_footer", rows.count, rows.total), {.Draw_Text}, COLOR_TEXT_DIM)
}

// One option as a row at `r`: its group as a tag and its label, the
// filter's letters lit in both, its summary dimmed at the right.
@(private = "file")
option_view :: proc(s: ^ui.State, dpi: f32, o: Lister_Option, index: int, selected: bool, r: Workspace_Rect, query: string) -> ui.Signal {
	ui.set_next_bg_color(s, COLOR_LISTER_SELECTED if selected else COLOR_LISTER)
	ui.set_next_corner_radius(s, 3 * dpi)
	sig := cell(s, r, fmt.tprintf("###lister_option_%d", index), {.Clickable, .Draw_Background, .Draw_Hot_Effects})
	group_w, pad := 84 * dpi, 11 * dpi * 0.7
	summary_w := ui.line_edit_text_width(s, o.summary, 11 * dpi) + 2 * pad
	label := Workspace_Rect{r.x + group_w, r.y, max(r.width - group_w - summary_w, 0), r.height}
	// Both columns the filter scored light their matched letters.
	match_marks(s, {r.x, r.y, group_w, r.height}, o.group, query, 11 * dpi, pad, fmt.tprintf("lister_group_%d", index))
	ui.set_next_font_size(s, 11 * dpi); ui.set_next_text_padding(s, pad)
	cell(s, {r.x, r.y, group_w, r.height}, fmt.tprintf("%s###lister_group_%d", o.group, index), {.Draw_Text, .Clip}, COLOR_TEXT_DIM)
	match_marks(s, label, o.label, query, 13 * dpi, 13 * dpi * 0.7, fmt.tprintf("lister_%d", index))
	ui.set_next_font_size(s, 13 * dpi); ui.set_next_text_padding(s, 13 * dpi * 0.7)
	cell(s, label, fmt.tprintf("%s###lister_label_%d", o.label, index), {.Draw_Text, .Clip})
	ui.set_next_font_size(s, 11 * dpi); ui.set_next_text_padding(s, pad)
	cell(s, {r.x + r.width - summary_w, r.y, summary_w, r.height}, fmt.tprintf("%s###lister_summary_%d", o.summary, index), {.Draw_Text, .Clip}, COLOR_TEXT_DIM)
	return sig
}
