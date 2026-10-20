package onimite_app

import "core:fmt"
import "core:strings"
import om "../onimite"
import script "../script"
import obase "deps:odawg/base"
import ocheck "deps:odawg/check"
import orender "deps:odawg/render"
import odevice "deps:odawg/device"
import otheory "deps:odawg/theory"
import osong "deps:odawg/song"

// Songs as the commands list them (`timeline`, `show song/NAME`): their
// form and tracks on the video clock, from odawg's composed tables.

Timeline_Song_Section :: struct {
	name:          string  `json:"name"`,
	start_seconds: f64     `json:"start_seconds"`,
	end_seconds:   f64     `json:"end_seconds"`,
	bars:          int     `json:"bars"`,
	beats_per_bar: int     `json:"beats_per_bar"`,
	bpm:           [2]f64  `json:"bpm"`,
	style:         string  `json:"style"`,
	energy:        f64     `json:"energy"`,
	chords:        string  `json:"chords"`,
}

Timeline_Song_Track :: struct {
	part:       string `json:"part"`,
	variant:    string `json:"variant"`,
	instrument: string `json:"instrument"`,
	notes:      int    `json:"notes"`,
	gain_db:    f64    `json:"gain_db"`,
}

Timeline_Song :: struct {
	name:          string                  `json:"name"`,
	key:           string                  `json:"key"`,
	start_seconds: f64                     `json:"start_seconds"`,
	end_seconds:   f64                     `json:"end_seconds"`,
	source:        string                  `json:"source"`,
	sections:      []Timeline_Song_Section `json:"sections"`,
	markers:       []Timeline_Song_Marker  `json:"markers"`,
	tracks:        []Timeline_Song_Track   `json:"tracks"`,
}

Timeline_Song_Marker :: struct {
	name:    string `json:"name"`,
	seconds: f64    `json:"seconds"`,
}

// The songs the script made (not its sounds), on the video clock.
@(private)
timeline_songs :: proc(s: ^script.Script) -> []Timeline_Song {
	out := make([dynamic]Timeline_Song, context.temp_allocator)
	for x in s.songs {
		if !x.sound {
			append(&out, timeline_song(x.clip, x.at))
		}
	}
	return out[:]
}

@(private)
timeline_song :: proc(sc: ^om.Song_Clip, at: string) -> Timeline_Song {
	g := &sc.song
	t := Timeline_Song{name = sc.name, key = sc.spec.key, start_seconds = g.start, end_seconds = g.start + g.duration, source = at}
	sections := make([]Timeline_Song_Section, len(g.sections), context.temp_allocator)
	for sec, i in g.sections {
		b := strings.builder_make(context.temp_allocator)
		for c, k in g.chords[sec.chords.first:obase.span_end(sec.chords)] {
			fmt.sbprintf(&b, "%s%s", k > 0 ? " " : "", otheory.string_from_chord(c))
		}
		sections[i] = {sec.name, g.start + sec.start, g.start + sec.stop, sec.bars, sec.beats_per_bar, {sec.bpm0, sec.bpm1}, osong.style_name(g, sec.style), sec.energy, strings.to_string(b)}
	}
	markers := make([]Timeline_Song_Marker, len(g.markers), context.temp_allocator)
	for mk, i in g.markers {
		markers[i] = {mk.name, g.start + mk.seconds}
	}
	tracks := make([]Timeline_Song_Track, len(g.tracks), context.temp_allocator)
	for tr, i in g.tracks {
		tracks[i] = {fmt.tprintf("%s/%s", sc.name, g.parts[tr.part]), osong.style_name(g, tr.style), g.labels[tr.instrument], osong.track_note_count(g, i), tr.gain_db}
	}
	t.sections, t.markers, t.tracks = sections, markers, tracks
	return t
}

// A song as text: a line, then its sections, markers and tracks.
@(private)
write_song :: proc(b: ^strings.Builder, t: Timeline_Song) {
	fmt.sbprintf(b, "song  %-28s %18s %s  %s\n", t.name, fmt.tprintf("%.3fs..%.3fs", t.start_seconds, t.end_seconds), t.key, t.source)
	for s in t.sections {
		bpm := fmt.tprintf("%.1f", s.bpm[0]) if s.bpm[0] == s.bpm[1] else fmt.tprintf("%.1f->%.1f", s.bpm[0], s.bpm[1])
		fmt.sbprintf(b, "  section %-12s %18s %-13s %-12s bpm  %-9s energy %.2f  %s\n", s.name, fmt.tprintf("%.3fs..%.3fs", s.start_seconds, s.end_seconds), fmt.tprintf("%d bars of %d", s.bars, s.beats_per_bar), bpm, s.style, s.energy, s.chords)
	}
	for m in t.markers {
		fmt.sbprintf(b, "  marker  %-12s %.3fs\n", m.name, m.seconds)
	}
	for tr in t.tracks {
		fmt.sbprintf(b, "  track   %-20s %-10s %-14s %-11s %+.1f dB\n", tr.part, tr.variant, tr.instrument, fmt.tprintf("%d notes", tr.notes), tr.gain_db)
	}
}

// What odawg's checks find in each song the script made, rendered alone
// (silent parts, clipping, its peak and loudness), as findings at the line
// that made it; the render isn't kept. Info rows (its loudness) only with
// `info`.
@(private)
song_check_diagnostics :: proc(s: ^script.Script, info: bool) -> []om.Diagnostic {
	out := make([dynamic]om.Diagnostic, context.temp_allocator)
	for x in s.songs {
		if x.sound {
			continue
		}
		findings := make(obase.Findings, context.temp_allocator)
		// its sample sets first: a Sampler not loaded is silent
		om.song_clip_load(x.clip)
		render := orender.output_from_song(&x.clip.song, {}, context.temp_allocator)
		ocheck.findings_from_render(&x.clip.song, &render, &findings)
		for f in findings {
			severity := om.Severity.Warning
			switch f.severity {
			case .Info:
				if !info {
					continue
				}
				severity = .Info
			case .Warning:
			case .Error:
				severity = .Error
			}
			append(&out, om.Diagnostic{severity = severity, code = .Song_Finding, name = x.at, a = x.name, b = fmt.tprintf("%s (%s, the song alone)", f.message, f.code)})
		}
	}
	return out[:]
}
