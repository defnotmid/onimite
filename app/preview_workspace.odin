package onimite_app

import "core:fmt"
import "core:hash"
import "core:math"
import "core:strings"
import ui "../ui"

// The preview's workspace, after oasic's: panels that split, and views as
// tabs in them that open, close, move and are dragged where you like.
// Panels and views are flat records with integer ids: an id is its row's
// index plus one, rows are only appended (a released one stays as a
// tombstone), so no id is reused and no pointer survives an append. A leaf
// panel holds a list of views (linked by id) and shows one; a branch splits
// its area between two children along an axis. Every change is a command
// row applied by `workspace_apply`; `workspace_measure` lays the panels out
// each window frame and the views (preview_panels.odin) only read that.

Panel_Id :: distinct u32
View_Id :: distinct u32

View_Kind :: enum u8 {
	Video,
	Timeline,
	Watch,
	Image,
	Audio,
}

// What a view is called and shows, whether it opens as a Watch: on one of
// the video's tables (WATCH_TABS), or empty, for the expressions you type;
// and whether it presents one row's value, so a row opens it and no lister
// offers it. The workspace holds at most one video, one timeline and one
// Watch on each table; expression Watches, as many as are opened.
View_Descriptor :: struct {
	name:    string,
	about:   string,
	watches: bool,
	of_row:  bool,
}

VIEW_DESCRIPTORS :: [View_Kind]View_Descriptor {
	.Video    = {"Video", "the rendered frame", false, false},
	.Timeline = {"Timeline", "ruler, scenes, cues and sound", false, false},
	.Watch    = {"Watch", "the expressions you type, each a row that unfolds", true, false},
	.Image    = {"Image", "an image file", false, true},
	.Audio    = {"Audio", "a sound file, its waveform and a player", false, true},
}

// The Watch tabs on the video's tables: each the Watch of one fixed
// expression, scoped (its rows are the top level).
WATCH_TABS :: [?]string{"video:scenes", "video:cues", "video:problems", "video:media", "video:marks"}

Direction :: enum u8 {
	None,
	Left,
	Right,
	Up,
	Down,
}

Split_Axis :: enum u8 {
	X,
	Y,
}

Workspace_Rect :: struct {
	x, y, width, height: f32,
}

Panel_Record :: struct {
	live:               bool,
	parent:             Panel_Id,
	// A branch's two sides ({0, 0}: a leaf).
	children:           [2]Panel_Id,
	axis:               Split_Axis,
	// The first side's share of a branch.
	ratio:              f32,
	// A branch whose second side keeps its shown view's natural height (the
	// timeline's rows) until its splitter is dragged.
	fit:                bool,
	// A leaf's views in tab order, and the one shown.
	first, last, shown: View_Id,
}

View_Record :: struct {
	live:           bool,
	kind:           View_Kind,
	panel:          Panel_Id,
	previous, next: View_Id,
	// Its first row shown (View_Scroll: a Watch's rows, the timeline's
	// below the scenes) and a Watch's filter (View_Filter, owned): the
	// top-level rows whose labels match.
	scroll:         int,
	filter:         [dynamic]u8,
	// A Watch's expressions (owned) in order: scoped, its one expression's
	// rows are its top level (a tab on one of the video's tables, fixed
	// when it opens); else each is a row of its own (the expression
	// Watch). Its open rows by their keys (owned), and the next
	// expression's id.
	inputs:         [dynamic]Watch_Input,
	scoped:         bool,
	expanded:       [dynamic]string,
	next_input:     u32,
	// An image's view: where it looks (preview_media_views.odin).
	bitmap:         Bitmap_View,
	// A row's view (RAD's view of a row, raddbg_core.c:4071): the same record
	// as a tab's, in no panel until it is dragged into one (View_Move, a tab's
	// move), which makes it a tab like any other. The view showing the row, and
	// the row's key (row_view_key), a tab's 0; and whether it was made only for
	// a drag (the row shows no view of it), going if it lands nowhere.
	owner:          View_Id,
	owner_row:      u64,
	transient:      bool,
}

// Where a panel is this window frame, in pixels: its whole area, below its
// tabs, and a branch's splitter.
Panel_Area :: struct {
	visible:                 bool,
	rect, content, splitter: Workspace_Rect,
}

