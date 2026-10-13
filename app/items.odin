package onimite_app

import "core:fmt"
import "core:slice"
import "core:strings"
import vg "deps:ovg"
import om "../onimite"
import script "../script"

// What the video's parts are called and what they say, for every view of
// them: `onimite show` (text and --json are two prints of one result),
// `inspect`'s findings, and the preview's timeline rows and Watch rows. A
// view never words an item itself.

// A placed track in one line: its file, span, scene, bus, level, pan,
// fades, where in the file it starts, voice and ducking, and its cue.
track_summary :: proc(p: om.Placed_Track) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s  %.3fs..%.3fs", p.track.src, f64(p.start) / om.MIX_RATE, f64(p.end) / om.MIX_RATE)
	if p.scene != "" {
		fmt.sbprintf(&b, "  scene %s", p.scene)
	}
	if p.track.bus != "" {
		fmt.sbprintf(&b, "  bus %s", p.track.bus)
	}
	if p.track.gain_db != 0 {
		fmt.sbprintf(&b, "  %+.1f dB", p.track.gain_db)
	}
	if p.track.pan != 0 {
		fmt.sbprintf(&b, "  pan %+.2f", p.track.pan)
	}
	if p.track.fade_in > 0 || p.track.fade_out > 0 {
		fmt.sbprintf(&b, "  fades %.2fs/%.2fs", p.track.fade_in, p.track.fade_out)
	}
	if p.track.offset > 0 {
		fmt.sbprintf(&b, "  from %.2fs of the file", p.track.offset)
	}
	if p.track.voice {
		strings.write_string(&b, "  voice")
	}
	if p.track.ducked {
		strings.write_string(&b, "  ducked")
	}
	if p.track.cue != "" {
		fmt.sbprintf(&b, "  cue %s", p.track.cue)
	}
	return strings.to_string(b)
}

// A scene in one line: its frames and seconds, its cue and script line.
scene_summary :: proc(s: om.Scene_Info, fps: f64) -> string {
	cue := fmt.tprintf("  cue %s", s.scene.cue) if s.scene.cue != "" else ""
	return fmt.tprintf("frames %d..%d (%.2fs..%.2fs)%s  %s", s.start_frame, s.end_frame, f64(s.start_frame) / fps, f64(s.end_frame) / fps, cue, s.scene.source)
}

// A cue in one line: its time, frame and script line.
cue_summary :: proc(c: script.Cue, fps: int) -> string {
	return fmt.tprintf("%.3fs (frame %d)  %s", c.seconds, om.frame_at(c.seconds, fps), c.at)
}

// When a finding was seen, in which scenes ("Warning 1.20s..1.40s (frames
// 36..42, seen in 4) [Title]"), or "Error at load".
finding_when :: proc(f: Finding) -> string {
	title := fmt.tprintf("%c%s", f.severity[0] - 32, f.severity[1:]) if f.severity != "" else ""
	if f.frames == 0 {
		return fmt.tprintf("%s at load", title)
	}
	return fmt.tprintf("%s %.2fs..%.2fs (frames %d..%d, seen in %d)%s", title, f.first_seconds, f.last_seconds, f.first_frame, f.last_frame, f.frames, scenes_label(f.scenes))
}

// A finding in one line: when, the script line and the message.
finding_summary :: proc(f: Finding) -> string {
	source := fmt.tprintf("%s: ", f.source) if f.source != "" && f.frames > 0 else ""
	return fmt.tprintf("%s: %s%s", finding_when(f), source, f.message)
}

// A bus in one line ("" is the tracks on no bus).
bus_summary :: proc(name: string, tracks: int, gain_db: f32) -> string {
	if name == "" {
		return fmt.tprintf("tracks  %d sounds on no bus", tracks)
	}
	if gain_db != 0 {
		return fmt.tprintf("bus %s  %d sounds  %+.1f dB", name, tracks, gain_db)
	}
	return fmt.tprintf("bus %s  %d sounds", name, tracks)
}

// A media file (or font face) as listings show it.
Media_Item :: struct {
	kind:   om.Media_Kind,
	// The file name; a font face's family.
	name:   string,
	// What it is, after its kind's label: "64x64", "12 cues, 80 words,
	// 0.500s..9.000s".
	detail: string,
	// The file could not be read.
	failed: bool,
}

