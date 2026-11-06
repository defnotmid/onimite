package onimite_app

import "core:fmt"
import "core:math"
import "core:strings"
import om "../onimite"
import platform "../platform"
import ui "../ui"
import vg "deps:ovg"

// A Watch view: RAD Debugger's watch window, after onib's watch_draw. Its
// rows are the evaluator's (eval_rows.odin): each an expression with a
// typed value, shown as its label (the expression, a member's name, a row's
// name) and its value's text (value_text, which words a row as items.odin
// does), opening into its members or rows where its expander is pressed (a
// pointing hand over it, RAD's ui_expander). A Watch tab on one of the
// video's tables (`video:scenes`; D, I, the status line and the + lister
// open them) is scoped: the table's rows are its top level, each with its
// status as a colour and a media file's thumbnail, the tab titled by their
// count in their worst status's colour. An expression Watch (the + lister's
// "Watch") holds the expressions you type, each a top-level row, with RAD's
// keys: typing or pasting on its last row, or a click on it, adds one; on
// an expression's row (or a click on it, or Enter) edits it; Enter commits,
// Escape cancels, Up or Down commits and moves; Delete removes it, Ctrl+C
// copies a row's expression, Alt+Up and Alt+Down move an expression. A
// click on another row with a frame (or Enter on it) goes there; N /
// Shift+N go to the next / previous row with a warning or an error
// (`Problem_Step`). Only the visible rows build boxes. A media file with a
// view (preview_media_views.odin) unfolds into it, one item across its rows.
// A row dragged out of itself goes out as a tab (row_drag_out).

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
STATUS_COLORS := [Status][4]u8 {
	.Ok      = {72, 160, 110, 255},
	.Info    = {110, 118, 132, 255},
	.Warning = COLOR_WARNING,
	.Error   = COLOR_ERROR,
}

// An expression being typed in a Watch (one at a time, as RAD's watch
// edits a cell): the view, the expression's place (one past the last: a new
// one) and its text with its cursor and mark.
Watch_Edit :: struct {
	view:         View_Id,
	input:        int,
	text:         [dynamic]u8,
	cursor, mark: int,
	started:      bool, // it began this frame: its field is drawn from the next (onib's `focus`)
}

// What a view's rows are made from.
watch_rows_source :: proc(v: ^View_Record) -> Watch_Rows_Source {
	return {inputs = v.inputs[:], scoped = v.scoped, filter = string(v.filter[:]), expanded = v.expanded[:]}
}

// The evaluator's reader over the preview's copies of the tables.
preview_reader :: proc(app: ^App_State) -> Reader {
	return {tables = &app.preview.tables, waves = &app.preview.waves}
}

// A Watch's rows, laid out (frame-lived).
watch_blocks :: proc(app: ^App_State, v: ^View_Record) -> View_Blocks {
	return view_blocks(preview_reader(app), watch_rows_source(v))
}

// A Watch's tab title: a tab's, its table's title and its rows' count, in
// its worst status's colour when that is a warning or an error (alpha 0:
// the theme's); an expression Watch's, "Watch".
watch_title :: proc(app: ^App_State, v: ^View_Record) -> (title: string, color: [4]u8) {
	if !v.scoped || len(v.inputs) == 0 do return "Watch", {}
	r := preview_reader(app)
	value, error := evaluate(&r, v.inputs[0].source)
	if error != "" do return v.inputs[0].source, COLOR_ERROR
	// A tab on one row (pulled out of the timeline): the row's name.
	if value.kind in ROW_KINDS do return row_label(&r, value), {}
	count := collection(value).info(&r, value, "").count
	if worst := r.tables.worst[value.kind]; count > 0 && worst >= .Warning do color = STATUS_COLORS[worst]
	return fmt.tprintf("%s %d", KINDS[value.kind].title, count), color
}

