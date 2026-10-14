package onimite_app

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import om "../onimite"
import enc "../encode"
import vg "deps:ovg"
import vgsdl "deps:ovg/sdlgpu"

// The command line's handlers: render, frame, strip, onion, snapshot,
// timeline and inspect, with fframes' outputs (text or --json).

// The renderer at `scale` unless the command line gave --scale.
@(private)
renderer_scaled :: proc(app: ^App_State, default_scale: f32) -> (^om.Renderer, Error) {
	return renderer(app, app.scale if app.scale_given else default_scale)
}

// ---- timeline -------------------------------------------------------------------

Timeline_Scene :: struct {
	index:         int    `json:"index"`,
	name:          string `json:"name"`,
	start_frame:   int    `json:"start_frame"`,
	end_frame:     int    `json:"end_frame"`,
	start_seconds: f32    `json:"start_seconds"`,
	end_seconds:   f32    `json:"end_seconds"`,
	// The cue it lands on ("" for none) and where the script defines it.
	cue:           string `json:"cue"`,
	source:        string `json:"source"`,
}

Timeline_Mix :: struct {
	gain_db:  f32  `json:"gain_db"`,
	pan:      f32  `json:"pan"`,
	fade_in:  f32  `json:"fade_in"`,
	fade_out: f32  `json:"fade_out"`,
	offset:   f32  `json:"offset"`,
	voice:    bool `json:"voice"`,
	ducked:   bool `json:"ducked"`,
}

Timeline_Track :: struct {
	file:          string       `json:"file"`,
	start_seconds: f32          `json:"start_seconds"`,
	end_seconds:   f32          `json:"end_seconds"`,
	scene:         string       `json:"scene"`,
	mix:           Timeline_Mix `json:"mix"`,
	bus:           string       `json:"bus"`,
}

Timeline_Report :: struct {
	width:            int              `json:"width"`,
	height:           int              `json:"height"`,
	fps:              int              `json:"fps"`,
	duration_frames:  int              `json:"duration_frames"`,
	duration_seconds: f32              `json:"duration_seconds"`,
	scenes:           []Timeline_Scene `json:"scenes"`,
	audio:            []Timeline_Track `json:"audio"`,
	sync:             []Timeline_Sync  `json:"sync"`,
	missing_files:    []string         `json:"missing_files"`,
}

