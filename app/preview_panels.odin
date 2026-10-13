package onimite_app

import "core:fmt"
import platform "../platform"
import render "../render"
import ui "../ui"

// The workspace's panels drawn from their measured areas, after oasic's
// view/panels.odin: each leaf's tab strip (a press on a tab shows its view
// and starts a drag, x closes it, + opens the lister on what opens in it,
// preview_lister.odin), the view it shows, and each branch's splitter (a
// drag resizes it). While a tab is dragged, every panel under the pointer offers drop
// sites: its tab strip (a reorder), its four edges (a split) and its centre
// (a join). A site is a typed Drop_Target, and `workspace_drop_command`
// turns it into the one command a drop pushes, the same rule deciding
// whether the site shows. Widgets only push rows; the drag is gesture state.

TAB_WIDTH :: 96
TAB_CLOSE :: 20
// Points the pointer moves before a press on a tab becomes a drag.
DRAG_START :: 10
COLOR_TABS :: [4]u8{25, 29, 35, 255}
COLOR_TABS_FOCUSED :: [4]u8{31, 40, 51, 255}
COLOR_TAB_SHOWN :: [4]u8{45, 63, 81, 255}
COLOR_SPLITTER :: [4]u8{14, 15, 19, 255}
COLOR_DROP :: [4]u8{38, 56, 74, 245}
COLOR_DROP_HOT :: [4]u8{57, 111, 150, 255}
COLOR_DROP_PREVIEW :: [4]u8{55, 130, 190, 65}
COLOR_DROP_MARK :: [4]u8{100, 195, 250, 255}

// A box at `r`, in pixels from its parent's corner (the panels' parent is
// the workspace box, at the window's corner).
place_box :: proc(s: ^ui.State, r: Workspace_Rect, flags: ui.Box_Flags, key: string) -> ^ui.Box {
	ui.set_next_fixed_x(s, r.x)
	ui.set_next_fixed_y(s, r.y)
	ui.set_next_fixed_width(s, max(r.width, 0))
	ui.set_next_fixed_height(s, max(r.height, 0))
	return ui.build_box(s, flags, key)
}

place_button :: proc(s: ^ui.State, r: Workspace_Rect, label: string) -> ui.Signal {
	ui.set_next_fixed_x(s, r.x)
	ui.set_next_fixed_y(s, r.y)
	ui.set_next_fixed_width(s, max(r.width, 0))
	ui.set_next_fixed_height(s, max(r.height, 0))
	ui.set_next_corner_radius(s, 0)
	return ui.button(s, label)
}

panels_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32) {
	pv := &app.preview
	ws := &pv.workspace
	if pv.drag_view != 0 && !pv.drag_active {
		d := platform.mouse_pos(s.p) - pv.drag_start
		pv.drag_active = d.x * d.x + d.y * d.y > DRAG_START * DRAG_START * dpi * dpi
	}
	for p, i in ws.panels {
		if !p.live || i >= len(ws.areas) || !ws.areas[i].visible {
			continue
		}
		id := Panel_Id(i + 1)
		a := ws.areas[i]
		if p.children[0] != 0 {
			splitter_view(app, s, id, a)
			continue
		}
		tabs_view(app, s, dpi, id, a)
		v := workspace_view(ws, p.shown)
		if v == nil {
			empty_panel_view(s, dpi, id, a.content)
			continue
		}
		switch v.kind {
		case .Video:
			video_view(app, s, dpi, a.content)
		case .Timeline:
			timeline_view(app, s, dpi, a.content)
		case .Watch:
			watch_view(app, s, dpi, p.shown, a.content)
		}
	}
	if pv.drag_active {
		drop_sites_view(app, s, dpi)
	}
	if !platform.mouse_down(s.p, .Left) {
		pv.drag_view, pv.drag_active = 0, false
	}
}