// Where a dragged tab may land: beside a panel (a split), among its tabs at
// the end (a join) or after a tab (a reorder). The same rule turns a target
// into the command a drop pushes and into the preview drawn under the drag.
Drop_Target_Kind :: enum u8 {
	Panel_Split,
	Panel_Join,
	View_Reorder,
}

Drop_Target :: struct {
	kind:      Drop_Target_Kind,
	panel:     Panel_Id,
	direction: Direction,
	previous:  View_Id,
}

Workspace :: struct {
	panels:        [dynamic]Panel_Record,
	views:         [dynamic]View_Record,
	// Parallel to `panels`, from the last measure.
	areas:         [dynamic]Panel_Area,
	root, focused: Panel_Id,
	// The open lister (preview_lister.odin).
	lister:        Lister,
	// A leaf's tab bar's height in pixels, from the last measure (its one
	// computation: tabs_height of the window's font).
	tab_height:    f32,
}

// The default arrangement: the video above the timeline, the timeline at
// its natural height.
workspace_init :: proc(ws: ^Workspace) {
	ws.root = panel_add(ws)
	ws.focused = ws.root
	workspace_open(ws, ws.root, .Video)
	timeline := workspace_split(ws, ws.root, .Down, 0.7)
	workspace_panel(ws, workspace_panel(ws, timeline).parent).fit = true
	workspace_open(ws, timeline, .Timeline)
	ws.focused = workspace_view(ws, workspace_find(ws, .Video)).panel
}

workspace_destroy :: proc(ws: ^Workspace) {
	for &v in ws.views do view_record_free(&v)
	delete(ws.panels)
	delete(ws.views)
	delete(ws.areas)
	delete(ws.lister.query)
	ws^ = {}
}

workspace_panel :: proc(ws: ^Workspace, id: Panel_Id) -> ^Panel_Record {
	if id == 0 || int(id) > len(ws.panels) || !ws.panels[id - 1].live {
		return nil
	}
	return &ws.panels[id - 1]
}

workspace_view :: proc(ws: ^Workspace, id: View_Id) -> ^View_Record {
	if id == 0 || int(id) > len(ws.views) || !ws.views[id - 1].live {
		return nil
	}
	return &ws.views[id - 1]
}

// A live leaf panel (nil for a branch or a closed one).
workspace_leaf :: proc(ws: ^Workspace, id: Panel_Id) -> ^Panel_Record {
	p := workspace_panel(ws, id)
	return p if p != nil && p.children[0] == 0 else nil
}

// The first open tab of `kind` (0: none).
workspace_find :: proc(ws: ^Workspace, kind: View_Kind) -> View_Id {
	for v, i in ws.views {
		if v.live && v.kind == kind && v.panel != 0 {
			return View_Id(i + 1)
		}
	}
	return 0
}

// The open Watch tab on `expression` (0: none).
workspace_find_watch :: proc(ws: ^Workspace, expression: string) -> View_Id {
	for v, i in ws.views {
		if v.live && v.kind == .Watch && v.panel != 0 && v.scoped && len(v.inputs) == 1 && v.inputs[0].source == expression {
			return View_Id(i + 1)
		}
	}
	return 0
}

// A row's durable key, as a row's view names it.
row_view_key :: proc(row_key: string) -> u64 {return hash.fnv64a(transmute([]u8)row_key)}

// The view of row `row` of view `owner` (0: none yet).
workspace_row_view :: proc(ws: ^Workspace, owner: View_Id, row: u64) -> View_Id {
	for v, i in ws.views {
		if v.live && v.owner == owner && v.owner_row == row {
			return View_Id(i + 1)
		}
	}
	return 0
}

// Row `row` of `owner` has a view of `kind` on `expression`, or the one it
// has follows the expression (a row's is written as its table's rows allow),
// and stays if the row now shows it.
@(private = "file")
row_view_open :: proc(ws: ^Workspace, owner: View_Id, row: u64, kind: View_Kind, expression: string, scoped, transient: bool) {
	if workspace_view(ws, owner) == nil {
		return
	}
	if v := workspace_view(ws, workspace_row_view(ws, owner, row)); v != nil {
		delete(v.inputs[0].source)
		v.inputs[0].source = strings.clone(expression)
		v.transient = v.transient && transient
		return
	}
	append(&ws.views, View_Record{live = true, kind = kind, owner = owner, owner_row = row, scoped = scoped, transient = transient, next_input = 1})
	append(&ws.views[len(ws.views) - 1].inputs, Watch_Input{strings.clone(expression), 0})
}

