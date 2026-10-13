package onimite_app

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import om "../onimite"

// Sync points: everything a script tags with the same `id` (cues, scenes,
// audio tracks, animate keys) should happen at the same moment. The anchors
// are flat rows; `sync_check` sorts them by id and reports each group's
// rows that are off its reference (a cue, else a sound, else the first), a
// family (`beat[0]`, `beat[1]`, ...) off by one amount as one finding.

Anchor_Kind :: enum u8 {
	Cue,
	Scene,
	Track,
	Key,
}

Anchor :: struct {
	id:      string,
	seconds: f64,
	kind:    Anchor_Kind,
	// What it is, for messages: "cue (video.lua:3)", "scene Title",
	// "audio boom.wav", "animate key (video.lua:12)".
	label:   string,
	// A cue's `hit`: the track whose sound should start there.
	hit:     string,
}

// How far a sound may be from its picture, and the picture from a cue.
SYNC_AUDIO_TOLERANCE :: 0.03

// Every sync point of the loaded script on the video clock, by id. Animate
// keys are the ones the frames rendered so far reached.
sync_anchors :: proc(app: ^App_State, r: ^om.Renderer) -> (anchors: []Anchor, err: Error) {
	out := make([dynamic]Anchor, context.temp_allocator)
	// Tracks with ids and `hit` cues measure sound: build deferred clips.
	needs_sound := tracks_have_ids(r)
	for c in app.script.cues {
		needs_sound ||= c.hit != ""
	}
	if needs_sound {
		build_audio(app) or_return
	}
	fps := f64(r.video.fps)
	for c in app.script.cues {
		append(&out, Anchor{c.name, c.seconds, .Cue, fmt.tprintf("cue (%s)", c.at), c.hit})
	}
	for s in r.timeline.scenes {
		if s.scene.cue != "" {
			append(&out, Anchor{s.scene.cue, f64(s.start_frame) / fps, .Scene, fmt.tprintf("scene %s", s.scene.name), ""})
		}
	}
	placed := om.placed_audio(&r.ctx).tracks[:]
	for p in placed {
		if p.track.cue != "" {
			append(&out, Anchor{p.track.cue, track_sound_start(&app.media, p), .Track, fmt.tprintf("audio %s", p.track.src), ""})
		}
	}
	for k in app.script.key_anchors {
		append(&out, Anchor{k.id, k.seconds, .Key, fmt.tprintf("animate key (%s)", k.at), ""})
	}
	slice.stable_sort_by(out[:], proc(a, b: Anchor) -> bool {return a.id < b.id})
	return out[:], nil
}

// A placed track's onset on the video clock.
Onset_At :: struct {
	seconds, strength: f64,
}

// The onsets of placed track `p` as strong as `min_strength` or more, on
// the video clock, in time order (temp memory): those in the part of the
// file it plays, one up to 2 ms before that part at its start.
@(private)
placed_onsets :: proc(m: ^om.Media, p: om.Placed_Track, min_strength: f32) -> []Onset_At {
	rep, ok := om.media_onsets(m, p.track.src)
	if !ok {
		return nil
	}
	out := make([dynamic]Onset_At, context.temp_allocator)
	from := f64(p.file_start) / om.MIX_RATE
	start := f64(p.start) / om.MIX_RATE
	end := f64(p.end) / om.MIX_RATE
	for o in rep.onsets {
		if o.strength < min_strength || f64(o.time) < from - 0.002 {
			continue
		}
		if t := start + max(f64(o.time) - from, 0); t < end {
			append(&out, Onset_At{t, f64(o.strength)})
		}
	}
	return out[:]
}

// Where a placed track's first sound starts on the video clock: its first
// onset in the part of the file it plays (silence before a sound is where
// drift hides), else its start.
@(private)
track_sound_start :: proc(m: ^om.Media, p: om.Placed_Track) -> f64 {
	if onsets := placed_onsets(m, p, 0); len(onsets) > 0 {
		return onsets[0].seconds
	}
	return f64(p.start) / om.MIX_RATE
}

