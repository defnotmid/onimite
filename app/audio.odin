package onimite_app

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import wav "deps:odecs/audio/wav"
import oanalyze "deps:odawg/analyze"
import orender "deps:odawg/render"
import osong "deps:odawg/song"
import common "deps:odecs/common"
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
	b := clip_builds_make(script.audio_pending_names(s), app.pool, app.background, s.shared, s.path, app.media.dir, s.args, s.props, &app.video)
	defer clip_builds_destroy(b)
	clip_builds_wait(b)
	if _, f := clip_builds_drain(b, &app.media, s); f.code != .None {
		return fail(app, {code = .Script, script = f})
	}
	return nil
}

// The placed tracks, all but `track` muted when it is set; No_Track when no
// track plays that file (or song part: `score/bass`).
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
			if p.song != nil {
				for part in p.song.song.parts {
					n := fmt.tprintf("%s/%s", p.track.src, part)
					if !slice.contains(names[:], n) {
						append(&names, n)
					}
				}
			}
		}
		return placed, fail(app, {code = .No_Track, name = track, names = names[:]})
	}
	return placed, nil
}

// Mutes every track but those playing file `name`, mixed through bus
// `name`, or playing song part `name` ("score/bass": that part alone);
// returns how many are left.
@(private)
solo :: proc(placed: []om.Placed_Track, name: string) -> (heard: int) {
	song, _, part := strings.partition(name, "/")
	for &p in placed {
		p.part = ""
		p.muted = p.track.src != name && p.track.bus != name
		if p.muted && p.song != nil && p.track.src == song && slice.contains(p.song.song.parts[:], part) {
			p.muted, p.part = false, part
		}
		heard += int(!p.muted)
	}
	return
}

// The mix of `[start, end)` video frames, with the placed tracks.
@(private)
audio_mix :: proc(app: ^App_State, r: ^om.Renderer, start, end: int, track := "") -> (mix: []f32, placed: [dynamic]om.Placed_Track, stats: om.Mix_Stats, err: Error) {
	placed = placed_tracks(app, r, track) or_return
	fps := r.video.fps
	mix, stats = om.mix_tracks(placed[:], om.frames_to_samples(start, fps), om.frames_to_samples(end, fps), r.video.mix, &app.background_work.work_pool)
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
	ensure_parent(out)
	if wav.write_file(out, mix, om.MIX_RATE, 2, .F32 if .Float in regs.flags else .S16) != .None {
		return fail(app, {code = .Write, path = out})
	}
	fps := f64(r.video.fps)
	res := Audio_Render_Result{out, f64(start) / fps, f64(end) / fps, missing_audio(app)}
	emit(app, res, fmt.tprintf("%s %.2fs..%.2fs", out, res.start_seconds, res.end_seconds))
	return nil
}

// ---- analyze --------------------------------------------------------------------------

Audio_Section :: struct {
	name:            string       `json:"name"`,
	start_seconds:   f64          `json:"start_seconds"`,
	end_seconds:     f64          `json:"end_seconds"`,
	integrated_lufs: Maybe(f64)   `json:"integrated_lufs"`,
	true_peak_dbtp:  Maybe(f64)   `json:"true_peak_dbtp"`,
	// What the stretch is made of (put_sound): its crest, stereo width and
	// correlation, and its level in each third octave (`band_hz`).
	crest_db:        f64          `json:"crest_db"`,
	width_db:        f64          `json:"width_db"`,
	correlation:     f64          `json:"correlation"`,
	bands_db:        []f64        `json:"bands_db"`,
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
	crest_db:            f64              `json:"crest_db"`,
	width_db:            f64              `json:"width_db"`,
	correlation:     f64              `json:"correlation"`,
	bands_db:            []f64            `json:"bands_db"`,
	// The bands' centres (Hz), for every `bands_db`.
	band_hz:             []f64           `json:"band_hz"`,
	sections:            []Audio_Section `json:"sections"`,
	// Each bus alone (its tracks as they sound in the mix).
	buses:               []Audio_Bus     `json:"buses"`,
	// Buses crowding each other in a band, per scene: within 6 dB of each
	// other there, the quieter within 15 dB of the mix (odawg's rule).
	masking:             []orender.Masking_Row `json:"masking"`,
	loudness:            Loudness_Curve  `json:"loudness"`,
}

