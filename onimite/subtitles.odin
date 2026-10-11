package onimite

import "core:strings"

// WebVTT subtitles (fframes' `get_subtitles` / `get_subtitle_phrase`). Cues
// are stored as parallel arrays so a time lookup scans only start/stop.
Subtitles :: struct {
	starts:   [dynamic]u32, // milliseconds
	stops:    [dynamic]u32,
	ids:      [dynamic]string,
	texts:    [dynamic]string, // lines joined with "\n"
	settings: [dynamic]string, // the cue settings after the timing, raw
	// Owns the strings above: slices of one copy of the file, plus texts
	// rewritten without "\r" in `rewritten`.
	buffer:   strings.Builder,
	rewritten: [dynamic]string,
}

subtitles_destroy :: proc(s: ^Subtitles) {
	delete(s.starts)
	delete(s.stops)
	delete(s.ids)
	delete(s.texts)
	delete(s.settings)
	for t in s.rewritten {
		delete(t, s.rewritten.allocator)
	}
	delete(s.rewritten)
	strings.builder_destroy(&s.buffer)
	s^ = {}
}

// Parses WebVTT text. NOTE, STYLE and REGION blocks are skipped; cue text
// keeps its lines. `ok = false` when the header is missing.
parse_vtt :: proc(text: string, allocator := context.allocator) -> (s: Subtitles, ok: bool) {
	src := strings.trim_prefix(text, "\xEF\xBB\xBF")
	if !strings.has_prefix(src, "WEBVTT") {
		return {}, false
	}
	return parse_cue_blocks(src, true, allocator), true
}

// Parses SubRip (.srt) text: numbered blocks of `00:00:01,000 --> 00:00:02,500`
// and text lines (the number becomes the cue id). `ok = false` when no cue
// parses.
parse_srt :: proc(text: string, allocator := context.allocator) -> (s: Subtitles, ok: bool) {
	s = parse_cue_blocks(strings.trim_prefix(text, "\xEF\xBB\xBF"), false, allocator)
	if len(s.starts) == 0 {
		subtitles_destroy(&s)
		return {}, false
	}
	return s, true
}

// The cue blocks of a VTT (after its header block when `header`) or SRT file.
@(private = "file")
parse_cue_blocks :: proc(src: string, header: bool, allocator := context.allocator) -> (s: Subtitles) {
	s.starts = make([dynamic]u32, allocator)
	s.stops = make([dynamic]u32, allocator)
	s.ids = make([dynamic]string, allocator)
	s.texts = make([dynamic]string, allocator)
	s.settings = make([dynamic]string, allocator)
	s.rewritten = make([dynamic]string, allocator)
	// Strings are slices of one owned copy of the file.
	s.buffer = strings.builder_make(allocator)
	strings.write_string(&s.buffer, src)
	own := strings.to_string(s.buffer)

	lines := strings.split_lines(own, context.temp_allocator)
	i := 0
	if header {
		// The header line and its continuation lines run until the first
		// blank line.
		for i < len(lines) && strings.trim_space(lines[i]) != "" {
			i += 1
		}
	}
	for i < len(lines) {
		for i < len(lines) && strings.trim_space(lines[i]) == "" {
			i += 1
		}
		if i >= len(lines) {
			break
		}
		first := strings.trim_right(lines[i], "\r")
		if strings.has_prefix(first, "NOTE") || strings.has_prefix(first, "STYLE") || strings.has_prefix(first, "REGION") {
			for i < len(lines) && strings.trim_space(lines[i]) != "" {
				i += 1
			}
			continue
		}
		id := ""
		timing := first
		if !strings.contains(first, "-->") {
			id = first
			i += 1
			if i >= len(lines) {
				break
			}
			timing = strings.trim_right(lines[i], "\r")
		}
		arrow := strings.index(timing, "-->")
		if arrow < 0 {
			// Not a cue: skip the block.
			for i < len(lines) && strings.trim_space(lines[i]) != "" {
				i += 1
			}
			continue
		}
		start, ok1 := parse_vtt_time(strings.trim_space(timing[:arrow]))
		rest := strings.trim_left_space(timing[arrow + 3:])
		end_text := rest
		settings := ""
		if sp := strings.index_any(rest, " \t"); sp >= 0 {
			end_text = rest[:sp]
			settings = strings.trim_space(rest[sp:])
		}
		stop, ok2 := parse_vtt_time(end_text)
		i += 1
		text_start, text_end := -1, -1
		for i < len(lines) && strings.trim_space(lines[i]) != "" {
			line := strings.trim_right(lines[i], "\r")
			off := int(uintptr(raw_data(line)) - uintptr(raw_data(own)))
			if text_start < 0 {
				text_start = off
			}
			text_end = off + len(line)
			i += 1
		}
		if !ok1 || !ok2 {
			continue
		}
		cue_text := own[text_start:text_end] if text_start >= 0 else ""
		append(&s.starts, start)
		append(&s.stops, stop)
		append(&s.ids, id)
		if strings.contains_rune(cue_text, '\r') {
			plain, _ := strings.remove_all(cue_text, "\r", allocator)
			append(&s.rewritten, plain)
			cue_text = plain
		}
		append(&s.texts, cue_text)
		append(&s.settings, settings)
	}
	return s
}

// `hh:mm:ss.ttt` or `mm:ss.ttt` in milliseconds (`,` before the
// milliseconds too, as SRT writes them).
@(private)
parse_vtt_time :: proc(s: string) -> (ms: u32, ok: bool) {
	parts := strings.split(s, ":", context.temp_allocator)
	if len(parts) < 2 || len(parts) > 3 {
		return 0, false
	}
	num :: proc(s: string) -> (int, bool) {
		if len(s) == 0 {
			return 0, false
		}
		v := 0
		for c in s {
			if c < '0' || c > '9' {
				return 0, false
			}
			v = v * 10 + int(c - '0')
		}
		return v, true
	}
	h := 0
	if len(parts) == 3 {
		h = num(parts[0]) or_return
	}
	m := num(parts[len(parts) - 2]) or_return
	sec_ms := parts[len(parts) - 1]
	dot := strings.index_any(sec_ms, ".,")
	if dot < 0 {
		return 0, false
	}
	sec := num(sec_ms[:dot]) or_return
	frac := sec_ms[dot + 1:]
	millis := num(frac) or_return
	for _ in len(frac) ..< 3 {
		millis *= 10
	}
	return u32(h * 3_600_000 + m * 60_000 + sec * 1000 + millis), true
}

// The last cue showing at `ms` (fframes picks the latest starting one), or
// -1.
subtitle_cue_at :: proc(s: ^Subtitles, ms: u32) -> int {
	#reverse for start, i in s.starts {
		if ms >= start && ms <= s.stops[i] {
			return i
		}
	}
	return -1
}