// The sync problems of `anchors` as diagnostics (frame: where the row that
// is off happens).
sync_check :: proc(app: ^App_State, r: ^om.Renderer, anchors: []Anchor) -> []om.Diagnostic {
	out := make([dynamic]om.Diagnostic, context.temp_allocator)
	fps := f64(r.video.fps)

	// One drift per row first; families are summarised below.
	Drift :: struct {
		family: string,
		a:      Anchor,
		ref:    Anchor,
		drift:  f64,
	}
	drifts := make([dynamic]Drift, context.temp_allocator)
	for i := 0; i < len(anchors); {
		j := i
		for j < len(anchors) && anchors[j].id == anchors[i].id {
			j += 1
		}
		group := anchors[i:j]
		i = j
		if len(group) == 1 {
			if group[0].kind != .Cue {
				append(&out, om.Diagnostic{severity = .Warning, code = .Cue_Alone, frame = om.frame_at(group[0].seconds, r.video.fps), name = group[0].id, a = group[0].label})
			}
		} else {
			ref := group[0]
			for a in group {
				if a.kind == .Cue {
					ref = a
					break
				}
				if a.kind == .Track && ref.kind != .Track {
					ref = a
				}
			}
			for a in group {
				if a.label == ref.label && a.seconds == ref.seconds {
					continue
				}
				audio := a.kind == .Track || ref.kind == .Track
				tolerance := SYNC_AUDIO_TOLERANCE if audio else 1 / fps
				if d := a.seconds - ref.seconds; abs(d) > tolerance + 1e-6 {
					append(&drifts, Drift{family_of(a.id), a, ref, d})
				}
			}
		}
		for c in group {
			if c.kind == .Cue && c.hit != "" {
				if d, problem := cue_hit(app, r, c); problem {
					append(&out, d)
				}
			}
		}
	}

	// A family (`beat[3]`, ...) with three or more rows of one kind off by
	// one amount is one finding.
	done := make([]bool, len(drifts), context.temp_allocator)
	for d, i in drifts {
		if done[i] {
			continue
		}
		same := make([dynamic]int, context.temp_allocator)
		if d.family != d.a.id {
			for e, k in drifts {
				if !done[k] && e.family == d.family && e.a.kind == d.a.kind && abs(e.drift - d.drift) < 1 / fps {
					append(&same, k)
				}
			}
		}
		if len(same) >= 3 {
			total := 0
			for a in anchors {
				if family_of(a.id) == d.family && a.kind == d.a.kind {
					total += 1
				}
			}
			for k in same {
				done[k] = true
			}
			append(&out, om.Diagnostic {
				severity = .Warning,
				code = .Cue_Drift,
				frame = om.frame_at(d.a.seconds, r.video.fps),
				name = fmt.tprintf("%s[*]", d.family),
				a = fmt.tprintf("%d of %d %ss", len(same), total, kind_name(d.a.kind)),
				b = fmt.tprintf("their %ss", kind_name(d.ref.kind)),
				w = f32(d.drift),
			})
			continue
		}
		done[i] = true
		append(&out, om.Diagnostic {
			severity = .Warning,
			code = .Cue_Drift,
			frame = om.frame_at(d.a.seconds, r.video.fps),
			name = d.a.id,
			a = fmt.tprintf("%s at %.3fs", d.a.label, d.a.seconds),
			b = fmt.tprintf("%s at %.3fs", d.ref.label, d.ref.seconds),
			w = f32(d.drift),
		})
	}
	return out[:]
}

@(private)
kind_name :: proc(k: Anchor_Kind) -> string {
	switch k {
	case .Cue:
		return "cue"
	case .Scene:
		return "scene"
	case .Track:
		return "sound"
	case .Key:
		return "animate key"
	}
	return ""
}

