package onimite_app

import "core:fmt"
import "core:math"
import "core:reflect"
import "core:strings"
import "../animation"
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
// the matches of the one matcher (fuzzy_find, RAD's) kept in their
// catalogs' order: nothing is ranked.
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
	for catalog in r.catalogs {
		for i in 0 ..< r.counts[catalog] {
			o := LISTER_CATALOGS[catalog].option(src, i)
			if fuzzy_find(lister_text(o), query) do append(&found, Lister_Ref{catalog, i})
		}
	}
	r.matches, r.count = found[:], len(found)
	return
}

// What the matcher reads of an option: its group and label, a space between.
lister_text :: proc(o: Lister_Option) -> string {return fmt.tprintf("%s %s", o.group, o.label)}

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

// What the lister shows that is not state: the lister it shows (to see it
// open again), the filter being typed with its cursor and mark, the
// selected row (the list's cursor), the list it scrolls in (an overlay's:
// its own scroll), and the box it opened from (the + it floats under, as
// RAD's query ui_key; 0: none).
Lister_View :: struct {
	shown:            bool,
	query:            [dynamic]u8,
	cursor, mark:     int,
	selected:         int,
	list:             animation.Scroll,
	anchor:           ui.Key,
}

// The open lister as RAD Debugger's floating query view (onib's
// query_draw), built before everything so it takes the pointer first and
// draws on top: placed under the box it opened from, 60 ems wide, or else
// centred in the workspace, 35% of its width, its top where an 80% tall
// view's would be, as tall as its rows (three ems each) up to that; inside
// the window either way. Inside it, laid out: its search row (the find
// icon, its title, the field), its options in the one list, and unanchored a
// footer of the keys that use it (RAD's binding buttons). It opens squished
// and clear at RAD's menu rates (faster when anchored), has the keys (Focus
// On; every panel is Off meanwhile): typing filters (Lister_Filter), the
// keys move its cursor (the list's, RAD's Nav), Enter or a click pushes the
// option's row and Lister_Close. A press outside it, or Cancel, closes it;
// unanchored, what lies beneath darkens and still takes its input.
lister_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32, content: Workspace_Rect) {
	pv := &app.preview
	l := &pv.workspace.lister
	v := &pv.lister
	c := &app.commands
	if l.panel == 0 {
		v.shown, v.anchor = false, 0
		return
	}
	reset := !v.shown
	if reset || string(v.query[:]) != string(l.query[:]) {
		clear(&v.query)
		append(&v.query, ..l.query[:])
		v.cursor, v.mark, v.selected, v.list = len(v.query), len(v.query), 0, {}
	}
	v.shown = true
	mode := LISTER_MODES[l.mode]
	query := string(l.query[:])
	rows := lister_rows({&pv.watch, preview_fps(app), l.panel}, l.mode, query)

	// RAD's rectangle: sized by its rows (and its search row) up to a limit.
	fs := ui.top_font_size(s)
	row := list_row_height(s)
	anchor := s.box_table[v.anchor] or_else nil
	width := anchor != nil ? fs * 60 : math.floor(content.width * 0.35)
	limit := anchor != nil ? fs * 80 : content.height * 0.8
	footer := anchor == nil ? fs * 4 : 0
	height := min(row * f32(rows.count + 1) + footer, limit)
	rect := Workspace_Rect{content.x + content.width / 2 - width / 2, content.y + content.height / 2 - limit / 2, width, height}
	if anchor != nil do rect.x, rect.y = anchor.rect.min.x, anchor.rect.max.y
	window := Workspace_Rect{0, 0, f32(s.p.width), f32(s.p.height)}
	rect.x += max(window.x - rect.x, 0) - max(rect.x + rect.width - (window.x + window.width), 0)
	rect.y += max(window.y - rect.y, 0) - max(rect.y + rect.height - (window.y + window.height), 0)
	// RAD's menu rates: 1 - 2^(-70 dt) a frame anchored, 1 - 2^(-50 dt) else.
	open := ui.anim_f32(s, ui.key_from_string(0, "floating_view_open_lister"), 1, {initial = 0, reset = reset, rate = anchor != nil ? MENU_RATE : MENU_SLOW_RATE})
	ui.push_focus(s, .On); defer ui.pop_focus(s)
	place(s, rect)
	ui.set_next_squish(s, 0.1 - 0.1 * open); ui.set_next_opacity(s, open)
	ui.set_next_corner_radius(s, footer > 0 ? fs : fs * 0.15)
	ui.set_next_bg_color(s, s.theme.floating); ui.set_next_border_color(s, s.theme.floating_border)
	ui.set_next_child_layout_axis(s, .Y)
	flags := ui.Box_Flags{.Clickable, .Draw_Border, .Draw_Background, .Draw_Background_Blur, .Round_Children_By_Parent, .Disable_Focus_Overlay, .Draw_Drop_Shadow}
	if anchor != nil do flags += {.Squish_Anchored}
	container := ui.build_box(s, flags, "###lister")
	// A press inside it or outside it, seen and left for the boxes it is for.
	outside := false
	for a in s.actions.rows do if !a.consumed && a.kind == .Mouse_Press && a.button == .Left && !inside(rect, a.position) do outside = true
	ui.push_parent(s, container)
	ui.push_focus(s, .Null)
	ui.push_opacity(s, open)

	// The search row: the find icon, the mode's title, the field.
	before := strings.clone(string(v.query[:]), context.temp_allocator)
	ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_pref_height(s, ui.px(row)); ui.set_next_child_layout_axis(s, .X)
	ui.push_parent(s, ui.build_box(s, {}, "###lister_search"))
	ui.push_pref_height(s, ui.pct(1))
	ui.set_next_pref_width(s, ui.px(fs * 0.5)); ui.build_box(s, {}, "")
	ui.set_next_pref_width(s, ui.px(fs * 3)); ui.set_next_icon(s, PREVIEW_ICONS[.Search]); ui.set_next_text_color(s, COLOR_TEXT_DIM)
	ui.build_box(s, {.Draw_Icon}, "###lister_icon")
	ui.set_next_pref_width(s, ui.text_content(0, 1)); ui.set_next_font_size(s, fs * 0.85); ui.set_next_text_color(s, COLOR_TEXT_DIM)
	ui.build_box(s, {.Draw_Text}, fmt.tprintf("%s###lister_title", mode.title))
	// RAD's search row lights neither its overlay nor its border.
	ui.push_focus(s, .On); ui.push_flags(s, {.Disable_Focus_Overlay, .Disable_Focus_Border})
	ui.line_edit(s, &v.query, &v.cursor, &v.mark, {.No_Background})
	ui.pop_flags(s); ui.pop_focus(s)
	ui.pop_pref_height(s)
	ui.pop_parent(s)
	changed := before != string(v.query[:])
	// Typing filters the options (in their order) and selects the first.
	if changed {
		command_push(c, .Lister_Filter, {spec = string(v.query[:])})
		v.selected = 0
		animation.scroll_to(&v.list, 0)
	}
	accept :: proc(c: ^Command_Storage, o: Lister_Option) {
		command_push(c, o.row.kind, o.row.regs)
		command_push(c, .Lister_Close)
	}
	v.selected = clamp(v.selected, 0, max(rows.count - 1, 0))

	// The options below, in the one list, its cursor (the selected row)
	// moved by the keys and kept in view.
	ui.push_focus(s, .On)
	first, last := list_begin(s, &v.list, {rect.width, max(0, rect.height - row - footer)}, "###lister_options", rows.count, row, &v.selected)
	for i in first ..< last {
		o := lister_option(&rows, i)
		if ui.clicked(option_view(s, dpi, o, i, i == v.selected, query)) {
			accept(c, o)
		}
	}
	list_end(s, &v.list)
	ui.pop_focus(s)
	// Typing and Enter in one frame: the list is still the last filter's.
	if !changed && rows.count > 0 && ui.action_pressed(s, .Accept) {
		accept(c, lister_option(&rows, v.selected))
	}

	// Unanchored, its footer: the keys that use it (RAD's binding buttons),
	// in a row padded an em above and below, centred along it.
	if footer > 0 {
		ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_pref_height(s, ui.px(footer))
		ui.set_next_child_layout_axis(s, .Y); ui.set_next_bg_color(s, s.theme.floating)
		ui.push_parent(s, ui.build_box(s, {.Draw_Background, .Draw_Border}, "###lister_footer"))
		ui.spacer(s, ui.px(fs))
		ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_pref_height(s, ui.pct(1, 0)); ui.set_next_child_layout_axis(s, .X)
		ui.push_parent(s, ui.build_box(s, {}, "###lister_footer_row"))
		ui.push_font_size(s, fs * 0.8)
		ui.push_pref_height(s, ui.pct(1))
		ui.set_next_pref_width(s, ui.pct(1, 0)); ui.build_box(s, {}, "")
		command_chip(s, .Move_Up); hint_label(s, "/"); command_chip(s, .Move_Down); hint_label(s, "to navigate")
		command_chip(s, .Accept); hint_label(s, "to use")
		command_chip(s, .Cancel); hint_label(s, "to cancel")
		ui.set_next_pref_width(s, ui.pct(1, 0)); ui.build_box(s, {}, "")
		ui.pop_pref_height(s)
		ui.pop_font_size(s)
		ui.pop_parent(s)
		ui.spacer(s, ui.px(fs))
		ui.pop_parent(s)
	}

	ui.pop_opacity(s)
	ui.pop_focus(s)
	ui.pop_parent(s)
	ui.signal_from_box(s, container)
	// Unanchored, what lies beneath darkens (RAD's inactive background), and
	// still takes its input.
	if anchor == nil {
		place(s, content); ui.set_next_bg_color(s, s.theme.inactive); ui.set_next_opacity(s, open)
		ui.build_box(s, {.Draw_Background}, "###lister_inactive")
	}
	if outside || ui.action_pressed(s, .Cancel) do command_push(c, .Lister_Close)
}