// A Watch view, laid out in its panel's content (`area`, from the panel
// tree): the filter row (Search), then its rows in the one scroll list, a
// row tall each (list_row_height), with RAD's list keyboard model while its
// panel is focused: the keys move its cursor row (focus hot: the focus
// overlay), Enter on it acts as a click. Its own keys come first (RAD's
// watch takes its events before it builds), then its rows. A press on any
// of it focuses its panel (RAD's table-wide press).
watch_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32, id: View_Id, area: Workspace_Rect) {
	pv := &app.preview
	v := workspace_view(&pv.workspace, id)
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

	filter_h := view_header(app, s, id, dpi)
	r := preview_reader(app)
	blocks := watch_blocks(app, v)
	filter := string(v.filter[:])
	adds := !v.scoped
	count := blocks.total + int(adds)
	if count == 0 {
		empty := "No rows match."
		if filter == "" && len(v.inputs) > 0 {
			value, _ := evaluate(&r, v.inputs[0].source)
			empty = KINDS[value.kind].empty
		}
		text_box(s, ui.pct(1), ui.px(24 * dpi), fmt.tprintf("%s###watch_none_%d", empty, id), 13 * dpi, 10 * dpi, COLOR_TEXT_DIM)
		return
	}
	row_h := list_row_height(s)
	l := view_list(pv, id)
	l.cursor = clamp(l.cursor, 0, blocks_item_from_row(&blocks, count - 1))
	edit := &pv.watch_edit
	ui.push_focus(s, .On)
	if ui.is_focus_active(s) {
		watch_keys(app, s, id, v, &blocks, l)
	} else if edit.view == id {
		// Leaving it (its panel losing the keys) commits it.
		watch_commit(app, v)
	}
	current := watch_current(app, &blocks)
	first, last := view_list_begin(app, s, {area.width, area.height - filter_h}, id, fmt.tprintf("###watch_rows_%d", id), count, row_h, &l.cursor, watch_row_blocks(&blocks, int(adds)))
	rows := make([dynamic]View_Row, context.temp_allocator)
	blocks_window(&blocks, first, last - first, &rows)
	drawn := false
	at := first
	for row in rows {
		num := at
		at += row.size > 0 ? row.size - row.skip - row.chop : 1
		item := blocks_item_from_row(&blocks, num)
		if row.size > 0 {
			sig := watch_visualizer_view(app, s, id, row, row_h, area.width - ui.scroll_bar_width(s), item == l.cursor)
			if ui.pressed(sig) do l.cursor = item
			continue
		}
		// (a comma list's expression is typed on its first item's row)
		editing := edit.view == id && row.root && edit.input == row.input && !v.scoped && row.key == item_key(v.inputs[row.input], 0)
		drawn ||= editing
		sig := watch_row_view(app, s, dpi, id, row, row_h, num == current, item == l.cursor, filter, editing)
		// A press puts the cursor on its row (RAD's).
		if ui.pressed(sig) do l.cursor = item
		if !editing && row.error == "" do row_drag_out(app, s, sig, id, row_view_key(row.key), row.source, row.value)
		// (a drag let go on its own row is no click on it)
		if !ui.clicked(sig) || editing || pv.drag != .Null do continue
		if row.root && !v.scoped {
			watch_edit_begin(app, id, row.input, v.inputs[row.input].source)
		} else if f := row_frame(&r, row.value); f >= 0 {
			command_push(&app.commands, .Go_To, {count = f})
		}
	}
	// The last row of an expression Watch takes a new expression.
	if adds && last == count {
		item := blocks_item_from_row(&blocks, count - 1)
		editing := edit.view == id && edit.input >= len(v.inputs)
		drawn ||= editing
		sig := watch_add_view(app, s, dpi, id, row_h, item == l.cursor, editing)
		if ui.pressed(sig) do l.cursor = item
		if ui.clicked(sig) && !editing do watch_edit_begin(app, id, len(v.inputs), "")
	}
	view_list_end(app, s, id)
	ui.pop_focus(s)
	// Its row gone (scrolled away, or its expression removed), the edit
	// goes; one a click began is drawn from the next frame.
	if edit.view == id && !drawn && !edit.started do edit.view = 0
	if edit.view == id {edit.started = false; s.text_edit_mode = true}
}

