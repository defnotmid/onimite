package onimite_app

import "core:fmt"
import "core:hash"
import "core:math"
import "core:slice"
import om "../onimite"
import platform "../platform"
import render "../render"
import "../animation"
import ui "../ui"
import vg "deps:ovg"
import sdl "vendor:sdl3"

// The preview's timeline: a time ruler over rows, one per item the worker
// published (preview_tables.odin), each drawn the way its kind says: the
// scenes as segments with thumbnails, the cues as marks, a bus's tracks as
// one group lane with their sound together (click its name to open it to
// a lane per track), a track's span and waveform, a song's open to a lane
// per part. Hovering a row says what
// it is, with the path `onimite show` takes. The bookmark, the hovered
// frame and the playhead run over all of it. It zooms (Ctrl+wheel, +/-),
// pans (the wheel over the ruler and scenes, horizontal wheel or touchpad,
// middle drag) and follows the playhead; the rows are RAD's scroll list
// (the wheel over them and its bar scroll them). In a panel at the side of
// another and taller than wide, time runs down and the ruler, the scenes and
// the cues are columns side by side (`Time_Axis`), with no other rows. The
// cues sit in the head with the ruler and the scenes, fixed while the rows
// below scroll.
//
// Its track holds its head and its rows, each a box whose custom draw
// paints from the published tables in O(pixels): waveforms read one pyramid
// level per pixel column, thumbnails come from the worker's cache by frame.
// Input on the boxes becomes command rows.

TRACK_PAD :: 8
TIMELINE_GAP :: 6
RULER_HEIGHT :: 18
// The ruler across when time runs down: its labels are side by side with it.
RULER_WIDTH :: 44
SCENE_HEIGHT :: 48
CUE_HEIGHT :: 14
LANE_HEIGHT :: 24
TRACK_HEIGHT :: 18
// The rows below the scenes take at most this many points at the
// timeline's natural height; past what its panel gives them, they scroll.
ROWS_AREA_MAX :: 12 * LANE_HEIGHT
// Clicks this far into a group's row open or close it.
ROW_NAME_WIDTH :: 160
RULER_BG :: [4]u8{22, 24, 30, 255}
LANE_BG :: [4]u8{24, 26, 33, 255}

// A row's height in points, by its kind.
@(private = "file")
TIMELINE_ROW_HEIGHT := [Timeline_Kind]f32 {
	.Scenes = SCENE_HEIGHT,
	.Cues   = CUE_HEIGHT,
	.Group  = LANE_HEIGHT,
	.Track  = TRACK_HEIGHT,
	.Part   = TRACK_HEIGHT,
	.Notes  = 2 * LANE_HEIGHT,
	.Hits   = TRACK_HEIGHT,
	.Bands  = 2 * LANE_HEIGHT,
}

// A row's height in points, by its kind (the table's tree lays its rows
// out by it too: timeline_tree).
row_height :: proc(kind: Timeline_Kind) -> f32 {
	return TIMELINE_ROW_HEIGHT[kind]
}

// The timeline's axes. It draws and hit-tests in its own space: time
// along x and the ruler, the scenes and the rows stacked across y, from
// its box's corner. Along a wide panel that is the window's space; in a
// panel taller than wide, time runs down, so the two axes swap about the
// corner (a swap is its own inverse: the same map takes the pointer into
// the timeline's space). Labels stay upright: only where they start maps.
// The layout decides it once per window frame (`Preview_State.timeline_axis`).
Time_Axis :: struct {
	vertical: bool,
	// The box's corner, the same point in both spaces.
	corner:   [2]f32,
	// Points the ruler takes across.
	ruler:    f32,
}

// Time along x: the window's own axes.
TIME_ALONG :: Time_Axis{ruler = RULER_HEIGHT}

// Whether the timeline in leaf `panel` runs down: the panel is at the side
// of another (its split is left / right) and its `area` is taller than
// wide. Across the top or bottom, or alone, it runs along.
timeline_vertical :: proc(ws: ^Workspace, panel: Panel_Id, area: Workspace_Rect) -> bool {
	p := workspace_panel(ws, panel)
	split := workspace_panel(ws, p.parent) if p != nil else nil
	return split != nil && split.axis == .X && area.height > area.width
}

// How the timeline lies: along its area, or (`vertical`) down it, its
// columns sharing the area's width as the head's layout sizes them.
timeline_axis :: proc(vertical: bool) -> Time_Axis {
	return {vertical = true, ruler = RULER_WIDTH} if vertical else TIME_ALONG
}

// The cues' row (its item; -1: the video has no cues): the head's band.
timeline_cues :: proc(app: ^App_State) -> int {
	for it, i in app.preview.waves.items do if it.kind == .Cues do return i
	return -1
}

// The cues' band in the head when time runs along, in points: CUE_HEIGHT
// when the video has cues.
timeline_cues_height :: proc(app: ^App_State) -> f32 {
	return CUE_HEIGHT if timeline_cues(app) >= 0 else 0
}

// A point between the timeline's space and the window's.
axis_point :: proc(a: Time_Axis, p: [2]f32) -> [2]f32 {
	if !a.vertical {
		return p
	}
	return {a.corner.x + (p.y - a.corner.y), a.corner.y + (p.x - a.corner.x)}
}

// A motion (a drag's) between the two spaces.
axis_motion :: proc(a: Time_Axis, v: [2]f32) -> [2]f32 {
	return v.yx if a.vertical else v
}

// A rect in the timeline's space, in the window's.
axis_rect :: proc(a: Time_Axis, x, y, w, h: f32) -> (wx, wy, ww, wh: f32) {
	p := axis_point(a, {x, y})
	if a.vertical {
		return p.x, p.y, h, w
	}
	return p.x, p.y, w, h
}

// How far an upright label `width` wide reaches along time.
axis_label_along :: proc(a: Time_Axis, width, line: f32) -> f32 {
	return line if a.vertical else width
}

// Drawing in the timeline's space, with ovg on the frame's canvas (the
// box's custom draw), in the UI's scratch path.
@(private = "file")
Pen :: struct {
	s: ^ui.State,
	c: ^vg.Canvas,
	r: ^render.Renderer,
	a: Time_Axis,
}

@(private = "file")
fill :: proc(p: Pen, x, y, w, h: f32, col: [4]u8) {
	wx, wy, ww, wh := axis_rect(p.a, x, y, w, h)
	vg.path_reset(&p.s.path)
	vg.path_rect(&p.s.path, wx, wy, ww, wh)
	vg.fill_path(p.c, &p.s.path, vg.paint_color(ui.color(col)))
}

@(private = "file")
fill_rounded :: proc(p: Pen, x, y, w, h, radius: f32, col: [4]u8) {
	wx, wy, ww, wh := axis_rect(p.a, x, y, w, h)
	vg.path_reset(&p.s.path)
	vg.path_rounded_rect(&p.s.path, wx, wy, ww, wh, radius)
	vg.fill_path(p.c, &p.s.path, vg.paint_color(ui.color(col)))
}

// What is drawn until clip_end, scissored to the rect.
@(private = "file")
clip :: proc(p: Pen, x, y, w, h: f32) {
	wx, wy, ww, wh := axis_rect(p.a, x, y, w, h)
	vg.save(p.c)
	vg.intersect_scissor(p.c, wx, wy, ww, wh)
}