Audio_Bus :: struct {
	name:            string     `json:"name"`,
	tracks:          int        `json:"tracks"`,
	integrated_lufs: Maybe(f64) `json:"integrated_lufs"`,
	true_peak_dbtp:  Maybe(f64) `json:"true_peak_dbtp"`,
	crest_db:        f64          `json:"crest_db"`,
	width_db:        f64          `json:"width_db"`,
	correlation:     f64          `json:"correlation"`,
	bands_db:        []f64        `json:"bands_db"`,
}

// A step of the analysis tables: 50 ms.
ANALYSIS_STEP :: om.MIX_RATE / 20

// The tables odawg measures a stretch of sound by (bands, stereo, crest),
// a row every ANALYSIS_STEP, over stereo channels `l, r`; temp memory.
Analysis_Tables :: struct {
	bands, stereo, crest: orender.Table,
}

@(private)
analysis_tables :: proc(l, r: []f32, pool: ^common.Work_Pool) -> (t: Analysis_Tables) {
	n := min(len(l), len(r))
	a := context.temp_allocator
	orender.table_init_frames(&t.bands, .Bands, n, ANALYSIS_STEP, 1, allocator = a)
	orender.table_init_frames(&t.stereo, .Stereo, n, ANALYSIS_STEP, 1, allocator = a)
	orender.table_init_frames(&t.crest, .Crest, n, ANALYSIS_STEP, 1, allocator = a)
	orender.tables_fill(nil, {&t.bands, &t.stereo, &t.crest}, {l, r}, nil, pool)
	return
}

// odawg's measures of samples [a, b) of the tables' source.
@(private)
analysis_measures :: proc(t: ^Analysis_Tables, a, b: int, name := "") -> orender.Measures {
	m := orender.measures_from_tables(&t.bands, &t.stereo, &t.crest, {a / ANALYSIS_STEP, (b + ANALYSIS_STEP - 1) / ANALYSIS_STEP}, context.temp_allocator)
	m.name = name
	return m
}

