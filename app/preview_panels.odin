package onimite_app

import "core:fmt"
import "core:math"
import "core:math/linalg"
import platform "../platform"
import render "../render"
import ui "../ui"

// The workspace's panels drawn from their measured areas, after oasic's
// view/panels.odin and onib's panels_controls: each leaf's tab strip (a
// press on a tab shows its view and, dragged, starts a drag; x closes it, +
// opens the lister on what opens in it, preview_lister.odin), the view it
// shows, and each branch's splitter (a drag resizes it). While a tab is
// dragged (RAD Debugger's drag/drop state: Dragging, Dropping once the left
// button is released), every panel under the pointer offers drop sites: its
// tab strip (a reorder), its four edges (a split) and its centre (a join).
// A site is a typed Drop_Target, and `workspace_drop_command` turns it into
// the one command a drop pushes, the same rule deciding whether the site
// shows. Widgets only push rows; the drag is gesture state. Built front to
// back: the drop sites, then the tab strips and splitters, then each
// panel's view.

// RAD's tab sizes, in the font's size (raddbg_core.c's panel build): a
// tab's close button's width, a tab's most, the space between tabs and at
// the bar's ends.
TAB_CLOSE :: 2.5
TAB_MAX :: 20
TAB_SPACING :: 0.4
TAB_PADDING :: 0.5
// Points the pointer moves before a press on a tab becomes a drag.
DRAG_START :: 10
COLOR_TABS :: [4]u8{25, 29, 35, 255}
COLOR_TABS_FOCUSED :: [4]u8{31, 40, 51, 255}
COLOR_TAB_SHOWN :: [4]u8{45, 63, 81, 255}
COLOR_SPLITTER :: [4]u8{14, 15, 19, 255}
COLOR_DROP :: [4]u8{38, 56, 74, 245}
COLOR_DROP_HOT :: [4]u8{57, 111, 150, 255}
COLOR_DROP_PREVIEW :: [4]u8{55, 130, 190, 65}

// RAD Debugger's drag/drop state: a tab being dragged (or a row's view, dragged
// out of its row: a tab in the making), then dropped (the frame the left button
// is released in: drop sites take it), then none.
Drag_State :: enum u8 {
	Null,
	Dragging,
	Dropping,
}

// A box at `r`, in window pixels: a panel's place in the tree, a
// splitter, a drop site (RAD's UI_Rect).
place_box :: proc(s: ^ui.State, r: Workspace_Rect, flags: ui.Box_Flags, key: string) -> ^ui.Box {
	place(s, r)
	return ui.build_box(s, flags, key)
}

// The panels, front to back: the drop sites while a tab is dragged, the
// splitters, then each leaf at its place in the tree (RAD's panel rects),
// laid out as RAD's: its tab bar above its content, the view it shows.
panels_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32) {
	pv := &app.preview
	ws := &pv.workspace
	pv.panels_resizing = false
	pv.drop_slot = {}
	panel_areas_ease(app, s, dpi)
	if pv.drag != .Null {
		drop_sites_view(app, s, dpi)
	}
	for p, i in ws.panels {
		if !p.live || p.children[0] == 0 || i >= len(ws.areas) || !ws.areas[i].visible do continue
		splitter_view(app, s, Panel_Id(i + 1), ws.areas[i])
	}
	for p, i in ws.panels {
		if !p.live || p.children[0] != 0 || i >= len(ws.areas) || !ws.areas[i].visible {
			continue
		}
		id := Panel_Id(i + 1)
		a := ws.areas[i]
		ui.set_next_child_layout_axis(s, .Y)
		ui.push_parent(s, place_box(s, a.rect, {}, fmt.tprintf("###panel_%d", id)))
		defer ui.pop_parent(s)
		tabs_view(app, s, dpi, id, a)
		// The keys reach the focused panel's views alone, and none while the
		// lister is up (RAD's panel focus: Null, else Off).
		ui.push_focus(s, id == ws.focused && ws.lister.panel == 0 ? .Null : .Off)
		defer ui.pop_focus(s)
		v := workspace_view(ws, p.shown)
		if v == nil {
			empty_panel_view(s, dpi, id)
			continue
		}
		switch v.kind {
		case .Video:
			video_view(app, s, dpi, a.content)
		case .Timeline:
			timeline_view(app, s, dpi, a.content)
		case .Watch:
			watch_view(app, s, dpi, p.shown, a.content)
		case .Image, .Audio:
			media_tab_view(app, s, dpi, p.shown, a.content)
		}
	}
}