// The Watch's own keys, while its panel has them, on its cursor row (RAD's
// watch view's table events, raddbg_core.c:2640-3260): editing, Enter
// commits, Escape cancels and Up or Down commits (the list then moves);
// else on an expression's row or the last one typing or a paste begins
// editing (the line edit then takes the text over its whole selection), and
// on an expression's row Delete removes it and Alt+Up or Alt+Down move it,
// the cursor with it; Ctrl+C copies the cursor row's expression.
@(private = "file")
watch_keys :: proc(app: ^App_State, s: ^ui.State, id: View_Id, v: ^View_Record, blocks: ^View_Blocks, l: ^View_List) {
	edit := &app.preview.watch_edit
	s_rows := make([dynamic]View_Row, context.temp_allocator)
	at := blocks_row_from_item(blocks, l.cursor)
	if at < blocks.total do blocks_window(blocks, at, 1, &s_rows)
	row: Maybe(View_Row) = s_rows[0] if len(s_rows) > 0 else nil
	on_add := !v.scoped && at >= blocks.total
	root, has_root := row.?
	editable := has_root && root.root && !v.scoped
	if edit.view == id || on_add || editable do s.text_edit_mode = true
	for &a in s.actions.rows {
		if a.consumed do continue
		if edit.view == id {
			#partial switch a.kind {
			case .Press:
				if a.slot == .Accept {a.consumed = true; watch_commit(app, v)}
				if a.slot == .Cancel {a.consumed = true; edit.view = 0}
			case .Navigate:
				if a.delta.y != 0 do watch_commit(app, v) // the list moves its cursor
			}
			continue
		}
		#partial switch a.kind {
		case .Text:
			if on_add || editable do watch_edit_begin(app, id, on_add ? len(v.inputs) : root.input, on_add ? "" : v.inputs[root.input].source)
		case .Edit:
			if .Copy in a.flags && has_root {
				a.consumed = true
				platform.set_clipboard(root.source)
			} else if .Delete in a.flags && editable {
				a.consumed = true
				command_push(&app.commands, .Watch_Input_Remove, {view = id, count = root.input})
			}
		case .Navigate:
			if .Reorder not_in a.flags || !editable do continue
			a.consumed = true
			to := root.input + (a.delta.y < 0 ? -1 : 1)
			if to < 0 || to >= len(v.inputs) do continue
			// The cursor follows it: to where the expression before it starts,
			// or as far down as the one after it has items.
			start :: proc(b: ^View_Blocks, v: ^View_Record, k: int) -> int {
				return blocks_item_from_row(b, k < len(v.inputs) ? blocks_index(b, item_key(v.inputs[k], 0)) : b.total)
			}
			if to < root.input {
				l.cursor = start(blocks, v, to)
			} else {
				l.cursor += start(blocks, v, to + 1) - start(blocks, v, to)
			}
			command_push(&app.commands, .Watch_Input_Move, {view = id, count = root.input, option = to})
		}
	}
}

// Starts typing expression `input` of Watch `id` from `text`, all of it
// selected (RAD's edits start so); one open elsewhere commits first.
@(private = "file")
watch_edit_begin :: proc(app: ^App_State, id: View_Id, input: int, text: string) {
	edit := &app.preview.watch_edit
	if edit.view != 0 && edit.view != id {
		if other := workspace_view(&app.preview.workspace, edit.view); other != nil do watch_commit(app, other)
	}
	edit.view, edit.input, edit.started = id, input, true
	clear(&edit.text)
	append(&edit.text, text)
	edit.cursor, edit.mark = len(edit.text), 0
}

