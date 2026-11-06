package onimite_app

import "core:fmt"
import "core:reflect"
import "core:strings"

// What the lister lists (preview_lister.odin): each mode a row of its
// title and its catalogs, in order. A catalog's options live in the
// preview's tables (the view descriptors, the workspace's actions on a
// panel, a command's query's rows): it counts them there and reads one by
// its place, so only the options a filter searches or the list shows are
// made. A query's rows are the evaluator's (eval_rows.odin), filtered in
// their collections as a Watch's are, until B's query views.

Lister_Mode :: enum u8 {
	Panel, // the tab strip's +: what opens in its panel, and its actions
	Query, // a command's query (Ctrl+P's Go_To): the rows its operand is picked from
}

Lister_Catalog :: enum u8 {
	Views,
	Panel_Actions,
	Query,
}

Lister_Mode_Descriptor :: struct {
	title:    string,
	catalogs: []Lister_Catalog,
}

LISTER_MODES := [Lister_Mode]Lister_Mode_Descriptor {
	.Panel = {"Open in this panel", {.Views, .Panel_Actions}},
	.Query = {"", {.Query}},
}

// What the catalogs read: the tables (an evaluation's reader), the frame
// rate, the leaf the lister was opened for, and a query's command, its
// filter and its rows.
Lister_Source :: struct {
	reader:  Reader,
	fps:     int,
	panel:   Panel_Id,
	command: Command_Kind,
	blocks:  ^View_Blocks,
}

// A catalog: how many options it has, and its i-th; one that `filters`
// counts only what the filter keeps (its rows' collections filter them).
Lister_Catalog_Descriptor :: struct {
	count:   proc(src: Lister_Source) -> int,
	option:  proc(src: Lister_Source, i: int) -> Lister_Option,
	filters: bool,
}

LISTER_CATALOGS := [Lister_Catalog]Lister_Catalog_Descriptor {
	.Views         = {view_count, view_option, false},
	.Panel_Actions = {proc(src: Lister_Source) -> int {return len(PANEL_ACTIONS)}, panel_action_option, false},
	.Query         = {proc(src: Lister_Source) -> int {return src.blocks.total}, query_option, true},
}

// The workspace's actions on a panel, each the row it pushes for the
// lister's panel; their labels and summaries are their kinds'
// (COMMAND_KINDS).
PANEL_ACTIONS := [?]Command_Row{{.Panel_Split, {direction = .Right}}, {.Panel_Split, {direction = .Down}}, {.Panel_Close, {}}}

// Each view kind to open in the panel (an open video, timeline or Watch
// tab moves there); the Watch once per tab on the video's tables
// (WATCH_TABS), then an expression Watch.
@(private = "file")
view_count :: proc(src: Lister_Source) -> int {
	n := 0
	for d in VIEW_DESCRIPTORS {
		if !d.of_row do n += len(WATCH_TABS) + 1 if d.watches else 1
	}
	return n
}

@(private = "file")
view_option :: proc(src: Lister_Source, i: int) -> Lister_Option {
	at := i
	for d, kind in VIEW_DESCRIPTORS {
		if d.of_row do continue
		n := len(WATCH_TABS) + 1 if d.watches else 1
		if at >= n {
			at -= n
			continue
		}
		row := Command_Row{.View_Open, {panel = src.panel, view_kind = kind}}
		if !d.watches || at == len(WATCH_TABS) {
			return {"View", d.name, d.about, row}
		}
		tabs := WATCH_TABS
		r := src.reader
		v, _ := evaluate(&r, tabs[at])
		row.regs.spec = tabs[at]
		return {"View", fmt.tprintf("%s: %s", d.name, KINDS[v.kind].title), value_text(&r, v), row}
	}
	return {}
}

// Each action labelled by its kind, and the side for one that opens a
// panel on a side ("Split right").
@(private = "file")
panel_action_option :: proc(src: Lister_Source, i: int) -> Lister_Option {
	row := PANEL_ACTIONS[i]
	d := COMMAND_KINDS[row.kind]
	o := Lister_Option{"Panel", d.label, d.about, row}
	if row.regs.direction != .None {
		side, _ := reflect.enum_name_from_value(row.regs.direction)
		o.label = fmt.tprintf("%s %s", d.label, strings.to_lower(side, context.temp_allocator))
	}
	o.row.regs.panel = src.panel
	return o
}

// A query's i-th row: what it is (its kind) and its label, when it is (its
// frame), and the command its pick pushes, the command's register filled
// from the row's kind (query_choose); a row that can't fill it pushes none.
@(private = "file")
query_option :: proc(src: Lister_Source, i: int) -> Lister_Option {
	rows := make([dynamic]View_Row, context.temp_allocator)
	blocks_window(src.blocks, i, 1, &rows)
	if len(rows) == 0 do return {}
	row := rows[0]
	r := src.reader
	o := Lister_Option{KINDS[row.value.kind].title, row.label, "at no frame", {}}
	if pick, ok := query_choose(&r, src.command, row.value); ok {
		o.row = pick
		if COMMAND_KINDS[src.command].slot == .Frame do o.summary = fmt.tprintf("%s · f %d", frame_clock(pick.regs.count, max(src.fps, 1)), pick.regs.count)
	}
	return o
}

// The command a picked row completes a query with, its register filled by
// what the row is (RAD Debugger's CompleteQuery filling registers by the
// row's evaluation, raddbg_core.c:2387-2513): a frame from the row's frame.
// False when the row can't fill it (a problem at no frame).
query_choose :: proc(r: ^Reader, command: Command_Kind, v: Value) -> (Command_Row, bool) {
	row := Command_Row{command, {}}
	switch COMMAND_KINDS[command].slot {
	case .None:
	case .Frame:
		f := row_frame(r, v)
		if f < 0 do return {}, false
		row.regs.count = f
	}
	return row, true
}

// A command run as RAD Debugger's RunCommand (raddbg_core.c:13673-13716):
// one whose operand has a query and comes without it (a key's) asks for it
// with the lister; else its row is pushed.
command_run :: proc(app: ^App_State, kind: Command_Kind, regs: Command_Regs) {
	if COMMAND_KINDS[kind].query != "" {
		command_push(&app.commands, .Lister_Open, {lister = .Query, command = kind})
		return
	}
	command_push(&app.commands, kind, regs)
}