@(private = "file")
clip_end :: proc(p: Pen) {vg.restore(p.c)}

// A texture the worker made (`size` texels), contained in the rect.
@(private = "file")
image :: proc(p: Pen, texture: ^sdl.GPUTexture, size: [2]u32, x, y, w, h: f32) {
	wx, wy, ww, wh := axis_rect(p.a, x, y, w, h)
	if texture == nil || size.x == 0 || size.y == 0 || ww <= 0 || wh <= 0 do return
	scale := min(ww / f32(size.x), wh / f32(size.y))
	dw, dh := f32(size.x) * scale, f32(size.y) * scale
	dx, dy := wx + (ww - dw) * 0.5, wy + (wh - dh) * 0.5
	id := render.image_borrow(p.r, p.c, texture, size.x, size.y)
	vg.path_reset(&p.s.path)
	vg.path_rect(&p.s.path, dx, dy, dw, dh)
	vg.fill_path(p.c, &p.s.path, vg.paint_image(id, dx, dy, dw, dh, 0))
}

// The texels `src` (x0, y0, x1, y1) of a texture the worker made (`size`
// texels) stretched over a window rect: a stretch of a strip texture (a
// spectrogram's rows).
@(private = "file")
image_src :: proc(p: Pen, texture: ^sdl.GPUTexture, size: [2]u32, src: [4]f32, x, y, w, h: f32) {
	if texture == nil || w <= 0 || h <= 0 || src[2] <= src[0] || src[3] <= src[1] do return
	sx, sy := w / (src[2] - src[0]), h / (src[3] - src[1])
	id := render.image_borrow(p.r, p.c, texture, size.x, size.y)
	vg.path_reset(&p.s.path)
	vg.path_rect(&p.s.path, x, y, w, h)
	vg.fill_path(p.c, &p.s.path, vg.paint_image(id, x - src[0] * sx, y - src[1] * sy, f32(size.x) * sx, f32(size.y) * sy, 0))
}

// Upright text starting at `at`.
@(private = "file")
text :: proc(p: Pen, str: string, at: [2]f32, px: f32, col: [4]u8) {
	q := axis_point(p.a, at)
	render.draw_text(p.c, p.s.font, str, q.x, q.y, px, ui.color(col), &p.s.path)
}

// An upright label: a tab `size` big (window pixels) starting at `at`,
// its text at `text_at` (both in the timeline's space; the text keeps its
// place in the tab).
@(private = "file")
label :: proc(p: Pen, str: string, at, size, text_at: [2]f32, radius, px: f32, tab, col: [4]u8) {
	q := axis_point(p.a, at)
	t := q + (text_at - at) if p.a.vertical else text_at
	vg.path_reset(&p.s.path)
	vg.path_rounded_rect(&p.s.path, q.x, q.y, size.x, size.y, radius)
	vg.fill_path(p.c, &p.s.path, vg.paint_color(ui.color(tab)))
	render.draw_text(p.c, p.s.font, str, t.x, t.y, px, ui.color(col), &p.s.path)
}

timeline_row_open :: proc(app: ^App_State, item: Timeline_Item) -> bool {
	return slice.contains(app.preview.rows_open[:], item.key)
}

// The rows below the scenes, laid out as onib lays out a view's rows
// (after RAD Debugger's): a block per open row, the top level's first, its
// children counted where they live (the table's `kids`) and its open ones
// found from their keys; then spans of row numbers over the blocks in
// order. Consumers ask the spans: the total rows and points, or a window of
// rows (only those are read: rows_window). Its blocks' opens and spans are
// the Watch's (Block_Open, Row_Span: eval_rows.odin).
Row_Block :: struct {
	kids:  []i32, // its children (items), in order
	opens: []Block_Open, // by place, ascending
}

Timeline_Rows :: struct {
	blocks: [dynamic]Row_Block,
	spans:  [dynamic]Row_Span,
	total:  int,
	points: f32,
}

timeline_rows :: proc(app: ^App_State) -> (r: Timeline_Rows) {
	w := &app.preview.waves
	r.blocks = make([dynamic]Row_Block, context.temp_allocator)
	r.spans = make([dynamic]Row_Span, context.temp_allocator)
	if w.top[1] == 0 {
		return
	}
	rows_block(app, &r, w.kids[w.top[0]:][:w.top[1]])
	rows_spans(&r, 0)
	for sp in r.spans {
		r.total += sp.hi - sp.lo
		r.points += span_points(w, r.blocks[sp.block].kids, sp.lo, sp.hi)
	}
	return
}

// The block of `kids`, and of its open children after it.
@(private = "file")
rows_block :: proc(app: ^App_State, r: ^Timeline_Rows, kids: []i32) -> int {
	pv := &app.preview
	w := &pv.waves
	block := len(r.blocks)
	append(&r.blocks, Row_Block{kids = kids})
	opens := make([dynamic]Block_Open, context.temp_allocator)
	for key in pv.rows_open {
		for k, at in kids {
			if it := w.items[k]; it.key == key && it.children > 0 {
				append(&opens, Block_Open{at, rows_block(app, r, w.kids[it.kids[0]:][:it.kids[1]])})
				break
			}
		}
	}
	slice.sort_by(opens[:], proc(x, y: Block_Open) -> bool {return x.at < y.at})
	r.blocks[block].opens = opens[:]
	return block
}

// A block's spans, its open children's between: a span ends at each open row.
@(private = "file")
rows_spans :: proc(r: ^Timeline_Rows, block: int) {
	from := 0
	for o in r.blocks[block].opens {
		append(&r.spans, Row_Span{block, from, o.at + 1, true})
		rows_spans(r, o.block)
		from = o.at + 1
	}
	if count := len(r.blocks[block].kids); from < count {
		append(&r.spans, Row_Span{block, from, count, false})
	}
}

// Points of children [lo, hi): their offsets among their siblings.
@(private = "file")
span_points :: proc(w: ^Wave_Table, kids: []i32, lo, hi: int) -> f32 {
	if hi <= lo {
		return 0
	}
	last := w.items[kids[hi - 1]]
	return last.y + row_height(last.kind) - w.items[kids[lo]].y
}

// The rows (items) from `first`, at most `limit`: only these are read.
rows_window :: proc(r: ^Timeline_Rows, first, limit: int) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	end := limit > max(int) - first ? max(int) : first + limit
	at := 0
	for sp in r.spans {
		n := sp.hi - sp.lo
		kids := r.blocks[sp.block].kids
		for i in sp.lo + clamp(first - at, 0, n) ..< sp.lo + clamp(end - at, 0, n) {
			append(&out, int(kids[i]))
		}
		at += n
	}
	return out[:]
}

// Points the rows get in the timeline's `area` (pixels) lying along `a`:
// below the ruler and the scenes what the track leaves; none when time runs
// down (the timeline is its ruler and scenes alone).
timeline_rows_room :: proc(app: ^App_State, a: Time_Axis, area: Workspace_Rect, dpi: f32) -> f32 {
	if a.vertical do return 0
	return max(area.height / dpi - 2 * TIMELINE_GAP - a.ruler - SCENE_HEIGHT - timeline_cues_height(app), 0)
}