@(private)
timeline_print :: proc(app: ^App_State, regs: Command_Regs) -> Error {
	build_audio(app) or_return
	r := renderer_scaled(app, 1) or_return
	v := r.video
	fps := f32(v.fps)
	// A range limits the listing to what happens in it.
	start, end := 0, r.timeline.duration_frames
	if regs.spec != "" {
		start, end = resolve_range(app, &r.timeline, v.fps, regs.spec) or_return
	}
	inside :: proc(a, b, start, end: int) -> bool {return a < end && b > start}
	rep := Timeline_Report {
		width            = v.width,
		height           = v.height,
		fps              = v.fps,
		duration_frames  = r.timeline.duration_frames,
		duration_seconds = f32(r.timeline.duration_frames) / fps,
	}
	scenes := make([dynamic]Timeline_Scene, context.temp_allocator)
	for s in r.timeline.scenes {
		if inside(s.start_frame, s.end_frame, start, end) {
			append(&scenes, Timeline_Scene{s.index, s.scene.name, s.start_frame, s.end_frame, f32(s.start_frame) / fps, f32(s.end_frame) / fps, s.scene.cue, s.scene.source})
		}
	}
	rep.scenes = scenes[:]
	placed := om.placed_audio(&r.ctx).tracks[:]
	tracks := make([dynamic]Timeline_Track, context.temp_allocator)
	shown := make([dynamic]om.Placed_Track, context.temp_allocator)
	for p in placed {
		tr := p.track
		a, b := int(f64(p.start) * f64(fps) / om.MIX_RATE), int(f64(p.end) * f64(fps) / om.MIX_RATE)
		if !inside(a, b + 1, start, end) {
			continue
		}
		append(&shown, p)
		append(&tracks, Timeline_Track {
			tr.src,
			f32(p.start) / om.MIX_RATE,
			f32(p.end) / om.MIX_RATE,
			p.scene,
			{tr.gain_db, tr.pan, tr.fade_in, tr.fade_out, tr.offset, tr.voice, tr.ducked},
			tr.bus,
		})
	}
	rep.audio = tracks[:]
	rep.missing_files = missing_audio(app)
	sync := make([dynamic]Timeline_Sync, context.temp_allocator)
	for sp in timeline_sync(sync_anchors(app, r) or_return, v.fps) {
		f := om.frame_at(sp.seconds[0], v.fps)
		l := om.frame_at(sp.seconds[len(sp.seconds) - 1], v.fps)
		if inside(f, l + 1, start, end) {
			append(&sync, sp)
		}
	}
	rep.sync = sync[:]

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%dx%d @ %d fps, %d frames (%.2fs)\n", rep.width, rep.height, rep.fps, rep.duration_frames, rep.duration_seconds)
	if len(r.timeline.scenes) == 0 {
		strings.write_string(&b, "no scenes\n")
	}
	// A sync id carried only by its scene and a cue on time shows on the
	// scene's line; the sync list keeps the rest.
	on_scene_line :: proc(sp: Timeline_Sync, scenes: []Timeline_Scene) -> bool {
		if len(sp.seconds) > 1 {
			return false
		}
		for s in scenes {
			if s.cue != sp.id {
				continue
			}
			for w in sp.what { // on time: "cue" and "scene Name" without an offset
				if w != "cue" && w != fmt.tprintf("scene %s", s.name) {
					return false
				}
			}
			return true
		}
		return false
	}
	for s in rep.scenes {
		fmt.sbprintf(
			&b,
			"#%-3s %-14s frames %12s %18s  %-10s %s\n",
			fmt.tprint(s.index),
			s.name,
			fmt.tprintf("%d..%d", s.start_frame, s.end_frame),
			fmt.tprintf("%.2fs..%.2fs", s.start_seconds, s.end_seconds),
			s.cue,
			s.source,
		)
	}
	// A bus's tracks are one line (unless a range asks for the detail):
	// hundreds of sound effects stay readable.
	Bus_Line :: struct {
		count:      int,
		start, end: f32,
		files:      [dynamic]string,
	}
	bus_lines := make(map[string]Bus_Line, allocator = context.temp_allocator)
	bus_order := make([dynamic]string, context.temp_allocator)
	for t in rep.audio {
		if t.bus == "" || regs.spec != "" {
			continue
		}
		bl, seen := bus_lines[t.bus]
		if !seen {
			bl = {0, t.start_seconds, t.end_seconds, make([dynamic]string, context.temp_allocator)}
			append(&bus_order, t.bus)
		}
		bl.count += 1
		bl.start, bl.end = min(bl.start, t.start_seconds), max(bl.end, t.end_seconds)
		if !slice.contains(bl.files[:], t.file) {
			append(&bl.files, t.file)
		}
		bus_lines[t.bus] = bl
	}
	for name in bus_order {
		bl := bus_lines[name]
		gain: f32
		kind: om.Bus_Kind
		for bus in v.buses {
			if bus.name == name {gain, kind = bus.gain_db, bus.kind}
		}
		files := strings.join(bl.files[:], ", ", context.temp_allocator)
		if len(files) > 60 {
			files = fmt.tprintf("%d sounds", len(bl.files))
		}
		fmt.sbprintf(&b, "bus   %-28s %8s..%.3fs %d tracks (%s)%s\n", fmt.tprintf("%s [%s]", name, strings.to_lower(fmt.tprint(kind), context.temp_allocator)), fmt.tprintf("%.3fs", bl.start), bl.end, bl.count, files, fmt.tprintf(", %+.1f dB", gain) if gain != 0 else "")
	}
	for p in shown {
		if p.track.bus != "" && regs.spec == "" {
			continue
		}
		fmt.sbprintf(&b, "audio %s\n", track_summary(p))
	}
	for sp in rep.sync {
		if on_scene_line(sp, rep.scenes) {
			continue
		}
		at := fmt.tprintf("%.3fs", sp.seconds[0])
		if len(sp.seconds) > 1 {
			at = fmt.tprintf("%.3fs..%.3fs", sp.seconds[0], sp.seconds[len(sp.seconds) - 1])
		}
		fmt.sbprintf(&b, "cue   %-28s %18s %s\n", sp.id, at, strings.join(sp.what, ", ", context.temp_allocator))
	}
	emit(app, rep, strings.to_string(b))
	return nil
}

// ---- frame ----------------------------------------------------------------------

Frame_Result :: struct {
	spec:        string                `json:"spec"`,
	path:        string                `json:"path"`,
	// The SVG written next to the PNG (--svg), else null.
	svg:         Maybe(string)         `json:"svg"`,
	frame:       int                   `json:"frame"`,
	seconds:     f32                   `json:"seconds"`,
	scenes:      []string              `json:"scenes"`,
	diagnostics: []Reported_Diagnostic `json:"diagnostics"`,
}

// `Intro@1.5s` -> `intro_1.5s` (fframes' snapshot names).
snapshot_name :: proc(spec: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in spec {
		switch c {
		case 'a' ..= 'z', '0' ..= '9', '.', '-':
			strings.write_rune(&b, c)
		case 'A' ..= 'Z':
			strings.write_rune(&b, c + 32)
		case '%':
			strings.write_byte(&b, 'p')
		case:
			strings.write_byte(&b, '_')
		}
	}
	return strings.trim(strings.to_string(b), "_")
}

