package onimite_app

import "core:fmt"
import "core:slice"
import "core:strings"
import vg "deps:ovg"
import om "../onimite"

// What the video's parts are called and what they say, for every view of
// them: `onimite show` (text and --json are two prints of one result) and
// the preview's timeline rows and media panel. A view never words an item
// itself.

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
}

// Every media item, by kind (`Media_Kind` order) then name, in temp
// memory. A video's sound is part of its video's row.
media_items :: proc(m: ^om.Media) -> []Media_Item {
	items := make([dynamic]Media_Item, context.temp_allocator)
	for name, img in m.images {
		append(&items, Media_Item{.Image, name, fmt.tprintf("%dx%d", img.width, img.height) if img.width > 0 else "unreadable"})
	}
	v := &m.videos
	for name, i in v.names {
		info := v.infos[i]
		detail := fmt.tprintf("%dx%d, %.3fs", info.width, info.height, info.duration)
		if v.handles[i] < 0 {
			detail = fmt.tprintf("unreadable: %s", om.video_failure_message(v.failures[i], context.temp_allocator))
		}
		append(&items, Media_Item{.Video, name, detail})
	}
	for name, clip in m.audio {
		if name not_in v.by_name {
			channels := "mono" if clip.source_channels == 1 else "stereo"
			append(&items, Media_Item{.Audio, name, fmt.tprintf("%.3fs, %d Hz, %s", om.audio_clip_seconds(clip), clip.source_rate, channels)})
		}
	}
	for face in m.fonts.faces {
		append(&items, Media_Item{.Font, face.family, fmt.tprintf("%s %d%s", weight_name(face.weight), face.weight, " italic" if face.italic else "")})
	}
	for name, a in m.svgs {
		append(&items, Media_Item{.Svg, name, fmt.tprintf("%.0fx%.0f", a.doc.width, a.doc.height)})
	}
	for name, doc in m.lotties {
		append(&items, Media_Item{.Lottie, name, fmt.tprintf("%.0fx%.0f, %.3fs at %.0f fps", doc.width, doc.height, lottie_seconds(doc), doc.fps)})
	}
	for name, src in m.shaders {
		append(&items, Media_Item{.Shader, name, fmt.tprintf("%d lines", strings.count(src, "\n") + 1)})
	}
	for name, &c in m.captions {
		n := om.caption_count(&c)
		span := fmt.tprintf("%.3fs..%.3fs", f64(c.starts[0]) / 1000, f64(c.stops[n - 1]) / 1000) if n > 0 else "no words"
		if c.from_subtitles {
			append(&items, Media_Item{.Subtitles, name, fmt.tprintf("%d cues, %d words, %s", len(c.subtitles.starts), n, span)})
		} else {
			append(&items, Media_Item{.Captions, name, fmt.tprintf("%d words, %s", n, span)})
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