// "beat" for "beat[3]" (and "beat[*]"); the id itself otherwise.
@(private)
family_of :: proc(id: string) -> string {
	if strings.has_suffix(id, "]") {
		if open := strings.last_index_byte(id, '['); open > 0 {
			return id[:open]
		}
	}
	return id
}

// A cue's `hit`: some sound of that track (strength 0.1 or more) starts
// within SYNC_AUDIO_TOLERANCE of it.
@(private)
cue_hit :: proc(app: ^App_State, r: ^om.Renderer, c: Anchor) -> (d: om.Diagnostic, problem: bool) {
	placed := om.placed_audio(&r.ctx).tracks[:]
	nearest := math.INF_F64
	for p in placed {
		if p.track.src != c.hit {
			continue
		}
		for o in placed_onsets(&app.media, p, 0.1) {
			if abs(o.seconds - c.seconds) < abs(nearest - c.seconds) {
				nearest = o.seconds
			}
		}
	}
	if abs(nearest - c.seconds) <= SYNC_AUDIO_TOLERANCE {
		return {}, false
	}
	near := "none" if math.is_inf(nearest) else fmt.tprintf("%.3fs", nearest)
	return {
			severity = .Warning,
			code = .Cue_No_Hit,
			frame = om.frame_at(c.seconds, r.video.fps),
			name = c.id,
			a = near,
			b = c.hit,
			x = f32(c.seconds),
		},
		true
}

// The cues and sync ids a time spec can name (`om.parse_frame`), by
// their anchors: a cue's time, a scene's first frame, a track's first
// sound; animate keys are left out. None before the renderer is ready.
spec_names :: proc(app: ^App_State) -> (names: []om.Named_Time, err: Error) {
	r := &app.renderer
	if !app.renderer_ready || !app.script_loaded || (len(app.script.cues) == 0 && !has_ids(r)) {
		return nil, nil
	}
	out := make([dynamic]om.Named_Time, context.temp_allocator)
	for a in sync_anchors(app, r) or_return {
		if a.kind != .Key {
			append(&out, om.Named_Time{a.id, a.seconds})
		}
	}
	return out[:], nil
}

@(private)
has_ids :: proc(r: ^om.Renderer) -> bool {
	for s in r.video.scenes {
		if s.cue != "" {
			return true
		}
	}
	return tracks_have_ids(r)
}

@(private)
tracks_have_ids :: proc(r: ^om.Renderer) -> bool {
	for t in r.video.audio {
		if t.cue != "" {
			return true
		}
	}
	return false
}

// A sync point as `timeline` lists it: an id with what carries it, or a
// family of cues (`beat[0..23]`) with their times.
Timeline_Sync :: struct {
	id:      string   `json:"id"`,
	seconds: []f64    `json:"seconds"`,
	what:    []string `json:"what"`,
}

// The load-time sync points (cues, scenes, tracks) by id; families of three
// or more ids carried by cues alone are one entry.
timeline_sync :: proc(anchors: []Anchor, fps: int) -> []Timeline_Sync {
	out := make([dynamic]Timeline_Sync, context.temp_allocator)
	for i := 0; i < len(anchors); {
		j := i
		for j < len(anchors) && anchors[j].id == anchors[i].id {
			j += 1
		}
		group := anchors[i:j]
		i = j
		ref := group[0]
		for a in group {
			if a.kind == .Cue {
				ref = a
				break
			}
		}
		what := make([dynamic]string, context.temp_allocator)
		for a in group {
			if a.kind == .Key {
				continue
			}
			label := a.label
			if a.kind == .Cue {
				label = "cue"
			}
			// Within a frame is on time (frame rounding).
			if d := a.seconds - ref.seconds; abs(d) > 1 / f64(fps) {
				label = fmt.tprintf("%s %+.3fs", label, d)
			}
			append(&what, label)
		}
		if len(what) == 0 {
			continue
		}
		// Cue-only members of a family (`beat[3]`) join one entry.
		fam := family_of(ref.id)
		if fam != ref.id && len(group) == 1 && ref.kind == .Cue && len(out) > 0 {
			last := &out[len(out) - 1]
			cue_only := len(last.what) == 1 && (last.what[0] == "cue" || strings.has_suffix(last.what[0], " cues"))
			if cue_only && family_of(last.id) == fam {
				seconds := make([]f64, len(last.seconds) + 1, context.temp_allocator)
				copy(seconds, last.seconds)
				seconds[len(last.seconds)] = ref.seconds
				slice.sort(seconds)
				what := make([]string, 1, context.temp_allocator)
				what[0] = fmt.tprintf("%d cues", len(seconds))
				last^ = {fmt.tprintf("%s[*]", fam), seconds, what}
				continue
			}
		}
		seconds := make([]f64, 1, context.temp_allocator)
		seconds[0] = ref.seconds
		append(&out, Timeline_Sync{ref.id, seconds, what[:]})
	}
	return out[:]
}