// One option as a row in the list, as RAD's lister rows: a clickable box
// holding its group as a tag and its label, the filter's letters lit in
// both, its summary dimmed at the right. The selected row is focus hot
// (RAD's cursor row: the focus overlay over it; RAD's row disables it for
// its selected cell to draw, a known difference until C8's rows have cells).
@(private = "file")
option_view :: proc(s: ^ui.State, dpi: f32, o: Lister_Option, index: int, selected: bool, query: string) -> ui.Signal {
	ui.push_focus_hot(s, selected ? .On : .Off); ui.push_focus_active(s, .Off)
	defer ui.pop_focus(s)
	ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_child_layout_axis(s, .X)
	ui.set_next_bg_color(s, {0, 0, 0, 0}) // over the floating view's blur
	ui.set_next_corner_radius(s, 0)
	box := ui.build_box(s, {.Clickable, .Draw_Background, .Draw_Hot_Effects, .Draw_Active_Effects}, fmt.tprintf("###lister_option_%d", index))
	sig := ui.signal_from_box(s, box)
	ui.push_parent(s, box)
	defer ui.pop_parent(s)
	ui.push_pref_height(s, ui.pct(1))
	defer ui.pop_pref_height(s)
	pad := 11 * dpi * 0.7
	// Where the query matched what the matcher read, lit in each column.
	matched := make([dynamic]Fuzzy_Range, context.temp_allocator)
	fuzzy_find(lister_text(o), query, &matched)
	group := text_box(s, ui.px(84 * dpi), ui.pct(1), fmt.tprintf("%s###lister_group_%d", o.group, index), 11 * dpi, pad, COLOR_TEXT_DIM)
	ui.box_equip_fuzzy_match_ranges(group, column_ranges(matched[:], 0, len(o.group)))
	label := text_box(s, ui.pct(1, 0), ui.pct(1), fmt.tprintf("%s###lister_label_%d", o.label, index), 13 * dpi, 13 * dpi * 0.7)
	ui.box_equip_fuzzy_match_ranges(label, column_ranges(matched[:], len(o.group) + 1, len(o.group) + 1 + len(o.label)))
	text_box(s, ui.text_content(0, 1), ui.pct(1), fmt.tprintf("%s###lister_summary_%d", o.summary, index), 11 * dpi, pad, COLOR_TEXT_DIM)
	return sig
}