// Puts odawg's measures `m` in a report entry (a scene, a bus, the whole),
// rounded to what a reader uses.
@(private)
put_sound :: proc(x: ^$T, m: orender.Measures) {
	round :: proc(v: f64) -> f64 {return math.round(v * 10) / 10}
	bands := make([]f64, len(m.bands_db), context.temp_allocator)
	for v, i in m.bands_db {
		bands[i] = round(v)
	}
	x.crest_db, x.width_db, x.correlation, x.bands_db = round(m.crest_db), round(m.width_db), math.round(m.correlation * 100) / 100, bands
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
level :: proc(v: f64) -> Maybe(f64) {
	if math.is_inf(v) || math.is_nan(v) || v < -200 {
		return nil
	}
	return v
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
	warn_song_loads(&app.script)
	l, right := om.channels_from_interleaved(mix)
	lu := oanalyze.loudness_from_samples(l, right, om.MIX_RATE, context.temp_allocator)
	max_momentary := math.inf_f64(-1)
	for v in lu.momentary {
		max_momentary = max(max_momentary, f64(v))
	}
	// short-term values from 3 s on are whole 3 s blocks
	max_short_term := math.inf_f64(-1)
	for v in lu.short_term[min(29, len(lu.short_term)):] {
		max_short_term = max(max_short_term, f64(v))
	}
	offset := f64(start) / f64(fps)

	doc := Audio_Report_Doc {
		integrated_lufs     = level(lu.integrated),
		loudness_range_lu   = lu.range if len(lu.short_term) >= 30 else nil,
		max_momentary_lufs  = level(max_momentary),
		max_short_term_lufs = level(max_short_term),
		sample_peak_dbfs    = level(lu.sample_peak),
		true_peak_dbtp      = level(lu.true_peak),
		clipped_samples     = oanalyze.clipped_from_samples(l, right),
	}
	silences := oanalyze.silences_from_samples(l, right, om.MIX_RATE, -60, 0.5, context.temp_allocator)
	silent := make([][2]f64, len(silences), context.temp_allocator)
	for s, i in silences {
		silent[i] = {s[0] + offset, s[1] + offset}
	}
	doc.silent_ranges = silent
	from := om.frames_to_samples(start, fps)
	n := len(l)
	tables := analysis_tables(l, right, &app.background_work.work_pool)
	mix_whole := analysis_measures(&tables, 0, n)
	put_sound(&doc, mix_whole)
	band_hz := make([]f64, len(orender.BAND_HZ), context.temp_allocator)
	for hz, i in orender.BAND_HZ {
		band_hz[i] = f64(hz)
	}
	doc.band_hz = band_hz
	sections := make([dynamic]Audio_Section, context.temp_allocator)
	for s in r.timeline.scenes {
		if s.start_frame >= end || s.end_frame <= start {
			continue
		}
		a := clamp(om.frames_to_samples(s.start_frame, fps) - from, 0, n)
		b := clamp(om.frames_to_samples(s.end_frame, fps) - from, 0, n)
		sec := Audio_Section{name = s.scene.name, start_seconds = f64(a) / om.MIX_RATE + offset, end_seconds = f64(b) / om.MIX_RATE + offset}
		if b > a {
			part := oanalyze.loudness_from_samples(l[a:b], right[a:b], om.MIX_RATE, context.temp_allocator)
			sec.integrated_lufs = level(part.integrated)
			sec.true_peak_dbtp = level(part.true_peak)
			put_sound(&sec, analysis_measures(&tables, a, b))
		}
		append(&sections, sec)
	}
	doc.sections = sections[:]
	// Each bus alone: the effects against the music; and per scene, where
	// buses crowd each other.
	buses := make([dynamic]Audio_Bus, context.temp_allocator)
	bus_tables := make([dynamic]Analysis_Tables, context.temp_allocator)
	if regs.track == "" {
		bus_placed := slice.clone(placed[:], context.temp_allocator)
		for b in r.video.buses {
			count := solo(bus_placed, b.name)
			bm, _ := om.mix_tracks(bus_placed, om.frames_to_samples(start, fps), om.frames_to_samples(end, fps), r.video.mix, &app.background_work.work_pool, context.temp_allocator)
			bl, br_ch := om.channels_from_interleaved(bm)
			br := oanalyze.loudness_from_samples(bl, br_ch, om.MIX_RATE, context.temp_allocator)
			append(&bus_tables, analysis_tables(bl, br_ch, &app.background_work.work_pool))
			bus := Audio_Bus{name = b.name, tracks = count, integrated_lufs = level(br.integrated), true_peak_dbtp = level(br.true_peak)}
			put_sound(&bus, analysis_measures(&bus_tables[len(bus_tables) - 1], 0, len(bl)))
			append(&buses, bus)
		}
	}
	doc.buses = buses[:]
	masking := make([dynamic]orender.Masking_Row, context.temp_allocator)
	if len(bus_tables) >= 2 {
		for sec in sections {
			a := int((sec.start_seconds - offset) * om.MIX_RATE)
			z := int((sec.end_seconds - offset) * om.MIX_RATE)
			if z <= a {
				continue
			}
			stems := make([]orender.Measures, len(bus_tables), context.temp_allocator)
			for &bt, i in bus_tables {
				stems[i] = analysis_measures(&bt, a, z, buses[i].name)
			}
			append(&masking, ..orender.masking_from(analysis_measures(&tables, a, z), stems, sec.name, 3, context.temp_allocator))
		}
	}
	doc.masking = masking[:]
	curve := make([]Maybe(f64), len(lu.momentary), context.temp_allocator)
	for m, i in lu.momentary {
		if v, ok := level(f64(m)).?; ok {
			curve[i] = math.round(v * 10) / 10
		}
	}
	doc.loudness = {0.1, offset + 0.4, curve}

	res := Audio_Analyze_Result{report = doc, missing_files = missing_audio(app)}
	if regs.path != "" {
		if !write_waveform(app, r, regs.path, l, right, lu.momentary, &tables.bands, placed[:], start) {
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
	fmt.sbprintf(&b, "\ncrest %.1f dB, width %.1f dB, correlation %.2f", doc.crest_db, doc.width_db, doc.correlation)
	for m in doc.masking {
		fmt.sbprintf(&b, "\nmasking in %s: %s and %s at %.0f Hz (%.1f dB)", m.section, m.a, m.b, m.band_hz, m.overlap_db)
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
	l, right := om.channels_from_interleaved(mix)
	rep := oanalyze.onsets_from_samples(l, right, om.MIX_RATE, context.temp_allocator)
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
	file:         string        `json:"file"`,
	bus:          string        `json:"bus"`,
	file_seconds: f64           `json:"file_seconds"`,
	gain_db:      Maybe(f64)    `json:"gain_db"`,
	voice:        bool          `json:"voice"`,
	ducked_db:    Maybe(f64)    `json:"ducked_db"`,
	// A song: where in its form, and the notes sounding.
	song:         Maybe(Song_At) `json:"song"`,
}

Song_At :: struct {
	section:  string    `json:"section"`,
	bar:      int       `json:"bar"`,
	beat:     f64       `json:"beat"`,
	notes:    []Note_At `json:"notes"`,
}

Note_At :: struct {
	part:     string `json:"part"`,
	note:     string `json:"note"`,
	// Where it started on the video.
	start_seconds: f64 `json:"start_seconds"`,
	velocity: f64    `json:"velocity"`,
	held:     bool   `json:"held"`,
}

Audio_At_Result :: struct {
	spec:    string         `json:"spec"`,
	frame:   int            `json:"frame"`,
	seconds: f64            `json:"seconds"`,
	tracks:  []Active_Track `json:"tracks"`,
}

// What plays at each time: the file (or song: its section and the notes
// sounding), where in it, how loud (gain, fades and ducking) and how far
// it is ducked.
@(private)
audio_at :: proc(app: ^App_State, regs: Command_Regs) -> Error {
	build_audio(app) or_return
	r := renderer_scaled(app, 1) or_return
	fps := r.video.fps
	specs, frames := resolve_frames(app, &r.timeline, fps, regs.spec) or_return
	placed := placed_tracks(app, r, regs.track) or_return
	// The mix without its samples: how the voices duck the others.
	mx: om.Mix
	om.mix_init(&mx, placed[:], r.video.mix, samples = false)
	defer om.mix_destroy(&mx)
	results := make([]Audio_At_Result, len(frames), context.temp_allocator)
	for f, i in frames {
		s := int(math.round(f64(f) / f64(fps) * om.MIX_RATE))
		tracks := make([dynamic]Active_Track, context.temp_allocator)
		for p, pi in placed {
			if s < p.start || s >= p.end || p.muted {
				continue
			}
			tr := p.track
			k := s - p.start
			length := p.end - p.start
			cuts_in, cuts_out := om.track_cuts(p)
			env := om.track_envelope(k, length, om.seconds_to_samples(tr.fade_in), om.seconds_to_samples(tr.fade_out), tr.curve, cuts_in, cuts_out)
			duck: f32 = 1
			if tr.ducked {
				duck = om.mix_duck_gain(&mx, pi, s)
			}
			gain := tr.gain_db + 20 * math.log10(max(env * duck, 1e-12))
			at := Active_Track {
				file         = tr.src,
				bus          = tr.bus,
				file_seconds = f64(om.placed_file_sample(p, s)) / om.MIX_RATE,
				gain_db      = f64(gain) if env * duck > 0 else nil,
				voice        = tr.voice,
			}
			if tr.ducked {
				at.ducked_db = f64(20 * math.log10(max(duck, 1e-12)))
			}
			if p.song != nil {
				t := at.file_seconds
				sa: Song_At
				if place, inside := osong.place_from_seconds(&p.song.song, t); inside {
					sa.section, sa.bar, sa.beat = place.name, place.bar + 1, place.beat + 1
				}
				notes := make([dynamic]Note_At, context.temp_allocator)
				for n in osong.notes_at(&p.song.song, t) {
					if p.part != "" && n.part != p.part {
						continue
					}
					append(&notes, Note_At{fmt.tprintf("%s/%s", tr.src, n.part), n.note, f64(p.start - p.file_start) / om.MIX_RATE + n.time, f64(n.velocity), n.held})
				}
				sa.notes = notes[:]
				at.song = sa
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
			sa, is_song := t.song.?
			fmt.sbprintf(&b, "\n  %s%s at %.3fs of the %s, %s dB%s%s", t.file, bus, t.file_seconds, "song" if is_song else "file", gain, ", voice" if t.voice else "", ducked)
			if !is_song {
				continue
			}
			if sa.section != "" {
				fmt.sbprintf(&b, "\n    %s bar %d beat %.2f", sa.section, sa.bar, sa.beat)
			}
			for n in sa.notes {
				fmt.sbprintf(&b, "\n    %-16s %-6s from %.3fs  %s", n.part, n.note, n.start_seconds, "held" if n.held else "ringing")
			}
		}
	}
	emit(app, results, strings.to_string(b))
	return nil
}

// ---- waveform -------------------------------------------------------------------------

// Band rows (odawg's .Bands table) drawn as an image `width` x `height` at
// `top`: the row nearest each column, a band per row of pixels (filtered
// between bands), 20 Hz at the bottom, dB through a dark-to-bright ramp.
@(private = "file")
spectrogram :: proc(c: ^vg.Canvas, p: ^vg.Path, table: ^orender.Table, width: int, top, height: f32) {
	t := table
	if t.rows == 0 {
		return
	}
	bands := len(orender.BAND_HZ)
	pixels := make([]u8, 4 * width * bands, context.temp_allocator)
	for x in 0 ..< width {
		row := orender.table_row(t, min(x * t.rows / width, t.rows - 1))
		for b in 0 ..< bands {
			v := clamp((row[b] + 100) / 90, 0, 1) if row != nil else 0
			px := pixels[4 * ((bands - 1 - b) * width + x):][:4]
			px[0], px[1], px[2], px[3] = heat(v)
		}
	}
	id, err := vg.create_image(c, vg.image_source_rgba(pixels, u32(width), u32(bands)), {})
	if err != nil {
		return
	}
	vg.path_reset(p)
	vg.path_rect(p, 0, top, f32(width), height)
	vg.fill_path(c, p, vg.paint_image(id, 0, top, f32(width), height, 0))
}

// A dark-to-bright ramp (black, purple, red, orange, pale yellow) at `v` in
// 0..1: how a band level is drawn (the waveform PNG; the preview's bands are
// the same ramp in shaders/rect2d.slang).
@(private = "file")
heat :: proc(v: f32) -> (u8, u8, u8, u8) {
	STOPS :: [5][3]f32{{0, 0, 4}, {87, 16, 110}, {188, 55, 84}, {249, 142, 9}, {252, 255, 164}}
	stops := STOPS
	at := clamp(v, 0, 1) * 4
	i := min(int(at), 3)
	f := at - f32(i)
	a, b := stops[i], stops[i + 1]
	return u8(a[0] + (b[0] - a[0]) * f), u8(a[1] + (b[1] - a[1]) * f), u8(a[2] + (b[2] - a[2]) * f), 255
}

// fframes' waveform: min/max per column (blue), momentary loudness -60..0
// LUFS (pink), scene starts (purple), audio cues (yellow), a time axis and a
// legend; under it the spectrogram: odawg's third-octave band rows of the
// mix (render.BAND_HZ, a row per column), 20 Hz at the bottom.
@(private)
write_waveform :: proc(app: ^App_State, r: ^om.Renderer, path: string, l, right, momentary: []f32, bands: ^orender.Table, placed: []om.Placed_Track, start_frame: int) -> bool {
	W :: 1600
	TOP :: 28
	WAVE_H :: 300
	SPEC_TOP :: TOP + WAVE_H + 24
	BAND_H :: 6
	SPEC_H :: len(orender.BAND_HZ) * BAND_H
	H :: SPEC_TOP + SPEC_H + 76
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
	layout: vg.Text_Layout
	vg.text_layout_init(&layout)
	defer vg.text_layout_destroy(&layout)
	fonts := &app.media.fonts

	n := min(len(l), len(right))
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
			v := (l[i] + right[i]) * 0.5
			lo = min(lo, v)
			hi = max(hi, v)
		}
		scale := f32(WAVE_H) / 2
		vg.path_rect(&p, f32(x), mid - hi * scale, 1, max((hi - lo) * scale + 0.5, 1))
	}
	vg.fill_path(&c, &p, vg.paint_color(vg.rgb(56, 189, 248)))

	vg.path_reset(&p)
	for m, i in momentary {
		x := x_of((f64(i) + 4) * 0.1, duration)
		y := f32(TOP) + f32(WAVE_H) * (clamp(m, -60, 0) / -60)
		if i == 0 {
			vg.path_move_to(&p, x, y)
		} else {
			vg.path_line_to(&p, x, y)
		}
	}
	lp := vg.paint_color(vg.rgb(244, 114, 182))
	lp.stroke.line_width = 1.5
	vg.stroke_path(&c, &p, lp)

	spectrogram(&c, &p, bands, W, SPEC_TOP, SPEC_H)
	// the axis at BAND_HZ's 20 Hz, 100 Hz, 1 kHz and 10 kHz
	axis := [?]struct {
		text: string,
		band: int,
	}{{"20", 0}, {"100", 7}, {"1k", 17}, {"10k", 27}}
	for a in axis {
		fill_text(&c, fonts, &layout, &p, a.text, 4, f32(SPEC_TOP + SPEC_H - a.band * BAND_H - 2), 11, vg.rgb(212, 212, 216))
	}

	fps := f64(r.video.fps)
	offset := f64(start_frame) / fps
	for s in r.timeline.scenes {
		x := x_of(f64(s.start_frame) / fps - offset, duration)
		if x < 0 || x > W {
			continue
		}
		vg.path_reset(&p)
		vg.path_rect(&p, x, TOP, 1, WAVE_H)
		vg.path_rect(&p, x, SPEC_TOP, 1, SPEC_H)
		vg.fill_path(&c, &p, vg.paint_color(vg.rgb(167, 139, 250)))
		fill_text(&c, fonts, &layout, &p, s.scene.name, x + 3, TOP - 8, 13, vg.rgb(196, 181, 253))
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
	onsets := oanalyze.onsets_from_samples(l, right, om.MIX_RATE, context.temp_allocator)
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
			fill_text(&c, fonts, &layout, &p, fam, x + 3, TOP + 14, 12, vg.rgb(134, 239, 172))
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
		fill_text(&c, fonts, &layout, &p, fmt.tprintf("%.0fs", t + offset), x_of(t, duration) + 2, H - 12, 12, vg.rgb(161, 161, 170))
	}
	fill_text(&c, fonts, &layout, &p, "waveform (blue), momentary loudness -60..0 LUFS (pink), scenes (purple), track starts (yellow), onsets (white ticks), cues (green)", 8, H - 30, 12, vg.rgb(161, 161, 170))
	fill_text(&c, fonts, &layout, &p, "spectrogram: third-octave bands 20 Hz..20 kHz, -100 (dark) .. -10 dBFS (bright)", 8, H - 48, 12, vg.rgb(161, 161, 170))
	vg.flush(&c)
	ensure_parent(path)
	return write_png(path, sw.pixels, W, H)
}

// ---- pin -------------------------------------------------------------------------------

Audio_Pin_Result :: struct {
	pins:          []om.Source_Pins `json:"pins"`,
	missing_files: []string         `json:"missing_files"`,
}

// Fetches what the songs play from their sources and writes each source's
// pins (om.music_pin); the songs' findings (a refused path, a licence)
// are the load's. An error (a file that couldn't be fetched) fails the
// command, as odawg pin does: what was fetched is pinned either way.
@(private)
audio_pin :: proc(app: ^App_State, regs: Command_Regs) -> Error {
	build_audio(app) or_return
	pins := om.music_pin(app_media(app))
	res := Audio_Pin_Result{pins = pins, missing_files = missing_audio(app)}
	b := strings.builder_make(context.temp_allocator)
	if len(pins) == 0 {
		strings.write_string(&b, "no song names a source")
	}
	for p, i in pins {
		if p.error != "" {
			fmt.sbprintf(&b, "%serror: %s: %s", "\n" if i > 0 else "", p.source, p.error)
			app.exit_code = 1
			continue
		}
		fmt.sbprintf(&b, "%s%s: %d pinned (%d new) in %s, licence %s", "\n" if i > 0 else "", p.source, p.total, p.added, p.path, p.licence)
	}
	for d in load_diagnostics(&app.script, app_media(app)) {
		if d.severity == .Error {
			fmt.sbprintf(&b, "\nerror: %s", om.diagnostic_message(d, context.temp_allocator))
			app.exit_code = 1
		}
	}
	emit(app, res, strings.to_string(b))
	return nil
}