// The timeline's natural height in points (before dpi scaling): the
// ruler, the scenes and up to ROWS_AREA_MAX of rows.
timeline_height :: proc(app: ^App_State) -> f32 {
	if app.preview.timeline_collapsed {
		return 0
	}
	total := timeline_rows(app).points
	return TIMELINE_GAP * 2 + RULER_HEIGHT + SCENE_HEIGHT + timeline_cues_height(app) + min(total, ROWS_AREA_MAX)
}

// The scene segments; a video without scenes is one segment.
@(private = "file")
segments :: proc(app: ^App_State) -> []Preview_Scene {
	if scenes := app.preview.timeline.scenes[:]; len(scenes) > 0 {
		return scenes
	}
	whole := make([]Preview_Scene, 1, context.temp_allocator)
	whole[0] = {{}, 0, preview_duration(app), .Alive}
	return whole
}

// Thumbnails sit on a grid of frame steps from each segment's start: powers
// of two and their halves again (1, 2, 3, 4, 6, 8, 12, ...), the smallest
// that fits a thumbnail's width at this zoom. Gaps stay under a third of a
// thumbnail, and zooming finds most frames of the neighbouring grids already
// cached (the cache is keyed by frame). A thumbnail fills the scenes' band
// across (`scene_h` pixels; half of it each, on two rows) and keeps its
// frame's aspect along time.
@(private = "file")
Thumb_Grid :: struct {
	step:      int,
	width:     f64, // a thumbnail's width in frames
	thumb_w:   f32, // and in pixels
	thumb_h:   f32,
	two_rows:  bool,
}

@(private = "file")
thumb_grid :: proc(app: ^App_State, a: Time_Axis, ppf: f64, scene_h, dpi: f32) -> Thumb_Grid {
	pv := &app.preview
	g: Thumb_Grid
	g.two_rows = len(pv.timeline.scenes) > 1
	g.thumb_h = scene_h - 4 * dpi
	if g.two_rows {
		g.thumb_h *= 0.5
	}
	aspect := f32(16) / 9
	if pv.thumb_size.y > 0 {
		aspect = f32(pv.thumb_size.x) / f32(pv.thumb_size.y)
	} else if pv.timeline.height > 0 {
		aspect = f32(pv.timeline.width) / f32(pv.timeline.height)
	}
	// Running down, a thumbnail's width is across and its height along.
	if a.vertical {
		aspect = 1 / aspect
	}
	g.thumb_w = g.thumb_h * aspect
	g.width = f64(g.thumb_w) / max(ppf, 1e-9)
	g.step = 1
	for f64(g.step) < g.width {
		half := g.step + g.step / 2
		g.step = half if g.step >= 2 && f64(half) >= g.width else g.step * 2
	}
	return g
}

// The grid frames of segment `sc` in view (`first` and `visible` frames
// along): `from` up to `to`, `g.step` apart, a thumbnail at each.
@(private = "file")
thumb_range :: proc(sc: Preview_Scene, g: Thumb_Grid, first, visible: f64) -> (from, to: int) {
	// the first whose thumbnail reaches into view
	j := max(int(math.ceil((first - f64(sc.start_frame) - g.width) / f64(g.step))), 0)
	return sc.start_frame + j * g.step, min(sc.end_frame, int(math.ceil(first + visible)))
}

// The thumbnail frames the timeline drew this window frame
// (`thumbs_shown`), nearest the view's centre first, at most THUMB_MAX
// (what the worker keeps): what the worker renders when idle. None while
// the timeline is hidden.
thumbs_wanted :: proc(app: ^App_State) -> []int {
	pv := &app.preview
	if !timeline_shown(app) {
		return nil
	}
	out := slice.clone(pv.thumbs_shown[:], context.temp_allocator)
	context.user_index = int(pv.view_first + view_frames(app) / 2)
	slice.sort_by(out, proc(a, b: int) -> bool {
		c := context.user_index
		return abs(a - c) < abs(b - c) || (abs(a - c) == abs(b - c) && a < b)
	})
	return out[:min(len(out), THUMB_MAX)]
}

// Whether the timeline draws: its panel shown and not collapsed, with a
// video loaded.
timeline_shown :: proc(app: ^App_State) -> bool {
	pv := &app.preview
	_, shown := view_area(app, .Timeline)
	return shown && !pv.timeline_collapsed && pv.timeline.frames > 0
}

// How the timeline's time maps onto a region of it (its head, its rows):
// along `a`, from `x0` for `w` pixels, `first` the frame at x0, `ppf`
// pixels a frame. The head runs along the timeline's axis; the rows always
// run across (time along x), stacked in their list.
@(private = "file")
Time_Map :: struct {
	a:              Time_Axis,
	x0, w:          f32,
	first, visible: f64,
	ppf:            f64,
}

@(private = "file")
time_map :: proc(app: ^App_State, a: Time_Axis, x0, w: f32) -> Time_Map {
	visible := view_frames(app)
	return {a, x0, w, app.preview.view_first, visible, f64(max(w, 1)) / visible}
}

// The frame under `mouse` (window pixels).
@(private = "file")
frame_at :: proc(m: Time_Map, mouse: [2]f32) -> int {
	return int(math.floor(m.first + f64(axis_point(m.a, mouse).x - m.x0) / m.ppf))
}

@(private = "file")
Timeline_Draw :: struct {
	app:     ^App_State,
	dpi:     f32,
	m:       Time_Map,
	// A row's: its item and place among the rows, and the pixels of it
	// scrolled out above its box (it draws whole, the list clipping it).
	item:    int,
	order:   int,
	skipped: f32,
}

// The rows' list unit: RAD's scroll list scrolls whole rows of one height,
// a timeline row being a block of them (RAD's row blocks), so every row
// keeps its height (14, 18, 24, 48 points: 7, 9, 12, 24 units).
ROW_UNIT :: 2