// Every media item, by kind (`Media_Kind` order) then name, in temp
// memory. A video's sound is part of its video's row.
media_items :: proc(m: ^om.Media) -> []Media_Item {
	items := make([dynamic]Media_Item, context.temp_allocator)
	for name, img in m.images {
		append(&items, Media_Item{kind = .Image, name = name, detail = fmt.tprintf("%dx%d", img.width, img.height) if img.width > 0 else "unreadable", failed = img.width <= 0})
	}
	v := &m.videos
	for name, i in v.names {
		info := v.infos[i]
		detail := fmt.tprintf("%dx%d, %.3fs", info.width, info.height, info.duration)
		if v.handles[i] < 0 {
			detail = fmt.tprintf("unreadable: %s", om.video_failure_message(v.failures[i], context.temp_allocator))
		}
		append(&items, Media_Item{kind = .Video, name = name, detail = detail, failed = v.handles[i] < 0})
	}
	for name, clip in m.audio {
		if name not_in v.by_name {
			channels := "mono" if clip.source_channels == 1 else "stereo"
			append(&items, Media_Item{kind = .Audio, name = name, detail = fmt.tprintf("%.3fs, %d Hz, %s", om.audio_clip_seconds(clip), clip.source_rate, channels)})
		}
	}
	for face in om.media_font_faces(m) {
		append(&items, Media_Item{kind = .Font, name = face.family, detail = fmt.tprintf("%s %d%s", weight_name(face.weight), face.weight, " italic" if face.italic else "")})
	}
	for name, a in m.svgs {
		append(&items, Media_Item{kind = .Svg, name = name, detail = fmt.tprintf("%.0fx%.0f", a.doc.width, a.doc.height)})
	}
	for name, doc in m.lotties {
		append(&items, Media_Item{kind = .Lottie, name = name, detail = fmt.tprintf("%.0fx%.0f, %.3fs at %.0f fps", doc.width, doc.height, lottie_seconds(doc), doc.fps)})
	}
	for name, src in m.shaders {
		append(&items, Media_Item{kind = .Shader, name = name, detail = fmt.tprintf("%d lines", strings.count(src, "\n") + 1)})
	}
	for name, &c in m.captions {
		n := om.caption_count(&c)
		span := fmt.tprintf("%.3fs..%.3fs", f64(c.starts[0]) / 1000, f64(c.stops[n - 1]) / 1000) if n > 0 else "no words"
		if c.from_subtitles {
			append(&items, Media_Item{kind = .Subtitles, name = name, detail = fmt.tprintf("%d cues, %d words, %s", len(c.subtitles.starts), n, span)})
		} else {
			append(&items, Media_Item{kind = .Captions, name = name, detail = fmt.tprintf("%d words, %s", n, span)})
		}
	}
	slice.stable_sort_by(items[:], proc(a, b: Media_Item) -> bool {
		return a.kind < b.kind || a.kind == b.kind && a.name < b.name
	})
	return items[:]
}

// A media item in one line: its kind and what it is ("image 64x64").
media_item_summary :: proc(it: Media_Item) -> string {
	return fmt.tprintf("%s %s", om.MEDIA_KINDS[it.kind].label, it.detail)
}

// The first frame a placed track plays media `name` at (-1: none does).
media_first_frame :: proc(placed: []om.Placed_Track, name: string, fps: int) -> int {
	first := -1
	for p in placed {
		if p.track.src == name {
			f := int(i64(p.start) * i64(fps) / om.MIX_RATE)
			first = f if first < 0 else min(first, f)
		}
	}
	return first
}

// ---- the preview's Watch rows ----------------------------------------------------------

// A scene: its name; the problems seen in it, its length and what `show`
// says of it.
scene_watch :: proc(s: om.Scene_Info, fps: int, problems: int) -> (label, detail: string) {
	detail = fmt.tprintf("%.2fs long  %s", f64(s.end_frame - s.start_frame) / f64(fps), scene_summary(s, f64(fps)))
	if problems > 0 {
		detail = fmt.tprintf("%d problem%s  %s", problems, "" if problems == 1 else "s", detail)
	}
	return s.scene.name, detail
}

// A cue: its name; its sync finding (`finding`, "" for none) and what
// `show` says of it.
cue_watch :: proc(c: script.Cue, fps: int, finding: string) -> (label, detail: string) {
	detail = cue_summary(c, fps)
	if c.hit != "" {
		detail = fmt.tprintf("%s  hit %s", detail, c.hit)
	}
	if finding != "" {
		detail = fmt.tprintf("%s  %s", finding, detail)
	}
	return c.name, detail
}

// A finding: its message; when it was seen and the script line.
finding_watch :: proc(f: Finding) -> (label, detail: string) {
	detail = finding_when(f)
	if f.source != "" {
		detail = fmt.tprintf("%s  %s", detail, f.source)
	}
	return f.message, detail
}

// A media item: its name; what it is and where it is first used. Only
// sounds have a known use (the placed tracks); `first` is -1 for none.
media_watch :: proc(it: Media_Item, first: int, fps: int) -> (label, detail: string) {
	detail = media_item_summary(it)
	switch {
	case it.failed:
	case first >= 0:
		detail = fmt.tprintf("%s  first at %.3fs (frame %d)", detail, f64(first) / f64(max(fps, 1)), first)
	case it.kind == .Audio:
		detail = fmt.tprintf("%s  unused: no track plays it", detail)
	}
	return it.name, detail
}

// A Lottie animation's length.
lottie_seconds :: proc(doc: ^vg.Lottie_Document) -> f64 {
	return f64(doc.out_frame - doc.in_frame) / f64(max(doc.fps, 1))
}

// The common name of a font weight.
@(private = "file")
weight_name :: proc(weight: int) -> string {
	switch {
	case weight <= 150:
		return "Thin"
	case weight <= 250:
		return "Extra Light"
	case weight <= 350:
		return "Light"
	case weight <= 450:
		return "Regular"
	case weight <= 550:
		return "Medium"
	case weight <= 650:
		return "Semi Bold"
	case weight <= 750:
		return "Bold"
	case weight <= 850:
		return "Extra Bold"
	}
	return "Black"
}
