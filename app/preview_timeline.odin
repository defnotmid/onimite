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
// a lane per track), a track's span and waveform. Hovering a row says what
// it is, with the path `onimite show` takes. The bookmark, the hovered
// frame and the playhead run over all of it. It zooms (Ctrl+wheel, +/-),
// pans (wheel, horizontal wheel or touchpad, middle drag) and follows the
// playhead; the wheel over rows that don't fit scrolls them.
//
// It is one box whose custom draw paints everything from the published
// tables in O(pixels): waveforms read one pyramid level per pixel column,
// thumbnails come from the worker's cache by frame. Input on the box
// becomes command rows.

TRACK_PAD :: 8
TIMELINE_GAP :: 6
RULER_HEIGHT :: 18
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

// A row's height in points: its kind decides.
@(private = "file")
row_height :: proc(kind: Timeline_Kind) -> f32 {
	switch kind {
	case .Scenes:
		return SCENE_HEIGHT
	case .Cues:
		return CUE_HEIGHT
	case .Group:
		return LANE_HEIGHT
	case .Track:
		return TRACK_HEIGHT
	}
	return LANE_HEIGHT
}

timeline_row_open :: proc(app: ^App_State, item: Timeline_Item) -> bool {
	pv := &app.preview
	h := hash.fnv64a(transmute([]u8)text_of(pv.waves.text[:], item.path))
	return slice.contains(pv.rows_open[:], h)
}