@(private)
frames_export :: proc(app: ^App_State, regs: Command_Regs) -> Error {
	r := renderer_scaled(app, 1) or_return
	specs, frames := resolve_frames(app, &r.timeline, r.video.fps, regs.spec) or_return
	// `-o shot.png` is the file itself (one frame); anything else is a
	// directory that gets one PNG per spec, named after it.
	dir := regs.path if regs.path != "" else "frames"
	file := strings.has_suffix(strings.to_lower(dir, context.temp_allocator), ".png")
	if file {
		if len(frames) != 1 {
			return fail(app, {code = .Png_Many_Frames, path = dir, n = len(frames)})
		}
		dir = filepath.dir(dir)
		if dir == "" {
			dir = "."
		}
	}
	make_dir(app, dir) or_return
	results := make([]Frame_Result, len(frames), context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	// Problems name the script line that drew what they are about.
	app.script.node_sources_on = true
	defer app.script.node_sources_on = false
	for f, i in frames {
		pixels := om.render_frame(r, f)
		rep := take_frame_report(app, r, f)
		path := regs.path if file else filepath.join({dir, fmt.tprintf("%s.png", snapshot_name(specs[i]))}, context.temp_allocator) or_else ""
		if write_png(path, pixels, r.width, r.height) != nil {
			return fail(app, {code = .Write, path = path})
		}
		svg_path: Maybe(string)
		if .Svg in regs.flags {
			svg_path = fmt.tprintf("%s.svg", path[:len(path) - 4])
			sb := strings.builder_make(context.temp_allocator)
			om.svg_export(r, &sb)
			if os.write_entire_file(svg_path.?, sb.buf[:]) != nil {
				return fail(app, {code = .Write, path = svg_path.?})
			}
		}
		results[i] = {specs[i], path, svg_path, f, rep.seconds, rep.scenes, rep.diagnostics}
		fmt.sbprintf(&b, "%s frame %d %.2fs%s -> %s\n%s", specs[i], f, rep.seconds, scenes_label(rep.scenes), path, diagnostics_text(rep, "  "))

	}
	emit(app, results, strings.to_string(b))
	return nil
}

// ---- strip, onion ----------------------------------------------------------------

Sheet_Result :: struct {
	output:      string         `json:"output"`,
	frames:      []int          `json:"frames"`,
	diagnostics: []Frame_Report `json:"diagnostics"`,
}

@(private)
sheet_text :: proc(res: Sheet_Result) -> string {
	b := strings.builder_make(context.temp_allocator)
	names := make([]string, len(res.frames), context.temp_allocator)
	for f, i in res.frames {
		names[i] = fmt.tprint(f)
	}
	fmt.sbprintf(&b, "%s (%d frames: %s)", res.output, len(res.frames), strings.join(names, ", ", context.temp_allocator))
	for rep in res.diagnostics {
		fmt.sbprintf(&b, "\nframe %d %.2fs:\n%s", rep.frame, rep.seconds, strings.trim_right_space(diagnostics_text(rep, "  ")))
	}
	return strings.to_string(b)
}

// Renders `frames` and keeps copies of their pixels (one flat buffer, a
// frame after another) plus the reports of frames with problems.
@(private)
render_cells :: proc(app: ^App_State, r: ^om.Renderer, frames: []int) -> (pixels: []u8, reports: []Frame_Report) {
	size := int(r.width * r.height * 4)
	pixels = make([]u8, size * len(frames), context.temp_allocator)
	reps := make([dynamic]Frame_Report, context.temp_allocator)
	app.script.node_sources_on = true
	defer app.script.node_sources_on = false
	for f, i in frames {
		px := om.render_frame(r, f)
		copy(pixels[i * size:][:size], px)
		rep := take_frame_report(app, r, f)
		if frame_report_has_problems(rep) {
			append(&reps, rep)
		}
	}
	return pixels, reps[:]
}

@(private)
strip_export :: proc(app: ^App_State, regs: Command_Regs) -> Error {
	v := &app.script.video
	cell_w := regs.width if regs.width > 0 else 480
	r := renderer(app, f32(cell_w) / f32(v.width)) or_return
	start, end := resolve_range(app, &r.timeline, v.fps, regs.spec) or_return
	frames := spread(start, end, regs.count if regs.count > 0 else 12)
	pixels, reports := render_cells(app, r, frames)
	labels := make([]string, len(frames), context.temp_allocator)
	for f, i in frames {
		labels[i] = fmt.tprintf("%.2fs  f%d%s", f32(f) / f32(v.fps), f, scenes_label(scenes_at(&r.timeline, f)))
	}
	out := regs.path if regs.path != "" else "strip.png"
	contact_sheet(app, out, pixels, r.width, r.height, labels, regs.columns if regs.columns > 0 else 4) or_return
	res := Sheet_Result{out, frames, reports}
	emit(app, res, sheet_text(res))
	return nil
}

@(private)
onion_export :: proc(app: ^App_State, regs: Command_Regs) -> Error {
	r := renderer_scaled(app, 0.5) or_return
	start, end := resolve_range(app, &r.timeline, r.video.fps, regs.spec) or_return
	frames := spread(start, end, regs.count if regs.count > 0 else 6)
	pixels, reports := render_cells(app, r, frames)
	out := regs.path if regs.path != "" else "onion.png"
	blended := onion_skin(pixels, len(frames))
	ensure_parent(out)
	if write_png(out, blended, r.width, r.height) != nil {
		return fail(app, {code = .Write, path = out})
	}
	res := Sheet_Result{out, frames, reports}
	emit(app, res, sheet_text(res))
	return nil
}

// Blends frames, weights growing linearly so the last frame dominates
// (fframes' onion skin). `pixels` holds `count` frames back to back.
onion_skin :: proc(pixels: []u8, count: int) -> []u8 {
	size := len(pixels) / max(count, 1)
	out := make([]u8, size, context.temp_allocator)
	total := f32(count * (count + 1) / 2)
	for i in 0 ..< size {
		v: f32
		for k in 0 ..< count {
			v += f32(pixels[k * size + i]) * f32(k + 1)
		}
		out[i] = u8(clamp(math.round(v / total), 0, 255))
	}
	return out
}

// Makes directory `dir` (and its parents) unless it is there.
@(private)
make_dir :: proc(app: ^App_State, dir: string) -> Error {
	if err := os.make_directory_all(dir); err != nil && !os.is_dir(dir) {
		return fail(app, {code = .Create_Dir, path = dir, os = err})
	}
	return nil
}

// A PNG of straight-alpha pixels, or `.Write`.
@(private)
write_straight_png :: proc(app: ^App_State, path: string, pixels: []u8, w, h: u32) -> Error {
	if vg.write_png(path, pixels, w, h) != nil {
		return fail(app, {code = .Write, path = path})
	}
	return nil
}

@(private)
ensure_parent :: proc(path: string) {
	dir := filepath.dir(path)
	if dir != "" && dir != "." {
		os.make_directory_all(dir)
	}
}

// Lays frames out in a grid with a label under each (fframes' layout: 8 px
// gaps, label height cell_w / 16 clamped to 18..40).
@(private)
contact_sheet :: proc(app: ^App_State, out: string, pixels: []u8, cw, ch: u32, labels: []string, columns: int) -> Error {
	n := len(labels)
	if n == 0 {
		return fail(app, {code = .No_Sheet_Frames})
	}
	cols := u32(clamp(columns, 1, n))
	rows := (u32(n) + cols - 1) / cols
	gap: u32 = 8
	label_h := clamp(cw / 16, 18, 40)
	sheet_w := cols * cw + (cols + 1) * gap
	sheet_h := rows * (ch + label_h) + (rows + 1) * gap

	sw: vg.Software_Backend
	vg.software_backend_init(&sw)
	defer vg.software_backend_destroy(&sw)
	sheet: vg.Canvas
	vg.canvas_init(&sheet, vg.software_backend(&sw))
	defer vg.canvas_destroy(&sheet)
	vg.set_size(&sheet, sheet_w, sheet_h)
	vg.clear_rect(&sheet, 0, 0, sheet_w, sheet_h, vg.rgb(24, 24, 27))

	path: vg.Path
	defer vg.path_destroy(&path)
	glyphs: [dynamic]vg.Positioned_Glyph
	defer delete(glyphs)
	font := om.media_fallback_font(&app.media)
	em := vg.font_scale_for_em(font, f32(label_h) * 3 / 5)
	size := int(cw * ch * 4)
	images := make([]vg.Image_Id, n, context.temp_allocator)
	for i in 0 ..< n {
		images[i], _ = vg.create_image(&sheet, vg.image_source_rgba(pixels[i * size:][:size], cw, ch), {.Premultiplied})
		col, row := u32(i) % cols, u32(i) / cols
		x := f32(gap + col * (cw + gap))
		y := f32(gap + row * (ch + label_h + gap))
		vg.path_reset(&path)
		vg.path_rect(&path, x, y, f32(cw), f32(ch))
		p := vg.paint_image(images[i], x, y, f32(cw), f32(ch), 0)
		p.anti_alias = false
		vg.fill_path(&sheet, &path, p)
		clear(&glyphs)
		vg.layout_simple(font, labels[i], x + 6, y + f32(ch) + f32(label_h) * 3 / 4, em, &glyphs)
		vg.fill_glyph_outlines(&sheet, font, glyphs[:], em, vg.paint_color(vg.rgb(244, 244, 245)), &path)
	}
	vg.flush(&sheet)
	for img in images {
		vg.delete_image(&sheet, img)
	}
	ensure_parent(out)
	if write_png(out, sw.pixels, sheet_w, sheet_h) != nil {
		return fail(app, {code = .Write, path = out})
	}
	return nil
}

// ---- snapshot --------------------------------------------------------------------

Snapshot_Result :: struct {
	spec:       string         `json:"spec"`,
	frame:      int            `json:"frame"`,
	status:     string         `json:"status"`,
	snapshot:   string         `json:"snapshot"`,
	diff_ratio: f64            `json:"diff_ratio"`,
	actual:     Maybe(string)  `json:"actual"`,
	diff:       Maybe(string)  `json:"diff"`,
}

// Compares frames with approved PNGs (fframes' snapshot): missing ones are
// created, differing ones fail with `.actual.png` and `.diff.png` written
// (the expected frame dimmed, differing pixels red), or are replaced with
// --update. Exit code 2 when any fails.
@(private)
snapshot_check :: proc(app: ^App_State, regs: Command_Regs) -> Error {
	r := renderer_scaled(app, 1) or_return
	specs, frames := resolve_frames(app, &r.timeline, r.video.fps, regs.spec) or_return
	dir := regs.path if regs.path != "" else "_frame_snapshots"
	update := .Update in regs.flags
	threshold := regs.threshold if regs.threshold > 0 else 16
	max_ratio := regs.ratio if regs.ratio > 0 else 0.001
	make_dir(app, dir) or_return
	results := make([]Snapshot_Result, len(frames), context.temp_allocator)
	failed := false
	for f, i in frames {
		px := om.render_frame(r, f)
		om.diagnostics_clear(&r.ctx)
		name := snapshot_name(specs[i])
		snap := filepath.join({dir, fmt.tprintf("%s.png", name)}, context.temp_allocator) or_else ""
		actual_path := filepath.join({dir, fmt.tprintf("%s.actual.png", name)}, context.temp_allocator) or_else ""
		diff_path := filepath.join({dir, fmt.tprintf("%s.diff.png", name)}, context.temp_allocator) or_else ""
		os.remove(actual_path)
		os.remove(diff_path)
		res := Snapshot_Result{spec = specs[i], frame = f, status = "matched", snapshot = snap}
		actual := om.straight_alpha(px)
		if !os.exists(snap) {
			write_straight_png(app, snap, actual, r.width, r.height) or_return
			res.status = "created"
			results[i] = res
			continue
		}
		expected, ew, eh, read_ok := read_png(snap)
		ratio: f64 = 1
		diff: []u8
		if read_ok && (ew != r.width || eh != r.height) && !update {
			return fail(app, {code = .Snapshot_Size, path = snap, spec = specs[i], n = int(ew), m = int(eh), frame_size = {int(r.width), int(r.height)}})
		}
		if read_ok && ew == r.width && eh == r.height {
			ratio, diff = diff_frames(expected, actual, threshold)
		}
		res.diff_ratio = ratio
		if ratio > max_ratio {
			if update {
				write_straight_png(app, snap, actual, r.width, r.height) or_return
				res.status = "updated"
			} else {
				write_straight_png(app, actual_path, actual, r.width, r.height) or_return
				res.actual = actual_path
				if diff != nil {
					write_straight_png(app, diff_path, diff, r.width, r.height) or_return
					res.diff = diff_path
				}
				res.status = "failed"
				failed = true
			}
		}
		results[i] = res
	}
	b := strings.builder_make(context.temp_allocator)
	for res in results {
		status := strings.to_upper(res.status[:1], context.temp_allocator)
		fmt.sbprintf(&b, "%s%s %s (frame %d)", status, res.status[1:], res.spec, res.frame)
		if res.status == "failed" {
			fmt.sbprintf(&b, ": %.3f%% of pixels differ, actual %s, diff %s", res.diff_ratio * 100, res.actual.? or_else "-", res.diff.? or_else "-")
		}
		strings.write_byte(&b, '\n')
	}
	emit(app, results, strings.to_string(b))
	if failed && app.exit_code == 0 {
		app.exit_code = 2
	}
	return nil
}

// The fraction of pixels where any channel differs by more than
// `threshold`, and the diff image.
diff_frames :: proc(expected, actual: []u8, threshold: int) -> (f64, []u8) {
	n := len(actual) / 4
	diff := make([]u8, len(actual), context.temp_allocator)
	differing := 0
	for i in 0 ..< n {
		e := expected[i * 4:][:4]
		a := actual[i * 4:][:4]
		differs := false
		for k in 0 ..< 4 {
			if abs(int(e[k]) - int(a[k])) > threshold {
				differs = true
			}
		}
		d := diff[i * 4:][:4]
		if differs {
			differing += 1
			d[0], d[1], d[2], d[3] = 255, 0, 0, 255
		} else {
			gray := u8((u32(e[0]) + u32(e[1]) + u32(e[2])) / 3 / 4)
			d[0], d[1], d[2], d[3] = gray, gray, gray, 255
		}
	}
	return f64(differing) / f64(max(n, 1)), diff
}

// ---- inspect ------------------------------------------------------------------------

Finding :: struct {
	severity:      string      `json:"severity"`,
	code:          string      `json:"code"`,
	message:       string      `json:"message"`,
	fields:        json.Object `json:"fields"`,
	first_frame:   int      `json:"first_frame"`,
	last_frame:    int      `json:"last_frame"`,
	first_seconds: f32      `json:"first_seconds"`,
	last_seconds:  f32      `json:"last_seconds"`,
	frames:        int      `json:"frames"`,
	scenes:        []string `json:"scenes"`,
	// The script line that drew it, first time seen ("" when not a node).
	source:        string   `json:"source"`,
}

Inspect_Result :: struct {
	checked_frames: int       `json:"checked_frames"`,
	findings:       []Finding `json:"findings"`,
}

// Checks a frame every --every (and every scene's first and last frame and
// the range's last frame), groups findings across frames by key, and exits
// with code 2 per --fail-on.
@(private)
inspect :: proc(app: ^App_State, regs: Command_Regs) -> Error {
	r := renderer_scaled(app, 0.25) or_return
	fps := r.video.fps
	start, end := resolve_range(app, &r.timeline, fps, regs.spec) or_return
	step := 1
	if .All_Frames not_in regs.flags {
		every := regs.every if regs.every != "" else "0.25s"
		_, e, err := om.parse_range(r.timeline, fps, fmt.tprintf("0..%s", every))
		if err != nil {
			return fail(app, spec_failure(&r.timeline, fps, every, err))
		}
		step = max(e, 1)
	}
	checked := make([dynamic]int, context.temp_allocator)
	for f := start; f < end; f += step {
		append(&checked, f)
	}
	for s in r.timeline.scenes {
		for f in ([2]int{s.start_frame, s.end_frame - 1}) {
			if f >= start && f < end {
				append(&checked, f)
			}
		}
	}
	append(&checked, end - 1)
	sort_unique(&checked)
	// Problems name the script line that drew what they are about.
	app.script.node_sources_on = true
	defer app.script.node_sources_on = false

	findings: Finding_Table
	defer finding_table_destroy(&findings)
	for f in checked {
		// What a frame allocates in temp memory goes with it (the findings
		// keep copies in their own arena).
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		om.render_frame(r, f)
		for d in r.ctx.diagnostics {
			if d.severity != .Info || .Info in regs.flags {
				finding_add(&findings, &r.timeline, f, d, diagnostic_source(app, d))
			}
		}
		om.diagnostics_clear(&r.ctx)
	}
	// The sound checks measure the clips, those the script makes too.
	build_audio(app) or_return
	// Sync points, now that the frames have shown the tagged animate keys,
	// and sounds off the music's beat.
	timed := make([dynamic]om.Diagnostic, context.temp_allocator)
	append(&timed, ..sync_check(&app.media, om.placed_audio(&r.ctx).tracks[:], r.video.fps, sync_anchors(app, r) or_return))
	append(&timed, ..off_beat_check(app, r))
	for d in timed {
		if d.frame >= start && d.frame < end {
			finding_add(&findings, &r.timeline, d.frame, d)
		}
	}
	for d in load_diagnostics(&app.script, app_media(app)) {
		finding_add(&findings, nil, LOAD_FRAME, d)
	}
	failed := false
	if worst, any := findings_worst(&findings); any {
		switch Fail_On(regs.option) {
		case .Error:
			failed = worst >= .Error
		case .Warning:
			failed = worst >= .Warning
		case .Never:
		}
	}
	res := Inspect_Result{len(checked), findings_report(&findings, &r.timeline, fps)}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "checked %d frames: ", res.checked_frames)
	if len(res.findings) == 0 {
		strings.write_string(&b, "no problems found")
	} else {
		fmt.sbprintf(&b, "%d findings", len(res.findings))
	}
	findings_text(&b, res.findings)
	emit(app, res, strings.to_string(b))
	if failed && app.exit_code == 0 {
		app.exit_code = 2
	}
	return nil
}