// Panels slide to new places when the tree changes shape (a split, a dock,
// a close), as onib's panel_areas_ease (after RAD Debugger's, at its menu
// rate): each rect eases there in fractions of the window, so resizing the
// window moves nothing slowly, and a new panel starts in place. When only
// ratios change (a divider dragged) they follow at once. A splitter sits
// between its sides as they are drawn.
@(private = "file")
panel_areas_ease :: proc(app: ^App_State, s: ^ui.State, dpi: f32) {
	pv := &app.preview
	ws := &pv.workspace
	mix :: proc(h: u64, v: u64) -> u64 {return (h ~ v) * 0x100000001b3}
	shape, ratios := u64(0xcbf29ce484222325), u64(0xcbf29ce484222325)
	for p in ws.panels {
		shape = mix(mix(mix(mix(shape, u64(p.parent)), u64(p.children[0])), u64(p.children[1])), u64(p.live) | u64(p.axis) << 1)
		ratios = mix(ratios, u64(transmute(u32)p.ratio))
	}
	snap := shape == pv.panel_shape && ratios != pv.panel_ratios
	pv.panel_shape, pv.panel_ratios = shape, ratios
	if workspace_panel(ws, ws.root) == nil {
		return
	}
	window := ws.areas[ws.root - 1].rect
	if window.width <= 0 || window.height <= 0 {
		return
	}
	tab := ws.tab_height
	for &a, i in ws.areas {
		if !a.visible || a.rect.width <= 0 {
			continue
		}
		target := [4]f32{(a.rect.x - window.x) / window.width, (a.rect.y - window.y) / window.height, (a.rect.x + a.rect.width - window.x) / window.width, (a.rect.y + a.rect.height - window.y) / window.height}
		eased: [4]f32
		for k in 0 ..< 4 do eased[k] = ui.anim_f32(s, ui.key_from_string(0, fmt.tprintf("panel_%d_%d", i, k)), target[k], {initial = target[k], rate = MENU_RATE, reset = snap})
		a.rect = {window.x + eased[0] * window.width, window.y + eased[1] * window.height, (eased[2] - eased[0]) * window.width, (eased[3] - eased[1]) * window.height}
		if ws.panels[i].children[0] == 0 {
			header := min(tab, a.rect.height)
			a.content = {a.rect.x, a.rect.y + header, a.rect.width, max(a.rect.height - header, 0)}
		}
	}
	for p, i in ws.panels {
		if !p.live || p.children[0] == 0 || !ws.areas[i].visible {
			continue
		}
		one, two := ws.areas[p.children[0] - 1].rect, ws.areas[p.children[1] - 1].rect
		a := &ws.areas[i]
		if p.axis == .X {
			a.splitter = {one.x + one.width, a.rect.y, max(two.x - one.x - one.width, 0), a.rect.height}
		} else {
			a.splitter = {a.rect.x, one.y + one.height, a.rect.width, max(two.y - one.y - one.height, 0)}
		}
	}
}

