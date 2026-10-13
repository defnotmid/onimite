package onimite

import "core:encoding/json"
import "core:hash"
import "core:math"
import "core:slice"
import "core:strings"

// Word-level captions (karaoke / TikTok style, after @remotion/captions):
// one row per word in parallel arrays, from Whisper / whisper.cpp JSON,
// Remotion's caption arrays, WebVTT with inline timestamps, or plain
// VTT / SRT cues (their words share the cue's time evenly). Pages group the
// words for display (`caption_pages`).
Captions :: struct {
	starts:    [dynamic]u32, // milliseconds
	stops:     [dynamic]u32,
	// Where each word's text ends in `text` (it starts where the previous
	// one ends).
	ends:      [dynamic]u32,
	// The source cue of each word: a VTT / SRT cue, a Whisper segment; 0
	// for a flat word list. Pages never span two cues.
	cues:      [dynamic]u32,
	text:      [dynamic]u8,
	// The source groups its words into cues (else pages default to
	// `combine_ms = 1200`).
	segmented: bool,
	// The words come from a subtitle file, whose cues as written are
	// `subtitles` (for `subtitle_at`); `cues` index them.
	from_subtitles: bool,
	subtitles: Subtitles,
	// Of the rows above: the same text twice compares equal.
	hash:      u64,
}

captions_destroy :: proc(c: ^Captions) {
	delete(c.starts)
	delete(c.stops)
	delete(c.ends)
	delete(c.cues)
	delete(c.text)
	subtitles_destroy(&c.subtitles)
	c^ = {}
}

@(private = "file")
captions_make :: proc(allocator := context.allocator) -> Captions {
	return {
		starts = make([dynamic]u32, allocator),
		stops = make([dynamic]u32, allocator),
		ends = make([dynamic]u32, allocator),
		cues = make([dynamic]u32, allocator),
		text = make([dynamic]u8, allocator),
	}
}

caption_count :: proc(c: ^Captions) -> int {
	return len(c.starts)
}

// The text of word `i`.
caption_word :: proc(c: ^Captions, i: int) -> string {
	lo := c.ends[i - 1] if i > 0 else 0
	return string(c.text[lo:c.ends[i]])
}

// Appends a word (trimmed; nothing when blank). `&amp;`, `&lt;`, `&gt;` and
// `&nbsp;` are decoded.
caption_add_word :: proc(c: ^Captions, word: string, start, stop: u32, cue: u32) {
	w := strings.trim_space(word)
	if w == "" {
		return
	}
	for len(w) > 0 {
		amp := strings.index_byte(w, '&')
		if amp < 0 {
			append(&c.text, w)
			break
		}
		append(&c.text, w[:amp])
		w = w[amp:]
		decoded := false
		for e in ([?][2]string{{"&amp;", "&"}, {"&lt;", "<"}, {"&gt;", ">"}, {"&nbsp;", " "}}) {
			if strings.has_prefix(w, e[0]) {
				append(&c.text, e[1])
				w = w[len(e[0]):]
				decoded = true
				break
			}
		}
		if !decoded {
			append(&c.text, '&')
			w = w[1:]
		}
	}
	append(&c.starts, start)
	append(&c.stops, max(stop, start))
	append(&c.ends, u32(len(c.text)))
	append(&c.cues, cue)
}

// Appends a cue's words. Tags (`<c>`, `<i>`, `<v Name>`) are dropped; an
// inline timestamp `<00:00:01.200>` starts the words after it then. Each
// span between known times (the cue's start, its timestamps, its stop) is
// shared evenly by its words, so a cue without timestamps spreads its words
// over the whole cue.
captions_add_cue :: proc(c: ^Captions, text: string, start, stop: u32, cue: u32) {
	spans := make([dynamic]string, context.temp_allocator)
	ats := make([dynamic]u32, context.temp_allocator)
	span := strings.builder_make(context.temp_allocator)
	at := start
	rest := text
	for len(rest) > 0 {
		lt := strings.index_byte(rest, '<')
		if lt < 0 {
			strings.write_string(&span, rest)
			break
		}
		strings.write_string(&span, rest[:lt])
		gt := strings.index_byte(rest[lt:], '>')
		if gt < 0 {
			break
		}
		tag := rest[lt + 1:lt + gt]
		rest = rest[lt + gt + 1:]
		if ms, ok := parse_vtt_time(tag); ok {
			append(&spans, strings.clone(strings.to_string(span), context.temp_allocator))
			append(&ats, at)
			strings.builder_reset(&span)
			at = clamp(ms, at, max(stop, at))
		}
	}
	append(&spans, strings.to_string(span))
	append(&ats, at)
	for s, k in spans {
		a := ats[k]
		b := ats[k + 1] if k + 1 < len(ats) else max(stop, a)
		words := strings.fields(s, context.temp_allocator)
		n := u32(len(words))
		for w, j in words {
			ju := u32(j)
			caption_add_word(c, w, a + (b - a) * ju / n, a + (b - a) * (ju + 1) / n, cue)
		}
	}
}

