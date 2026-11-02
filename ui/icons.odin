package ui

import vg "deps:ovg"

// Icons are path data on the descriptor tables (tools, commands, value
// kinds, the scroll bar's arrows) in a 24 unit box, stroked into their
// box (Draw_Icon) at any size.
ICON_BOX :: 24
ICON_STROKE :: 1.75
ICON_STROKE_SETTINGS :: vg.Stroke_Settings{line_width = ICON_STROKE, line_join = .Round, line_cap_start = .Round, line_cap_end = .Round, miter_limit = 10}
// Each icon's stroke made once, as a shape (its outline is the same at every
// size, scaled into the box); Draw_Icon boxes fill these.
icons_set :: proc(s: ^State, sources: []string) {
	for source in sources {
		if source in s.icons do continue
		p: vg.Path; defer vg.path_destroy(&p)
		if !vg.path_svg(&p, source) do continue
		if shape, ok, _ := vg.shape_from_stroke(&p, ICON_STROKE_SETTINGS); ok {s.icons[source] = shape} else {vg.shape_destroy(&shape)}
	}
}