// The timeline in `area` (pixels), inset by TRACK_PAD and TIMELINE_GAP,
// laid out: its track holds its head (the ruler and the scenes, along its
// axis) and, when time runs along, its rows below the scenes in the one RAD
// scroll list, without keys (no cursor): each row a box, the
// list's row blocks giving them their heights. A press scrubs, on a group's
// name opens or closes it (timeline_pointer, for the track and every row
// alike); a middle or right drag pans from where the camera was when it was
// pressed (RAD's stored drag state and drag delta); the wheel scrolls the
// rows over them, elsewhere pans; with Control over it it zooms (as RAD's
// views take it while hovered). Focused, it takes the keys' events as the
// preview's commands (VIEW_EVENTS).
timeline_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32, area: Workspace_Rect) {
	pv := &app.preview
	c := &app.commands
	// Focused, it takes the keys' events its boxes left as the preview's
	// commands, as the video does (VIEW_EVENTS), collapsed too.
	defer {
		ui.push_focus(s, .On)
		view_events_take(app, s)
		ui.pop_focus(s)
	}
	if pv.timeline_collapsed {
		return
	}
	id := workspace_find(&pv.workspace, .Timeline)
	pad, gap := TRACK_PAD * dpi, TIMELINE_GAP * dpi
	track_w := max(area.width - 2 * pad, 0)
	a := pv.timeline_axis
	ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_pref_height(s, ui.pct(1, 0)); ui.set_next_child_layout_axis(s, .Y)
	ui.push_parent(s, ui.build_box(s, {}, "###timeline_area"))
	ui.spacer(s, ui.px(gap))
	ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_pref_height(s, ui.pct(1, 0)); ui.set_next_child_layout_axis(s, .X)
	ui.push_parent(s, ui.build_box(s, {}, "###timeline_row"))
	ui.spacer(s, ui.px(pad))
	ui.set_next_pref_width(s, ui.pct(1, 0)); ui.set_next_pref_height(s, ui.pct(1))
	ui.set_next_bg_color(s, COLOR_TRACK)
	ui.set_next_corner_radius(s, 4 * dpi)
	ui.set_next_child_layout_axis(s, .Y)
	track := ui.build_box(s, {.Clickable, .Scroll, .Draw_Background, .Clip}, "###timeline")
	ui.push_parent(s, track)

	// The head: the ruler, the scenes and the cues across time (down the
	// track when time runs along; side by side, the whole track, when it
	// runs down), sized as RAD sizes boxes: the ruler its points, the scenes
	// theirs or, running down, the rest (ParentPct, giving way), the cues
	// theirs or, running down, their widest label (ChildrenSum of their
	// labels' TextContent). The cues' band is the cues row's: a press
	// scrubs, hovered it shows the row's tooltip.
	ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_pref_height(s, ui.pct(1) if a.vertical else ui.children_sum())
	ui.set_next_child_layout_axis(s, .X if a.vertical else .Y)
	head := ui.build_box(s, {}, "###timeline_head")
	head_sig := ui.signal_from_box(s, head)
	a.corner = head.rect.min
	head_map := time_map(app, a, head.rect.min.x, axis_motion(a, head.rect.max - head.rect.min).x)
	if !a.vertical {
		head_map.w = max(track_w - ui.scroll_bar_width(s), 1)
		head_map.ppf = f64(head_map.w) / head_map.visible
	}
	row_hovered := false
	ui.push_parent(s, head)
	ruler := across_box(s, a, ui.px(a.ruler * dpi), "###timeline_ruler")
	if !a.vertical {
		ui.push_parent(s, ruler)
		timeline_zoom_view(app, s, dpi)
		ui.pop_parent(s)
	}
	across_box(s, a, ui.pct(1, 0) if a.vertical else ui.px(SCENE_HEIGHT * dpi), "###timeline_scenes")
	if cues := timeline_cues(app); cues >= 0 {
		band := across_box(s, a, ui.children_sum() if a.vertical else ui.px(CUE_HEIGHT * dpi), "###timeline_cues", {.Clickable})
		ui.push_parent(s, band)
		cue_labels(app, s, dpi, head_map)
		ui.pop_parent(s)
		sig := ui.signal_from_box(s, band)
		timeline_pointer(app, s, sig, head_map, cues)
		if ui.hovering(sig) {
			row_hovered = true
			timeline_tip(app, s, dpi, cues)
		}
	}
	ui.pop_parent(s)
	rows_map := head_map
	if !a.vertical {
		hovered: bool
		hovered, rows_map = timeline_rows_view(app, s, dpi, id, track_w)
		row_hovered ||= hovered
	}
	ui.pop_parent(s) // the track

	ui.spacer(s, ui.px(pad))
	ui.pop_parent(s)
	ui.spacer(s, ui.px(gap))
	ui.pop_parent(s)

	// The track takes what no row took: a press in the head (or below the
	// rows) scrubs, the wheel pans.
	sig := ui.signal_from_box(s, track)
	mouse := platform.mouse_pos(s.p)
	in_head := ui.mouse_over(head_sig)
	m := head_map if in_head else rows_map
	timeline_pointer(app, s, sig, m, -1)
	if ui.mouse_over(sig) {
		command_push(c, .Cursor_Hover, {count = clamp(frame_at(m, mouse), 0, preview_duration(app) - 1)})
	}
	// The wheel left by the rows pans a tenth of the view a notch, down or
	// right forward, as the horizontal wheel does (Shift turns the wheel
	// horizontal: the UI's); with Control, a notch up zooms in 1.25 times.
	if pan := sig.scroll.x + sig.scroll.y; pan != 0 {
		command_push(c, .Timeline_Pan, {scalar = f64(pan) / ui.NOTCH_STEPS * head_map.visible * 0.1})
	}
	if zoom := ui.action_scroll_take(s, {.Control}, any = true) if ui.hovering(sig) || row_hovered else 0; zoom != 0 {
		at := clamp(f64(axis_point(m.a, mouse).x - m.x0) / f64(m.w), 0, 1)
		command_push(c, .Timeline_Zoom, {scalar = math.pow(1.25, -f64(zoom) / ui.NOTCH_STEPS), ratio = at, flag = true})
	}
	track_data := new(Timeline_Draw, context.temp_allocator)
	track_data^ = {app, dpi, head_map, -1, 0, 0}
	ui.box_equip_custom_draw(track, track_draw, track_data)
	head_data := new(Timeline_Draw, context.temp_allocator)
	head_data^ = {app, dpi, head_map, -1, 0, 0}
	ui.box_equip_custom_draw(head, head_draw, head_data)
}

// The rows below the scenes, in the one scroll list: a block of units
// each (RAD's row blocks), `track_w` across; whether one is hovered, and how
// time maps onto them.
@(private = "file")
timeline_rows_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32, id: View_Id, track_w: f32) -> (row_hovered: bool, rows_map: Time_Map) {
	pv := &app.preview
	rows := timeline_rows(app)
	items := rows_window(&rows, 0, max(int))
	blocks := make([]ui.Scroll_List_Row_Block, len(items), context.temp_allocator)
	total := 0
	for i, k in items {
		blocks[k] = {int(row_height(pv.waves.items[i].kind)) / ROW_UNIT, 1}
		total += blocks[k].row_count
	}
	unit := ROW_UNIT * dpi
	dim := [2]f32{track_w, min(rows.points, pv.rows_room) * dpi}
	first_row, last_row := view_list_begin(app, s, dim, id, "###timeline_rows", total, unit)
	rows_map = time_map(app, TIME_ALONG, s.scroll_list.content.rect.min.x, max(dim.x - ui.scroll_bar_width(s), 1))
	if total > 0 {
		k := ui.scroll_list_item_from_row(blocks, first_row)
		for start := ui.scroll_list_row_from_item(blocks, k); k < len(items) && start < last_row; k += 1 {
			units := blocks[k].row_count
			skipped, chopped := max(0, first_row - start), max(0, start + units - last_row)
			start += units
			it := pv.waves.items[items[k]]
			ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_pref_height(s, ui.px(f32(units - skipped - chopped) * unit))
			box := ui.build_box(s, {.Clickable}, fmt.tprintf("###timeline_row_%x_%d", it.key, int(it.kind)))
			sig := ui.signal_from_box(s, box)
			timeline_pointer(app, s, sig, rows_map, items[k])
			draw := new(Timeline_Draw, context.temp_allocator)
			draw^ = {app, dpi, rows_map, items[k], k, f32(skipped) * unit}
			ui.box_equip_custom_draw(box, row_draw, draw)
			if ui.hovering(sig) {
				row_hovered = true
				timeline_tip(app, s, dpi, items[k])
			}
		}
	}
	view_list_end(app, s, id)
	return
}