// ---- sounds on the music's beat ------------------------------------------------------

// How far a hit may land from the music's half-beat grid (as cue_no_hit).
OFF_BEAT_TOLERANCE :: SYNC_AUDIO_TOLERANCE

// The music's beat measured around each hit of the other tracks: the music
// is the tracks on a `music` bus (Bus_Kind); its onsets within OFF_BEAT_WINDOW of
// a hit, the strong ones there (half the window's strongest or more), give
// the beat (their median spacing, a beat being OFF_BEAT_MIN_BEAT or longer)
// and its phase (the nearest one), so a tempo map's changes are followed.
// Where their spacing is not steady (a drone, a rubato intro) there is no
// beat to be off. A hit is a track's attack (where it starts when it starts
// loud, else its first strong onset within 50 ms of its start: a stutter's
// later grains are its own rhythm, and a sound that swells in, a riser, has
// no attack); hits of one instrument (the clip name before `_`) and placing
// line less than a quarter beat apart (not layered together) are a roll or
// typing, a texture, not checked; speech (a `voice` bus, `voice = true`)
// and `other` buses never are. One finding per placing line (a
// scene's sounds), naming its loudest off-beat hit (clip peak with gain).
off_beat_check :: proc(app: ^App_State, r: ^om.Renderer) -> []om.Diagnostic {
	OFF_BEAT_WINDOW :: 3.0
	OFF_BEAT_MIN_BEAT :: 0.25
	placed := om.placed_audio(&r.ctx).tracks[:]
	is_music :: proc(p: om.Placed_Track) -> bool {
		return p.kind == .Music
	}
	music := make([dynamic]Onset_At, context.temp_allocator)
	Hit :: struct {
		t:     f64,
		level: f32,
		track: ^om.Placed_Track,
	}
	sounds := make([dynamic]Hit, context.temp_allocator)
	for &p in placed {
		if is_music(p) {
			append(&music, ..placed_onsets(&app.media, p, 0))
			continue
		}
		// Speech is not on the beat; an `other` bus has no role.
		if p.muted || p.clip == nil || p.track.voice || p.kind == .Voice || p.kind == .Other {
			continue
		}
		peak: f32
		for v in p.clip.samples {
			peak = max(peak, abs(v))
		}
		// A sound that swells in (a riser into a cut) has no attack to place.
		SWELL :: 0.05
		start := f64(p.start) / om.MIX_RATE
		t := -1.0
		if starts_loud(p.clip.samples, p.file_start, peak) {
			t = start
		} else if strong := placed_onsets(&app.media, p, 0.5); len(strong) > 0 && strong[0].seconds - start <= SWELL {
			t = strong[0].seconds
		}
		if t >= 0 {
			append(&sounds, Hit{t, peak * math.pow(10, p.track.gain_db / 20), &p})
		}
	}
	if len(music) < 4 || len(sounds) == 0 {
		return nil
	}
	slice.sort_by(music[:], proc(a, b: Onset_At) -> bool {return a.seconds < b.seconds})
	slice.sort_by(sounds[:], proc(a, b: Hit) -> bool {return a.t < b.t})

	Row :: struct {
		d:     om.Diagnostic,
		count: int,
		level: f32,
	}
	rows := make([dynamic]Row, context.temp_allocator)
	strong := make([dynamic]f64, context.temp_allocator)
	gaps := make([dynamic]f64, context.temp_allocator)
	for h, i in sounds {
		t := h.t
		// The music around it: its strong onsets, their beat, the nearest one.
		clear(&strong)
		loudest := 0.0
		for m in music {
			if abs(m.seconds - t) <= OFF_BEAT_WINDOW {
				loudest = max(loudest, m.strength)
			}
		}
		for m in music {
			if abs(m.seconds - t) <= OFF_BEAT_WINDOW && m.strength >= loudest * 0.5 {
				append(&strong, m.seconds)
			}
		}
		if len(strong) < 4 {
			continue
		}
		clear(&gaps)
		nearest := strong[0]
		for m, k in strong {
			if k > 0 && m - strong[k - 1] >= OFF_BEAT_MIN_BEAT {
				append(&gaps, m - strong[k - 1])
			}
			if abs(m - t) < abs(nearest - t) {
				nearest = m
			}
		}
		if len(gaps) < 3 {
			continue
		}
		slice.sort(gaps[:])
		period := gaps[len(gaps) / 2]
		steady := 0
		for g in gaps {
			if abs(g - period) <= period * 0.1 {
				steady += 1
			}
		}
		if steady * 3 < len(gaps) * 2 {
			continue // no steady beat here
		}
		// A roll or typing: another hit of the same instrument and line
		// within a quarter beat (but not with it: sounds layered into one hit).
		LAYERED :: 0.01
		same :: proc(a, b: ^om.Placed_Track) -> bool {
			stem :: proc(name: string) -> string {
				i := strings.index_any(name, "_.")
				return name if i < 0 else name[:i]
			}
			return a.track.source == b.track.source && stem(a.track.src) == stem(b.track.src)
		}
		texture := false
		for k := i - 1; k >= 0 && t - sounds[k].t < period / 4; k -= 1 {
			texture ||= t - sounds[k].t > LAYERED && same(sounds[k].track, h.track)
		}
		for k := i + 1; k < len(sounds) && sounds[k].t - t < period / 4; k += 1 {
			texture ||= sounds[k].t - t > LAYERED && same(sounds[k].track, h.track)
		}
		if texture {
			continue
		}
		half := period / 2
		off := t - nearest
		off -= half * math.round(off / half)
		if abs(off) <= OFF_BEAT_TOLERANCE {
			continue
		}
		d := om.Diagnostic {
			severity = .Warning,
			code     = .Off_Beat,
			frame    = om.frame_at(t, r.video.fps),
			name     = h.track.track.source,
			a        = h.track.track.src,
			x        = f32(t),
			w        = f32(off),
			h        = f32(period),
		}
		found := false
		for &row in rows {
			if row.d.name == d.name {
				row.count += 1
				if h.level > row.level {
					row.d, row.level = d, h.level
				}
				found = true
				break
			}
		}
		if !found {
			append(&rows, Row{d, 1, h.level})
		}
	}
	out := make([]om.Diagnostic, len(rows), context.temp_allocator)
	for row, i in rows {
		out[i] = row.d
		out[i].n = i64(row.count)
	}
	return out
}

// Whether interleaved stereo `samples` played from frame `first` reach a
// third of the clip's `peak` within their first 10 ms.
@(private = "file")
starts_loud :: proc(samples: []f32, first: int, peak: f32) -> bool {
	head: f32
	lo := min(first * 2, len(samples))
	hi := min(lo + om.MIX_RATE / 100 * 2, len(samples))
	for v in samples[lo:hi] {
		head = max(head, abs(v))
	}
	return peak > 0 && head >= peak / 3
}