// The views of a closing view's rows go with it; those made tabs are their own.
@(private = "file")
row_views_close :: proc(ws: ^Workspace, owner: View_Id) {
	for &v in ws.views {
		if v.live && v.owner == owner {
			view_record_free(&v)
			v = {}
		}
	}
}

// A row shut: its view goes.
@(private = "file")
row_view_close :: proc(ws: ^Workspace, owner: View_Id, row_key: string) {
	if id := workspace_row_view(ws, owner, row_view_key(row_key)); id != 0 {
		workspace_close_view(ws, id)
	}
}

// What a view owns, freed (a closed view stays a tombstone).
@(private = "file")
view_record_free :: proc(v: ^View_Record) {
	delete(v.filter)
	for input in v.inputs do delete(input.source)
	delete(v.inputs)
	for key in v.expanded do delete(key)
	delete(v.expanded)
}

// The open view of `kind` when its panel shows it (0: none or hidden).
workspace_shown :: proc(ws: ^Workspace, kind: View_Kind) -> View_Id {
	for v, i in ws.views {
		if v.live && v.kind == kind && v.panel != 0 && ws.panels[v.panel - 1].shown == View_Id(i + 1) {
			return View_Id(i + 1)
		}
	}
	return 0
}

@(private = "file")
panel_add :: proc(ws: ^Workspace) -> Panel_Id {
	append(&ws.panels, Panel_Record{live = true, ratio = 0.5})
	return Panel_Id(len(ws.panels))
}

// Takes view `id` out of its panel's tab list (a row's view is in none).
@(private = "file")
view_detach :: proc(ws: ^Workspace, id: View_Id) {
	v := workspace_view(ws, id)
	p := workspace_panel(ws, v.panel)
	if p == nil {
		return
	}
	if v.previous != 0 {
		workspace_view(ws, v.previous).next = v.next
	} else {
		p.first = v.next
	}
	if v.next != 0 {
		workspace_view(ws, v.next).previous = v.previous
	} else {
		p.last = v.previous
	}
	if p.shown == id {
		p.shown = p.first
	}
	v.panel, v.previous, v.next = 0, 0, 0
}

// Puts view `id` into leaf `panel` after `previous` (0: first) and shows it.
@(private = "file")
view_attach :: proc(ws: ^Workspace, id: View_Id, panel: Panel_Id, previous: View_Id) {
	v := workspace_view(ws, id)
	p := workspace_panel(ws, panel)
	next := p.first
	if previous != 0 {
		next = workspace_view(ws, previous).next
	}
	v.panel, v.previous, v.next = panel, previous, next
	if previous == 0 {
		p.first = id
	} else {
		workspace_view(ws, previous).next = id
	}
	if next == 0 {
		p.last = id
	} else {
		workspace_view(ws, next).previous = id
	}
	p.shown = id
	ws.focused = panel
}

// Splits leaf `panel`: a new empty leaf on the `direction` side, with
// `ratio` the first side's share (0: half). Returns the new leaf.
workspace_split :: proc(ws: ^Workspace, panel: Panel_Id, direction: Direction, ratio: f32 = 0) -> Panel_Id {
	if workspace_leaf(ws, panel) == nil || direction == .None {
		return 0
	}
	old_parent := workspace_panel(ws, panel).parent
	branch := panel_add(ws)
	leaf := panel_add(ws)
	// Reacquired after the appends: ids never depend on array addresses.
	b := workspace_panel(ws, branch)
	b.parent = old_parent
	b.axis = .X if direction == .Left || direction == .Right else .Y
	b.children = {panel, leaf} if direction == .Right || direction == .Down else {leaf, panel}
	b.ratio = clamp(ratio, 0.05, 0.95) if ratio > 0 else 0.5
	workspace_panel(ws, panel).parent = branch
	workspace_panel(ws, leaf).parent = branch
	if old_parent == 0 {
		ws.root = branch
	} else {
		for &child in workspace_panel(ws, old_parent).children {
			if child == panel {
				child = branch
			}
		}
	}
	ws.focused = leaf
	return leaf
}