// A branch's splitter: dragging it moves the split.
@(private = "file")
splitter_view :: proc(app: ^App_State, s: ^ui.State, id: Panel_Id, a: Panel_Area) {
	pv := &app.preview
	p := workspace_panel(&pv.workspace, id)
	ui.set_next_bg_color(s, COLOR_SPLITTER)
	ui.set_next_corner_radius(s, 0)
	ui.set_next_hover_cursor(s, .Left_Right if p.axis == .X else .Up_Down)
	sig := ui.signal_from_box(s, place_box(s, a.splitter, {.Clickable, .Draw_Background, .Draw_Hot_Effects}, fmt.tprintf("###split_%d", id)))
	if ui.dragging(sig) do pv.panels_resizing = true
	if ui.dragging(sig) && sig.drag_delta != {} && pv.drag == .Null {
		mouse := platform.mouse_pos(s.p)
		at, extent := mouse.x - a.rect.x, a.rect.width - a.splitter.width
		if p.axis == .Y {
			at, extent = mouse.y - a.rect.y, a.rect.height - a.splitter.height
		}
		command_push(&app.commands, .Panel_Resize, {panel = id, ratio = f64(at / max(extent, 1))})
	}
}

// A tab's width, as RAD's: its title's, its close button's and an em, at
// most TAB_MAX ems, easing there at the menu rate (a tab that appears grows
// in, except one that appears as the window opens or while a splitter is
// dragged). (RAD's focused tab adds a gear's width: not yet, see
// tabs_view.)
tab_width :: proc(app: ^App_State, s: ^ui.State, tab: View_Id) -> f32 {
	fs := ui.top_font_size(s)
	title, _ := view_title(app, tab)
	target := math.floor(min(render.measure_text(s.font, title, fs) + TAB_CLOSE * fs + fs, TAB_MAX * fs))
	// (RAD's reset only picks a new tab's first width: .initial)
	snap := s.build_index < 5 || app.preview.panels_resizing
	return math.floor(ui.anim_f32(s, ui.key_from_string(0, fmt.tprintf("tab_width_%d", tab)), target, {initial = snap ? target : 0, rate = MENU_RATE}))
}

// A view's title (RAD's title from its cfg): what the tabs, the dragged
// tab's label and the lister call it, in its colour (alpha 0: the theme's
// text). A Watch tab's is its table's title and count, in its worst
// status's colour (watch_title).
view_title :: proc(app: ^App_State, id: View_Id) -> (title: string, color: [4]u8) {
	v := workspace_view(&app.preview.workspace, id)
	if v == nil {
		return
	}
	if v.kind == .Watch {
		return watch_title(app, v)
	}
	if v.kind == .Image || v.kind == .Audio {
		return media_title(app, v)
	}
	descriptors := VIEW_DESCRIPTORS
	return descriptors[v.kind].name, {}
}

