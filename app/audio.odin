package onimite_app

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import om "../onimite"
import script "../script"
import vg "deps:ovg"

// `audio render`, `audio analyze`, `audio at` and `audio onsets`, with
// fframes' outputs. `--track FILE` hears one track alone: the others are
// muted but still duck it, so it sounds as it does in the mix.

// Builds the clips whose function the script's audio_add deferred (before
// anything that plays or measures sound), side by side on the app's pool
// or one after another without (clip_builds.odin); a failing build fails
// the command as the script's failure.
@(private)
build_audio :: proc(app: ^App_State) -> Error {
	if !app.script_loaded || !script.audio_pending(&app.script) {
		return nil
	}
	s := &app.script
	b := clip_builds_make(script.audio_pending_names(s), app.pool, s.shared, s.path, app.media.dir, s.args, s.props, &app.video)
	defer clip_builds_destroy(b)
	clip_builds_wait(b)
	if _, f := clip_builds_drain(b, &app.media, s); f.code != .None {
		return fail(app, {code = .Script, script = f})
	}
	return nil
}

// The placed tracks, all but `track` muted when it is set; No_Track when no
// track plays that file.
@(private)
placed_tracks :: proc(app: ^App_State, r: ^om.Renderer, track: string) -> (placed: [dynamic]om.Placed_Track, err: Error) {
	// Copied: muting one track alone is this call's.
	placed = slice.clone_to_dynamic(om.placed_audio(&r.ctx).tracks[:], context.temp_allocator)
	if track == "" {
		return placed, nil
	}
	if solo(placed[:], track) == 0 {
		names := make([dynamic]string, context.temp_allocator)
		for p in placed {
			for n in ([2]string{p.track.src, p.track.bus}) {
				if n != "" && !slice.contains(names[:], n) {
					append(&names, n)
				}
			}
		}
		return placed, fail(app, {code = .No_Track, name = track, names = names[:]})
	}
	return placed, nil
}

// Mutes every track but those playing file `name` or mixed through bus
// `name`; returns how many are left.
@(private)
solo :: proc(placed: []om.Placed_Track, name: string) -> (heard: int) {
	for &p in placed {
		p.muted = p.track.src != name && p.track.bus != name
		heard += int(!p.muted)
	}
	return
}

// The mix of `[start, end)` video frames, with the placed tracks.
@(private)
audio_mix :: proc(app: ^App_State, r: ^om.Renderer, start, end: int, track := "") -> (mix: []f32, placed: [dynamic]om.Placed_Track, stats: om.Mix_Stats, err: Error) {
	placed = placed_tracks(app, r, track) or_return
	fps := r.video.fps
	mix, stats = om.mix_tracks(placed[:], om.frames_to_samples(start, fps), om.frames_to_samples(end, fps), r.video.mix)
	return
}

@(private)
has_audio :: proc(v: ^om.Video) -> bool {
	return len(v.audio) > 0
}

// The sounds the tracks need that the media lacks (`missing_files`), as the
// load reported them (`load_diagnostics`: played, or counted by a track's
// start or stop).
@(private)
missing_audio :: proc(app: ^App_State) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for d in load_diagnostics(&app.script, app_media(app)) {
		if d.code == .Missing_Track || d.code == .Missing_Track_Time {
			append(&names, d.a)
		}
	}
	return names[:]
}

// ---- render ---------------------------------------------------------------------------

Audio_Render_Result :: struct {
	output:        string   `json:"output"`,
	start_seconds: f64      `json:"start_seconds"`,
	end_seconds:   f64      `json:"end_seconds"`,
	missing_files: []string `json:"missing_files"`,
}