// A subtitle file's captions (taking `subs`): each cue's words, by
// `captions_add_cue`, with the cues.
captions_from_subtitles :: proc(subs: Subtitles, allocator := context.allocator) -> Captions {
	c := captions_make(allocator)
	c.segmented = true
	c.from_subtitles = true
	c.subtitles = subs
	for text, i in subs.texts {
		captions_add_cue(&c, text, subs.starts[i], subs.stops[i], u32(i))
	}
	captions_seal(&c)
	return c
}

// Parses caption text by its shape: JSON (`{` or `[`, see
// `captions_parse_json`), else subtitles (`parse_subtitles`). `ok = false`
// when it is neither.
captions_parse :: proc(text: string, allocator := context.allocator) -> (c: Captions, ok: bool) {
	src := strings.trim_left_space(strings.trim_prefix(text, "\xEF\xBB\xBF"))
	if strings.has_prefix(src, "{") || strings.has_prefix(src, "[") {
		return captions_parse_json(src, allocator)
	}
	subs := parse_subtitles(src, allocator) or_return
	return captions_from_subtitles(subs, allocator), true
}

// Parses word timings from JSON:
// - OpenAI Whisper (`verbose_json`): `{ "segments": [{ "start", "end",
//   "text", "words": [{ "word", "start", "end" }] }] }` (seconds; a segment
//   without words spreads its text) or a top-level `"words"` list;
// - whisper.cpp (`-oj` / `-ojf`): `{ "transcription": [{ "offsets": { "from",
//   "to" }, "text", "tokens": [{ "text", "offsets" }] }] }` (milliseconds;
//   tokens without a leading space continue the previous word, `[_...]`
//   tokens are skipped);
// - a list of words: `[{ "text", "start", "end" }]` in seconds, or Remotion's
//   `[{ "text", "startMs", "endMs" }]`.
// `ok = false` for other JSON (Lottie files, data).
captions_parse_json :: proc(text: string, allocator := context.allocator) -> (c: Captions, ok: bool) {
	v, err := json.parse_string(text, allocator = context.temp_allocator)
	if err != nil {
		return {}, false
	}
	c = captions_make(allocator)
	defer if !ok {
		captions_destroy(&c)
	}
	#partial switch x in v {
	case json.Array:
		ok = add_json_words(&c, x, 0)
	case json.Object:
		if segs, is := x["segments"].(json.Array); is {
			c.segmented = true
			for seg, i in segs {
				obj := seg.(json.Object) or_continue
				if words, has := obj["words"].(json.Array); has && len(words) > 0 {
					add_json_words(&c, words, u32(i))
				} else {
					cue_text, _ := obj["text"].(json.String)
					captions_add_cue(&c, cue_text, json_ms(obj, "start", 1000), json_ms(obj, "end", 1000), u32(i))
				}
			}
			ok = true
		} else if items, is_cpp := x["transcription"].(json.Array); is_cpp {
			c.segmented = true
			for item, i in items {
				obj := item.(json.Object) or_continue
				from, to := json_offsets(obj)
				tokens, has := obj["tokens"].(json.Array)
				if !has || len(tokens) == 0 {
					cue_text, _ := obj["text"].(json.String)
					captions_add_cue(&c, cue_text, from, to, u32(i))
					continue
				}
				first := caption_count(&c)
				for tok in tokens {
					t := tok.(json.Object) or_continue
					piece, _ := t["text"].(json.String)
					if piece == "" || strings.has_prefix(piece, "[_") {
						continue
					}
					a, b := json_offsets(t)
					n := caption_count(&c)
					if n > first && !strings.has_prefix(piece, " ") {
						// A piece of the previous word ("Hel" "lo", ",").
						append(&c.text, strings.trim_space(piece))
						c.ends[n - 1] = u32(len(c.text))
						c.stops[n - 1] = max(c.stops[n - 1], b)
					} else {
						caption_add_word(&c, piece, a, b, u32(i))
					}
				}
			}
			ok = true
		} else if words, is_flat := x["words"].(json.Array); is_flat {
			ok = add_json_words(&c, words, 0)
		}
	}
	if ok {
		captions_seal(&c)
	}
	return
}

