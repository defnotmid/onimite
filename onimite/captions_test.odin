package onimite

import "core:testing"

@(private = "file")
expect_words :: proc(t: ^testing.T, c: ^Captions, want: []string, loc := #caller_location) {
	if !testing.expect_value(t, caption_count(c), len(want), loc) {
		return
	}
	for w, i in want {
		testing.expect_value(t, caption_word(c, i), w, loc)
	}
}

@(test)
test_captions_whisper_json :: proc(t: ^testing.T) {
	src := `{"text": " Hello world. Again", "segments": [
		{"start": 0.0, "end": 1.0, "text": " Hello world.", "words": [
			{"word": " Hello", "start": 0.0, "end": 0.42},
			{"word": " world.", "start": 0.5, "end": 0.98}]},
		{"start": 2.0, "end": 3.0, "text": " Again &amp; again"}]}`
	c, ok := captions_parse(src)
	defer captions_destroy(&c)
	testing.expect(t, ok)
	testing.expect(t, c.segmented)
	expect_words(t, &c, {"Hello", "world.", "Again", "&", "again"})
	testing.expect_value(t, c.starts[1], 500)
	testing.expect_value(t, c.stops[1], 980)
	// A segment without words spreads its text: 3 words over 1 s.
	testing.expect_value(t, c.starts[3], 2333)
	testing.expect_value(t, c.stops[4], 3000)
	testing.expect_value(t, c.cues[4], 1)

	// Remotion's caption list (milliseconds) and the plain one (seconds).
	r, rok := captions_parse(`[{"text": " One", "startMs": 0, "endMs": 300, "timestampMs": 150, "confidence": 1},
		{"text": " two", "startMs": 300, "endMs": 650}]`)
	defer captions_destroy(&r)
	testing.expect(t, rok && !r.segmented)
	expect_words(t, &r, {"One", "two"})
	testing.expect_value(t, r.stops[1], 650)
	p, pok := captions_parse(`[{"text": "Hi", "start": 1.5, "end": 1.75}]`)
	defer captions_destroy(&p)
	testing.expect(t, pok)
	testing.expect_value(t, p.starts[0], 1500)
	testing.expect_value(t, p.stops[0], 1750)

	// Other JSON is not captions.
	_, lottie := captions_parse(`{"v": "5.7.0", "layers": []}`)
	testing.expect(t, !lottie)
	_, data := captions_parse(`[1, 2, 3]`)
	testing.expect(t, !data)
}

@(test)
test_captions_whisper_cpp_json :: proc(t: ^testing.T) {
	src := `{"transcription": [{"offsets": {"from": 0, "to": 1500}, "text": " Hello, world", "tokens": [
		{"text": "[_BEG_]", "offsets": {"from": 0, "to": 0}},
		{"text": " Hel", "offsets": {"from": 0, "to": 200}},
		{"text": "lo", "offsets": {"from": 200, "to": 400}},
		{"text": ",", "offsets": {"from": 400, "to": 450}},
		{"text": " world", "offsets": {"from": 500, "to": 1500}},
		{"text": "[_TT_75]", "offsets": {"from": 1500, "to": 1500}}]},
		{"offsets": {"from": 2000, "to": 3000}, "text": " no tokens"}]}`
	c, ok := captions_parse(src)
	defer captions_destroy(&c)
	testing.expect(t, ok)
	expect_words(t, &c, {"Hello,", "world", "no", "tokens"})
	testing.expect_value(t, c.starts[0], 0)
	testing.expect_value(t, c.stops[0], 450)
	testing.expect_value(t, c.starts[3], 2500)
	testing.expect_value(t, c.cues[3], 1)
}

@(test)
test_captions_vtt_inline_timestamps :: proc(t: ^testing.T) {
	src := "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\n<v Ann>Never <00:00:01.400><c>drink</c> <00:00:02.000>liquid nitrogen\n"
	c, ok := captions_parse(src)
	defer captions_destroy(&c)
	testing.expect(t, ok)
	expect_words(t, &c, {"Never", "drink", "liquid", "nitrogen"})
	testing.expect_value(t, c.starts[0], 1000)
	testing.expect_value(t, c.stops[0], 1400)
	testing.expect_value(t, c.starts[1], 1400)
	testing.expect_value(t, c.stops[1], 2000)
	// Two words share the span from the last timestamp to the cue's end.
	testing.expect_value(t, c.starts[2], 2000)
	testing.expect_value(t, c.starts[3], 2500)
	testing.expect_value(t, c.stops[3], 3000)
}