// A leaf's tab bar, laid out along it as RAD's (raddbg_core.c's panel
// build): padded half an em at its ends, each tab tab_width wide, TAB_SPACING
// apart, its top corners rounded, holding half an em, its title and its
// close button: TAB_CLOSE ems wide, its X icon centred in a rounded square
// inset by RAD's visual margins (half an em across, the tab's height less
// TAB_CLOSE ems and a quarter em down and up). A click or a middle click on
// the X, or a middle click on the tab, closes it (View_Close, as Ctrl+W);
// a press on the tab shows it, dragged it starts a drag. Its boxes take the
// pointer before the tab does (RAD's order). After the last tab, the +
// button, a tab's height square inset a fifth of it (pressed: the lister on
// what can open in the panel, floating under it, or closed when it is that
// one), and the end's half em. Its tabs past its width, the wheel
// scrolls it sideways (RAD's ViewScrollX, ViewClampX). RAD's focused tab
// also shows a gear (its view's settings, its width another TAB_CLOSE ems)
// and a right click opens them: approved differences until views have
// settings (C8/B).
@(private = "file")
tabs_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32, id: Panel_Id, a: Panel_Area) {
	pv := &app.preview
	ws := &pv.workspace
	c := &app.commands
	p := workspace_panel(ws, id)
	fs := ui.top_font_size(s)
	h := min(ws.tab_height, a.rect.height)
	ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_pref_height(s, ui.px(h)); ui.set_next_child_layout_axis(s, .X)
	ui.set_next_bg_color(s, COLOR_TABS_FOCUSED if ws.focused == id else COLOR_TABS)
	ui.set_next_corner_radius(s, 0)
	bar := ui.build_box(s, {.Clickable, .Clip, .View_Scroll_X, .View_Clamp_X, .Draw_Background}, fmt.tprintf("###tabs_%d", id))
	ui.push_parent(s, bar)
	defer {
		ui.pop_parent(s)
		ui.signal_from_box(s, bar)
	}
	ui.push_pref_height(s, ui.pct(1))
	defer ui.pop_pref_height(s)
	ui.spacer(s, ui.px(math.floor(TAB_PADDING * fs)))
	radius: f32 = 0 // square tabs: onimite's (RAD rounds their tops 0.6 em)
	// Where a dragged tab would drop among these, a hollow slot four ems
	// wide (RAD's drop visualisation).
	slot :: proc(s: ^ui.State, fs, radius: f32, key: string) {
		ui.set_next_pref_width(s, ui.px(4 * fs)); ui.set_next_border_color(s, COLOR_TEXT_DIM)
		b := ui.build_box(s, {.Draw_Border}, key)
		b.corner_radii = {radius, 0, radius, 0}
		ui.spacer(s, ui.px(math.floor(TAB_SPACING * fs)))
	}
	if pv.drop_slot.panel == id && pv.drop_slot.after == 0 do slot(s, fs, radius, fmt.tprintf("###drop_slot_%d", id))
	for tab := p.first; tab != 0; tab = workspace_view(ws, tab).next {
		shown := tab == p.shown
		// The dragged tab lies hollow, its name and X left out (RAD's: while
		// the drag is active with it as its view). It is the same box, still
		// clickable, so the drag's release ends on it like any press's.
		hollow := pv.drag != .Null && tab == pv.drag_view
		ui.set_next_bg_color(s, COLOR_TAB_SHOWN if shown else COLOR_TABS); ui.set_next_border_color(s, COLOR_TEXT_DIM)
		ui.set_next_pref_width(s, ui.px(tab_width(app, s, tab))); ui.set_next_child_layout_axis(s, .X)
		box := ui.build_box(s, {.Clickable, .Draw_Border} if hollow else {.Clickable, .Draw_Background, .Draw_Hot_Effects}, fmt.tprintf("###tab_%d", tab))
		box.corner_radii = {radius, 0, radius, 0} // its top corners (RAD's tabs on top)
		if !hollow {
			ui.push_parent(s, box)
			ui.spacer(s, ui.px(math.floor(TAB_PADDING * fs)))
			title, color := view_title(app, tab)
			ui.set_next_text_align(s, .Left); ui.set_next_text_padding(s, 0)
			if color.a != 0 do ui.set_next_text_color(s, color)
			ui.set_next_pref_width(s, ui.text_content(10, 0))
			ui.build_box(s, {.Draw_Text}, fmt.tprintf("%s###tab_title_%d", title, tab))
			close := TAB_CLOSE * fs
			ui.set_next_pref_width(s, ui.px(close))
			ui.set_next_visual_margin(s, {math.ceil(fs * 0.5), math.floor(h - close + fs * 0.25)})
			ui.set_next_font_size(s, s.theme.default_font_px * 0.75); ui.set_next_icon(s, PREVIEW_ICONS[.Close])
			// (RAD's implicit button: its background and border lit as it is hot)
			ui.set_next_text_color(s, COLOR_TEXT_DIM); ui.set_next_corner_radius(s, fs)
			ui.set_next_bg_color(s, {}); ui.set_next_border_color(s, {})
			x := ui.signal_from_box(s, ui.build_box(s, {.Clickable, .Draw_Border, .Draw_Background, .Draw_Icon, .Draw_Hot_Effects, .Draw_Active_Effects}, fmt.tprintf("###close_%d", tab)))
			if ui.clicked(x) || ui.middle_clicked(x) do command_push(c, .View_Close, {view = tab})
			ui.pop_parent(s)
		}
		// The tab takes what its boxes left (RAD's order).
		t := ui.signal_from_box(s, box)
		if ui.pressed(t) {
			command_push(c, .View_Select, {view = tab})
		} else if ui.dragging(t) && pv.drag == .Null && linalg.length(ui.drag_delta(s)) > DRAG_START * dpi {
			pv.drag, pv.drag_view = .Dragging, tab
		} else if ui.middle_clicked(t) {
			command_push(c, .View_Close, {view = tab})
		}
		ui.spacer(s, ui.px(math.floor(TAB_SPACING * fs)))
		if pv.drop_slot.panel == id && pv.drop_slot.after == tab do slot(s, fs, radius, fmt.tprintf("###drop_slot_%d", id))
	}
	ui.set_next_pref_width(s, ui.px(h))
	ui.set_next_visual_margin(s, {h / 5, h / 5})
	ui.set_next_text_align(s, .Center); ui.set_next_corner_radius(s, (h - h / 4) / 3)
	own := ws.lister.panel == id && ws.lister.mode == .Panel
	if own do ui.set_next_bg_color(s, COLOR_TAB_SHOWN)
	// Pressed (RAD's): its panel focused, then its lister closed when it is
	// the one open, else opened.
	if add := ui.button(s, fmt.tprintf("+###add_%d", id)); ui.pressed(add) {
		if p.shown != 0 do focus_panel(app, p.shown)
		if own {
			command_push(c, .Lister_Close)
		} else {
			command_push(c, .Lister_Open, {panel = id, lister = .Panel})
			pv.lister.anchor = add.box.key
		}
	}
	ui.spacer(s, ui.px(math.floor(TAB_PADDING * fs)))
}