// `[{ "word" | "text", "start", "end" }]` (seconds) or `"startMs"` /
// `"endMs"`: false unless every item is a word object.
@(private = "file")
add_json_words :: proc(c: ^Captions, items: json.Array, cue: u32) -> bool {
	for item in items {
		obj, is := item.(json.Object)
		if !is {
			return false
		}
		word, has_word := obj["word"].(json.String)
		if !has_word {
			word, has_word = obj["text"].(json.String)
		}
		if !has_word {
			return false
		}
		if "startMs" in obj {
			caption_add_word(c, word, json_ms(obj, "startMs", 1), json_ms(obj, "endMs", 1), cue)
		} else if "start" in obj {
			stop_key := "end" if "end" in obj else "stop"
			caption_add_word(c, word, json_ms(obj, "start", 1000), json_ms(obj, stop_key, 1000), cue)
		} else {
			return false
		}
	}
	return true
}

// Field `key` (a number of units) in milliseconds.
@(private = "file")
json_ms :: proc(obj: json.Object, key: string, ms_per_unit: f64) -> u32 {
	v: f64
	#partial switch n in obj[key] {
	case json.Float:
		v = n
	case json.Integer:
		v = f64(n)
	}
	return u32(max(math.round(v * ms_per_unit), 0))
}

// whisper.cpp's `"offsets": { "from", "to" }` (milliseconds).
@(private = "file")
json_offsets :: proc(obj: json.Object) -> (from, to: u32) {
	off, _ := obj["offsets"].(json.Object)
	return json_ms(off, "from", 1), json_ms(off, "to", 1)
}

// Computes `hash` once the rows are complete.
@(private = "file")
captions_seal :: proc(c: ^Captions) {
	h := hash.fnv64a(slice.to_bytes(c.starts[:]))
	h = hash.fnv64a(slice.to_bytes(c.stops[:]), h)
	h = hash.fnv64a(slice.to_bytes(c.ends[:]), h)
	h = hash.fnv64a(slice.to_bytes(c.cues[:]), h)
	h = hash.fnv64a(c.text[:], h ~ (1 if c.segmented else 0))
	// The cues as written: their ids and settings too.
	c.hash = hash.fnv64a(c.subtitles.buffer.buf[:], h)
}

// Captions from words a script lists (seconds), as one flat cue, or
// grouped into the cues `cues` gives each word (pages never span two).
captions_from_words :: proc(texts: []string, starts, stops: []f32, cues: []u32 = nil, allocator := context.allocator) -> Captions {
	c := captions_make(allocator)
	for w, i in texts {
		caption_add_word(&c, w, u32(max(math.round(starts[i] * 1000), 0)), u32(max(math.round(stops[i] * 1000), 0)), cues[i] if cues != nil else 0)
	}
	c.segmented = cues != nil
	captions_seal(&c)
	return c
}

// How words group into pages (Remotion's createTikTokStyleCaptions). A
// page ends with its source cue, and before a word that would break a
// limit. Zero is no limit; with no limit at all, a flat word list (no cues)
// pages by `combine_ms = 1200`.
Caption_Page_Options :: struct {
	max_words:    int,
	max_duration: u32, // ms from the page's first word start to a word's stop
	combine_ms:   u32, // a word joins while it starts within this of the page's start
}

// Appends the first word of each page to `firsts` (a page runs to the next
// one's first word).
caption_pages :: proc(c: ^Captions, opts: Caption_Page_Options, firsts: ^[dynamic]u32) {
	o := opts
	if !c.segmented && o == {} {
		o.combine_ms = 1200
	}
	first := 0
	for i in 0 ..< caption_count(c) {
		split :=
			i == 0 ||
			c.cues[i] != c.cues[first] ||
			(o.max_words > 0 && i - first >= o.max_words) ||
			(o.max_duration > 0 && c.stops[i] - min(c.starts[first], c.stops[i]) > o.max_duration) ||
			(o.combine_ms > 0 && c.starts[i] > c.starts[first] + o.combine_ms)
		if split {
			first = i
			append(firsts, u32(i))
		}
	}
}

// Words [first, last) of page `k`.
caption_page_words :: proc(c: ^Captions, firsts: []u32, k: int) -> (first, last: int) {
	first = int(firsts[k])
	last = int(firsts[k + 1]) if k + 1 < len(firsts) else caption_count(c)
	return
}

// The page showing at `ms`: the last one started by then, shown until its
// last word stops plus `hold` ms (never past the next page's start); -1 for
// none.
caption_page_at :: proc(c: ^Captions, firsts: []u32, ms, hold: u32) -> int {
	#reverse for f, k in firsts {
		if c.starts[f] > ms {
			continue
		}
		_, last := caption_page_words(c, firsts, k)
		return k if ms < c.stops[last - 1] + hold else -1
	}
	return -1
}

// The word of page words [first, last) to highlight at `ms`: the last one
// started (it stays through the pause after it), or -1 before the first.
caption_active_word :: proc(c: ^Captions, first, last: int, ms: u32) -> int {
	for i := last - 1; i >= first; i -= 1 {
		if c.starts[i] <= ms {
			return i
		}
	}
	return -1
}