// Ends the edit, sending what changed: a new expression (not empty), or an
// expression's new text.
@(private = "file")
watch_commit :: proc(app: ^App_State, v: ^View_Record) {
	edit := &app.preview.watch_edit
	id := edit.view
	edit.view = 0
	text := string(edit.text[:])
	if edit.input >= len(v.inputs) {
		if text != "" do command_push(&app.commands, .Watch_Input_Add, {view = id, count = edit.input, spec = text})
	} else if text != v.inputs[edit.input].source {
		command_push(&app.commands, .Watch_Input_Set, {view = id, count = edit.input, spec = text})
	}
}

// The row the playhead is in: of the top-level rows that have frames, the
// last starting at or before it (-1: none). A scoped Watch's top level is
// its collections' rows, read by their table rows (no row built).
@(private = "file")
watch_current :: proc(app: ^App_State, blocks: ^View_Blocks) -> int {
	pv := &app.preview
	current, at, n := -1, -1, 0
	consider :: proc(r: ^Reader, v: Value, num, frame: int, current, at: ^int) {
		f := row_frame(r, v)
		if f >= 0 && f <= frame && (current^ < 0 || f >= at^) do current^, at^ = num, f
	}
	for sp in blocks.spans {
		if sp.block < 0 {
			for i in sp.lo ..< sp.hi do consider(&blocks.r, blocks.tops[i].value, n + i - sp.lo, pv.frame, &current, &at)
		} else if k := &blocks.blocks[sp.block]; k.row.depth == -1 && k.info.of != .Invalid {
			for num in sp.lo ..< sp.hi {
				row := info_row(&k.info, num)
				consider(&blocks.r, {kind = k.info.of, ref = {k.info.of, row}}, n + num - sp.lo, pv.frame, &current, &at)
			}
		}
		n += sp.hi - sp.lo
	}
	return current
}