// The items shown below the scenes, in order: the top-level ones and the
// tracks of open groups (items list each group's tracks right after it).
timeline_rows :: proc(app: ^App_State) -> []int {
	pv := &app.preview
	items := pv.waves.items[:]
	rows := make([dynamic]int, 0, len(items), context.temp_allocator)
	for it, i in items {
		if it.kind == .Scenes {
			continue
		}
		if it.parent >= 0 && !timeline_row_open(app, items[it.parent]) {
			continue
		}
		append(&rows, i)
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
	pv.rows_scroll = clamp(pv.rows_scroll, 0, last if total > shown else 0)
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
	if scenes := app.preview.timeline.scenes; len(scenes) > 0 {
		return scenes
	}
	whole := make([]Preview_Scene, 1, context.temp_allocator)
	whole[0] = {"", 0, preview_duration(app)}
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
thumb_grid :: proc(app: ^App_State, ppf: f64, dpi: f32) -> Thumb_Grid {
	pv := &app.preview
	g: Thumb_Grid
	g.two_rows = len(pv.timeline.scenes) > 1
	g.thumb_h = (SCENE_HEIGHT - 4) * dpi
	if g.two_rows {
		g.thumb_h *= 0.5
	}
	aspect := f32(16) / 9
	if pv.thumb_size.y > 0 {
		aspect = f32(pv.thumb_size.x) / f32(pv.thumb_size.y)
	} else if pv.timeline.height > 0 {
		aspect = f32(pv.timeline.width) / f32(pv.timeline.height)
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
	w := f64(area.width) - 2 * TRACK_PAD * f64(dpi)
	first, visible := pv.view_first, view_frames(app)
	g := thumb_grid(app, w / visible, dpi)
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
	head: f32, // the playhead frame, eased
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

	// Last frame's rect (immediate-mode): what the pointer maps onto.
	w := f64(track.rect.max.x - track.rect.min.x)
	visible := view_frames(app)
	if w > 0 {
		ppf := w / visible
		frame_at :: proc(pv: ^Preview_State, track: ^ui.Box, x: f32, ppf: f64) -> int {
			return int(math.floor(pv.view_first + f64(x - track.rect.min.x) / ppf))
		}
		mouse := platform.mouse_pos(s.p)
		hit, in_name := row_at(app, track, mouse, dpi)
		if ui.pressed(sig) {
			// A press on a group's name opens or closes it, and the drag it
			// starts doesn't scrub.
			pv.press_on_name = hit >= 0 && in_name && pv.waves.items[hit].kind == .Group
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
		if ui.middle_dragging(sig) {
			if dx := platform.mouse_delta(s.p).x; dx != 0 {
				command_push(c, .Timeline_Pan, {scalar = -f64(dx) / ppf})
			}
		}
		total, shown := rows_points(app, timeline_rows(app))
		if sig.scroll != 0 && hit >= 0 && total > shown {
			command_push(c, .Timeline_Rows_Scroll, {count = -1 if sig.scroll > 0 else 1})
		} else if sig.scroll != 0 || sig.scroll_x != 0 {
			command_push(c, .Timeline_Pan, {scalar = f64(sig.scroll_x - sig.scroll) * visible * 0.1})
		}
		if zoom := ui.action_scroll_consume(s, true, track.rect.min, track.rect.max, true); zoom != 0 {
			command_push(c, .Timeline_Zoom, {scalar = math.pow(1.25, f64(zoom)), count = frame_at(pv, track, mouse.x, ppf)})
		}
	}

	data := new(Timeline_Draw, context.temp_allocator)
	data^ = {app, dpi, ui.anim_f32(s, track.key, f32(pv.frame), {initial = f64(pv.frame), duration = 0.05})}
	track.custom_draw = timeline_draw
	track.custom_draw_data = data
}

// The row under `mouse` (an item index, -1 for none: the ruler, the scenes,
// below the rows) and whether it is over the row's name, from the box's
// last rect.
@(private = "file")
row_at :: proc(app: ^App_State, track: ^ui.Box, mouse: [2]f32, dpi: f32) -> (item: int, in_name: bool) {
	pv := &app.preview
	y := track.rect.min.y + (RULER_HEIGHT + SCENE_HEIGHT) * dpi
	_, shown := rows_points(app, timeline_rows(app))
	if mouse.y < y || mouse.y >= y + shown * dpi {
		return -1, false
	}
	rows := timeline_rows(app)
	for i in rows[min(pv.rows_scroll, len(rows)):] {
		h := row_height(pv.waves.items[i].kind) * dpi
		if mouse.y < y + h {
			return i, mouse.x - track.rect.min.x < ROW_NAME_WIDTH * dpi
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
	x0, y0 := box.rect.min.x, box.rect.min.y
	w := box.rect.max.x - x0
	h := box.rect.max.y - y0
	fps := preview_fps(app)
	first, visible := pv.view_first, view_frames(app)
	ppf := f64(w) / visible
	x_of :: proc(f, first, ppf: f64, x0: f32) -> f32 {
		return x0 + f32((f - first) * ppf)
	}
	line_w := max(dpi, 1)

	// Ruler: major ticks with labels (m:ss, or m:ss:ff below a second),
	// minor ticks between.
	ruler_h := RULER_HEIGHT * dpi
	render.draw_rect(r, x0, y0, w, ruler_h, RULER_BG)
	step := ruler_step(fps, ppf, 70 * f64(dpi))
	minor := step / 5 if step % 5 == 0 else (step / 2 if step % 2 == 0 else step)
	if f64(minor) * ppf < 5 * f64(dpi) {
		minor = step
	}
	font_px := 11 * dpi
	for f := int(first) / minor * minor; f64(f) <= first + visible; f += minor {
		x := x_of(f64(f), first, ppf, x0)
		if f % step == 0 {
			render.draw_rect(r, x, y0 + ruler_h * 0.35, line_w, ruler_h * 0.65, {120, 128, 142, 255})
			secs := f / fps
			label := fmt.tprintf("%d:%02d", secs / 60, secs % 60) if step % fps == 0 else fmt.tprintf("%d:%02d:%02d", secs / 60, secs % 60, f % fps)
			render.draw_text(r, s.font, label, x + 3 * dpi, y0 + 1 * dpi, font_px, COLOR_TEXT_DIM)
		} else {
			render.draw_rect(r, x, y0 + ruler_h * 0.7, line_w, ruler_h * 0.3, {80, 86, 98, 255})
		}
	}

	// Scenes, overlapping ones on alternating rows, with thumbnails.
	g := thumb_grid(app, ppf, dpi)
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
		render.draw_rect_rounded(r, xa, y, xb - xa - line_w, g.thumb_h, 3 * dpi, SCENE_COLORS[i % len(SCENE_COLORS)])
		render.clip_push(r, cx0, y, cx1 - cx0, g.thumb_h)
		j := max(int(math.floor((first - f64(sc.start_frame) - g.width) / f64(g.step))), 0)
		for f := sc.start_frame + j * g.step; f < sc.end_frame && f64(f) < first + visible; f += g.step {
			k, found := slice.binary_search_by(pv.thumbs[:], f, proc(t: Preview_Thumb, f: int) -> slice.Ordering {
				return slice.cmp(t.frame, f)
			})
			if !found {
				continue
			}
			img := render.Image{pv.thumbs[k].texture, pv.thumb_size.x, pv.thumb_size.y}
			render.draw_image_contain(r, &img, x_of(f64(f), first, ppf, x0), y, g.thumb_w - line_w, g.thumb_h)
		}
		if sc.name != "" {
			fs := 12 * dpi
			tw := render.measure_text(s.font, sc.name, fs)
			lh := render.line_height(s.font, fs)
			render.draw_rect_rounded(r, cx0 + 2 * dpi, y + 2 * dpi, tw + 8 * dpi, lh + 2 * dpi, 3 * dpi, {0, 0, 0, 150})
			render.draw_text(r, s.font, sc.name, cx0 + 6 * dpi, y + 3 * dpi, fs, {240, 242, 246, 255})
		}
		render.clip_pop(r)
	}

	// The rows below the scenes, each drawn the way its kind says.
	rows := timeline_rows(app)
	_, shown := rows_points(app, rows)
	rows_y := y0 + ruler_h + SCENE_HEIGHT * dpi
	render.clip_push(r, x0, rows_y, w, shown * dpi)
	view := Row_View{s, d, x0, w, first, ppf, f64(om.MIX_RATE) / f64(fps), line_w, font_px}
	mouse := platform.mouse_pos(s.p)
	hovered := -1
	y := rows_y
	for i, n in rows[min(pv.rows_scroll, len(rows)):] {
		it := &pv.waves.items[i]
		rh := row_height(it.kind) * dpi
		if y >= rows_y + shown * dpi {
			break
		}
		switch it.kind {
		case .Scenes:
		case .Cues:
			draw_cues(&view, y, rh)
		case .Group:
			draw_lane(&view, int(it.lane), y, rh - 2 * dpi, n + 2)
			open := timeline_row_open(app, it^)
			draw_row_name(&view, fmt.tprintf("%s %s  %d", "-" if open else "+", text_of(pv.waves.text[:], it.label), it.children), y, rh - 2 * dpi, 0)
		case .Track:
			draw_lane(&view, int(it.lane), y, rh - 2 * dpi, n + 2)
			lane := pv.waves.lanes[it.lane]
			name := text_of(pv.waves.text[:], it.label)
			if lane.gain_db != 0 {
				name = fmt.tprintf("%s · %+.1f dB", name, lane.gain_db)
			}
			draw_row_name(&view, name, y, rh - 2 * dpi, 14 * dpi if it.parent >= 0 else 0, lane.start)
		}
		if mouse.y >= y && mouse.y < y + rh && mouse.x >= x0 && mouse.x < x0 + w {
			hovered = i
		}
		y += rh
	}
	render.clip_pop(r)
	// What the hovered row is, and its path for `onimite show`.
	if hovered >= 0 {
		it := pv.waves.items[hovered]
		tip := fmt.tprintf("%s   (onimite show %s)", text_of(pv.waves.text[:], it.summary), text_of(pv.waves.text[:], it.path))
		tw := render.measure_text(s.font, tip, font_px) + 10 * dpi
		lh := render.line_height(s.font, font_px)
		tx := clamp(mouse.x + 12 * dpi, x0, x0 + w - tw)
		ty := max(mouse.y - lh - 10 * dpi, y0)
		render.draw_rect_rounded(r, tx, ty, tw, lh + 4 * dpi, 3 * dpi, {10, 11, 15, 235})
		render.draw_text(r, s.font, tip, tx + 5 * dpi, ty + 2 * dpi, font_px, {235, 238, 244, 255})
	}

	// The bookmark, the hovered frame and the playhead over everything.
	if pv.bookmark >= 0 {
		x := x_of(f64(pv.bookmark), first, ppf, x0)
		render.draw_rect(r, x, y0, line_w, h, {COLOR_BOOKMARK.r, COLOR_BOOKMARK.g, COLOR_BOOKMARK.b, 200})
		render.draw_rect(r, x, y0, 8 * dpi, 7 * dpi, COLOR_BOOKMARK)
	}
	if pv.hover_valid {
		render.draw_rect(r, x_of(f64(pv.hover_frame), first, ppf, x0), y0, line_w, h, COLOR_HOVER)
	}
	head := x_of(f64(d.head), first, ppf, x0)
	render.draw_rect(r, head - dpi, y0, 2 * dpi, h, COLOR_PLAYHEAD)
	render.draw_rect(r, head - 4 * dpi, y0, 8 * dpi, 5 * dpi, COLOR_PLAYHEAD)
}

// What drawing a row needs from the timeline's draw.
@(private = "file")
Row_View :: struct {
	s:                 ^ui.State,
	d:                 ^Timeline_Draw,
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
	render.draw_rect(r, v.x0, y, v.w, lane_h, LANE_BG)
	xa := v.x0 + f32((f64(lane.start) / v.samples_per_frame - v.first) * v.ppf)
	xb := v.x0 + f32((f64(lane.end) / v.samples_per_frame - v.first) * v.ppf)
	cx0, cx1 := max(xa, v.x0), min(xb, v.x0 + v.w)
	if cx1 <= cx0 {
		return
	}
	color := SCENE_COLORS[color_index % len(SCENE_COLORS)]
	render.draw_rect_rounded(r, xa, y, xb - xa, lane_h, 3 * dpi, {color.r, color.g, color.b, 90})
	clip := &waves.clips[lane.clip]
	mid := y + lane_h * 0.5
	half := lane_h * 0.5 - v.line_w
	length := lane.end - lane.start
	wave := [4]u8{u8(min(int(color.r) + 90, 255)), u8(min(int(color.g) + 90, 255)), u8(min(int(color.b) + 90, 255)), 255}
	col_w := max(math.round(dpi), 1)
	for cx := cx0; cx < cx1; cx += col_w {
		s0 := (v.first + f64(cx - v.x0) / v.ppf) * v.samples_per_frame
		s1 := (v.first + f64(cx + col_w - v.x0) / v.ppf) * v.samples_per_frame
		k := int(s0) - lane.start
		lo, hi, ok := wave_peak(waves, clip, k + lane.file_start, int(s1) - lane.start + lane.file_start)
		if !ok {
			break // still being computed
		}
		env := om.track_envelope_peak(k, int(s1) - lane.start, length, lane.fade_in, lane.fade_out, lane.curve)
		top := mid - clamp(hi * env, -1, 1) * half
		bottom := mid - clamp(lo * env, -1, 1) * half
		render.draw_rect(r, cx, top, col_w, max(bottom - top, v.line_w), wave)
	}
}

// A row's name on a dark tab: at the left edge (groups, `at < 0`), or at
// the start of its span (`at` in mix samples) while that is in view.
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
	render.draw_rect_rounded(r, x + 2 * dpi, y + (row_h - label_h) * 0.5 - dpi, tw + 6 * dpi, label_h + 2 * dpi, 3 * dpi, {0, 0, 0, 140})
	render.draw_text(r, v.s.font, name, x + 5 * dpi, y + (row_h - label_h) * 0.5, v.font_px, {235, 238, 244, 230})
}

// The cues as marks with their names where there is room.
@(private = "file")
draw_cues :: proc(v: ^Row_View, y, row_h: f32) {
	r := v.s.r
	pv := &v.d.app.preview
	fps := f64(preview_fps(v.d.app))
	render.draw_rect(r, v.x0, y, v.w, row_h - v.d.dpi, LANE_BG)
	free_x := v.x0
	for c in pv.waves.cues {
		x := v.x0 + f32((c.seconds * fps - v.first) * v.ppf)
		if x < v.x0 || x > v.x0 + v.w {
			continue
		}
		render.draw_rect(r, x, y, v.line_w, row_h - v.d.dpi, {250, 204, 21, 220})
		name := text_of(pv.waves.text[:], c.name)
		tw := render.measure_text(v.s.font, name, v.font_px * 0.85)
		if x + 3 * v.d.dpi >= free_x && x + tw < v.x0 + v.w {
			render.draw_text(r, v.s.font, name, x + 3 * v.d.dpi, y, v.font_px * 0.85, {250, 230, 160, 230})
			free_x = x + tw + 8 * v.d.dpi
		}
	}
}