// The mix as a stereo WAV: 16-bit PCM, or 32-bit float with --float.
@(private)
audio_render :: proc(app: ^App_State, regs: Command_Regs) -> Error {
	build_audio(app) or_return
	r := renderer_scaled(app, 1) or_return
	start, end := resolve_range(app, &r.timeline, r.video.fps, regs.spec) or_return
	mix, _, _ := audio_mix(app, r, start, end, regs.track) or_return
	defer delete(mix)
	out := regs.path if regs.path != "" else "audio.wav"
	wav := encode_wav_float(mix, om.MIX_RATE) if .Float in regs.flags else om.encode_wav16(mix, om.MIX_RATE)
	defer delete(wav)
	ensure_parent(out)
	if os.write_entire_file(out, wav) != nil {
		return fail(app, {code = .Write, path = out})
	}
	fps := f64(r.video.fps)
	res := Audio_Render_Result{out, f64(start) / fps, f64(end) / fps, missing_audio(app)}
	emit(app, res, fmt.tprintf("%s %.2fs..%.2fs", out, res.start_seconds, res.end_seconds))
	return nil
}

// Interleaved stereo as a 32-bit float WAV file.
encode_wav_float :: proc(samples: []f32, rate: int, allocator := context.allocator) -> []u8 {
	n := len(samples)
	out := make([]u8, 44 + n * 4, allocator)
	put16 :: proc(b: []u8, at: int, v: int) {b[at], b[at + 1] = u8(v), u8(v >> 8)}
	put32 :: proc(b: []u8, at: int, v: int) {put16(b, at, v); put16(b, at + 2, v >> 16)}
	copy(out[0:], "RIFF")
	put32(out, 4, 36 + n * 4)
	copy(out[8:], "WAVEfmt ")
	put32(out, 16, 16)
	put16(out, 20, 3) // IEEE float
	put16(out, 22, 2)
	put32(out, 24, rate)
	put32(out, 28, rate * 8)
	put16(out, 32, 8)
	put16(out, 34, 32)
	copy(out[36:], "data")
	put32(out, 40, n * 4)
	for s, i in samples {
		put32(out, 44 + i * 4, int(transmute(u32)s))
	}
	return out
}

// ---- analyze --------------------------------------------------------------------------

Audio_Section :: struct {
	name:            string       `json:"name"`,
	start_seconds:   f64          `json:"start_seconds"`,
	end_seconds:     f64          `json:"end_seconds"`,
	integrated_lufs: Maybe(f64)   `json:"integrated_lufs"`,
	true_peak_dbtp:  Maybe(f64)   `json:"true_peak_dbtp"`,
}

Audio_Report_Doc :: struct {
	integrated_lufs:     Maybe(f64)      `json:"integrated_lufs"`,
	loudness_range_lu:   Maybe(f64)      `json:"loudness_range_lu"`,
	max_momentary_lufs:  Maybe(f64)      `json:"max_momentary_lufs"`,
	max_short_term_lufs: Maybe(f64)      `json:"max_short_term_lufs"`,
	sample_peak_dbfs:    Maybe(f64)      `json:"sample_peak_dbfs"`,
	true_peak_dbtp:      Maybe(f64)      `json:"true_peak_dbtp"`,
	clipped_samples:     int             `json:"clipped_samples"`,
	silent_ranges:       [][2]f64        `json:"silent_ranges"`,
	sections:            []Audio_Section `json:"sections"`,
	// Each bus alone (its tracks as they sound in the mix).
	buses:               []Audio_Bus     `json:"buses"`,
	loudness:            Loudness_Curve  `json:"loudness"`,
}

Audio_Bus :: struct {
	name:            string     `json:"name"`,
	tracks:          int        `json:"tracks"`,
	integrated_lufs: Maybe(f64) `json:"integrated_lufs"`,
	true_peak_dbtp:  Maybe(f64) `json:"true_peak_dbtp"`,
}

// Momentary loudness (400 ms windows) every 100 ms: where the music gets
// loud or quiet (an intro, a build, a drop). Value i covers the 400 ms
// ending at `first_seconds + i * step_seconds`; null is silence.
Loudness_Curve :: struct {
	step_seconds:   f64          `json:"step_seconds"`,
	first_seconds:  f64          `json:"first_seconds"`,
	momentary_lufs: []Maybe(f64) `json:"momentary_lufs"`,
}