@(private)
sort_unique :: proc(list: ^[dynamic]int) {
	for i in 1 ..< len(list) {
		for j := i; j > 0 && list[j - 1] > list[j]; j -= 1 {
			list[j - 1], list[j] = list[j], list[j - 1]
		}
	}
	w := 0
	for v, i in list {
		if i == 0 || v != list[w - 1] {
			list[w] = v
			w += 1
		}
	}
	resize(list, w)
}

// ---- render -------------------------------------------------------------------------

Render_Result :: struct {
	output:          string      `json:"output"`,
	frames:          Frame_Range `json:"frames"`,
	start_seconds:   f32         `json:"start_seconds"`,
	end_seconds:     f32         `json:"end_seconds"`,
	width:           int         `json:"width"`,
	height:          int         `json:"height"`,
	elapsed_seconds: f32         `json:"elapsed_seconds"`,
	encoder:         string      `json:"encoder"`,
	findings:        []Finding   `json:"findings"`,
}

DRAFT_QP :: 32

@(private)
video_render :: proc(app: ^App_State, regs: Command_Regs) -> Error {
	build_audio(app) or_return
	// Problems seen while rendering, in their own arena: the temp allocator
	// is freed every frame.
	findings_arena: virtual.Arena
	_ = virtual.arena_init_growing(&findings_arena)
	defer virtual.arena_destroy(&findings_arena)
	res := video_render_to(app, regs, virtual.arena_allocator(&findings_arena)) or_return
	emit(app, res, render_text(res))
	return nil
}