// A branch's splitter: dragging it moves the split.
@(private = "file")
splitter_view :: proc(app: ^App_State, s: ^ui.State, id: Panel_Id, a: Panel_Area) {
	pv := &app.preview
	p := workspace_panel(&pv.workspace, id)
	ui.set_next_bg_color(s, COLOR_SPLITTER)
	ui.set_next_corner_radius(s, 0)
	sig := ui.signal_from_box(s, place_box(s, a.splitter, {.Clickable, .Draw_Background, .Draw_Hot_Effects}, fmt.tprintf("###split_%d", id)))
	if ui.dragging(sig) && sig.drag_delta != {} && !pv.drag_active {
		mouse := platform.mouse_pos(s.p)
		at, extent := mouse.x - a.rect.x, a.rect.width - a.splitter.width
		if p.axis == .Y {
			at, extent = mouse.y - a.rect.y, a.rect.height - a.splitter.height
		}
		command_push(&app.commands, .Panel_Resize, {panel = id, ratio = f64(at / max(extent, 1))})
	}
}

// The tabs' width in leaf `p` that is `width` wide: TAB_WIDTH while they
// fit beside the + button.
@(private = "file")
tab_width :: proc(ws: ^Workspace, p: ^Panel_Record, width, dpi: f32) -> f32 {
	n := 0
	for tab := p.first; tab != 0; tab = workspace_view(ws, tab).next {
		n += 1
	}
	return min(TAB_WIDTH * dpi, (width - PANEL_TABS * dpi) / f32(max(n, 1)))
}

// What is under `at` in leaf `id`'s tab strip `r`: a tab (and whether its
// close mark), or the + button.
@(private = "file")
Tab_Hit :: struct {
	tab:   View_Id,
	close: bool,
	plus:  bool,
}

@(private = "file")
tab_hit :: proc(ws: ^Workspace, id: Panel_Id, r: Workspace_Rect, at: [2]f32, dpi: f32) -> (hit: Tab_Hit) {
	if at.y < r.y || at.y >= r.y + r.height || at.x < r.x || at.x >= r.x + r.width {
		return
	}
	if at.x >= r.x + r.width - r.height {
		return {plus = true}
	}
	p := workspace_panel(ws, id)
	w := tab_width(ws, p, r.width, dpi)
	x := r.x
	for tab := p.first; tab != 0; tab = workspace_view(ws, tab).next {
		if at.x < x + w {
			return {tab = tab, close = at.x >= x + w - min(TAB_CLOSE * dpi, w * 0.4)}
		}
		x += w
	}
	return
}

// A leaf's tab strip: one box, painted by `tabs_draw`; a press on a tab
// shows it and may start a drag, a click on its x closes it, on + opens
// the lister on what can open in the panel.
@(private = "file")
tabs_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32, id: Panel_Id, a: Panel_Area) {
	pv := &app.preview
	ws := &pv.workspace
	c := &app.commands
	r := Workspace_Rect{a.rect.x, a.rect.y, a.rect.width, min(PANEL_TABS * dpi, a.rect.height)}
	strip := place_box(s, r, {.Clickable}, fmt.tprintf("###tabs_%d", id))
	sig := ui.signal_from_box(s, strip)
	mouse := platform.mouse_pos(s.p)
	hit := tab_hit(ws, id, r, mouse, dpi)
	if ui.pressed(sig) && hit.tab != 0 && !hit.close && !pv.drag_active {
		command_push(c, .View_Select, {view = hit.tab})
		pv.drag_view, pv.drag_start = hit.tab, mouse
	}
	// A click acts where it was pressed too.
	if ui.clicked(sig) && hit == tab_hit(ws, id, r, s.drag_start, dpi) {
		if hit.plus {
			command_push(c, .Lister_Open, {panel = id, lister = .Panel})
		} else if hit.close {
			command_push(c, .View_Close, {view = hit.tab})
		}
	}
	data := new(Tabs_Draw, context.temp_allocator)
	data^ = {app, id, dpi, hit}
	strip.custom_draw = tabs_draw
	strip.custom_draw_data = data
}