// What the hovered row (`item`; the cues' band in the head is the cues
// row) is, and its path for `onimite show`, beside the pointer over
// everything (the tooltip root).
@(private = "file")
timeline_tip :: proc(app: ^App_State, s: ^ui.State, dpi: f32, item: int) {
	w := &app.preview.waves
	it := w.items[item]
	mouse := platform.mouse_pos(s.p)
	tip := fmt.tprintf("%s   (onimite show %s)", text_of(w.text[:], it.summary), text_of(w.text[:], it.path))
	ui.tooltip_begin(s)
	ui.set_next_bg_color(s, {10, 11, 15, 235}); ui.set_next_text_color(s, {235, 238, 244, 255})
	ui.set_next_font_size(s, 11 * dpi); ui.set_next_corner_radius(s, 3 * dpi)
	ui.set_next_text_padding(s, 5 * dpi)
	lh := render.line_height(s.font, 11 * dpi)
	place(s, {mouse.x + 12 * dpi, mouse.y - lh - 10 * dpi, ui.line_edit_text_width(s, tip, 11 * dpi) + 10 * dpi, lh + 4 * dpi})
	ui.build_box(s, {.Draw_Background, .Draw_Text}, fmt.tprintf("%s###timeline_tip", tip))
	ui.tooltip_end(s)
}

// The timeline's own controls at its ruler's right end, over the ruler's
// labels (RAD's top bar holds what acts on everything; a view's own
// controls are the view's): Follow while zoomed in or not following, zoom
// out, the zoom (a click fits it), zoom in. Running down, the ruler is too
// narrow: the keys and Ctrl+wheel zoom it.
@(private = "file")
timeline_zoom_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32) {
	pv := &app.preview
	c := &app.commands
	button :: proc(s: ^ui.State, text: string, dpi: f32, on := false) -> bool {
		ui.set_next_pref_width(s, ui.text_content(math.floor(8 * dpi), 1)); ui.set_next_pref_height(s, ui.pct(1))
		ui.set_next_visual_margin(s, {math.floor(dpi), math.floor(2 * dpi)})
		if on do ui.set_next_bg_color(s, s.theme.active)
		return ui.clicked(ui.button(s, text))
	}
	ui.spacer(s, ui.fill())
	ui.set_next_pref_width(s, ui.children_sum()); ui.set_next_pref_height(s, ui.pct(1)); ui.set_next_child_layout_axis(s, .X)
	ui.set_next_bg_color(s, RULER_BG); ui.set_next_corner_radius(s, 0)
	ui.push_parent(s, ui.build_box(s, {.Draw_Background}, "###timeline_zoom"))
	defer ui.pop_parent(s)
	if pv.zoom > 1.01 || pv.detached {
		if button(s, "Follow###follow", dpi, !pv.detached) do command_push(c, .Timeline_Follow, {flag = pv.detached})
	}
	if button(s, "-###zoom_out", dpi) do command_push(c, .Timeline_Zoom, {scalar = 1 / 1.5, count = pv.frame})
	if button(s, fmt.tprintf("%d%%###zoom_fit", int(math.round(pv.zoom * 100))), dpi) do command_push(c, .Timeline_Fit)
	if button(s, "+###zoom_in", dpi) do command_push(c, .Timeline_Zoom, {scalar = 1.5, count = pv.frame})
}

// A part of the head, `across` thick across time and along all of it
// (ParentPct 1), its children laid out along time.
@(private = "file")
across_box :: proc(s: ^ui.State, a: Time_Axis, across: ui.Size, key: string, flags: ui.Box_Flags = {}) -> ^ui.Box {
	if a.vertical {
		ui.set_next_pref_width(s, across); ui.set_next_pref_height(s, ui.pct(1))
	} else {
		ui.set_next_pref_width(s, ui.pct(1)); ui.set_next_pref_height(s, across)
	}
	ui.set_next_child_layout_axis(s, .Y if a.vertical else .X)
	return ui.build_box(s, flags, key)
}

// The cues' labels in their band (the parent): each a box its text's size
// (TextContent), floating at its cue along time, so the band is as wide as
// its widest when time runs down (ChildrenSum across). A label shows its
// text in view and clear of the one before.
@(private = "file")
cue_labels :: proc(app: ^App_State, s: ^ui.State, dpi: f32, m: Time_Map) {
	pv := &app.preview
	fps := f64(preview_fps(app))
	px := 11 * dpi * 0.85
	free: f32 = 0
	for c, i in pv.waves.cues {
		at := f32((c.seconds * fps - m.first) * m.ppf)
		name := text_of(pv.waves.text[:], c.name)
		along := axis_label_along(m.a, render.measure_text(s.font, name, px), render.line_height(s.font, px))
		shown := at >= 0 && at <= m.w && at + 3 * dpi >= free && at + along < m.w
		if shown do free = at + along + 8 * dpi
		if m.a.vertical {
			ui.set_next_fixed_y(s, at + 3 * dpi)
		} else {
			ui.set_next_fixed_x(s, at + 3 * dpi)
		}
		ui.set_next_pref_width(s, ui.text_content(4 * dpi)); ui.set_next_pref_height(s, ui.text_content())
		ui.set_next_font_size(s, px); ui.set_next_text_padding(s, 0)
		ui.set_next_text_color(s, {250, 230, 160, 230})
		label := ui.build_box(s, {.Draw_Text} if shown else {}, fmt.tprintf("%s###timeline_cue_%d", name, i))
		if !shown do label.str = name // measured, not drawn: the band's width counts it
	}
}

// One stage for the pointer on the timeline, the track's and each row's: a
// press focuses the timeline's panel; on a group's name (`item`'s, across
// its row's start) it opens or closes it, and the drag it starts doesn't
// scrub; else a press or a drag scrubs (Frame_Set); a middle or right drag
// pans from where the camera was when it was pressed.
@(private = "file")
timeline_pointer :: proc(app: ^App_State, s: ^ui.State, sig: ui.Signal, m: Time_Map, item: int) {
	pv := &app.preview
	c := &app.commands
	mouse := platform.mouse_pos(s.p)
	if ui.pressed(sig) {
		focus_panel(app, workspace_find(&pv.workspace, .Timeline))
		pv.press_on_name = false
		if item >= 0 && pv.waves.items[item].children > 0 && axis_point(m.a, mouse).x - m.x0 < ROW_NAME_WIDTH * app.preview.dpi {
			pv.press_on_name = true
			command_push(c, .Timeline_Row_Toggle, {spec = text_of(pv.waves.text[:], pv.waves.items[item].path)})
		}
	}
	if sig.flags & {.Middle_Pressed, .Right_Pressed} != {} {
		start := pv.timeline_camera.first
		ui.store_drag_struct(s, &start)
	}
	if (ui.dragging(sig) || ui.pressed(sig)) && !pv.press_on_name {
		command_push(c, .Frame_Set, {count = frame_at(m, mouse), flag = ui.dragging(sig)})
	}
	if ui.middle_dragging(sig) || ui.right_dragging(sig) {
		want := ui.drag_struct(s, f64)^ - f64(axis_motion(m.a, ui.drag_delta(s)).x) / m.ppf
		if want != pv.timeline_camera.first do command_push(c, .Timeline_Pan, {scalar = want - pv.timeline_camera.first, flag = true})
	}
}