Audio_Analyze_Result :: struct {
	report:        Audio_Report_Doc `json:"report"`,
	waveform:      Maybe(string)    `json:"waveform"`,
	missing_files: []string         `json:"missing_files"`,
}

// `-inf` (silence) as null.
@(private)
level :: proc(v: f32) -> Maybe(f64) {
	if math.is_inf(v) || math.is_nan(v) || v < -200 {
		return nil
	}
	return f64(v)
}

@(private)
level_text :: proc(v: Maybe(f64), unit: string) -> string {
	if x, ok := v.?; ok {
		return fmt.tprintf("%.1f %s", x, unit)
	}
	return "silent"
}

// Loudness (LUFS), loudness range, peaks, clipping, silences and per scene
// loudness; with -o also the waveform PNG.
@(private)
audio_analyze :: proc(app: ^App_State, regs: Command_Regs) -> Error {
	build_audio(app) or_return
	r := renderer_scaled(app, 1) or_return
	fps := r.video.fps
	start, end := resolve_range(app, &r.timeline, fps, regs.spec) or_return
	mix, placed, _ := audio_mix(app, r, start, end, regs.track) or_return
	defer delete(mix)
	rep := om.analyze_audio(mix)
	defer om.audio_report_destroy(&rep)
	offset := f64(start) / f64(fps)

	doc := Audio_Report_Doc {
		integrated_lufs     = level(rep.integrated_lufs),
		loudness_range_lu   = f64(rep.loudness_range) if len(rep.short_term_curve) >= 30 else nil,
		max_momentary_lufs  = level(rep.max_momentary),
		max_short_term_lufs = level(rep.max_short_term),
		sample_peak_dbfs    = level(rep.sample_peak_db),
		true_peak_dbtp      = level(rep.true_peak_db),
		clipped_samples     = rep.clipped_samples,
	}
	silent := make([][2]f64, len(rep.silent_ranges), context.temp_allocator)
	for s, i in rep.silent_ranges {
		silent[i] = {f64(s[0]) + offset, f64(s[1]) + offset}
	}
	doc.silent_ranges = silent
	from := om.frames_to_samples(start, fps)
	n := len(mix) / 2
	sections := make([dynamic]Audio_Section, context.temp_allocator)
	for s in r.timeline.scenes {
		if s.start_frame >= end || s.end_frame <= start {
			continue
		}
		a := clamp(om.frames_to_samples(s.start_frame, fps) - from, 0, n)
		b := clamp(om.frames_to_samples(s.end_frame, fps) - from, 0, n)
		sec := Audio_Section{name = s.scene.name, start_seconds = f64(a) / om.MIX_RATE + offset, end_seconds = f64(b) / om.MIX_RATE + offset}
		if b > a {
			part := om.analyze_audio(mix[a * 2:b * 2], context.temp_allocator)
			sec.integrated_lufs = level(part.integrated_lufs)
			sec.true_peak_dbtp = level(part.true_peak_db)
		}
		append(&sections, sec)
	}
	doc.sections = sections[:]
	// Each bus alone: the effects against the music.
	buses := make([dynamic]Audio_Bus, context.temp_allocator)
	if regs.track == "" {
		bus_placed := slice.clone(placed[:], context.temp_allocator)
		for b in r.video.buses {
			count := solo(bus_placed, b.name)
			bm, _ := om.mix_tracks(bus_placed, om.frames_to_samples(start, fps), om.frames_to_samples(end, fps), r.video.mix, context.temp_allocator)
			br := om.analyze_audio(bm, context.temp_allocator)
			append(&buses, Audio_Bus{b.name, count, level(br.integrated_lufs), level(br.true_peak_db)})
		}
	}
	doc.buses = buses[:]
	curve := make([]Maybe(f64), len(rep.momentary_curve), context.temp_allocator)
	for l, i in rep.momentary_curve {
		if v, ok := level(l).?; ok {
			curve[i] = math.round(v * 10) / 10
		}
	}
	doc.loudness = {0.1, offset + 0.4, curve}

	res := Audio_Analyze_Result{report = doc, missing_files = missing_audio(app)}
	if regs.path != "" {
		if !write_waveform(app, r, regs.path, mix, rep, placed[:], start) {
			return fail(app, {code = .Write, path = regs.path})
		}
		res.waveform = regs.path
	}

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&b,
		"integrated %s, range %s, max momentary %s, max short-term %s\nsample peak %s, true peak %s, clipped samples %d",
		level_text(doc.integrated_lufs, "LUFS"),
		fmt.tprintf("%.1f LU", doc.loudness_range_lu.?) if doc.loudness_range_lu != nil else "-",
		level_text(doc.max_momentary_lufs, "LUFS"),
		level_text(doc.max_short_term_lufs, "LUFS"),
		level_text(doc.sample_peak_dbfs, "dBFS"),
		level_text(doc.true_peak_dbtp, "dBTP"),
		doc.clipped_samples,
	)
	for s in silent {
		fmt.sbprintf(&b, "\nsilent %.2fs..%.2fs", s[0], s[1])
	}
	for s in sections {
		fmt.sbprintf(
			&b,
			"\n%-28s %18s %s / peak %s",
			s.name,
			fmt.tprintf("%.2fs..%.2fs", s.start_seconds, s.end_seconds),
			level_text(s.integrated_lufs, "LUFS"),
			level_text(s.true_peak_dbtp, "dBTP"),
		)
	}
	for bus in doc.buses {
		fmt.sbprintf(&b, "\nbus %-24s %6s %s / peak %s", bus.name, fmt.tprintf("%d tracks", bus.tracks), level_text(bus.integrated_lufs, "LUFS"), level_text(bus.true_peak_dbtp, "dBTP"))
	}
	write_loudness_seconds(&b, doc.loudness)
	if regs.path != "" {
		fmt.sbprintf(&b, "\nwaveform %s", regs.path)
	}
	emit(app, res, strings.to_string(b))
	return nil
}