// An empty panel (only the whole workspace can be one): how to fill it.
@(private = "file")
empty_panel_view :: proc(s: ^ui.State, dpi: f32, id: Panel_Id) {
	ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_pref_height(s, ui.pct(1, 0))
	ui.set_next_bg_color(s, COLOR_PANEL_BG)
	ui.set_next_corner_radius(s, 0)
	ui.set_next_text_color(s, COLOR_TEXT_DIM)
	ui.set_next_text_align(s, .Center)
	ui.set_next_font_size(s, 13 * dpi)
	ui.build_box(s, {.Draw_Background, .Draw_Text}, fmt.tprintf("+ opens a view here, Ctrl+P goes to a scene, cue or problem###empty_%d", id))
}

// A row dragged out of itself goes out as a tab (RAD's: a row's drag past its
// box, raddbg_core.c:4714), every list's rows the same. What goes is the view of
// `source` (`value`), by RAD's rule (rd_view_from_eval, :1481): its visualizer's,
// else a Watch on it. A view the row has (an open image's) or a Watch tab already
// on it is the one dragged, a tab's drag; else one is made, by a command, for the
// next frame to drag, and it goes if it lands nowhere.
row_drag_out :: proc(app: ^App_State, s: ^ui.State, sig: ui.Signal, owner: View_Id, row: u64, source: string, value: Value) {
	pv := &app.preview
	ws := &pv.workspace
	if !ui.dragging(sig) || pv.drag != .Null do return
	mouse := platform.mouse_pos(s.p)
	r := sig.box.rect
	if mouse.x >= r.min.x && mouse.y >= r.min.y && mouse.x < r.max.x && mouse.y < r.max.y do return
	reader := preview_reader(app)
	kind := View_Kind.Watch
	if lens, ok := visualizer_of(&reader, value); ok do kind = VISUALIZER_VIEWS[lens]
	view := workspace_row_view(ws, owner, row)
	if view == 0 && kind == .Watch do view = workspace_find_watch(ws, source)
	if view != 0 {
		pv.drag, pv.drag_view = .Dragging, view
		return
	}
	regs := Command_Regs{view = owner, row = row, view_kind = kind, spec = source, flag = true}
	if kind == .Watch && expandable(value) do regs.flags += {.Scoped}
	command_push(&app.commands, .Row_View_Open, regs)
}

// A drag ends (dropped, or cancelled): a view made only for it, if it landed
// nowhere, goes. Queued after the drop's own move, which leaves it a tab that
// this doesn't close.
preview_drag_end :: proc(app: ^App_State) {
	pv := &app.preview
	if v := workspace_view(&pv.workspace, pv.drag_view); v != nil && v.transient {
		command_push(&app.commands, .Row_View_Close, {view = pv.drag_view})
	}
	pv.drag, pv.drag_view = .Null, 0
}