// One row, `h` tall, laid out in the list as RAD's cell (raddbg_widgets.c
// rd_cell): a clickable box (keyboard clickable: the cursor row's Enter is
// its click; focus hot, it lights the focus overlay) holding its status
// strip (a row's; a member's none), its depth's indent (an em each), its
// expander (pressed, Watch_Expand; a pointing hand) or the room of one, a
// media file's thumbnail or kind, its label (the filter's letters lit on
// the top level; typed, the line edit) and its value's text, or its error.
// Its parts take the pointer before it does: the box's signal comes last.
// It fades in as it appears (RAD Debugger's alive_t, at its entity-alive
// rate), keyed by what it is.
@(private = "file")
watch_row_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32, id: View_Id, row: View_Row, h: f32, current, cursor: bool, filter: string, editing: bool) -> ui.Signal {
	pv := &app.preview
	r := preview_reader(app)
	v := row.value
	alive := ui.anim_f32(s, ui.key_from_string(0, fmt.tprintf("watch_%d_%s_alive", id, row.key)), 1, {initial = 0, rate = ALIVE_RATE})
	ui.push_opacity(s, alive)
	defer ui.pop_opacity(s)
	ui.push_focus_hot(s, cursor ? .On : .Off); ui.push_focus_active(s, editing ? .Null : .Off)
	defer ui.pop_focus(s)
	ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_child_layout_axis(s, .X)
	ui.set_next_bg_color(s, {40, 46, 58, 255} if current else {0, 0, 0, 0})
	ui.set_next_corner_radius(s, 0)
	box := ui.build_box(s, {.Clickable, .Keyboard_Clickable, .Draw_Background, .Draw_Hot_Effects, .Draw_Active_Effects}, fmt.tprintf("###watch_row_%d_%s", id, row.key))
	ui.push_parent(s, box)
	ui.push_pref_height(s, ui.pct(1))
	fs := ui.top_font_size(s)
	// The status strip, inset 4 points above and below: a row's status.
	ui.set_next_pref_width(s, ui.px(3 * dpi)); ui.set_next_child_layout_axis(s, .Y)
	ui.push_parent(s, ui.build_box(s, {}, ""))
	ui.spacer(s, ui.px(4 * dpi))
	if v.kind in ROW_KINDS {
		ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_pref_height(s, ui.pct(1, 0))
		ui.set_next_bg_color(s, STATUS_COLORS[row_status(&r, v)]); ui.set_next_corner_radius(s, 0)
		ui.build_box(s, {.Draw_Background}, fmt.tprintf("###watch_status_%d_%s", id, row.key))
	}
	ui.pop_parent(s)
	ui.spacer(s, ui.px(4 * dpi))
	// Its depth's indent, an em a level (RAD's cell indent).
	if row.depth > 0 do ui.spacer(s, ui.px(math.floor(fs) * f32(row.depth)))
	// The expander, or its room: RAD's ui_expander (a pointing hand, the
	// open state on a press).
	expander := math.floor(fs * 1.5)
	if row.unfolds {
		// (outside the row's focus, as RAD's: the cursor row lights the row, not it)
		icons := PREVIEW_ICONS
		ui.push_focus(s, .Off)
		ui.set_next_pref_width(s, ui.px(expander)); ui.set_next_hover_cursor(s, .Hand_Point)
		ui.set_next_icon(s, icons[.Expanded if row.expanded else .Collapsed]); ui.set_next_text_color(s, COLOR_TEXT_DIM)
		ui.set_next_visual_margin(s, {math.floor(fs * 0.3), math.floor((h - fs) / 2)})
		if ui.pressed(ui.signal_from_box(s, ui.build_box(s, {.Clickable, .Draw_Icon}, fmt.tprintf("###watch_expander_%d_%s", id, row.key)))) {
			command_push(&app.commands, .Watch_Expand, {view = id, spec = row.key})
		}
		ui.pop_focus(s)
	} else {
		ui.spacer(s, ui.px(expander))
	}
	if v.kind == .Media_File do watch_thumb(app, s, dpi, h, pv.tables.media[v.ref.row], row.key)
	// Its label and value as RAD's lister cell: at a row's height on one
	// line, the label filling what the value (at its text's width) leaves,
	// cut before it as RAD cuts a name before its value; in a row taller
	// than 3.5 ems the value under the label (RAD's description). Both at
	// the window's font size, the value in the weak colour (an error in the
	// error colour), with RAD's text padding (three tenths of the font).
	px := s.theme.default_font_px
	pad := math.floor(fs * 0.3)
	detail := row.error if row.error != "" else value_text(&r, v)
	label_key := fmt.tprintf("%s###watch_label_%d_%s", row.label, id, row.key)
	detail_key := fmt.tprintf("%s###watch_detail_%d_%s", detail, id, row.key)
	detail_color := COLOR_ERROR if row.error != "" else COLOR_TEXT_DIM
	tall := h > 3.5 * fs
	if tall {
		ui.set_next_pref_width(s, ui.pct(1, 0)); ui.set_next_child_layout_axis(s, .Y)
		ui.push_parent(s, ui.build_box(s, {}, ""))
	}
	if editing {
		ui.set_next_pref_width(s, ui.pct(1, 0) if !tall else ui.pct(1)); ui.set_next_pref_height(s, ui.pct(0.5) if tall else ui.pct(1))
		watch_line_edit(app, s)
	} else {
		label_box := text_box(s, ui.pct(1) if tall else ui.pct(1, 0), ui.pct(0.5) if tall else ui.pct(1), label_key, px, pad)
		if row.depth <= 0 do ui.box_equip_fuzzy_match_ranges(label_box, fuzzy_ranges(row.label, filter))
	}
	if tall {
		text_box(s, ui.pct(1), ui.pct(0.5), detail_key, px, pad, detail_color)
		ui.pop_parent(s)
	} else {
		ui.spacer(s, ui.px(fs))
		text_box(s, ui.text_content(0, 1), ui.pct(1), detail_key, px, pad, detail_color)
	}
	ui.spacer(s, ui.px(4 * dpi))
	ui.pop_pref_height(s)
	ui.pop_parent(s)
	return ui.signal_from_box(s, box)
}