// The loudness curve as text: the loudest momentary value in each second,
// rounded, 15 seconds a line ("-" for silence).
@(private)
write_loudness_seconds :: proc(b: ^strings.Builder, c: Loudness_Curve) {
	if len(c.momentary_lufs) == 0 {
		return
	}
	first := c.first_seconds - 0.4 // the second the first window starts in
	fmt.sbprintf(b, "\nloudness per second from %.0fs (momentary max, LUFS):", first)
	per := int(math.round(1 / c.step_seconds))
	for i := 0; i < len(c.momentary_lufs); i += per {
		if (i / per) % 15 == 0 {
			fmt.sbprintf(b, "\n  %5s", fmt.tprintf("%.0fs", first + f64(i) * c.step_seconds))
		}
		loudest: Maybe(f64)
		for v in c.momentary_lufs[i:min(i + per, len(c.momentary_lufs))] {
			if x, ok := v.?; ok && (loudest == nil || x > loudest.?) {
				loudest = x
			}
		}
		if x, ok := loudest.?; ok {
			fmt.sbprintf(b, " %4s", fmt.tprintf("%.0f", x))
		} else {
			strings.write_string(b, "    -")
		}
	}
}

// ---- onsets ---------------------------------------------------------------------------

Onset_Doc :: struct {
	seconds:  f64 `json:"seconds"`,
	strength: f64 `json:"strength"`,
}

Audio_Onsets_Result :: struct {
	start_seconds:       f64          `json:"start_seconds"`,
	end_seconds:         f64          `json:"end_seconds"`,
	// null when there is no steady beat.
	bpm:                 Maybe(f64)   `json:"bpm"`,
	first_beat_seconds:  Maybe(f64)   `json:"first_beat_seconds"`,
	onsets:              []Onset_Doc  `json:"onsets"`,
	missing_files:       []string     `json:"missing_files"`,
}

