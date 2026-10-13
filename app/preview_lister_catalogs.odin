package onimite_app

import "core:fmt"

// What the lister lists (preview_lister.odin): each mode a row of its
// title and its catalogs, in order; each catalog fills option rows
// from the preview's tables: the view descriptors, the Watch's sections
// and rows, and the workspace's actions on a panel.

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

LISTER_CATALOGS := [Lister_Catalog]proc(src: Lister_Source, out: ^[dynamic]Lister_Option) {
	.Views         = view_options,
	.Panel_Actions = panel_action_options,
	.Places        = place_options,
}

// The workspace's actions on a panel, each the row it pushes for the
// lister's panel.
PANEL_ACTIONS := [?]Lister_Option {
	{"Panel", "Split right", "an empty panel beside this one", {.Panel_Split, {direction = .Right}}},
	{"Panel", "Split down", "an empty panel below this one", {.Panel_Split, {direction = .Down}}},
	{"Panel", "Close panel", "with its views", {.Panel_Close, {}}},
}

// Each view kind to open in the panel (an open video or timeline moves
// there); one opening on a section, once per Watch section.
@(private = "file")
view_options :: proc(src: Lister_Source, out: ^[dynamic]Lister_Option) {
	for d, kind in VIEW_DESCRIPTORS {
		row := Command_Row{.View_Open, {panel = src.panel, view_kind = kind}}
		if !d.sections {
			append(out, Lister_Option{"View", d.name, d.about, row})
			continue
		}
		for section_d, section in WATCH_SECTIONS {
			row.regs.section = section
			append(out, Lister_Option{"View", fmt.tprintf("%s: %s", d.name, section_d.name), fmt.tprintf("%d %s", src.watch.sections[section].count, d.about), row})
		}
	}
}

@(private = "file")
panel_action_options :: proc(src: Lister_Source, out: ^[dynamic]Lister_Option) {
	for o in PANEL_ACTIONS {
		o := o
		o.row.regs.panel = src.panel
		append(out, o)
	}
}

// The rows of each Watch section whose rows are places to go: the
// playhead to a row's frame, or the Watch on its section for a row at no
// frame.
@(private = "file")
place_options :: proc(src: Lister_Source, out: ^[dynamic]Lister_Option) {
	w := src.watch
	for d, section in WATCH_SECTIONS {
		if !d.go_to {
			continue
		}
		g := w.sections[section]
		for row in w.rows[g.first:][:g.count] {
			o := Lister_Option{d.noun, text_of(w.text[:], row.label), "at no frame", {.Watch_Show, {section = section}}}
			if row.frame >= 0 {
				o.summary = fmt.tprintf("%s · f %d", frame_clock(row.frame, max(src.fps, 1)), row.frame)
				o.row = {.Frame_Set, {count = row.frame}}
			}
			append(out, o)
		}
	}
}