// The drop sites of every panel under the dragged tab, and its label at
// the pointer, over everything (the tooltip root).
@(private = "file")
drop_sites_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32) {
	pv := &app.preview
	ws := &pv.workspace
	mouse := platform.mouse_pos(s.p)
	for &p, i in ws.panels {
		if !p.live || p.children[0] != 0 || i >= len(ws.areas) || !ws.areas[i].visible {
			continue
		}
		id := Panel_Id(i + 1)
		a := ws.areas[i]
		strip := Workspace_Rect{a.rect.x, a.rect.y, a.rect.width, ws.tab_height}
		if inside(strip, mouse) {
			// After the tab whose right edge is nearest (0: before the
			// first), the tabs' widths summed along the bar (RAD's).
			after, at := View_Id(0), a.rect.x
			x := a.rect.x
			for tab := p.first; tab != 0; tab = workspace_view(ws, tab).next {
				x += tab_width(app, s, tab)
				if abs(mouse.x - x) < abs(mouse.x - at) {
					after, at = tab, x
				}
			}
			// The site over the strip; where it drops, the bar opens a slot
			// (tabs_view), none for a drop that moves nothing (RAD's).
			if drop_site(app, s, {kind = .View_Reorder, panel = id, previous = after}, strip, {}, fmt.tprintf("###reorder_%d", id), false) do pv.drop_slot = {id, after}
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
	if v := workspace_view(ws, pv.drag_view); v != nil {
		title, _ := view_title(app, pv.drag_view)
		ui.tooltip_begin(s)
		ui.set_next_text_color(s, {180, 220, 250, 255})
		ui.set_next_font_size(s, 12 * dpi)
		place_box(s, {mouse.x + 14 * dpi, mouse.y + 16 * dpi, 200 * dpi, 24 * dpi}, {.Draw_Text}, fmt.tprintf("Move %s###drag_label", title))
		ui.tooltip_end(s)
	}
}

// One drop site, shown (`visible`) only when the dragged view can land on
// `target`; under the pointer it previews `preview` and, dropped on (RAD's
// drag drop), pushes the drop's command. Returns whether it is under the
// pointer.
@(private = "file")
drop_site :: proc(app: ^App_State, s: ^ui.State, target: Drop_Target, rect, preview: Workspace_Rect, key: string, visible: bool) -> bool {
	pv := &app.preview
	row, ok := workspace_drop_command(&pv.workspace, pv.drag_view, target)
	if !ok {
		return false
	}
	flags: ui.Box_Flags = {.Drop_Site}
	if visible {
		// a shown site fades in at RAD's menu rate
		flags += {.Draw_Background, .Draw_Border, .Draw_Text}
		ui.set_next_opacity(s, ui.anim_f32(s, ui.key_from_string(0, fmt.tprintf("%s_open", key)), 1, {initial = 0, rate = MENU_RATE}))
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
		// the preview grows from its centre to the area the drop gives
		grow :: proc(s: ^ui.State, key, edge: string, to, from: f32) -> f32 {
			return ui.anim_f32(s, ui.key_from_string(0, fmt.tprintf("%s_%s", key, edge)), to, {initial = from, rate = MENU_RATE})
		}
		cx, cy := preview.x + preview.width / 2, preview.y + preview.height / 2
		x0, y0 := grow(s, key, "x0", preview.x, cx), grow(s, key, "y0", preview.y, cy)
		x1, y1 := grow(s, key, "x1", preview.x + preview.width, cx), grow(s, key, "y1", preview.y + preview.height, cy)
		ui.set_next_bg_color(s, COLOR_DROP_PREVIEW)
		place_box(s, {x0, y0, max(1, x1 - x0), max(1, y1 - y0)}, {.Draw_Background, .Draw_Border}, fmt.tprintf("%s_preview", key))
	}
	if pv.drag == .Dropping {
		command_push(&app.commands, row.kind, row.regs)
	}
	return true
}