// Ruler steps: frames below a second, then seconds and minutes.
@(private = "file")
ruler_step :: proc(fps: int, ppf: f64, min_px: f64) -> int {
	FRAME_STEPS :: [?]int{1, 2, 5, 10}
	SECOND_STEPS :: [?]int{1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600}
	for f in FRAME_STEPS {
		if f < fps && f64(f) * ppf >= min_px {
			return f
		}
	}
	for sec in SECOND_STEPS {
		if f64(sec * fps) * ppf >= min_px {
			return sec * fps
		}
	}
	return 3600 * fps
}

// The timeline's markers over a region `h` across from `y0` (the
// timeline's space): the marks (ranges as bands, moments as lines, each with
// its number at the top), the pending in point, the bookmark, the hovered
// frame and the playhead; `top`: with what sits at the top (numbers, flags,
// the playhead's head), `bottom`: with what sits at the bottom (the in
// point's foot). One stage for the head, every row and the track below them.
@(private = "file")
draw_markers :: proc(pen: Pen, d: ^Timeline_Draw, y0, h: f32, top, bottom: bool) {
	pv := &d.app.preview
	dpi := d.dpi
	m := d.m
	line_w := max(dpi, 1)
	x_of :: proc(m: Time_Map, f: f64) -> f32 {return m.x0 + f32((f - m.first) * m.ppf)}
	for mk in pv.marks {
		x := x_of(m, f64(mk.at))
		if mk.to >= 0 {
			x1 := x_of(m, f64(mk.to + 1))
			fill(pen, x, y0, max(x1 - x, line_w), h, {COLOR_MARK.r, COLOR_MARK.g, COLOR_MARK.b, 40})
			if top do fill(pen, x, y0, max(x1 - x, line_w), 3 * dpi, COLOR_MARK)
			fill(pen, x1 - line_w, y0, line_w, h, {COLOR_MARK.r, COLOR_MARK.g, COLOR_MARK.b, 160})
		}
		fill(pen, x, y0, line_w, h, {COLOR_MARK.r, COLOR_MARK.g, COLOR_MARK.b, 200})
		if top do text(pen, fmt.tprintf("%d", mk.n), {x + 3 * dpi, y0 + 3 * dpi}, 11 * dpi, COLOR_MARK)
	}
	if pv.mark_in >= 0 {
		x := x_of(m, f64(pv.mark_in))
		fill(pen, x, y0, line_w, h, COLOR_MARK)
		if top do fill(pen, x, y0, 7 * dpi, line_w * 2, COLOR_MARK)
		if bottom do fill(pen, x, y0 + h - line_w * 2, 7 * dpi, line_w * 2, COLOR_MARK)
	}
	if pv.bookmark >= 0 {
		x := x_of(m, f64(pv.bookmark))
		fill(pen, x, y0, line_w, h, {COLOR_BOOKMARK.r, COLOR_BOOKMARK.g, COLOR_BOOKMARK.b, 200})
		if top do fill(pen, x, y0, 8 * dpi, 7 * dpi, COLOR_BOOKMARK)
	}
	if pv.hover_valid {
		fill(pen, x_of(m, f64(pv.hover_frame)), y0, line_w, h, COLOR_HOVER)
	}
	head := x_of(m, f64(pv.frame))
	fill(pen, head - dpi, y0, 2 * dpi, h, COLOR_PLAYHEAD)
	if top do fill(pen, head - 4 * dpi, y0, 8 * dpi, 5 * dpi, COLOR_PLAYHEAD)
}

// The track's draw, beneath its head and rows: the markers over it all (the
// in point's foot at its bottom); and the frames the timeline shows ask
// again this frame (thumbs_shown, bands_shown, filled by the draws after).
@(private = "file")
track_draw :: proc(s: ^ui.State, box: ^ui.Box, c: ^vg.Canvas) {
	d := (^Timeline_Draw)(box.custom_data)
	pv := &d.app.preview
	clear(&pv.thumbs_shown)
	clear(&pv.bands_shown)
	a := d.m.a
	a.corner = box.rect.min
	pen := Pen{s, c, pv.renderer, a}
	extent := axis_motion(a, box.rect.max - box.rect.min)
	draw_markers(pen, d, box.rect.min.y, extent.y, false, true)
}

// The head's draw, each part where the head's layout put it (its boxes:
// across_box): the ruler (major ticks with labels: m:ss, or m:ss:ff below
// a second; minor ticks between), the scenes (overlapping ones on
// alternating rows, with thumbnails: each grid frame laid out asked for,
// thumbs_shown), the cues' band (its labels are its boxes), then the
// markers over it.
@(private = "file")
head_draw :: proc(s: ^ui.State, box: ^ui.Box, c: ^vg.Canvas) {
	d := (^Timeline_Draw)(box.custom_data)
	ruler := box.first
	scenes := ruler.next if ruler != nil else nil
	if scenes == nil do return
	app := d.app
	pv := &app.preview
	dpi := d.dpi
	m := d.m
	a := m.a
	a.corner = box.rect.min
	pen := Pen{s, c, pv.renderer, a}
	x0, y0 := m.x0, box.rect.min.y
	w := m.w
	h := axis_motion(a, box.rect.max - box.rect.min).y
	fps := preview_fps(app)
	first, visible, ppf := m.first, m.visible, m.ppf
	x_of :: proc(f, first, ppf: f64, x0: f32) -> f32 {
		return x0 + f32((f - first) * ppf)
	}
	line_w := max(dpi, 1)
	// A part's place across the head and its thickness.
	part :: proc(a: Time_Axis, head, b: ^ui.Box) -> (at, thick: f32) {
		return axis_motion(a, b.rect.min - head.rect.min).y, axis_motion(a, b.rect.max - b.rect.min).y
	}
	_, ruler_h := part(a, box, ruler)
	fill(pen, x0, y0, axis_motion(a, box.rect.max - box.rect.min).x, ruler_h, RULER_BG)
	step := ruler_step(fps, ppf, 70 * f64(dpi))
	minor := step / 5 if step % 5 == 0 else (step / 2 if step % 2 == 0 else step)
	if f64(minor) * ppf < 5 * f64(dpi) {
		minor = step
	}
	font_px := 11 * dpi
	for f := int(first) / minor * minor; f64(f) <= first + visible; f += minor {
		x := x_of(f64(f), first, ppf, x0)
		if f % step == 0 {
			fill(pen, x, y0 + ruler_h * 0.35, line_w, ruler_h * 0.65, {120, 128, 142, 255})
			secs := f / fps
			label := fmt.tprintf("%d:%02d", secs / 60, secs % 60) if step % fps == 0 else fmt.tprintf("%d:%02d:%02d", secs / 60, secs % 60, f % fps)
			text(pen, label, {x + 3 * dpi, y0 + 1 * dpi}, font_px, COLOR_TEXT_DIM)
		} else {
			fill(pen, x, y0 + ruler_h * 0.7, line_w, ruler_h * 0.3, {80, 86, 98, 255})
		}
	}
	scene_at, scene_h := part(a, box, scenes)
	g := thumb_grid(app, a, ppf, scene_h, dpi)
	scene_y := y0 + scene_at + 2 * dpi
	for sc, i in segments(app) {
		xa := x_of(f64(sc.start_frame), first, ppf, x0)
		xb := x_of(f64(min(sc.end_frame, preview_duration(app))), first, ppf, x0)
		if xb < x0 || xa > x0 + w {
			continue
		}
		y := scene_y + (g.thumb_h * f32(i % 2) if g.two_rows else 0)
		cx0, cx1 := max(xa, x0), min(xb - line_w, x0 + w)
		if cx1 <= cx0 {
			continue
		}
		fill_rounded(pen, xa, y, xb - xa - line_w, g.thumb_h, 3 * dpi, SCENE_COLORS[i % len(SCENE_COLORS)])
		clip(pen, cx0, y, cx1 - cx0, g.thumb_h)
		from, to := thumb_range(sc, g, first, visible)
		for f := from; f < to; f += g.step {
			append(&pv.thumbs_shown, f)
			k, found := slice.binary_search_by(pv.thumbs[:], f, proc(t: Preview_Thumb, f: int) -> slice.Ordering {
				return slice.cmp(t.frame, f)
			})
			if !found {
				continue
			}
			image(pen, pv.thumbs[k].texture, pv.thumb_size, x_of(f64(f), first, ppf, x0), y, g.thumb_w - line_w, g.thumb_h)
		}
		if name := scene_name(&pv.timeline, sc); name != "" {
			fs := 12 * dpi
			tw := render.measure_text(s.font, name, fs)
			lh := render.line_height(s.font, fs)
			label(pen, name, {cx0 + 2 * dpi, y + 2 * dpi}, {tw + 8 * dpi, lh + 2 * dpi}, {cx0 + 6 * dpi, y + 3 * dpi}, 3 * dpi, fs, {0, 0, 0, 150}, {240, 242, 246, 255})
		}
		clip_end(pen)
	}
	// The cues' band, after the scenes (beside them when time runs down).
	if band := scenes.next; band != nil {
		at, thick := part(a, box, band)
		view := Row_View{s, d, a, pen, x0, w, first, ppf, f64(om.MIX_RATE) / f64(fps), line_w, font_px}
		draw_cues(&view, y0 + at, thick)
	}
	draw_markers(pen, d, y0, h, true, false)
}