// A command's first row in the preview's keys (its key, its modifiers).
command_binding :: proc(kind: Command_Kind) -> (Key_Binding, bool) {
	for b in PREVIEW_KEYS do if b.kind == kind do return b, true
	return {}, false
}

// A command's first key as a chip (RAD's rd_cmd_binding_buttons with a
// limit of one, not editable, as onib's).
command_chip :: proc(s: ^ui.State, kind: Command_Kind) {
	if b, ok := command_binding(kind); ok do binding_chip(s, b)
}

// A binding as a chip: its modifiers and key, joined by " + ".
binding_chip :: proc(s: ^ui.State, b: Key_Binding) {
	parts := make([dynamic]string, context.temp_allocator)
	if .Control in b.mods do append(&parts, "Ctrl")
	if .Shift in b.mods do append(&parts, "Shift")
	if .Alt in b.mods do append(&parts, "Alt")
	#partial switch b.key {
	case .Enter:
		append(&parts, "Return")
	case .Escape:
		append(&parts, "Esc")
	case:
		name, _ := reflect.enum_name_from_value(b.key)
		append(&parts, name)
	}
	fs := ui.top_font_size(s)
	ui.set_next_pref_width(s, ui.px(fs)); ui.build_box(s, {}, "")
	ui.set_next_text_align(s, .Center); ui.set_next_corner_radius(s, fs * 0.5)
	ui.set_next_pref_width(s, ui.text_content(fs, 1))
	ui.build_box(s, {.Draw_Text, .Draw_Hot_Effects, .Draw_Active_Effects, .Draw_Border, .Draw_Background}, fmt.tprintf("%s###bind_btn_%v_%v", strings.join(parts[:], " + ", context.temp_allocator), b.kind, b.key))
}

@(private = "file")
hint_label :: proc(s: ^ui.State, text: string) {
	ui.set_next_pref_width(s, ui.text_content(ui.top_font_size(s) * 0.5, 1)); ui.set_next_text_color(s, COLOR_TEXT_DIM)
	ui.build_box(s, {.Draw_Text}, fmt.tprintf("%s##hint", text))
}