// Closes leaf `panel` and its views; its sibling takes the parent's place
// (the root stays, empty).
workspace_close_panel :: proc(ws: ^Workspace, panel: Panel_Id) {
	p := workspace_leaf(ws, panel)
	if p == nil {
		return
	}
	for id := p.first; id != 0; {
		row_views_close(ws, id)
		v := workspace_view(ws, id)
		id = v.next
		view_record_free(v)
		v^ = {}
	}
	p.first, p.last, p.shown = 0, 0, 0
	if ws.lister.panel == panel {
		lister_close(&ws.lister)
	}
	if p.parent == 0 {
		ws.focused = ws.root
		return
	}
	parent_id := p.parent
	parent := workspace_panel(ws, parent_id)
	sibling := parent.children[1] if parent.children[0] == panel else parent.children[0]
	if parent.parent == 0 {
		ws.root = sibling
	} else {
		for &child in workspace_panel(ws, parent.parent).children {
			if child == parent_id {
				child = sibling
			}
		}
	}
	workspace_panel(ws, sibling).parent = parent.parent
	p.live, parent.live = false, false
	ws.focused = sibling
	for workspace_panel(ws, ws.focused).children[0] != 0 {
		ws.focused = workspace_panel(ws, ws.focused).children[0]
	}
}

// A leaf left without views closes (unless it is the whole workspace).
@(private = "file")
collapse_empty :: proc(ws: ^Workspace, panel: Panel_Id) {
	p := workspace_leaf(ws, panel)
	if p != nil && p.first == 0 && p.parent != 0 {
		focused := ws.focused
		workspace_close_panel(ws, panel)
		if workspace_panel(ws, focused) != nil {
			ws.focused = focused
		}
	}
}

// Opens a view of `kind` (a Watch: a tab on `expression`, scoped; with none,
// an expression Watch) in leaf `panel` after `previous`, or (with a
// direction) in a new panel on that side of it. One already open (the
// video, the timeline, the Watch tab on that expression) moves there
// instead. Returns the view.
workspace_open :: proc(ws: ^Workspace, panel: Panel_Id, kind: View_Kind, direction := Direction.None, ratio: f32 = 0, previous := View_Id(0), expression := "") -> View_Id {
	open := workspace_find(ws, kind)
	if kind == .Watch do open = workspace_find_watch(ws, expression) if expression != "" else 0
	if open != 0 {
		if p := workspace_leaf(ws, panel); p != nil && (p != workspace_panel(ws, workspace_view(ws, open).panel) || direction != .None) {
			workspace_move(ws, open, panel, previous if previous != 0 || direction != .None else p.last, direction, ratio)
		}
		workspace_select(ws, open)
		return open
	}
	if workspace_leaf(ws, panel) == nil {
		return 0
	}
	if v := workspace_view(ws, previous); previous != 0 && (v == nil || v.panel != panel) {
		return 0
	}
	target := panel
	if direction != .None {
		target = workspace_split(ws, panel, direction, ratio)
	}
	append(&ws.views, View_Record{live = true, kind = kind})
	id := View_Id(len(ws.views))
	if kind == .Watch && expression != "" {
		v := workspace_view(ws, id)
		append(&v.inputs, Watch_Input{strings.clone(expression), 0})
		v.scoped, v.next_input = true, 1
	}
	view_attach(ws, id, target, previous if direction == .None else 0)
	return id
}

workspace_close_view :: proc(ws: ^Workspace, id: View_Id) {
	v := workspace_view(ws, id)
	if v == nil {
		return
	}
	row_views_close(ws, id)
	view_record_free(v)
	v.filter, v.inputs, v.expanded = {}, {}, {}
	panel := v.panel
	view_detach(ws, id)
	v^ = {}
	collapse_empty(ws, panel)
}

// Shows view `id` in its panel and focuses the panel.
workspace_select :: proc(ws: ^Workspace, id: View_Id) {
	if v := workspace_view(ws, id); v != nil && v.panel != 0 {
		workspace_panel(ws, v.panel).shown = id
		ws.focused = v.panel
	}
}

// Moves view `id` into leaf `panel` after `previous` (0: first), or (with a
// direction) into a new panel on that side of it; a panel it leaves empty
// closes.
workspace_move :: proc(ws: ^Workspace, id: View_Id, panel: Panel_Id, previous: View_Id, direction: Direction, ratio: f32 = 0) {
	v := workspace_view(ws, id)
	p := workspace_leaf(ws, panel)
	if v == nil || p == nil || previous == id {
		return
	}
	if prev := workspace_view(ws, previous); previous != 0 && (prev == nil || prev.panel != panel) {
		return
	}
	if direction == .None && v.panel == panel && v.previous == previous {
		return
	}
	if direction != .None && v.panel == panel && p.first == p.last {
		return // splitting a panel to hold its only view
	}
	old := v.panel
	target := panel
	if direction != .None {
		target = workspace_split(ws, panel, direction, ratio)
	}
	view_detach(ws, id)
	view_attach(ws, id, target, previous if direction == .None else 0)
	// A row's view that lands is a tab: its row makes itself another.
	v.owner, v.owner_row, v.transient = 0, 0, false
	if old != target {
		collapse_empty(ws, old)
	}
}