// Where sounds start in the mix (or one track) on the video clock, how
// strong each is, and the beat they imply.
@(private)
audio_onsets :: proc(app: ^App_State, regs: Command_Regs) -> Error {
	build_audio(app) or_return
	r := renderer_scaled(app, 1) or_return
	fps := r.video.fps
	start, end := resolve_range(app, &r.timeline, fps, regs.spec) or_return
	mix, _, _ := audio_mix(app, r, start, end, regs.track) or_return
	defer delete(mix)
	rep := om.audio_onsets(mix, context.temp_allocator)
	offset := f64(start) / f64(fps)
	res := Audio_Onsets_Result {
		start_seconds = offset,
		end_seconds   = f64(end) / f64(fps),
		missing_files = missing_audio(app),
	}
	if rep.bpm > 0 {
		res.bpm = f64(rep.bpm)
		res.first_beat_seconds = offset + f64(rep.offset)
	}
	list := make([dynamic]Onset_Doc, context.temp_allocator)
	for o in rep.onsets {
		if f64(o.strength) >= regs.ratio {
			append(&list, Onset_Doc{offset + f64(o.time), f64(o.strength)})
		}
	}
	res.onsets = list[:]

	b := strings.builder_make(context.temp_allocator)
	if bpm, ok := res.bpm.?; ok {
		fmt.sbprintf(&b, "%.1f BPM, first beat at %.3fs: beat_clock(%.2f, %.3f)", bpm, res.first_beat_seconds.?, bpm, res.first_beat_seconds.?)
	} else {
		strings.write_string(&b, "no steady beat")
	}
	fmt.sbprintf(&b, "\n%d onsets %.2fs..%.2fs (seconds strength)", len(list), res.start_seconds, res.end_seconds)
	for o, i in list {
		if i % 6 == 0 {
			strings.write_string(&b, "\n ")
		}
		fmt.sbprintf(&b, " %9s %.2f", fmt.tprintf("%.3f", o.seconds), o.strength)
	}
	emit(app, res, strings.to_string(b))
	return nil
}

// ---- at -------------------------------------------------------------------------------

Active_Track :: struct {
	file:         string     `json:"file"`,
	bus:          string     `json:"bus"`,
	file_seconds: f64        `json:"file_seconds"`,
	gain_db:      Maybe(f64) `json:"gain_db"`,
	voice:        bool       `json:"voice"`,
	ducked_db:    Maybe(f64) `json:"ducked_db"`,
}

Audio_At_Result :: struct {
	spec:    string         `json:"spec"`,
	frame:   int            `json:"frame"`,
	seconds: f64            `json:"seconds"`,
	tracks:  []Active_Track `json:"tracks"`,
}

