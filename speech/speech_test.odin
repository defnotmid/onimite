package onimite_speech

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"
import "deps:ottis/assets"
import common "deps:odecs/common"

// The key changes with everything a line's samples depend on and nothing
// else.
@(test)
test_line_key :: proc(t: ^testing.T) {
	o := Options{voice = "alba", seed = 3, temperature = 0.3}
	k := line_key("The lamp was dark.", o)
	testing.expect(t, k == line_key("The lamp was dark.", o))
	testing.expect(t, k != line_key("The lamp was lit.", o))
	other := o
	other.voice = "marius"
	testing.expect(t, k != line_key("The lamp was dark.", other))
	other = o
	other.seed = 4
	testing.expect(t, k != line_key("The lamp was dark.", other))
	other = o
	other.temperature = 0.5
	testing.expect(t, k != line_key("The lamp was dark.", other))
}

// A kept line reads back as it was written; a missing or damaged file is
// no line.
@(test)
test_store_round_trip :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_speech_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)

	l := placeholder("One two. Three four five!")
	defer line_destroy(&l)
	for &x, i in l.samples {
		x = f32(i % 7) * 0.01
	}
	l.words[3].estimated = false
	k := line_key("One two. Three four five!", {voice = "alba"})
	testing.expect_value(t, store_write(dir, k, l).code, Error.None)

	got, ok := store_read(dir, k)
	defer line_destroy(&got)
	testing.expect(t, ok)
	testing.expect(t, got.ready)
	testing.expect_value(t, got.rate, l.rate)
	testing.expect(t, slice.equal(got.samples, l.samples))
	testing.expect(t, slice.equal(got.words, l.words))
	testing.expect(t, slice.equal(got.chunks, l.chunks))
	testing.expect(t, slice.equal(got.text, l.text))

	_, missing := store_read(dir, line_key("never said", {voice = "alba"}))
	testing.expect(t, !missing)
	path := store_path(dir, k)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, data[:len(data) - 4]) == nil)
	_, damaged := store_read(dir, k)
	testing.expect(t, !damaged)
}

// A placeholder: a chunk per sentence, words in order with their texts,
// every time an estimate, silence as long as the words.
@(test)
test_placeholder :: proc(t: ^testing.T) {
	l := placeholder("The keeper climbed. Up top, the lamp was dark!")
	defer line_destroy(&l)
	testing.expect(t, !l.ready)
	testing.expect_value(t, len(l.words), 9)
	testing.expect_value(t, len(l.chunks), 2)
	testing.expect_value(t, word_text(l, 0), "The")
	testing.expect_value(t, word_text(l, 8), "dark")
	testing.expect_value(t, chunk_text(l, 0), "The keeper climbed")
	testing.expect_value(t, chunk_text(l, 1), "Up top, the lamp was dark")
	testing.expect_value(t, l.chunks[1].first, 3)
	testing.expect_value(t, l.words[3].chunk, 1)
	for w, i in l.words {
		testing.expect(t, bool(w.estimated))
		testing.expect(t, w.stop > w.start)
		if i > 0 {
			testing.expect(t, w.start >= l.words[i - 1].stop)
		}
	}
	testing.expect(t, l.duration >= l.words[8].stop)
	testing.expect(t, slice.all_of(l.samples, 0))
}

// Synthesis is deterministic and a store hit is the synthesized line:
// identical samples and words. Needs ottis's files (about 830 MB); skipped
// when they are not downloaded yet (`ottis fetch`).
@(test)
test_store_hit_is_synthesis :: proc(t: ^testing.T) {
	root, rerr := assets.data_dir(context.temp_allocator)
	if rerr != nil || !os.exists(assets.path_in(root, assets.ALIGNER.path)) || !os.exists(assets.path_in(root, assets.BUNDLE[4].path)) {
		fmt.eprintln("test_store_hit_is_synthesis: ottis's files are not downloaded, skipped")
		return
	}
	dir, derr := os.make_directory_temp("", "onimite_speech_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)

	text := "Up top, the lamp was dark."
	o := Options{voice = "alba", seed = 3, temperature = DEFAULT_TEMPERATURE}
	lines: [1]Line
	fails: [1]Failure
	synthesize({{text, o}}, lines[:], fails[:])
	a := lines[0]
	defer line_destroy(&a)
	testing.expect_value(t, fails[0].code, Error.None)
	testing.expect(t, a.ready && len(a.samples) > 0 && len(a.words) == 6)
	testing.expect_value(t, word_text(a, 3), "lamp")

	// again, beside another line, the two on a pool: the same samples
	pool: common.Static_Pool
	common.init_static_pool(&pool, 2)
	defer common.destroy_static_pool(&pool)
	both: [2]Line
	fails2: [2]Failure
	synthesize({{"Below, the sea was loud.", o}, {text, o}}, both[:], fails2[:], &pool.work_pool)
	defer for &l in both {
		line_destroy(&l)
	}
	testing.expect_value(t, fails2[1].code, Error.None)
	testing.expect(t, slice.equal(a.samples, both[1].samples))

	k := line_key(text, o)
	testing.expect_value(t, store_write(dir, k, a).code, Error.None)
	c, ok := store_read(dir, k)
	defer line_destroy(&c)
	testing.expect(t, ok)
	testing.expect(t, slice.equal(a.samples, c.samples))
	testing.expect(t, slice.equal(a.words, c.words))
	testing.expect(t, slice.equal(a.chunks, c.chunks))
	testing.expect(t, slice.equal(a.text, c.text))
}