@(private)
render_text :: proc(res: Render_Result) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s frames %d..%d (%.2fs..%.2fs) %dx%d in %.1fs", res.output, res.frames.start, res.frames.end, res.start_seconds, res.end_seconds, res.width, res.height, res.elapsed_seconds)
	findings_text(&b, res.findings)
	return strings.to_string(b)
}

// Renders the video per `regs`; the findings (and `regs.path`) must outlive
// the frames, whose temp allocations are freed one by one: they are in
// `fa`. Failures go through `fail`.
@(private)
video_render_to :: proc(app: ^App_State, regs: Command_Regs, fa: mem.Allocator) -> (res: Render_Result, err: Error) {
	began := time.tick_now()
	load_ready(app) or_return
	draft := .Draft in regs.flags
	r := renderer_scaled(app, 0.5 if draft else 1) or_return
	fps := r.video.fps
	start, end := resolve_range(app, &r.timeline, fps, regs.spec) or_return
	out := regs.path if regs.path != "" else "out.mp4"
	as_png := !strings.has_suffix(strings.to_lower(out, context.temp_allocator), ".mp4")
	if !as_png {
		ensure_parent(out)
	}
	qp := i32(regs.count)
	if draft && qp == 0 {
		qp = DRAFT_QP
	}

	e: enc.Encoder
	defer enc.destroy(&e)
	if as_png {
		make_dir(app, out) or_return
	} else if enc.open(&e, out, int(r.width), int(r.height), fps, {codec = .H265 if regs.option == 1 else .H264, qp = qp, software = .Native in regs.flags, audio = has_audio(r.video), gop = fps if draft else 0, pool = app.pool}) != nil {
		return {}, fail(app, {code = .Encoder, encoder = e.failure})
	}
	if !as_png && e.audio {
		// Before the frames, so the MP4 interleaves audio with video.
		mix, _, _, _ := audio_mix(app, r, start, end)
		audio_err := enc.write_audio(&e, mix)
		delete(mix)
		if audio_err != nil {
			return {}, fail(app, encoder_failure(&e, audio_err))
		}
	}

	// Problems seen while rendering and found by the load, grouped like
	// inspect's (errors and warnings only).
	findings: Finding_Table
	defer finding_table_destroy(&findings)
	for d in load_diagnostics(&app.script, app_media(app)) {
		finding_add(&findings, nil, LOAD_FRAME, d)
	}

	// Frames are built by builders on the pool (builders.odin) and taken in
	// order here. GPU frames are played on this thread, converted to NV12
	// on the GPU and read back pipelined (or read back as RGBA for PNGs,
	// written by pool tasks); CPU frames arrive converted or written.
	pool := app.pool
	run := Build_Run {
		script_path  = app.script.path,
		script_args  = app.script.args,
		script_props = app.script.props,
		shared       = app.script.shared,
		media        = &app.media,
		scale        = r.scale,
		software     = r.is_software,
		gpu3d        = r.gpu3d,
		png_dir      = out if as_png else "",
	}
	// No frame is in flight yet: pins left by an earlier render go.
	om.media_evict(&app.media)
	builders: Builder_Set
	builder_set_init(&builders, &run, pool, start, end, om.frame_has_feedback(r, start))
	defer builder_set_destroy(&builders)

	shared: vg.Shared_Images
	players: []om.Frame_Player
	png_jobs: []Png_Job
	yuv: enc.GPU_NV12
	gpu_yuv := false
	if !r.is_software {
		// Record frame N + 1 while the GPU draws frame N.
		app.gpu.frames_in_flight = 2
		backend := vgsdl.backend(&app.gpu)
		vg.shared_images_init(&shared, backend)
		players = make([]om.Frame_Player, len(builders.builders))
		for &p in players {
			om.frame_player_init(&p, backend, &app.media, &shared)
			p.gpu3d = &app.gpu3d
		}
		gpu_yuv = !as_png && enc.gpu_nv12_init(&yuv, app.gpu.device, int(r.width), int(r.height)) == nil
		if as_png {
			png_jobs = make([]Png_Job, len(builders.builders))
		}
	}
	defer if !r.is_software {
		app.gpu.frames_in_flight = 0
		png_jobs_destroy(png_jobs)
		delete(png_jobs)
		if gpu_yuv {
			enc.gpu_nv12_destroy(&yuv)
		}
		for &p in players {
			om.frame_player_destroy(&p)
		}
		delete(players)
		vg.shared_images_destroy(&shared)
	}
	// Texture keys of the images each frame's eviction freed.
	evicted := make([dynamic]u64)
	defer delete(evicted)
	last_report := began
	// The first failure; its strings in `fa` (the temp allocator is freed
	// every frame).
	failed: Failure
	for f in start ..< end {
		done, k, setup_err := builder_set_take(&builders)
		if setup_err != nil {
			failed = builders.builders[k].failure
			break
		}
		switch {
		case r.is_software && as_png:
			if done.png_failed {
				failed = {code = .Write, path = fmt.aprintf("%s/%06d.png", out, f, allocator = fa)}
			}
		case r.is_software:
			if err := enc.write_i420(&e, done.i420, int(r.width)); err != nil {
				failed = encoder_failure(&e, err, f)
			}
		case as_png:
			om.play_frame(&players[k], &done.record)
			j := &png_jobs[(f - start) % len(png_jobs)]
			om.pool_join(&j.job)
			if j.failed {
				failed = {code = .Write, path = strings.clone(j.path, fa)}
				break
			}
			shot, err := vg.player_screenshot(&players[k].player)
			if err != nil {
				failed = {code = .Read_Back, n = f, gpu = err}
				break
			}
			png_job_start(j, shot.pixels, shot.width, shot.height, fmt.aprintf("%s/%06d.png", out, f), pool)
		case:
			if gpu_yuv {
				// The encoder reads the converted frames where they are
				// mapped; a slot frees once it is done with one.
				if err := enc.gpu_nv12_reserve(&yuv, &e); err != nil {
					failed = encoder_failure(&e, err, f)
					break
				}
				target := vgsdl.Output{texture = enc.gpu_nv12_target(&yuv), format = .R8G8B8A8_UNORM, width = r.width, height = r.height}
				om.play_frame(&players[k], &done.record, vgsdl.output(&target))
				err := enc.gpu_nv12_submit(&yuv, f)
				if err == nil {
					err = enc.gpu_nv12_feed(&yuv, &e, wait = false)
				}
				if err != nil {
					failed = encoder_failure(&e, err, f)
				}
				break
			}
			// No compute pass on this device: convert here.
			om.play_frame(&players[k], &done.record)
			shot, err := vg.player_screenshot(&players[k].player, context.temp_allocator)
			planes := make([]u8, enc.i420_size(int(r.width), int(r.height)), context.temp_allocator)
			if err != nil {
				failed = {code = .Read_Back, n = f, gpu = err}
				break
			}
			enc.rgba_to_i420(shot.pixels, int(r.width), int(r.height), planes)
			if werr := enc.write_i420(&e, planes, int(r.width)); werr != nil {
				failed = encoder_failure(&e, werr, f)
			}
		}
		// What building, drawing and (GPU) playing the frame reported.
		for d in done.record.diagnostics {
			if d.severity != .Info {
				finding_add(&findings, &r.timeline, f, d)
			}
		}
		om.frame_record_clear_diagnostics(&done.record)
		// Frames up to `f` are played (GPU) or drawn (CPU): images used
		// only by them may go, their shared textures with them.
		clear(&evicted)
		om.media_evict(&app.media, f + 1, &evicted)
		for key in evicted {
			vg.shared_images_remove(&shared, key)
		}
		free_all(context.temp_allocator)
		om.pool_drain_done(pool)
		if failed.code != .None {
			break
		}
		if time.tick_since(last_report) > time.Second {
			last_report = time.tick_now()
			done := f - start + 1
			fmt.eprintf("\r%d/%d frames, %.1f fps", done, end - start, f64(done) / time.duration_seconds(time.tick_since(began)))
		}
	}
	if gpu_yuv {
		if err := enc.gpu_nv12_finish(&yuv, &e); err != nil && failed.code == .None {
			failed = encoder_failure(&e, err)
		}
	}
	for &j in png_jobs {
		om.pool_join(&j.job)
		if j.failed && failed.code == .None {
			failed = {code = .Write, path = strings.clone(j.path, fa)}
		}
	}
	om.pool_drain_done(pool)
	if !as_png && enc.close(&e) != nil {
		fmt.eprint("\r\x1b[K")
		return {}, fail(app, {code = .Encoder, encoder = e.failure})
	}
	if failed.code != .None {
		fmt.eprint("\r\x1b[K")
		return {}, fail(app, failed)
	}
	fmt.eprint("\r\x1b[K")
	res = {
		output          = out,
		frames          = {start, end},
		start_seconds   = f32(start) / f32(fps),
		end_seconds     = f32(end) / f32(fps),
		width           = int(r.width),
		height          = int(r.height),
		elapsed_seconds = f32(time.duration_seconds(time.tick_since(began))),
		encoder         = "png" if as_png else strings.clone(e.backend, fa),
		findings        = findings_report(&findings, &r.timeline, fps, fa),
	}
	return res, nil
}