// The command a drop of view `id` on `target` pushes (false: it can't land
// there). The drag's preview asks the same question.
workspace_drop_command :: proc(ws: ^Workspace, id: View_Id, target: Drop_Target) -> (row: Command_Row, ok: bool) {
	p := workspace_leaf(ws, target.panel)
	v := workspace_view(ws, id)
	if p == nil || v == nil {
		return
	}
	regs := Command_Regs{view = id, panel = target.panel, previous = target.previous}
	switch target.kind {
	case .Panel_Split:
		if target.direction == .None || (v.panel == target.panel && p.first == p.last) {
			return
		}
		regs.direction = target.direction
		regs.previous = 0
	case .Panel_Join:
		regs.previous = p.last
	case .View_Reorder:
	}
	if regs.previous == id || (regs.direction == .None && v.panel == target.panel && regs.previous == v.previous) {
		return
	}
	return {.View_Move, regs}, true
}

// Applies a workspace command row.
workspace_apply :: proc(ws: ^Workspace, kind: Command_Kind, regs: Command_Regs) {
	#partial switch kind {
	case .Panel_Split:
		workspace_split(ws, regs.panel, regs.direction, f32(regs.ratio))
	case .Panel_Close:
		workspace_close_panel(ws, regs.panel)
	case .Panel_Resize:
		if p := workspace_panel(ws, regs.panel); p != nil && p.children[0] != 0 {
			p.ratio = clamp(f32(regs.ratio), 0.05, 0.95)
			p.fit = false
		}
	case .View_Open:
		workspace_open(ws, regs.panel, regs.view_kind, regs.direction, f32(regs.ratio), regs.previous, regs.spec)
	case .View_Close:
		// No view named: the focused panel's shown tab (RAD's close_tab,
		// its tab register defaulting to it).
		id := regs.view
		if p := workspace_leaf(ws, ws.focused); id == 0 && p != nil do id = p.shown
		workspace_close_view(ws, id)
	case .View_Select:
		workspace_select(ws, regs.view)
	case .View_Move:
		workspace_move(ws, regs.view, regs.panel, regs.previous, regs.direction, f32(regs.ratio))
	case .Watch_Expand, .Watch_Input_Add, .Watch_Input_Set, .Watch_Input_Remove, .Watch_Input_Move:
		if v := workspace_view(ws, regs.view); v != nil && v.kind == .Watch do watch_apply(ws, v, kind, regs)
	case .Row_View_Open:
		row_view_open(ws, regs.view, regs.row, regs.view_kind, regs.spec, .Scoped in regs.flags, regs.flag)
	case .Row_View_Close:
		if v := workspace_view(ws, regs.view); v != nil && v.owner != 0 do workspace_close_view(ws, regs.view)
	case .Lister_Open:
		if panel := regs.panel if regs.panel != 0 else ws.focused; workspace_leaf(ws, panel) != nil {
			lister_open(&ws.lister, panel, regs.lister, regs.command)
		}
	case .Lister_Filter:
		lister_filter_set(&ws.lister, regs.spec)
	case .Lister_Close:
		lister_close(&ws.lister)
	}
}