// What plays at each time: the file, where in it, how loud (gain, fades and
// ducking) and how far it is ducked.
@(private)
audio_at :: proc(app: ^App_State, regs: Command_Regs) -> Error {
	build_audio(app) or_return
	r := renderer_scaled(app, 1) or_return
	fps := r.video.fps
	specs, frames := resolve_frames(app, &r.timeline, fps, regs.spec) or_return
	placed := placed_tracks(app, r, regs.track) or_return
	results := make([]Audio_At_Result, len(frames), context.temp_allocator)
	for f, i in frames {
		s := int(math.round(f64(f) / f64(fps) * om.MIX_RATE))
		tracks := make([dynamic]Active_Track, context.temp_allocator)
		for p in placed {
			if s < p.start || s >= p.end || p.muted {
				continue
			}
			tr := p.track
			k := s - p.start
			length := p.end - p.start
			env := om.track_envelope(k, length, om.seconds_to_samples(tr.fade_in), om.seconds_to_samples(tr.fade_out), tr.curve)
			duck: f32 = 1
			if tr.ducked {
				duck = om.duck_envelope(placed[:], om.ducking_resolved(tr.duck), s, s + 1)[0]
			}
			gain := tr.gain_db + 20 * math.log10(max(env * duck, 1e-12))
			at := Active_Track {
				file         = tr.src,
				bus          = tr.bus,
				file_seconds = f64(p.file_start + k) / om.MIX_RATE,
				gain_db      = f64(gain) if env * duck > 0 else nil,
				voice        = tr.voice,
			}
			if tr.ducked {
				at.ducked_db = f64(20 * math.log10(max(duck, 1e-12)))
			}
			append(&tracks, at)
		}
		results[i] = {specs[i], f, f64(f) / f64(fps), tracks[:]}
	}
	b := strings.builder_make(context.temp_allocator)
	for res, i in results {
		if i > 0 {
			strings.write_byte(&b, '\n')
		}
		fmt.sbprintf(&b, "%s (%.3fs):", res.spec, res.seconds)
		if len(res.tracks) == 0 {
			strings.write_string(&b, " silence")
		}
		for t in res.tracks {
			gain := fmt.tprintf("%.1f", t.gain_db.?) if t.gain_db != nil else "-inf"
			ducked := ""
			if d, has := t.ducked_db.?; has && d < -0.05 {
				ducked = fmt.tprintf(", ducked %.1f dB", d)
			}
			bus := fmt.tprintf(" (bus %s)", t.bus) if t.bus != "" else ""
			fmt.sbprintf(&b, "\n  %s%s at %.3fs of the file, %s dB%s%s", t.file, bus, t.file_seconds, gain, ", voice" if t.voice else "", ducked)
		}
	}
	emit(app, results, strings.to_string(b))
	return nil
}

// ---- waveform -------------------------------------------------------------------------