@(private = "file")
Tabs_Draw :: struct {
	app:   ^App_State,
	panel: Panel_Id,
	dpi:   f32,
	hover: Tab_Hit,
}

@(private = "file")
tabs_draw :: proc(s: ^ui.State, box: ^ui.Box, data: rawptr) {
	d := (^Tabs_Draw)(data)
	ws := &d.app.preview.workspace
	p := workspace_panel(ws, d.panel)
	r := s.r
	dpi := d.dpi
	x0, y0 := box.rect.min.x, box.rect.min.y
	w, h := box.rect.max.x - x0, box.rect.max.y - y0
	render.draw_rect(r, x0, y0, w, h, COLOR_TABS_FOCUSED if ws.focused == d.panel else COLOR_TABS)
	px := 12 * dpi
	ty := y0 + (h - render.line_height(s.font, px)) * 0.5
	descriptors := VIEW_DESCRIPTORS
	tw := tab_width(ws, p, w, dpi)
	close := min(TAB_CLOSE * dpi, tw * 0.4)
	x := x0
	for tab := p.first; tab != 0; tab = workspace_view(ws, tab).next {
		if tab == p.shown {
			render.draw_rect(r, x, y0, tw - dpi, h, COLOR_TAB_SHOWN)
		}
		if d.hover.tab == tab {
			render.draw_rect(r, x + (tw - close if d.hover.close else 0), y0, close if d.hover.close else tw - close, h, {255, 255, 255, 20})
		}
		render.clip_push(r, x, y0, tw - close, h)
		render.draw_text(r, s.font, descriptors[workspace_view(ws, tab).kind].name, x + 10 * dpi, ty, px, s.theme.text)
		render.clip_pop(r)
		render.draw_text(r, s.font, "x", x + tw - close + 6 * dpi, ty, px, COLOR_TEXT_DIM)
		x += tw
	}
	plus_x := x0 + w - h
	if ws.lister.panel == d.panel && ws.lister.mode == .Panel {
		render.draw_rect(r, plus_x, y0, h, h, COLOR_TAB_SHOWN)
	} else if d.hover.plus {
		render.draw_rect(r, plus_x, y0, h, h, {255, 255, 255, 20})
	}
	render.draw_text(r, s.font, "+", plus_x + h * 0.5 - 4 * dpi, ty, px, s.theme.text)
}

// An empty panel (only the whole workspace can be one): how to fill it.
@(private = "file")
empty_panel_view :: proc(s: ^ui.State, dpi: f32, id: Panel_Id, area: Workspace_Rect) {
	ui.set_next_bg_color(s, s.theme.background)
	ui.set_next_corner_radius(s, 0)
	ui.set_next_text_color(s, COLOR_TEXT_DIM)
	ui.set_next_text_align(s, .Center)
	ui.set_next_font_size(s, 13 * dpi)
	place_box(s, area, {.Draw_Background, .Draw_Text}, fmt.tprintf("+ opens a view here, Ctrl+P goes to a scene, cue or problem###empty_%d", id))
}