// The list's row blocks (RAD's): a visualizer's rows one item, the rest a
// row an item, and an expression Watch's last row (`adds`).
@(private = "file")
watch_row_blocks :: proc(b: ^View_Blocks, adds: int) -> []ui.Scroll_List_Row_Block {
	out := make([dynamic]ui.Scroll_List_Row_Block, 0, len(b.spans) + 1, context.temp_allocator)
	for s in b.spans {
		n := s.hi - s.lo
		append(&out, ui.Scroll_List_Row_Block{n, s.block >= 0 && b.blocks[s.block].rows > 0 ? 1 : n})
	}
	if adds > 0 do append(&out, ui.Scroll_List_Row_Block{adds, adds})
	return out[:]
}

// A visualizer's row, as RAD's view cell (raddbg_core.c:4048-4076): a cell
// as tall as what of it is in the window, holding a clipping box of all its
// rows, floated up by those above the window, the view inside. It fades in
// as a row does. Its signal is its view's, which takes the pointer.
@(private = "file")
watch_visualizer_view :: proc(app: ^App_State, s: ^ui.State, id: View_Id, row: View_Row, h, width: f32, cursor: bool) -> ui.Signal {
	key := fmt.tprintf("watch_%d_%s", id, row.key)
	alive := ui.anim_f32(s, ui.key_from_string(0, fmt.tprintf("%s_alive", key)), 1, {initial = 0, rate = ALIVE_RATE})
	ui.push_opacity(s, alive)
	defer ui.pop_opacity(s)
	ui.push_focus_hot(s, cursor ? .On : .Off); ui.push_focus_active(s, .Off)
	defer ui.pop_focus(s)
	ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_pref_height(s, ui.px(math.floor(f32(row.size - row.skip - row.chop) * h)))
	ui.push_parent(s, ui.build_box(s, {}, fmt.tprintf("###cell_%s", key)))
	defer ui.pop_parent(s)
	dim := [2]f32{width, f32(row.size) * h}
	r := preview_reader(app)
	lens, _ := visualizer_of(&r, row.value)
	ui.set_next_fixed_x(s, 0); ui.set_next_fixed_y(s, -f32(row.skip) * h)
	ui.set_next_fixed_width(s, dim.x); ui.set_next_fixed_height(s, dim.y)
	// (a sound's takes Accept on the cursor: its player's play and pause)
	flags: ui.Box_Flags = {.Clip, .Clickable}
	if lens == .Audio do flags += {.Keyboard_Clickable}
	box := ui.build_box(s, flags, fmt.tprintf("###val_%s", key))
	ui.push_parent(s, box)
	defer ui.pop_parent(s)
	// (outside its focus, as the expander's: the cursor lights the cell)
	ui.push_focus(s, .Off)
	defer ui.pop_focus(s)
	// Its view: a view like a tab's, its row's until it is dragged out. It
	// is made (and follows the row's expression, and is kept once the row shows
	// it) by a command, so the frame that asks draws an empty cell.
	ws := &app.preview.workspace
	row_id := row_view_key(strings.trim_suffix(row.key, "/v"))
	view_id := workspace_row_view(ws, id, row_id)
	view := workspace_view(ws, view_id)
	if view == nil || view.transient || view.inputs[0].source != row.source {
		command_push(&app.commands, .Row_View_Open, {view = id, row = row_id, view_kind = VISUALIZER_VIEWS[lens], spec = row.source})
	}
	if view == nil do return ui.signal_from_box(s, box)
	file := r.tables.media[row.value.ref.row].id
	sig: ui.Signal
	switch lens {
	case .Image:
		sig = bitmap_view(app, s, &view.bitmap, file, key, dim, false)
	case .Audio:
		sig = audio_view(app, s, file, key, dim)
	}
	if ui.keyboard_pressed(ui.signal_from_box(s, box)) do solo_toggle(app, file)
	return sig
}