// The encoder's failure (`code` when it has none: the GPU conversion's).
@(private)
encoder_failure :: proc(e: ^enc.Encoder, code: enc.Error, frame := 0) -> Failure {
	if e.failure.code != .None {
		return {code = .Encoder, encoder = e.failure}
	}
	return {code = .Encoder, encoder = {code = code, frame = i64(frame)}}
}

// ---- pixels -------------------------------------------------------------------------

// A render never ships what the load found broken (a silent spoken line,
// a track whose sound is missing): it refuses while the load found errors.
@(private)
load_ready :: proc(app: ^App_State) -> Error {
	count, first := 0, ""
	for d in load_diagnostics(&app.script, app_media(app)) {
		if d.severity == .Error {
			if count == 0 {
				first = om.diagnostic_message(d, context.temp_allocator)
			}
			count += 1
		}
	}
	if count == 0 {
		return nil
	}
	return fail(app, {code = .Load_Errors, count = count, name = first})
}

// ---- probe --------------------------------------------------------------------------

// The streams of media files (`onimite probe`): a result per file, text or
// one JSON document each. A file that can't be read is reported and the
// others still go (exit code 1).
@(private)
probe_print :: proc(app: ^App_State, regs: Command_Regs) -> Error {
	for path in strings.split_lines(regs.args, context.temp_allocator) {
		res, f := enc.probe(path)
		if f.code != .None {
			fail(app, {code = .Probe, encoder = f})
			failure_print(app)
			failure_clear(app)
			continue
		}
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, "%s: %s", path, res.container)
		if v, ok := res.video.?; ok {
			fmt.sbprintf(&b, "\n  video: %s %dx%d, %.3f fps, %d frames, %.3fs, %d-bit%s%s", v.codec, v.width, v.height, v.fps, v.frames, v.duration, v.bit_depth, ", alpha" if v.has_alpha else "", fmt.tprintf(", rotated %d", v.rotation) if v.rotation != 0 else "")
		}
		if a, ok := res.audio.?; ok {
			fmt.sbprintf(&b, "\n  audio: %s %d Hz, %d ch, %.3fs", a.codec, a.sample_rate, a.channels, a.duration)
		}
		emit(app, res, strings.to_string(b))
	}
	return nil
}