// A row's draw, the way its kind says (a bands row shown asks for its
// source's rows: bands_shown), whole from where it starts (above its box
// when scrolled partly out: the list clips it), then the markers over its
// box.
@(private = "file")
row_draw :: proc(s: ^ui.State, box: ^ui.Box, c: ^vg.Canvas) {
	d := (^Timeline_Draw)(box.custom_data)
	app := d.app
	pv := &app.preview
	dpi := d.dpi
	m := d.m
	pen := Pen{s, c, pv.renderer, m.a}
	fps := preview_fps(app)
	font_px := 11 * dpi
	view := Row_View{s, d, m.a, pen, m.x0, m.w, m.first, m.ppf, f64(om.MIX_RATE) / f64(fps), max(dpi, 1), font_px}
	it := &pv.waves.items[d.item]
	y := box.rect.min.y - d.skipped
	rh := row_height(it.kind) * dpi
	depth := 0
	for p := it.parent; p >= 0; p = pv.waves.items[p].parent {
		depth += 1
	}
	switch it.kind {
	case .Scenes, .Cues:
	// the head's
	case .Bands:
		draw_bands(&view, it^, y, rh - 2 * dpi)
		draw_row_name(&view, text_of(pv.waves.text[:], it.label), y, rh - 2 * dpi, 14 * dpi * f32(depth))
	case .Group, .Track, .Part, .Notes, .Hits:
		// a lane: its regions, each with its waveform (a notes view: its
		// notes over them), its name (and level when it differs from what
		// it sits under), open or closed when it has children
		if it.kind == .Notes || it.kind == .Hits {
			draw_notes(&view, it^, y, rh - 2 * dpi, d.order + 2)
		} else {
			draw_lane(&view, int(it.lane), y, rh - 2 * dpi, d.order + 2)
		}
		lane := pv.waves.lanes[it.lane]
		name := text_of(pv.waves.text[:], it.label)
		above: f32
		if it.parent >= 0 && pv.waves.items[it.parent].lane >= 0 {
			above = pv.waves.lanes[pv.waves.items[it.parent].lane].gain_db
		}
		if lane.gain_db != above {
			name = fmt.tprintf("%s · %+.1f dB", name, lane.gain_db)
		}
		if it.children > 0 {
			name = fmt.tprintf("%s %s  %d", "-" if timeline_row_open(app, it^) else "+", name, it.children)
		}
		draw_row_name(&view, name, y, rh - 2 * dpi, 14 * dpi * f32(depth))
	}
	draw_markers(pen, d, box.rect.min.y, box.rect.max.y - box.rect.min.y, false, false)
}

// What drawing a row needs from the timeline's draw.
@(private = "file")
Row_View :: struct {
	s:                 ^ui.State,
	d:                 ^Timeline_Draw,
	a:                 Time_Axis,
	pen:               Pen,
	x0, w:             f32,
	first, ppf:        f64,
	samples_per_frame: f64,
	line_w, font_px:   f32,
}

// A lane: its span, and its min/max waveform shaped by its fades (at full
// scale so quiet tracks stay readable; the gain is in the name; ducking and
// the limiter are not shown). A group's lane is its tracks' sound together.
@(private = "file")
draw_lane :: proc(v: ^Row_View, index: int, y, lane_h: f32, color_index: int) {
	waves := &v.d.app.preview.waves
	if index < 0 || index >= len(waves.lanes) {
		return
	}
	lane := &waves.lanes[index]
	dpi := v.d.dpi
	fill(v.pen, v.x0, y, v.w, lane_h, LANE_BG)
	color := SCENE_COLORS[color_index % len(SCENE_COLORS)]
	wave := [4]u8{u8(min(int(color.r) + 90, 255)), u8(min(int(color.g) + 90, 255)), u8(min(int(color.b) + 90, 255)), 255}
	mid := y + lane_h * 0.5
	half := lane_h * 0.5 - v.line_w
	length := lane.end - lane.start
	col_w := max(math.round(dpi), 1)
	// each region: where its source sounds, a view of its pyramid
	for reg in waves.regions[lane.regions[0]:][:lane.regions[1]] {
		xa, xb := x_of_sample(v, reg.start), x_of_sample(v, reg.end)
		cx0, cx1 := max(xa, v.x0), min(xb, v.x0 + v.w)
		if cx1 <= cx0 {
			continue
		}
		fill_rounded(v.pen, xa, y, xb - xa, lane_h, 3 * dpi, {color.r, color.g, color.b, 90})
		if reg.clip < 0 {
			continue
		}
		clip := &waves.clips[reg.clip]
		for cx := cx0; cx < cx1; cx += col_w {
			s0 := int((v.first + f64(cx - v.x0) / v.ppf) * v.samples_per_frame)
			s1 := int((v.first + f64(cx + col_w - v.x0) / v.ppf) * v.samples_per_frame)
			// the source samples under the column, either way
			f0 := reg.at + int(f64(s0 - reg.start) * f64(reg.speed))
			f1 := reg.at + int(f64(s1 - reg.start) * f64(reg.speed))
			lo, hi, ok := wave_peak(waves, clip, min(f0, f1), max(f0, f1))
			if !ok {
				break // still being computed
			}
			env := om.track_envelope_peak(s0 - lane.start, s1 - lane.start, length, lane.fade_in, lane.fade_out, lane.curve)
			top := mid - clamp(hi * env, -1, 1) * half
			bottom := mid - clamp(lo * env, -1, 1) * half
			fill(v.pen, cx, top, col_w, max(bottom - top, v.line_w), wave)
		}
	}
}

