package onimite_app

import "core:fmt"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
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

// The options of `mode` for a lister opened for leaf `panel`: its
// catalogs' in order.
lister_options :: proc(src: Lister_Source, mode: Lister_Mode, out: ^[dynamic]Lister_Option) {
	for catalog in LISTER_MODES[mode].catalogs {
		LISTER_CATALOGS[catalog](src, out)
	}
}

// The options matching `query`, ranked: those whose group and label start
// with it, then those with a word starting with it, then the rest that
// have its characters in order, each in the options' order.
lister_filter :: proc(options: []Lister_Option, query: string, out: ^[dynamic]Lister_Option) {
	ranks := make([]Match_Rank, len(options), context.temp_allocator)
	for o, i in options {
		ranks[i] = match_rank(fmt.tprintf("%s %s", o.group, o.label), query)
	}
	for rank in Match_Rank.Prefix ..= Match_Rank.Scattered {
		for o, i in options {
			if ranks[i] == rank {
				append(out, o)
			}
		}
	}
}

// How a text matches a filter, best first.
Match_Rank :: enum u8 {
	Prefix, // the text starts with it (an empty filter matches every text so)
	Word, // a word in the text starts with it
	Scattered, // its characters are in the text in order
	None,
}

// How `text` matches `query`, ignoring case.
match_rank :: proc(text, query: string) -> Match_Rank {
	if starts_with_fold(text, query) {
		return .Prefix
	}
	word :: proc(r: rune) -> bool {return unicode.is_letter(r) || unicode.is_digit(r)}
	previous: rune = ' '
	for r, i in text {
		if word(r) && !word(previous) && starts_with_fold(text[i:], query) {
			return .Word
		}
		previous = r
	}
	return .Scattered if in_order_fold(text, query) else .None
}

// Whether `s` starts with `prefix`, ignoring case.
@(private = "file")
starts_with_fold :: proc(s, prefix: string) -> bool {
	rest := s
	for p in prefix {
		r, n := utf8.decode_rune(rest)
		if n == 0 || unicode.to_lower(r) != unicode.to_lower(p) {
			return false
		}
		rest = rest[n:]
	}
	return true
}

// Whether the characters of `needle` are in `haystack` in order, ignoring
// case (paf's fuzzy_match, oasic's text_matches).
@(private = "file")
in_order_fold :: proc(haystack, needle: string) -> bool {
	remaining := needle
	for r in haystack {
		if len(remaining) == 0 {
			return true
		}
		next, n := utf8.decode_rune(remaining)
		if unicode.to_lower(r) == unicode.to_lower(next) {
			remaining = remaining[n:]
		}
	}
	return len(remaining) == 0
}

// ---- the view ---------------------------------------------------------------------------

// What the lister shows that is not state: whether it was shown last
// frame, the filter being typed and the cursor in it, the selected option
// (among those matching) and the first row shown.
Lister_View :: struct {
	shown:                   bool,
	query:                   [dynamic]u8,
	cursor, selected, first: int,
}

LISTER_WIDTH :: 560
LISTER_HEIGHT :: 440
LISTER_ROW :: 28
COLOR_LISTER :: [4]u8{28, 31, 38, 255}
COLOR_LISTER_SELECTED :: [4]u8{52, 70, 104, 255}