// An expression Watch's last row: where a new expression is typed, blank
// until then (RAD's empty last row).
@(private = "file")
watch_add_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32, id: View_Id, h: f32, cursor, editing: bool) -> ui.Signal {
	ui.push_focus_hot(s, cursor ? .On : .Off); ui.push_focus_active(s, editing ? .Null : .Off)
	defer ui.pop_focus(s)
	ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_child_layout_axis(s, .X)
	ui.set_next_bg_color(s, {0, 0, 0, 0})
	ui.set_next_corner_radius(s, 0)
	box := ui.build_box(s, {.Clickable, .Keyboard_Clickable, .Draw_Background, .Draw_Hot_Effects, .Draw_Active_Effects}, fmt.tprintf("###watch_add_%d", id))
	ui.push_parent(s, box)
	ui.push_pref_height(s, ui.pct(1))
	fs := ui.top_font_size(s)
	ui.spacer(s, ui.px(7 * dpi + math.floor(fs * 1.5)))
	if editing {
		ui.set_next_pref_width(s, ui.pct(1, 0))
		watch_line_edit(app, s)
	}
	ui.spacer(s, ui.px(4 * dpi))
	ui.pop_pref_height(s)
	ui.pop_parent(s)
	return ui.signal_from_box(s, box)
}

// The expression being typed: the UI's line edit (RAD's UI_TxtOp edits,
// cursor and mark), with the keys (focus on).
@(private = "file")
watch_line_edit :: proc(app: ^App_State, s: ^ui.State) {
	edit := &app.preview.watch_edit
	ui.push_focus(s, .On)
	ui.line_edit(s, &edit.text, &edit.cursor, &edit.mark, {.No_Background})
	ui.pop_focus(s)
}

// A media file's thumbnail (the media table's row, while it is the same
// file: the tables are published separately), or its kind's tag, inset 3
// points above and below.
@(private = "file")
watch_thumb :: proc(app: ^App_State, s: ^ui.State, dpi, h: f32, m: Media_File_Row, key: string) {
	pv := &app.preview
	side := h - 6 * dpi
	image: vg.Image_Id
	if m.thumb >= 0 && int(m.thumb) < len(pv.media.rows) && int(m.thumb) < len(pv.media_images) {
		t := pv.media.rows[m.thumb]
		if text_of(pv.media.text[:], t.name) == text_of(pv.tables.text[:], m.name) do image = pv.media_images[m.thumb]
	}
	ui.set_next_pref_width(s, ui.px(side)); ui.set_next_child_layout_axis(s, .Y)
	ui.push_parent(s, ui.build_box(s, {}, ""))
	ui.spacer(s, ui.px(3 * dpi))
	ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_pref_height(s, ui.px(side))
	if vg.image_id_valid(image) {
		t := pv.media.rows[m.thumb]
		b := ui.build_box(s, {}, fmt.tprintf("###watch_icon_%s", key))
		draw := new(Image_Draw, context.temp_allocator)
		draw^ = {image, {u32(t.thumb_size.x), u32(t.thumb_size.y)}}
		ui.box_equip_custom_draw(b, image_contain_draw, draw)
	} else {
		ui.set_next_bg_color(s, KIND_COLORS[m.kind])
		ui.set_next_text_align(s, .Center)
		ui.set_next_font_size(s, 10 * dpi)
		ui.set_next_corner_radius(s, 4 * dpi)
		ui.build_box(s, {.Draw_Background, .Draw_Text}, fmt.tprintf("%s###watch_icon_%s", om.MEDIA_KINDS[m.kind].tag, key))
	}
	ui.pop_parent(s)
	ui.spacer(s, ui.px(6 * dpi))
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
