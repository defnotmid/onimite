package onimite_app

import "core:fmt"
import "core:hash"
import "core:math"
import "core:slice"
import om "../onimite"
import platform "../platform"
import render "../render"
import ui "../ui"

// The preview's timeline: a time ruler over rows, one per item the worker
// published (preview_tables.odin), each drawn the way its kind says: the
// scenes as segments with thumbnails, the cues as marks, a bus's tracks as
// one group lane with their sound together (click its name to open it to
// a lane per track), a track's span and waveform, a song's open to a lane
// per part. Hovering a row says what
// it is, with the path `onimite show` takes. The bookmark, the hovered
// frame and the playhead run over all of it. It zooms (Ctrl+wheel, +/-),
// pans (wheel, horizontal wheel or touchpad, middle drag) and follows the
// playhead; the wheel over rows that don't fit scrolls them. In a panel
// at the side of another and taller than wide, time runs down and the
// ruler, the scenes and the rows are columns side by side (`Time_Axis`).
//
// It is one box whose custom draw paints everything from the published
// tables in O(pixels): waveforms read one pyramid level per pixel column,
// thumbnails come from the worker's cache by frame. Input on the box
// becomes command rows.

TRACK_PAD :: 8
TIMELINE_GAP :: 6
RULER_HEIGHT :: 18
// The ruler across when time runs down: its labels are side by side with it.
RULER_WIDTH :: 44
// Running down, the scenes and rows widen up to this many times to share
// the panel's width.
ACROSS_MAX :: 4
SCENE_HEIGHT :: 48
CUE_HEIGHT :: 14
LANE_HEIGHT :: 24
TRACK_HEIGHT :: 18
// The rows below the scenes take at most this many points at the
// timeline's natural height; past what its panel gives them, they scroll.
ROWS_AREA_MAX :: 12 * LANE_HEIGHT
// Clicks this far into a group's row open or close it.
ROW_NAME_WIDTH :: 160
THUMBS_WANTED_MAX :: 64
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
}

@(private = "file")
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
	// The scenes' and rows' points across per point of their height (above
	// 1 when they share a wider panel than they need).
	across:   f32,
}

// Time along x: the window's own axes.
TIME_ALONG :: Time_Axis{ruler = RULER_HEIGHT, across = 1}

// Whether the timeline in leaf `panel` runs down: the panel is at the side
// of another (its split is left / right) and its `area` is taller than
// wide. Across the top or bottom, or alone, it runs along.
timeline_vertical :: proc(ws: ^Workspace, panel: Panel_Id, area: Workspace_Rect) -> bool {
	p := workspace_panel(ws, panel)
	split := workspace_panel(ws, p.parent) if p != nil else nil
	return split != nil && split.axis == .X && area.height > area.width
}