// A bands view: where its song plays, the song's band rows as the worker
// made them into its texture (20 Hz at the bottom), a column per row; the
// rows asked for while shown (bands_shown).
@(private = "file")
draw_bands :: proc(v: ^Row_View, it: Timeline_Item, y, h: f32) {
	pv := &v.d.app.preview
	fill(v.pen, v.x0, y, v.w, h, LANE_BG)
	spans := pv.waves.band_spans[it.bands[0]:][:it.bands[1]]
	if len(spans) == 0 {
		return
	}
	source := spans[0].source
	if !slice.contains(pv.bands_shown[:], source) {
		append(&pv.bands_shown, source)
	}
	if int(source) >= len(pv.band_textures) {
		return
	}
	bt := pv.band_textures[source]
	if bt.texture == nil || bt.rows == 0 {
		return
	}
	for sp in spans {
		xa, xb := max(x_of_sample(v, sp.start), v.x0), min(x_of_sample(v, sp.end), v.x0 + v.w)
		if xb <= xa {
			continue
		}
		// song rows under [xa, xb): split where a strip ends
		sample_at :: proc(v: ^Row_View, x: f32) -> f64 {return (v.first + f64(x - v.x0) / v.ppf) * v.samples_per_frame}
		r0 := (sample_at(v, xa) - f64(sp.zero)) / f64(bt.step)
		r1 := (sample_at(v, xb) - f64(sp.zero)) / f64(bt.step)
		for r0 < r1 && r0 < f64(bt.rows) {
			strip := int(max(r0, 0)) / BAND_STRIP
			end := min(r1, f64((strip + 1) * BAND_STRIP), f64(bt.rows))
			if end <= r0 {
				break
			}
			x0 := xa + f32((r0 - (sample_at(v, xa) - f64(sp.zero)) / f64(bt.step)) * f64(bt.step) / v.samples_per_frame * v.ppf)
			x1 := xa + f32((end - (sample_at(v, xa) - f64(sp.zero)) / f64(bt.step)) * f64(bt.step) / v.samples_per_frame * v.ppf)
			// half a texel in from the strip's top and bottom: filtering
			// blends bands, never the strips stacked above and below
			src := [4]f32{f32(r0 - f64(strip * BAND_STRIP)), f32(strip * om.BAND_COUNT) + 0.5, f32(end - f64(strip * BAND_STRIP)), f32((strip + 1) * om.BAND_COUNT) - 0.5}
			wx, wy, ww, wh := axis_rect(v.a, x0, y, x1 - x0, h)
			image_src(v.pen, bt.texture, {u32(bt.width), u32(bt.height)}, src, wx, wy, ww, wh)
			r0 = end
		}
	}
}

// A notes view: its lane's regions, and its notes over them: pitched notes
// by pitch (its lowest at the bottom, its highest at the top), a pad's hits
// as marks, each as strong as it is played.
@(private = "file")
draw_notes :: proc(v: ^Row_View, it: Timeline_Item, y, lane_h: f32, color_index: int) {
	waves := &v.d.app.preview.waves
	dpi := v.d.dpi
	fill(v.pen, v.x0, y, v.w, lane_h, LANE_BG)
	color := SCENE_COLORS[color_index % len(SCENE_COLORS)]
	if it.lane >= 0 {
		lane := waves.lanes[it.lane]
		for reg in waves.regions[lane.regions[0]:][:lane.regions[1]] {
			xa, xb := x_of_sample(v, reg.start), x_of_sample(v, reg.end)
			if min(xb, v.x0 + v.w) > max(xa, v.x0) {
				fill_rounded(v.pen, xa, y, xb - xa, lane_h, 3 * dpi, {color.r, color.g, color.b, 50})
			}
		}
	}
	notes := waves.notes[it.notes[0]:][:it.notes[1]]
	lo, hi := f32(math.F32_MAX), f32(-math.F32_MAX)
	for n in notes {
		lo, hi = min(lo, n.pitch), max(hi, n.pitch)
	}
	rows := max(hi - lo + 1, 1)
	step := lane_h / rows
	for n in notes {
		xa, xb := x_of_sample(v, n.start), x_of_sample(v, n.end)
		if xb < v.x0 || xa > v.x0 + v.w {
			continue
		}
		a := u8(clamp(90 + 165 * n.velocity, 0, 255))
		ink := [4]u8{u8(min(int(color.r) + 110, 255)), u8(min(int(color.g) + 110, 255)), u8(min(int(color.b) + 110, 255)), a}
		if it.kind == .Hits {
			fill(v.pen, xa, y + 2 * dpi, max(2 * dpi, min(xb - xa, 4 * dpi)), lane_h - 4 * dpi, ink)
			continue
		}
		ny := y + (hi - n.pitch) * step
		fill(v.pen, xa, ny, max(xb - xa, dpi), max(step - dpi, dpi), ink)
	}
}

// Where mix sample `s` is across the row.
@(private = "file")
x_of_sample :: proc(v: ^Row_View, s: int) -> f32 {
	return v.x0 + f32((f64(s) / v.samples_per_frame - v.first) * v.ppf)
}

// A row's name on a dark tab: at the start of the row (groups, `at < 0`),
// or at the start of its span (`at` in mix samples) while that is in view;
// kept inside its row.
@(private = "file")
draw_row_name :: proc(v: ^Row_View, name: string, y, row_h, indent: f32, at := -1) {
	dpi := v.d.dpi
	label_h := render.line_height(v.s.font, v.font_px)
	if row_h < label_h {
		return
	}
	x := v.x0 + indent
	if at >= 0 {
		x = max(x, v.x0 + f32((f64(at) / v.samples_per_frame - v.first) * v.ppf))
	}
	if x >= v.x0 + v.w {
		return
	}
	tw := render.measure_text(v.s.font, name, v.font_px)
	clip(v.pen, v.x0, y, v.w, row_h)
	label(v.pen, name, {x + 2 * dpi, y + (row_h - label_h) * 0.5 - dpi}, {tw + 6 * dpi, label_h + 2 * dpi}, {x + 5 * dpi, y + (row_h - label_h) * 0.5}, 3 * dpi, v.font_px, {0, 0, 0, 140}, {235, 238, 244, 230})
	clip_end(v.pen)
}

// The cues' band: a mark at each cue (their names are the band's boxes:
// cue_labels).
@(private = "file")
draw_cues :: proc(v: ^Row_View, y, row_h: f32) {
	pv := &v.d.app.preview
	fps := f64(preview_fps(v.d.app))
	fill(v.pen, v.x0, y, v.w, row_h - v.d.dpi, LANE_BG)
	for c in pv.waves.cues {
		x := v.x0 + f32((c.seconds * fps - v.first) * v.ppf)
		if x >= v.x0 && x <= v.x0 + v.w do fill(v.pen, x, y, v.line_w, row_h - v.d.dpi, {250, 204, 21, 220})
	}
}