// fframes' waveform: min/max per column (blue), momentary loudness -60..0
// LUFS (pink), scene starts (purple), audio cues (yellow), a time axis and a
// legend.
@(private)
write_waveform :: proc(app: ^App_State, r: ^om.Renderer, path: string, mix: []f32, rep: om.Audio_Report, placed: []om.Placed_Track, start_frame: int) -> bool {
	W :: 1600
	H :: 420
	TOP :: 28
	WAVE_H :: 300
	sw: vg.Software_Backend
	vg.software_backend_init(&sw)
	defer vg.software_backend_destroy(&sw)
	c: vg.Canvas
	vg.canvas_init(&c, vg.software_backend(&sw))
	defer vg.canvas_destroy(&c)
	vg.set_size(&c, W, H)
	vg.clear_rect(&c, 0, 0, W, H, vg.rgb(24, 24, 27))
	p: vg.Path
	defer vg.path_destroy(&p)
	glyphs: [dynamic]vg.Positioned_Glyph
	defer delete(glyphs)
	font := om.media_fallback_font(&app.media)
	label :: proc(c: ^vg.Canvas, font: ^vg.Font, glyphs: ^[dynamic]vg.Positioned_Glyph, p: ^vg.Path, text: string, x, y, size: f32, color: vg.Color) {
		em := vg.font_scale_for_em(font, size)
		clear(glyphs)
		vg.layout_simple(font, text, x, y, em, glyphs)
		vg.fill_glyph_outlines(c, font, glyphs[:], em, vg.paint_color(color), p)
	}

	n := len(mix) / 2
	duration := max(f64(n) / om.MIX_RATE, 1e-6)
	x_of :: proc(seconds, duration: f64) -> f32 {return f32(seconds / duration * W)}
	mid := f32(TOP + WAVE_H / 2)
	vg.path_rect(&p, 0, mid, W, 1)
	vg.fill_path(&c, &p, vg.paint_color(vg.rgb(63, 63, 70)))

	vg.path_reset(&p)
	per := max(n / W, 1)
	for x in 0 ..< W {
		a := min(x * per, n)
		b := min((x + 1) * per, n)
		lo, hi: f32 = 0, 0
		for i in a ..< b {
			v := (mix[i * 2] + mix[i * 2 + 1]) * 0.5
			lo = min(lo, v)
			hi = max(hi, v)
		}
		scale := f32(WAVE_H) / 2
		vg.path_rect(&p, f32(x), mid - hi * scale, 1, max((hi - lo) * scale + 0.5, 1))
	}
	vg.fill_path(&c, &p, vg.paint_color(vg.rgb(56, 189, 248)))

	vg.path_reset(&p)
	for l, i in rep.momentary_curve {
		x := x_of((f64(i) + 4) * 0.1, duration)
		y := f32(TOP) + f32(WAVE_H) * (clamp(l, -60, 0) / -60)
		if i == 0 {
			vg.path_move_to(&p, x, y)
		} else {
			vg.path_line_to(&p, x, y)
		}
	}
	lp := vg.paint_color(vg.rgb(244, 114, 182))
	lp.stroke.line_width = 1.5
	vg.stroke_path(&c, &p, lp)

	fps := f64(r.video.fps)
	offset := f64(start_frame) / fps
	for s in r.timeline.scenes {
		x := x_of(f64(s.start_frame) / fps - offset, duration)
		if x < 0 || x > W {
			continue
		}
		vg.path_reset(&p)
		vg.path_rect(&p, x, TOP, 1, WAVE_H)
		vg.fill_path(&c, &p, vg.paint_color(vg.rgb(167, 139, 250)))
		label(&c, font, &glyphs, &p, s.scene.name, x + 3, TOP - 8, 13, vg.rgb(196, 181, 253))
	}
	for pl in placed {
		t := f64(pl.start) / om.MIX_RATE - offset
		if t < 0 || t > duration {
			continue
		}
		x := x_of(t, duration)
		vg.path_reset(&p)
		vg.path_rect(&p, x - 0.75, TOP + WAVE_H + 4, 1.5, 12)
		vg.fill_path(&c, &p, vg.paint_color(vg.rgb(251, 191, 36)))
	}
	// Every onset of the mix (ticks as tall as they are strong) and the
	// script's cues (green, named; a family by its first).
	onsets := om.audio_onsets(mix, context.temp_allocator)
	vg.path_reset(&p)
	for o in onsets.onsets {
		vg.path_rect(&p, x_of(f64(o.time), duration) - 0.5, TOP + WAVE_H - 10 * o.strength, 1, 10 * o.strength)
	}
	vg.fill_path(&c, &p, vg.paint_color(vg.rgb(244, 244, 245)))
	last_family := ""
	for cue in app.script.cues {
		t := cue.seconds - offset
		if t < 0 || t > duration {
			continue
		}
		x := x_of(t, duration)
		vg.path_reset(&p)
		vg.path_rect(&p, x - 0.5, TOP, 1, WAVE_H)
		vg.fill_path(&c, &p, vg.paint_color(vg.rgba(74, 222, 128, 160)))
		if fam := family_of(cue.name); fam != last_family {
			label(&c, font, &glyphs, &p, fam, x + 3, TOP + 14, 12, vg.rgb(134, 239, 172))
			last_family = fam
		}
	}
	tick: f64 = 120
	for t in ([?]f64{1, 2, 5, 10, 15, 30, 60}) {
		if duration / t <= 16 {
			tick = t
			break
		}
	}
	for t: f64 = 0; t <= duration; t += tick {
		label(&c, font, &glyphs, &p, fmt.tprintf("%.0fs", t + offset), x_of(t, duration) + 2, H - 12, 12, vg.rgb(161, 161, 170))
	}
	label(&c, font, &glyphs, &p, "waveform (blue), momentary loudness -60..0 LUFS (pink), scenes (purple), track starts (yellow), onsets (white ticks), cues (green)", 8, H - 30, 12, vg.rgb(161, 161, 170))
	vg.flush(&c)
	ensure_parent(path)
	return write_png(path, sw.pixels, W, H) == nil
}