// A Watch's own commands: a row opened or closed (Watch_Expand, its key in
// regs.spec), and, in an expression Watch, an expression added at a place
// (regs.count; past the end: last), set, removed or moved to another place
// (regs.option). Its open rows below a removed expression go with it.
@(private = "file")
watch_apply :: proc(ws: ^Workspace, v: ^View_Record, kind: Command_Kind, regs: Command_Regs) {
	#partial switch kind {
	case .Watch_Expand:
		for key, i in v.expanded {
			if key == regs.spec {
				row_view_close(ws, regs.view, key)
				delete(key)
				ordered_remove(&v.expanded, i)
				return
			}
		}
		append(&v.expanded, strings.clone(regs.spec))
	case .Watch_Input_Add:
		if v.scoped do return
		inject_at(&v.inputs, clamp(regs.count, 0, len(v.inputs)), Watch_Input{strings.clone(regs.spec), v.next_input})
		v.next_input += 1
	case .Watch_Input_Set:
		if v.scoped || regs.count < 0 || regs.count >= len(v.inputs) do return
		delete(v.inputs[regs.count].source)
		v.inputs[regs.count].source = strings.clone(regs.spec)
	case .Watch_Input_Remove:
		if v.scoped || regs.count < 0 || regs.count >= len(v.inputs) do return
		prefix := fmt.tprintf("i%d", v.inputs[regs.count].id)
		for i := len(v.expanded) - 1; i >= 0; i -= 1 {
			if key := v.expanded[i]; key == prefix || strings.has_prefix(key, prefix) && (key[len(prefix)] == '/' || key[len(prefix)] == ',') {
				row_view_close(ws, regs.view, key)
				delete(key)
				ordered_remove(&v.expanded, i)
			}
		}
		delete(v.inputs[regs.count].source)
		ordered_remove(&v.inputs, regs.count)
	case .Watch_Input_Move:
		if v.scoped || regs.count < 0 || regs.count >= len(v.inputs) do return
		to := clamp(regs.option, 0, len(v.inputs) - 1)
		input := v.inputs[regs.count]
		ordered_remove(&v.inputs, regs.count)
		inject_at(&v.inputs, to, input)
	}
}

// A leaf's tab bar's height, in the font's size (RAD's tab_height setting:
// it follows the window's font size); points: a splitter, the least a side
// of a split gets.
TAB_HEIGHT :: 3
PANEL_SPLITTER :: 4
PANEL_MIN :: 64

// A leaf's tab bar's height in pixels at a font `font_px` big (RAD's
// tab_bar_vheight).
tabs_height :: proc(font_px: f32) -> f32 {return math.floor(TAB_HEIGHT * font_px)}

// Lays the panels out in `rect` (pixels): each leaf's tabs (`tab` pixels
// tall: tabs_height) above its content, a splitter between a branch's
// sides. `natural` is the content height in pixels a view would like (-1:
// none), for fitted branches.
workspace_measure :: proc(ws: ^Workspace, rect: Workspace_Rect, dpi, tab: f32, natural: [View_Kind]f32) {
	ws.tab_height = tab
	gap := PANEL_SPLITTER * dpi
	resize(&ws.areas, len(ws.panels))
	for &a in ws.areas {
		a = {}
	}
	if workspace_panel(ws, ws.root) == nil {
		return
	}
	// Top down from the root: every branch before its children.
	order := make([dynamic]Panel_Id, 0, len(ws.panels), context.temp_allocator)
	append(&order, ws.root)
	for i := 0; i < len(order); i += 1 {
		if p := workspace_panel(ws, order[i]); p.children[0] != 0 {
			append(&order, ..p.children[:])
		}
	}
	ws.areas[ws.root - 1] = {visible = true, rect = rect}
	for id in order {
		p := workspace_panel(ws, id)
		a := &ws.areas[id - 1]
		if p.children[0] == 0 {
			a.content = a.rect
			header := min(tab, a.rect.height)
			a.content.y += header
			a.content.height -= header
			continue
		}
		one, two := &ws.areas[p.children[0] - 1], &ws.areas[p.children[1] - 1]
		one^ = {visible = true, rect = a.rect}
		two^ = {visible = true, rect = a.rect}
		extent := a.rect.width if p.axis == .X else a.rect.height
		separator := min(gap, max(0, extent))
		room := max(0, extent - separator)
		floor := min(PANEL_MIN * dpi, room * 0.5)
		first := clamp(room * p.ratio, floor, room - floor)
		if second := workspace_leaf(ws, p.children[1]); p.fit && p.axis == .Y && second != nil {
			if v := workspace_view(ws, second.shown); v != nil && natural[v.kind] >= 0 {
				first = max(room - min(natural[v.kind] + tab, room), min(floor, room))
			}
		}
		a.splitter = a.rect
		if p.axis == .X {
			one.rect.width = first
			two.rect.x += first + separator
			two.rect.width = room - first
			a.splitter.x += first
			a.splitter.width = separator
		} else {
			one.rect.height = first
			two.rect.y += first + separator
			two.rect.height = room - first
			a.splitter.y += first
			a.splitter.height = separator
		}
	}
}