// How the timeline lies in its `area` (pixels): along it, or (`vertical`)
// down it, its columns sharing the area's width.
timeline_axis :: proc(app: ^App_State, area: Workspace_Rect, dpi: f32, vertical: bool) -> Time_Axis {
	if !vertical {
		return TIME_ALONG
	}
	total, _ := rows_points(app, timeline_rows(app))
	room := area.width / dpi - 2 * TRACK_PAD - RULER_WIDTH
	return {vertical = true, ruler = RULER_WIDTH, across = clamp(room / (SCENE_HEIGHT + total), 1, ACROSS_MAX)}
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

// Drawing in the timeline's space.
@(private = "file")
fill :: proc(r: ^render.Renderer, a: Time_Axis, x, y, w, h: f32, c: [4]u8) {
	wx, wy, ww, wh := axis_rect(a, x, y, w, h)
	render.draw_rect(r, wx, wy, ww, wh, c)
}

@(private = "file")
fill_rounded :: proc(r: ^render.Renderer, a: Time_Axis, x, y, w, h, radius: f32, c: [4]u8) {
	wx, wy, ww, wh := axis_rect(a, x, y, w, h)
	render.draw_rect_rounded(r, wx, wy, ww, wh, radius, c)
}

@(private = "file")
clip :: proc(r: ^render.Renderer, a: Time_Axis, x, y, w, h: f32) {
	wx, wy, ww, wh := axis_rect(a, x, y, w, h)
	render.clip_push(r, wx, wy, ww, wh)
}

@(private = "file")
image :: proc(r: ^render.Renderer, a: Time_Axis, img: ^render.Image, x, y, w, h: f32) {
	wx, wy, ww, wh := axis_rect(a, x, y, w, h)
	render.draw_image_contain(r, img, wx, wy, ww, wh)
}

// Upright text starting at `at`.
@(private = "file")
text :: proc(s: ^ui.State, a: Time_Axis, str: string, at: [2]f32, px: f32, c: [4]u8) {
	p := axis_point(a, at)
	render.draw_text(s.r, s.font, str, p.x, p.y, px, c)
}

// An upright label: a tab `size` big (window pixels) starting at `at`,
// its text at `text_at` (both in the timeline's space; the text keeps its
// place in the tab).
@(private = "file")
label :: proc(s: ^ui.State, a: Time_Axis, str: string, at, size, text_at: [2]f32, radius, px: f32, tab, c: [4]u8) {
	p := axis_point(a, at)
	q := p + (text_at - at) if a.vertical else text_at
	render.draw_rect_rounded(s.r, p.x, p.y, size.x, size.y, radius, tab)
	render.draw_text(s.r, s.font, str, q.x, q.y, px, c)
}

timeline_row_open :: proc(app: ^App_State, item: Timeline_Item) -> bool {
	pv := &app.preview
	h := hash.fnv64a(transmute([]u8)text_of(pv.waves.text[:], item.path))
	return slice.contains(pv.rows_open[:], h)
}

// The items shown below the scenes, in order: the top-level ones and the
// children of open items (a group's tracks, a song's parts), each listed
// right after its parent.
timeline_rows :: proc(app: ^App_State) -> []int {
	pv := &app.preview
	items := pv.waves.items[:]
	rows := make([dynamic]int, 0, len(items), context.temp_allocator)
	for it, i in items {
		if it.kind == .Scenes {
			continue
		}
		shown := true
		for p := it.parent; p >= 0 && shown; p = items[p].parent {
			shown = timeline_row_open(app, items[p])
		}
		if shown {
			append(&rows, i)
		}
	}
	return rows[:]
}

// Points of the rows below the scenes: all of them, and what shows in the
// timeline's panel.
@(private = "file")
rows_points :: proc(app: ^App_State, rows: []int) -> (total, shown: f32) {
	for i in rows {
		total += row_height(app.preview.waves.items[i].kind)
	}
	return total, min(total, app.preview.rows_room)
}

// Keeps the scroll inside the rows (after a group opens or closes).
timeline_rows_clamp :: proc(app: ^App_State) {
	pv := &app.preview
	rows := timeline_rows(app)
	total, shown := rows_points(app, rows)
	// The last first row that still fills the area.
	last := len(rows)
	for acc: f32 = 0; last > 0 && acc + row_height(pv.waves.items[rows[last - 1]].kind) <= shown; last -= 1 {
		acc += row_height(pv.waves.items[rows[last - 1]].kind)
	}
	limit := last if total > shown else 0
	pv.rows_scroll = clamp(pv.rows_scroll, 0, limit)
	ui.scroll_limit(&pv.rows_scroll_reg, f64(limit))
	ui.scroll_to(&pv.rows_scroll_reg, f64(pv.rows_scroll))
}

// Points the rows below the scenes get in the timeline's `area` (pixels)
// lying along `a`: what the box leaves across after the ruler and the
// scenes.
timeline_rows_room :: proc(a: Time_Axis, area: Workspace_Rect, dpi: f32) -> f32 {
	across := area.width / dpi - 2 * TRACK_PAD if a.vertical else area.height / dpi - 2 * TIMELINE_GAP
	return max((across - a.ruler) / a.across - SCENE_HEIGHT, 0)
}

// The timeline's natural height in points (before dpi scaling): the
// ruler, the scenes and up to ROWS_AREA_MAX of rows.
timeline_height :: proc(app: ^App_State) -> f32 {
	if app.preview.timeline_collapsed {
		return 0
	}
	total, _ := rows_points(app, timeline_rows(app))
	return TIMELINE_GAP * 2 + RULER_HEIGHT + SCENE_HEIGHT + min(total, ROWS_AREA_MAX)
}

// The scene segments; a video without scenes is one segment.
@(private = "file")
segments :: proc(app: ^App_State) -> []Preview_Scene {
	if scenes := app.preview.timeline.scenes[:]; len(scenes) > 0 {
		return scenes
	}
	whole := make([]Preview_Scene, 1, context.temp_allocator)
	whole[0] = {{}, 0, preview_duration(app)}
	return whole
}

// Thumbnails sit on a grid of frame steps from each segment's start: powers
// of two and their halves again (1, 2, 3, 4, 6, 8, 12, ...), the smallest
// that fits a thumbnail's width at this zoom. Gaps stay under a third of a
// thumbnail, and zooming finds most frames of the neighbouring grids already
// cached (the cache is keyed by frame).
@(private = "file")
Thumb_Grid :: struct {
	step:      int,
	width:     f64, // a thumbnail's width in frames
	thumb_w:   f32, // and in pixels
	thumb_h:   f32,
	two_rows:  bool,
}

@(private = "file")
thumb_grid :: proc(app: ^App_State, a: Time_Axis, ppf: f64, dpi: f32) -> Thumb_Grid {
	pv := &app.preview
	g: Thumb_Grid
	g.two_rows = len(pv.timeline.scenes) > 1
	g.thumb_h = (SCENE_HEIGHT - 4) * dpi * a.across
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

// The thumbnail frames the timeline shows (at most THUMBS_WANTED_MAX),
// nearest the view's centre first: what the worker renders when idle.
thumbs_wanted :: proc(app: ^App_State, p: ^platform.Platform) -> []int {
	pv := &app.preview
	area, shown := view_area(app, .Timeline)
	if !shown || pv.timeline_collapsed || pv.timeline.frames <= 0 {
		return nil
	}
	dpi := p.dpi_scale
	a := pv.timeline_axis
	w := f64(area.width) - 2 * TRACK_PAD * f64(dpi)
	if a.vertical {
		w = f64(area.height) - 2 * TIMELINE_GAP * f64(dpi)
	}
	first, visible := pv.view_first, view_frames(app)
	g := thumb_grid(app, a, w / visible, dpi)
	out := make([dynamic]int, 0, THUMBS_WANTED_MAX, context.temp_allocator)
	for sc in segments(app) {
		j := max(int(math.floor((first - f64(sc.start_frame) - g.width) / f64(g.step))), 0)
		for f := sc.start_frame + j * g.step; f < sc.end_frame && f64(f) < first + visible; f += g.step {
			if len(out) == THUMBS_WANTED_MAX {
				break
			}
			if f64(f) + g.width >= first {
				append(&out, f)
			}
		}
	}
	centre := int(first + visible / 2)
	context.user_index = centre
	slice.sort_by(out[:], proc(a, b: int) -> bool {
		c := context.user_index
		return abs(a - c) < abs(b - c) || (abs(a - c) == abs(b - c) && a < b)
	})
	return out[:]
}

@(private = "file")
Timeline_Draw :: struct {
	app:  ^App_State,
	dpi:  f32,
	axis: Time_Axis,
	head: f32, // the playhead frame
}

// The timeline in `area` (pixels), inset by TRACK_PAD and TIMELINE_GAP.
timeline_view :: proc(app: ^App_State, s: ^ui.State, dpi: f32, area: Workspace_Rect) {
	pv := &app.preview
	c := &app.commands
	if pv.timeline_collapsed {
		return
	}
	pad, gap := TRACK_PAD * dpi, TIMELINE_GAP * dpi
	ui.set_next_bg_color(s, COLOR_TRACK)
	ui.set_next_corner_radius(s, 4 * dpi)
	track := place_box(s, {area.x + pad, area.y + gap, max(area.width - 2 * pad, 0), max(area.height - 2 * gap, 0)}, {.Clickable, .Draw_Background, .Clip}, "###timeline")
	sig := ui.signal_from_box(s, track)
	a := pv.timeline_axis

	// Last frame's rect (immediate-mode): what the pointer maps onto, in
	// the timeline's space.
	a.corner = track.rect.min
	extent := axis_motion(a, track.rect.max - track.rect.min)
	w := f64(extent.x)
	visible := view_frames(app)
	if w > 0 {
		ppf := w / visible
		frame_at :: proc(pv: ^Preview_State, track: ^ui.Box, x: f32, ppf: f64) -> int {
			return int(math.floor(pv.view_first + f64(x - track.rect.min.x) / ppf))
		}
		mouse := axis_point(a, platform.mouse_pos(s.p))
		hit, in_name := row_at(app, a, track, mouse, dpi)
		if ui.pressed(sig) {
			// A press on a group's name opens or closes it, and the drag it
			// starts doesn't scrub.
			pv.press_on_name = hit >= 0 && in_name && pv.waves.items[hit].children > 0
			if pv.press_on_name {
				command_push(c, .Timeline_Row_Toggle, {spec = text_of(pv.waves.text[:], pv.waves.items[hit].path)})
			}
		}
		if (ui.dragging(sig) || ui.pressed(sig)) && !pv.press_on_name {
			command_push(c, .Frame_Set, {count = frame_at(pv, track, mouse.x, ppf), flag = ui.dragging(sig)})
		}
		if ui.mouse_over(sig) {
			command_push(c, .Cursor_Hover, {count = clamp(frame_at(pv, track, mouse.x, ppf), 0, preview_duration(app) - 1)})
		}
		if motion := axis_motion(a, sig.drag_motion); (ui.middle_dragging(sig) || ui.right_dragging(sig)) && motion.x != 0 {
			command_push(c, .Timeline_Pan, {scalar = -f64(motion.x) / ppf, flag = true})
		}
		total, shown := rows_points(app, timeline_rows(app))
		shift := platform.shift_down(s.p)
		if sig.scroll != 0 && !shift && hit >= 0 && total > shown {
			command_push(c, .Timeline_Rows_Scroll, {count = -1 if sig.scroll > 0 else 1})
		} else if sig.scroll != 0 || sig.scroll_x != 0 {
			command_push(c, .Timeline_Pan, {scalar = f64(sig.scroll_x - sig.scroll) * visible * 0.1})
		}
		if sig.zoom != 0 {
			at := clamp(f64(mouse.x - track.rect.min.x) / w, 0, 1)
			command_push(c, .Timeline_Zoom, {scalar = math.pow(1.25, f64(sig.zoom)), ratio = at, flag = true})
		}
	}

	data := new(Timeline_Draw, context.temp_allocator)
	data^ = {app, dpi, a, f32(pv.frame)}
	track.custom_draw = timeline_draw
	track.custom_draw_data = data
}

// The row under `mouse` (an item index, -1 for none: the ruler, the scenes,
// below the rows) and whether it is over the row's name, from the box's
// last rect.
@(private = "file")
row_at :: proc(app: ^App_State, a: Time_Axis, track: ^ui.Box, mouse: [2]f32, dpi: f32) -> (item: int, in_name: bool) {
	pv := &app.preview
	y := track.rect.min.y + (a.ruler + SCENE_HEIGHT * a.across) * dpi
	rows := timeline_rows(app)
	_, shown := rows_points(app, rows)
	if mouse.y < y || mouse.y >= y + shown * dpi * a.across {
		return -1, false
	}
	first_row := clamp(int(math.floor(pv.rows_scroll_reg.current)), 0, len(rows))
	fraction := f32(pv.rows_scroll_reg.current) - f32(first_row)
	if first_row < len(rows) && fraction > 0 {
		y -= fraction * row_height(pv.waves.items[rows[first_row]].kind) * dpi * a.across
	}
	for i in rows[first_row:] {
		h := row_height(pv.waves.items[i].kind) * dpi * a.across
		if mouse.y < y + h {
			return i, mouse.x - track.rect.min.x < axis_label_along(a, ROW_NAME_WIDTH, LANE_HEIGHT) * dpi
		}
		y += h
	}
	return -1, false
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

@(private = "file")
timeline_draw :: proc(s: ^ui.State, box: ^ui.Box, data: rawptr) {
	d := (^Timeline_Draw)(data)
	app := d.app
	pv := &app.preview
	dpi := d.dpi
	r := s.r
	a := d.axis
	a.corner = box.rect.min
	// The box in the timeline's space: `w` along time, `h` across.
	x0, y0 := box.rect.min.x, box.rect.min.y
	extent := axis_motion(a, box.rect.max - box.rect.min)
	w, h := extent.x, extent.y
	fps := preview_fps(app)
	first, visible := pv.view_first, view_frames(app)
	ppf := f64(w) / visible
	x_of :: proc(f, first, ppf: f64, x0: f32) -> f32 {
		return x0 + f32((f - first) * ppf)
	}
	line_w := max(dpi, 1)

	// Ruler: major ticks with labels (m:ss, or m:ss:ff below a second),
	// minor ticks between.
	ruler_h := a.ruler * dpi
	fill(r, a, x0, y0, w, ruler_h, RULER_BG)
	step := ruler_step(fps, ppf, 70 * f64(dpi))
	minor := step / 5 if step % 5 == 0 else (step / 2 if step % 2 == 0 else step)
	if f64(minor) * ppf < 5 * f64(dpi) {
		minor = step
	}
	font_px := 11 * dpi
	for f := int(first) / minor * minor; f64(f) <= first + visible; f += minor {
		x := x_of(f64(f), first, ppf, x0)
		if f % step == 0 {
			fill(r, a, x, y0 + ruler_h * 0.35, line_w, ruler_h * 0.65, {120, 128, 142, 255})
			secs := f / fps
			label := fmt.tprintf("%d:%02d", secs / 60, secs % 60) if step % fps == 0 else fmt.tprintf("%d:%02d:%02d", secs / 60, secs % 60, f % fps)
			text(s, a, label, {x + 3 * dpi, y0 + 1 * dpi}, font_px, COLOR_TEXT_DIM)
		} else {
			fill(r, a, x, y0 + ruler_h * 0.7, line_w, ruler_h * 0.3, {80, 86, 98, 255})
		}
	}

	// Scenes, overlapping ones on alternating rows, with thumbnails.
	g := thumb_grid(app, a, ppf, dpi)
	scene_y := y0 + ruler_h + 2 * dpi
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
		fill_rounded(r, a, xa, y, xb - xa - line_w, g.thumb_h, 3 * dpi, SCENE_COLORS[i % len(SCENE_COLORS)])
		clip(r, a, cx0, y, cx1 - cx0, g.thumb_h)
		j := max(int(math.floor((first - f64(sc.start_frame) - g.width) / f64(g.step))), 0)
		for f := sc.start_frame + j * g.step; f < sc.end_frame && f64(f) < first + visible; f += g.step {
			k, found := slice.binary_search_by(pv.thumbs[:], f, proc(t: Preview_Thumb, f: int) -> slice.Ordering {
				return slice.cmp(t.frame, f)
			})
			if !found {
				continue
			}
			img := render.Image{pv.thumbs[k].texture, pv.thumb_size.x, pv.thumb_size.y}
			image(r, a, &img, x_of(f64(f), first, ppf, x0), y, g.thumb_w - line_w, g.thumb_h)
		}
		if name := scene_name(&pv.timeline, sc); name != "" {
			fs := 12 * dpi
			tw := render.measure_text(s.font, name, fs)
			lh := render.line_height(s.font, fs)
			label(s, a, name, {cx0 + 2 * dpi, y + 2 * dpi}, {tw + 8 * dpi, lh + 2 * dpi}, {cx0 + 6 * dpi, y + 3 * dpi}, 3 * dpi, fs, {0, 0, 0, 150}, {240, 242, 246, 255})
		}
		render.clip_pop(r)
	}

	// The rows below the scenes, each drawn the way its kind says.
	rows := timeline_rows(app)
	_, shown := rows_points(app, rows)
	rows_y := y0 + ruler_h + SCENE_HEIGHT * dpi * a.across
	clip(r, a, x0, rows_y, w, shown * dpi * a.across)
	view := Row_View{s, d, a, x0, w, first, ppf, f64(om.MIX_RATE) / f64(fps), line_w, font_px}
	window_mouse := platform.mouse_pos(s.p)
	mouse := axis_point(a, window_mouse)
	hovered := -1
	first_row, fraction := ui.scroll_page_reg(s, &pv.rows_scroll_reg)
	first_row = clamp(first_row, 0, len(rows))
	y := rows_y
	if first_row < len(rows) && fraction > 0 {
		y -= fraction * row_height(pv.waves.items[rows[first_row]].kind) * dpi * a.across
	}
	for i, n in rows[first_row:] {
		it := &pv.waves.items[i]
		rh := row_height(it.kind) * dpi * a.across
		if y >= rows_y + shown * dpi * a.across {
			break
		}
		row_idx := first_row + n
		switch it.kind {
		case .Scenes:
		case .Cues:
			draw_cues(&view, y, rh)
		case .Group, .Track, .Part, .Notes, .Hits:
			// a lane: its regions, each with its waveform (a notes view: its
			// notes over them), its name (and level when it differs from what
			// it sits under), open or closed when it has children
			if it.kind == .Notes || it.kind == .Hits {
				draw_notes(&view, it^, y, rh - 2 * dpi, row_idx + 2)
			} else {
				draw_lane(&view, int(it.lane), y, rh - 2 * dpi, row_idx + 2)
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
			depth := 0
			for p := it.parent; p >= 0; p = pv.waves.items[p].parent {
				depth += 1
			}
			draw_row_name(&view, name, y, rh - 2 * dpi, 14 * dpi * f32(depth))
		}
		if mouse.y >= y && mouse.y < y + rh && mouse.x >= x0 && mouse.x < x0 + w {
			hovered = i
		}
		y += rh
	}
	render.clip_pop(r)
	// What the hovered row is, and its path for `onimite show`: upright,
	// beside the pointer and inside the box.
	if hovered >= 0 {
		it := pv.waves.items[hovered]
		tip := fmt.tprintf("%s   (onimite show %s)", text_of(pv.waves.text[:], it.summary), text_of(pv.waves.text[:], it.path))
		tw := render.measure_text(s.font, tip, font_px) + 10 * dpi
		lh := render.line_height(s.font, font_px)
		tx := clamp(window_mouse.x + 12 * dpi, box.rect.min.x, box.rect.max.x - tw)
		ty := max(window_mouse.y - lh - 10 * dpi, box.rect.min.y)
		render.draw_rect_rounded(r, tx, ty, tw, lh + 4 * dpi, 3 * dpi, {10, 11, 15, 235})
		render.draw_text(r, s.font, tip, tx + 5 * dpi, ty + 2 * dpi, font_px, {235, 238, 244, 255})
	}

	// The bookmark, the hovered frame and the playhead over everything.
	if pv.bookmark >= 0 {
		x := x_of(f64(pv.bookmark), first, ppf, x0)
		fill(r, a, x, y0, line_w, h, {COLOR_BOOKMARK.r, COLOR_BOOKMARK.g, COLOR_BOOKMARK.b, 200})
		fill(r, a, x, y0, 8 * dpi, 7 * dpi, COLOR_BOOKMARK)
	}
	if pv.hover_valid {
		fill(r, a, x_of(f64(pv.hover_frame), first, ppf, x0), y0, line_w, h, COLOR_HOVER)
	}
	head := x_of(f64(d.head), first, ppf, x0)
	fill(r, a, head - dpi, y0, 2 * dpi, h, COLOR_PLAYHEAD)
	fill(r, a, head - 4 * dpi, y0, 8 * dpi, 5 * dpi, COLOR_PLAYHEAD)
}

// What drawing a row needs from the timeline's draw.
@(private = "file")
Row_View :: struct {
	s:                 ^ui.State,
	d:                 ^Timeline_Draw,
	a:                 Time_Axis,
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
	r := v.s.r
	waves := &v.d.app.preview.waves
	if index < 0 || index >= len(waves.lanes) {
		return
	}
	lane := &waves.lanes[index]
	dpi := v.d.dpi
	fill(r, v.a, v.x0, y, v.w, lane_h, LANE_BG)
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
		fill_rounded(r, v.a, xa, y, xb - xa, lane_h, 3 * dpi, {color.r, color.g, color.b, 90})
		if reg.clip < 0 {
			continue
		}
		clip := &waves.clips[reg.clip]
		for cx := cx0; cx < cx1; cx += col_w {
			s0 := int((v.first + f64(cx - v.x0) / v.ppf) * v.samples_per_frame)
			s1 := int((v.first + f64(cx + col_w - v.x0) / v.ppf) * v.samples_per_frame)
			lo, hi, ok := wave_peak(waves, clip, s0 - reg.start + reg.at, s1 - reg.start + reg.at)
			if !ok {
				break // still being computed
			}
			env := om.track_envelope_peak(s0 - lane.start, s1 - lane.start, length, lane.fade_in, lane.fade_out, lane.curve)
			top := mid - clamp(hi * env, -1, 1) * half
			bottom := mid - clamp(lo * env, -1, 1) * half
			fill(r, v.a, cx, top, col_w, max(bottom - top, v.line_w), wave)
		}
	}
}

// A notes view: its lane's regions, and its notes over them: pitched notes
// by pitch (its lowest at the bottom, its highest at the top), a pad's hits
// as marks, each as strong as it is played.
@(private = "file")
draw_notes :: proc(v: ^Row_View, it: Timeline_Item, y, lane_h: f32, color_index: int) {
	r := v.s.r
	waves := &v.d.app.preview.waves
	dpi := v.d.dpi
	fill(r, v.a, v.x0, y, v.w, lane_h, LANE_BG)
	color := SCENE_COLORS[color_index % len(SCENE_COLORS)]
	if it.lane >= 0 {
		lane := waves.lanes[it.lane]
		for reg in waves.regions[lane.regions[0]:][:lane.regions[1]] {
			xa, xb := x_of_sample(v, reg.start), x_of_sample(v, reg.end)
			if min(xb, v.x0 + v.w) > max(xa, v.x0) {
				fill_rounded(r, v.a, xa, y, xb - xa, lane_h, 3 * dpi, {color.r, color.g, color.b, 50})
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
			fill(r, v.a, xa, y + 2 * dpi, max(2 * dpi, min(xb - xa, 4 * dpi)), lane_h - 4 * dpi, ink)
			continue
		}
		ny := y + (hi - n.pitch) * step
		fill(r, v.a, xa, ny, max(xb - xa, dpi), max(step - dpi, dpi), ink)
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
	r := v.s.r
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
	clip(r, v.a, v.x0, y, v.w, row_h)
	label(v.s, v.a, name, {x + 2 * dpi, y + (row_h - label_h) * 0.5 - dpi}, {tw + 6 * dpi, label_h + 2 * dpi}, {x + 5 * dpi, y + (row_h - label_h) * 0.5}, 3 * dpi, v.font_px, {0, 0, 0, 140}, {235, 238, 244, 230})
	render.clip_pop(r)
}

// The cues as marks with their names where there is room (inside the row).
@(private = "file")
draw_cues :: proc(v: ^Row_View, y, row_h: f32) {
	r := v.s.r
	pv := &v.d.app.preview
	fps := f64(preview_fps(v.d.app))
	fill(r, v.a, v.x0, y, v.w, row_h - v.d.dpi, LANE_BG)
	clip(r, v.a, v.x0, y, v.w, row_h)
	defer render.clip_pop(r)
	free_x := v.x0
	px := v.font_px * 0.85
	for c in pv.waves.cues {
		x := v.x0 + f32((c.seconds * fps - v.first) * v.ppf)
		if x < v.x0 || x > v.x0 + v.w {
			continue
		}
		fill(r, v.a, x, y, v.line_w, row_h - v.d.dpi, {250, 204, 21, 220})
		name := text_of(pv.waves.text[:], c.name)
		along := axis_label_along(v.a, render.measure_text(v.s.font, name, px), render.line_height(v.s.font, px))
		if x + 3 * v.d.dpi >= free_x && x + along < v.x0 + v.w {
			text(v.s, v.a, name, {x + 3 * v.d.dpi, y}, px, {250, 230, 160, 230})
			free_x = x + along + 8 * v.d.dpi
		}
	}
}
