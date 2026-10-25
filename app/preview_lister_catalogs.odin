package onimite_app

import "core:fmt"
import "core:reflect"
import "core:strings"

// What the lister lists (preview_lister.odin): each mode a row of its
// title and its catalogs, in order. A catalog's options live in the
// preview's tables (the view descriptors, the Watch's sections and rows,
// the workspace's actions on a panel): it counts them there and reads one
// by its place, so only the options a filter searches or the list shows
// are made.

Lister_Mode :: enum u8 {
	Panel, // the tab strip's +: what opens in its panel, and its actions
	Go_To, // Ctrl+P: where the playhead can go, then the views
}

Lister_Catalog :: enum u8 {
	Views,
	Panel_Actions,
	Places,
}

Lister_Mode_Descriptor :: struct {
	title:    string,
	catalogs: []Lister_Catalog,
}

LISTER_MODES := [Lister_Mode]Lister_Mode_Descriptor {
	.Panel = {"Open in this panel", {.Views, .Panel_Actions}},
	.Go_To = {"Go to a scene, cue or problem, or open a view", {.Places, .Views}},
}

// What the catalogs read: the Watch's table, the frame rate, and the
// leaf the lister was opened for.
Lister_Source :: struct {
	watch: ^Watch_Table,
	fps:   int,
	panel: Panel_Id,
}

// A catalog: how many options it has, and its i-th.
Lister_Catalog_Descriptor :: struct {
	count:  proc(src: Lister_Source) -> int,
	option: proc(src: Lister_Source, i: int) -> Lister_Option,
}

LISTER_CATALOGS := [Lister_Catalog]Lister_Catalog_Descriptor {
	.Views         = {view_count, view_option},
	.Panel_Actions = {proc(src: Lister_Source) -> int {return len(PANEL_ACTIONS)}, panel_action_option},
	.Places        = {place_count, place_option},
}

// The workspace's actions on a panel, each the row it pushes for the
// lister's panel; their labels and summaries are their kinds'
// (COMMAND_KINDS).
PANEL_ACTIONS := [?]Command_Row{{.Panel_Split, {direction = .Right}}, {.Panel_Split, {direction = .Down}}, {.Panel_Close, {}}}

// Each view kind to open in the panel (an open video or timeline moves
// there); one opening on a section, once per Watch section.
@(private = "file")
view_count :: proc(src: Lister_Source) -> int {
	n := 0
	for d in VIEW_DESCRIPTORS {
		n += len(Watch_Section) if d.sections else 1
	}
	return n
}

@(private = "file")
view_option :: proc(src: Lister_Source, i: int) -> Lister_Option {
	at := i
	for d, kind in VIEW_DESCRIPTORS {
		n := len(Watch_Section) if d.sections else 1
		if at >= n {
			at -= n
			continue
		}
		row := Command_Row{.View_Open, {panel = src.panel, view_kind = kind}}
		if !d.sections {
			return {"View", d.name, d.about, row}
		}
		section := Watch_Section(at)
		row.regs.section = section
		return {"View", fmt.tprintf("%s: %s", d.name, WATCH_SECTIONS[section].name), fmt.tprintf("%d %s", src.watch.sections[section].count, d.about), row}
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

// The rows of each Watch section whose rows are places to go: the
// playhead to a row's frame, or the Watch on its section for a row at no
// frame. Read in place: the i-th is a section's row by position.
@(private = "file")
place_count :: proc(src: Lister_Source) -> int {
	n := 0
	for d, section in WATCH_SECTIONS {
		if d.go_to {
			n += src.watch.sections[section].count
		}
	}
	return n
}

@(private = "file")
place_option :: proc(src: Lister_Source, i: int) -> Lister_Option {
	w := src.watch
	at := i
	for d, section in WATCH_SECTIONS {
		if !d.go_to {
			continue
		}
		g := w.sections[section]
		if at >= g.count {
			at -= g.count
			continue
		}
		row := w.rows[g.first + at]
		o := Lister_Option{d.noun, text_of(w.text[:], row.label), "at no frame", {.Watch_Show, {section = section}}}
		if row.frame >= 0 {
			o.summary = fmt.tprintf("%s · f %d", frame_clock(row.frame, max(src.fps, 1)), row.frame)
			o.row = {.Frame_Set, {count = row.frame}}
		}
		return o
	}
	return {}
}