// The drop sites of every panel under the dragged tab, and its label at
// the pointer.
@(private = "file")
drop_sites_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32) {
	pv := &app.preview
	ws := &pv.workspace
	mouse := platform.mouse_pos(s.p)
	inside :: proc(r: Workspace_Rect, m: [2]f32) -> bool {
		return m.x >= r.x && m.x < r.x + r.width && m.y >= r.y && m.y < r.y + r.height
	}
	for &p, i in ws.panels {
		if !p.live || p.children[0] != 0 || i >= len(ws.areas) || !ws.areas[i].visible {
			continue
		}
		id := Panel_Id(i + 1)
		a := ws.areas[i]
		strip := Workspace_Rect{a.rect.x, a.rect.y, a.rect.width, PANEL_TABS * dpi}
		if inside(strip, mouse) {
			// After the tab whose right edge is nearest (0: before the first).
			w := tab_width(ws, &p, a.rect.width, dpi)
			after, at := View_Id(0), a.rect.x
			x := a.rect.x
			for tab := p.first; tab != 0; tab = workspace_view(ws, tab).next {
				x += w
				if abs(mouse.x - x) < abs(mouse.x - at) {
					after, at = tab, x
				}
			}
			if drop_site(app, s, {kind = .View_Reorder, panel = id, previous = after}, strip, {}, fmt.tprintf("###reorder_%d", id), false) {
				ui.set_next_bg_color(s, COLOR_DROP_MARK)
				place_box(s, {at - 2 * dpi, strip.y, 4 * dpi, strip.height}, {.Draw_Background}, "###reorder_mark")
			}
			continue
		}
		if !inside(a.content, mouse) {
			continue
		}
		// The four edges and the centre around the middle; each previews the
		// area the drop gives the view.
		r := a.content
		size := min(48 * dpi, min(r.width, r.height) / 4)
		cx, cy := r.x + r.width / 2, r.y + r.height / 2
		for dir in Direction {
			zone := Workspace_Rect{cx - size / 2, cy - size / 2, size, size}
			preview := r
			target := Drop_Target{kind = .Panel_Split, panel = id, direction = dir}
			label := "Tabs"
			switch dir {
			case .None:
				target.kind = .Panel_Join
			case .Left:
				zone.x -= size + 4 * dpi
				preview.width *= 0.5
				label = "<"
			case .Right:
				zone.x += size + 4 * dpi
				preview.x += preview.width / 2
				preview.width *= 0.5
				label = ">"
			case .Up:
				zone.y -= size + 4 * dpi
				preview.height *= 0.5
				label = "^"
			case .Down:
				zone.y += size + 4 * dpi
				preview.y += preview.height / 2
				preview.height *= 0.5
				label = "v"
			}
			drop_site(app, s, target, zone, preview, fmt.tprintf("%s###dock_%d_%v", label, id, dir), true)
		}
		drop_site(app, s, {kind = .Panel_Join, panel = id}, r, {}, fmt.tprintf("###join_%d", id), false)
	}
	descriptors := VIEW_DESCRIPTORS
	if v := workspace_view(ws, pv.drag_view); v != nil {
		ui.set_next_text_color(s, {180, 220, 250, 255})
		ui.set_next_font_size(s, 12 * dpi)
		place_box(s, {mouse.x + 14 * dpi, mouse.y + 16 * dpi, 200 * dpi, 24 * dpi}, {.Draw_Text}, fmt.tprintf("Move %s###drag_label", descriptors[v.kind].name))
	}
}

// One drop site, shown (`visible`) only when the dragged view can land on
// `target`; under the pointer it previews `preview` and, on release,
// pushes the drop's command. Returns whether it is under the pointer.
@(private = "file")
drop_site :: proc(app: ^App_State, s: ^ui.State, target: Drop_Target, rect, preview: Workspace_Rect, key: string, visible: bool) -> bool {
	pv := &app.preview
	row, ok := workspace_drop_command(&pv.workspace, pv.drag_view, target)
	if !ok {
		return false
	}
	flags: ui.Box_Flags = {.Drop_Site}
	if visible {
		flags += {.Draw_Background, .Draw_Border, .Draw_Text}
	}
	ui.set_next_bg_color(s, COLOR_DROP)
	ui.set_next_text_align(s, .Center)
	b := place_box(s, rect, flags, key)
	// Sites are born under the drag: their rect is known before layout.
	b.rect = {{rect.x, rect.y}, {rect.x + rect.width, rect.y + rect.height}}
	ui.signal_from_box(s, b)
	if s.drop_hot != b.key {
		return false
	}
	b.bg_color = COLOR_DROP_HOT
	if preview.width > 0 && preview.height > 0 {
		ui.set_next_bg_color(s, COLOR_DROP_PREVIEW)
		place_box(s, preview, {.Draw_Background, .Draw_Border}, "###drop_preview")
	}
	if platform.mouse_released(s.p, .Left) {
		command_push(&app.commands, row.kind, row.regs)
	}
	return true
}