// The open lister as a modal: its title, the filter, the matching options
// and their count. Typing filters, Up/Down and Page Up/Down select, Enter
// or a click accepts, Escape (Dismiss) closes.
lister_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32) {
	pv := &app.preview
	ws := &pv.workspace
	l := &ws.lister
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
		v.cursor, v.selected, v.first = len(v.query), 0, 0
	}
	v.shown = true
	mode := LISTER_MODES[l.mode]
	options := make([dynamic]Lister_Option, context.temp_allocator)
	lister_options({&pv.watch, preview_fps(app), l.panel}, l.mode, &options)

	pad := 10 * dpi
	row_h := LISTER_ROW * dpi
	title_h, field_h, footer_h := 30 * dpi, 32 * dpi, 26 * dpi
	chrome := title_h + field_h + footer_h + 2 * pad + 8 * dpi
	height := min(LISTER_HEIGHT * dpi, f32(s.p.height) - 24 * dpi)
	ui.modal_surface_begin(s, "###lister", {width = min(LISTER_WIDTH * dpi, f32(s.p.width) - 24 * dpi), height = height, background = COLOR_LISTER, backdrop = {0, 0, 0, 150}, corner_radius = 6 * dpi, vertical_squish = 0.1})
	defer ui.modal_surface_end(s)

	ui.set_next_pref_width(s, ui.fill())
	ui.set_next_pref_height(s, ui.px(title_h))
	ui.set_next_font_size(s, 13 * dpi)
	ui.set_next_text_padding(s, pad)
	ui.set_next_text_color(s, COLOR_TEXT_DIM)
	ui.build_box(s, {.Draw_Text}, fmt.tprintf("%s###lister_title", mode.title))

	inset_row(s, "lister_field", field_h, pad)
	before := strings.clone(string(v.query[:]), context.temp_allocator)
	ui.set_next_pref_height(s, ui.px(field_h))
	ui.set_next_font_size(s, 14 * dpi)
	ui.set_next_text_padding(s, 8 * dpi)
	field := ui.line_edit(s, "###lister_query", &v.query, &v.cursor, "Type to filter")
	if opened {
		s.keyboard_focus = field.box.key
	}
	inset_row_end(s, pad)
	changed := before != string(v.query[:])
	if changed {
		command_push(c, .Lister_Filter, {spec = string(v.query[:])})
		v.selected, v.first = 0, 0
	}

	matches := make([dynamic]Lister_Option, context.temp_allocator)
	lister_filter(options[:], string(l.query[:]), &matches)
	list_h := max(height - chrome + 8 * dpi, row_h)
	visible := max(1, int((list_h - 6) / row_h))
	step := ui.action_list_step(s, visible)
	v.selected = clamp(v.selected + step, 0, max(len(matches) - 1, 0))
	accept :: proc(c: ^Command_Storage, o: Lister_Option) {
		command_push(c, o.row.kind, o.row.regs)
		command_push(c, .Lister_Close)
	}
	// Typing and Enter in one frame: the list is still the last filter's.
	if !changed && len(matches) > 0 && ui.action_key_take(s, .Enter) {
		accept(c, matches[v.selected])
	}

	ui.spacer(s, ui.px(pad))
	inset_row(s, "lister_list", list_h, pad)
	ui.set_next_pref_height(s, ui.px(list_h))
	list := ui.scroll_list_begin(s, "###lister_options")
	if !ui.list_scroll_apply(&v.first, list.scroll, visible, len(matches)) && step != 0 {
		ui.list_scroll_contain_selection(&v.first, v.selected, visible, len(matches))
	}
	first, fraction := ui.scroll_page(s, list.box.key, v.first)
	ui.set_next_fixed_y(s, -fraction * row_h)
	ui.set_next_pref_width(s, ui.fill())
	ui.set_next_pref_height(s, ui.px(row_h * f32(visible + 1)))
	ui.column(s, "lister_rows")
	for o, i in matches[min(first, len(matches)):min(first + visible + 1, len(matches))] {
		if ui.clicked(option_view(s, dpi, o, first + i, first + i == v.selected)) {
			accept(c, o)
		}
	}
	ui.pop_parent(s)
	ui.scroll_list_end(s)
	inset_row_end(s, pad)

	ui.set_next_pref_width(s, ui.fill())
	ui.set_next_pref_height(s, ui.px(footer_h))
	ui.set_next_font_size(s, 11 * dpi)
	ui.set_next_text_padding(s, pad)
	ui.set_next_text_color(s, COLOR_TEXT_DIM)
	ui.build_box(s, {.Draw_Text}, fmt.tprintf("%d of %d · Enter picks · Esc closes###lister_footer", len(matches), len(options)))
}

// One option as a row: its group as a tag, its label, its summary dimmed
// at the right.
@(private = "file")
option_view :: proc(s: ^ui.State, dpi: f32, o: Lister_Option, index: int, selected: bool) -> ui.Signal {
	ui.set_next_pref_width(s, ui.fill())
	ui.set_next_pref_height(s, ui.px(LISTER_ROW * dpi))
	ui.set_next_child_layout_axis(s, .X)
	ui.set_next_bg_color(s, COLOR_LISTER_SELECTED if selected else COLOR_LISTER)
	ui.set_next_corner_radius(s, 3 * dpi)
	item := ui.build_box(s, {.Clickable, .Draw_Background, .Draw_Hot_Effects}, fmt.tprintf("###lister_option_%d", index))
	sig := ui.signal_from_box(s, item)
	ui.push_parent(s, item)
	defer ui.pop_parent(s)
	cell :: proc(s: ^ui.State, text, key: string, width: ui.Size, px: f32, color: Maybe([4]u8) = nil) {
		ui.set_next_pref_width(s, width)
		ui.set_next_pref_height(s, ui.fill())
		ui.set_next_font_size(s, px)
		ui.set_next_text_padding(s, px * 0.7)
		if c, ok := color.?; ok {
			ui.set_next_text_color(s, c)
		}
		ui.build_box(s, {.Draw_Text, .Clip}, fmt.tprintf("%s###%s", text, key))
	}
	cell(s, o.group, "group", ui.px(84 * dpi), 11 * dpi, COLOR_TEXT_DIM)
	cell(s, o.label, "label", ui.fill(), 13 * dpi)
	cell(s, o.summary, "summary", ui.text_content(), 11 * dpi, COLOR_TEXT_DIM)
	return sig
}

// A row `h` high with a `pad` gap at each side, pushed as parent for what
// goes between (end it with inset_row_end).
@(private = "file")
inset_row :: proc(s: ^ui.State, key: string, h, pad: f32) {
	ui.set_next_pref_width(s, ui.fill())
	ui.set_next_pref_height(s, ui.px(h))
	ui.row(s, key)
	ui.spacer(s, ui.px(pad))
}

@(private = "file")
inset_row_end :: proc(s: ^ui.State, pad: f32) {
	ui.spacer(s, ui.px(pad))
	ui.pop_parent(s)
}