@(test)
test_captions_srt_even_split :: proc(t: ^testing.T) {
	src := "1\r\n00:00:00,000 --> 00:00:02,000\r\nfour <i>words</i> in\r\nthis\r\n\r\n2\r\n00:00:03,000 --> 00:00:03,900\r\nlast  three words\r\n"
	subs, sok := parse_srt(src)
	defer subtitles_destroy(&subs)
	testing.expect(t, sok)
	testing.expect_value(t, len(subs.starts), 2)
	testing.expect_value(t, subs.ids[1], "2")
	testing.expect_value(t, subs.stops[1], 3900)
	c, ok := captions_parse(src)
	defer captions_destroy(&c)
	testing.expect(t, ok)
	expect_words(t, &c, {"four", "words", "in", "this", "last", "three", "words"})
	for i in 0 ..< 4 {
		testing.expect_value(t, c.starts[i], u32(i * 500))
		testing.expect_value(t, c.stops[i], u32(i * 500 + 500))
	}
	testing.expect_value(t, c.starts[5], 3300)
	testing.expect_value(t, c.stops[6], 3900)
	_, none := parse_srt("not subtitles")
	testing.expect(t, !none)
}

@(test)
test_caption_pages :: proc(t: ^testing.T) {
	texts := []string{"a", "b", "c", "d", "e", "f", "g"}
	starts := []f32{0, 0.3, 0.6, 0.9, 1.4, 1.7, 4.0}
	stops := []f32{0.3, 0.6, 0.9, 1.2, 1.7, 2.0, 4.5}
	c := captions_from_words(texts, starts, stops)
	defer captions_destroy(&c)
	firsts := make([dynamic]u32)
	defer delete(firsts)

	// No limits on a flat list: combine_ms = 1200 (a word starting more than
	// 1.2 s after the page's start begins a new page).
	caption_pages(&c, {}, &firsts)
	testing.expect_value(t, len(firsts), 3)
	testing.expect_value(t, firsts[1], 4)
	testing.expect_value(t, firsts[2], 6)

	clear(&firsts)
	caption_pages(&c, {max_words = 3}, &firsts)
	testing.expect_value(t, len(firsts), 3)
	testing.expect_value(t, firsts[1], 3)
	testing.expect_value(t, firsts[2], 6)

	clear(&firsts)
	caption_pages(&c, {max_duration = 1000}, &firsts)
	// a..c end by 0.9 s; d stops at 1.2 s, 1.2 s after a's start.
	testing.expect_value(t, firsts[1], 3)

	// Lookups: the page shows until its last word stops (+ hold), and the
	// active word is the last one started.
	clear(&firsts)
	caption_pages(&c, {max_words = 3}, &firsts)
	testing.expect_value(t, caption_page_at(&c, firsts[:], 100, 0), 0)
	testing.expect_value(t, caption_page_at(&c, firsts[:], 2100, 0), -1)
	testing.expect_value(t, caption_page_at(&c, firsts[:], 2100, 500), 1)
	testing.expect_value(t, caption_page_at(&c, firsts[:], 4000, 5000), 2)
	first, last := caption_page_words(&c, firsts[:], 1)
	testing.expect_value(t, first, 3)
	testing.expect_value(t, last, 6)
	testing.expect_value(t, caption_active_word(&c, first, last, 1300), 3) // the pause after d
	testing.expect_value(t, caption_active_word(&c, first, last, 1500), 4)

	// Pages keep to their source cues.
	vtt, _ := captions_parse("WEBVTT\n\n00:00.000 --> 00:01.000\none two\n\n00:01.000 --> 00:02.000\nthree\n")
	defer captions_destroy(&vtt)
	clear(&firsts)
	caption_pages(&vtt, {}, &firsts)
	testing.expect_value(t, len(firsts), 2)
	testing.expect_value(t, firsts[1], 2)
}
