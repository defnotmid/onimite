package onimite_script

import "core:c"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import common "deps:oicut/common"
import om "../onimite"
import "../speech"
import lua "vendor:lua/5.4"

// Spoken lines: `say(name, text, { voice, seed, temperature })` at load
// speaks `text` (ottis: Pocket TTS with word timings by forced alignment,
// speech/) and makes, under `name`, an audio clip (24 kHz mono, resampled
// to the mix), captions with one cue per chunk, and returns
//
//     { name, text, voice, seed, duration, ready,
//       words = { { text, start, stop, estimated, chunk }, ... },   -- seconds into the line
//       chunks = { { text, start, stop, first, count }, ... } }
//
// A line comes from the shared rows of the render (the frame builders), else
// the on-disk store (by content), else it is synthesized there and then and
// kept in the store: one load point, like a media file. A line that can't
// be synthesized is a silent placeholder with estimated times (`ready =
// false`) and a `tts_unavailable` error, so the script still loads (and a
// render refuses to start).

// A line in the shared rows: its words and chunks without the samples.
Said_Line :: struct {
	key:  speech.Key,
	line: speech.Line,
}

// A line `say` spoke in this load: what it says, how (owned strings).
Said :: struct {
	key:     speech.Key,
	text:    string,
	options: speech.Options,
}

// The line `say` spoke as `name` in this load (its words and chunks; no
// samples), if any.
said_line :: proc(s: ^Script, name: string) -> (speech.Line, bool) {
	if _, ok := s.said[name]; !ok {
		return {}, false
	}
	sh := s.shared
	sync.guard(&sh.lock)
	if l := sh.lines[name]; l != nil {
		return l.line, true
	}
	return {}, false
}

// The line `say` spoke as `name` in this load: its text and options.
said :: proc(s: ^Script, name: string) -> (Said, bool) {
	return s.said[name]
}

// The names of the lines `say` spoke, sorted (temp memory).
said_names :: proc(s: ^Script) -> []string {
	names := make([dynamic]string, 0, len(s.said), context.temp_allocator)
	for name in s.said {
		append(&names, name)
	}
	slice.sort(names[:])
	return names[:]
}

// A line the load's first pass missed: what to speak, its copies owned.
Say_Miss :: struct {
	name:    string,
	key:     speech.Key,
	request: speech.Request,
}

// A line the batch made for the second pass, and why it was not stored
// (None when it was).
Say_Made :: struct {
	line: speech.Line,
	kept: speech.Failure,
}

@(private)
say_miss :: proc(s: ^Script, name: string, k: speech.Key, text: string, o: speech.Options) {
	for x in s.say_misses {
		if x.key == k {
			return // the same line under another name: made once
		}
	}
	r := speech.Request{text = strings.clone(text), options = o}
	r.options.voice = strings.clone(o.voice)
	r.options.voice_file = strings.clone(o.voice_file)
	r.options.voice_samples = slice.clone(o.voice_samples)
	append(&s.say_misses, Say_Miss{strings.clone(name), k, r})
}

@(private)
say_misses_clear :: proc(s: ^Script) {
	for &x in s.say_misses {
		delete(x.name)
		delete(x.request.text)
		delete(x.request.options.voice)
		delete(x.request.options.voice_file)
		delete(x.request.options.voice_samples)
	}
	delete(s.say_misses)
	s.say_misses = nil
}

@(private)
say_made_clear :: proc(s: ^Script) {
	for _, &x in s.say_made {
		speech.line_destroy(&x.line)
		speech.failure_destroy(&x.kept)
	}
	delete(s.say_made)
	s.say_made = nil
}

// Between a load's passes: the lines its first pass missed, synthesized
// together on the background pool and stored; the second pass reads them
// (say_made), and a line that failed gets its stand-in and error there.
@(private)
say_synthesize :: proc(s: ^Script) {
	defer say_misses_clear(s)
	n := len(s.say_misses)
	speech.log(fmt.tprintf("say: synthesizing %d line%s", n, "" if n == 1 else "s"))
	requests := make([]speech.Request, n, context.temp_allocator)
	for x, i in s.say_misses {
		requests[i] = x.request
	}
	lines := make([]speech.Line, n, context.temp_allocator)
	fails := make([]speech.Failure, n, context.temp_allocator)
	// the media's background pool, where its songs render
	work: om.Pool_Work
	om.pool_work_init(&work, s.media.music.pool if s.media != nil && s.media.music != nil else nil)
	defer om.pool_work_destroy(&work)
	speech.synthesize(requests, lines, fails, &work.work_pool)
	s.spoke = true
	dir, has_dir := speech.store_dir()
	for x, i in s.say_misses {
		if fails[i].code != .None {
			continue // known to speech now: the second pass gives the stand-in
		}
		kept := speech.store_write(dir, x.key, lines[i]) if has_dir else speech.Failure{code = .No_Store_Dir}
		if s.say_made == nil {
			s.say_made = make(map[speech.Key]Say_Made)
		}
		s.say_made[x.key] = {lines[i], speech.failure_clone(kept)}
	}
}

@(private)
say_unload :: proc(s: ^Script) {
	for name, l in s.said {
		delete(name)
		delete(l.text)
		delete(l.options.voice)
	}
	delete(s.said)
}

@(private)
l_say :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	name := strings.clone(string(lua.L_checkstring(L, 1)), context.temp_allocator)
	text := strings.clone(string(lua.L_checkstring(L, 2)), context.temp_allocator)
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	o := speech.Options{voice = speech.DEFAULT_VOICE, temperature = speech.DEFAULT_TEMPERATURE}
	if lua.istable(L, 3) {
		fields_begin(L, 3)
		o.voice = strings.clone(get_str(L, 3, "voice", o.voice), context.temp_allocator)
		field(L, 3, "seed")
		if lua.isinteger(L, -1) && lua.tointeger(L, -1) >= 0 {
			o.seed = u64(lua.tointeger(L, -1))
		} else if !lua.isnil(L, -1) {
			lua.L_error(L, "say(%s): seed is a whole number from 0", cname)
		}
		lua.pop(L, 1)
		o.temperature = get_num(L, 3, "temperature", o.temperature)
		fields_end(L, s, 3, "say")
	}
	if strings.trim_space(text) == "" {
		lua.L_error(L, "say(%s): nothing to say", cname)
	}
	m := measure_media(L, s, "say")
	if !speech.voice_known(o.voice) {
		if clip, ok := m.audio[o.voice]; ok && clip.frames > 0 {
			// A recording of the media, as decoded: its first 30 s in mono.
			n := min(clip.frames, speech.VOICE_SECONDS * om.MIX_RATE)
			mono := make([]f32, n, context.temp_allocator)
			for i in 0 ..< n {
				mono[i] = (clip.samples[i * 2] + clip.samples[i * 2 + 1]) * 0.5
			}
			o.voice_samples, o.voice_rate = mono, om.MIX_RATE
			o.voice_hash = hash.fnv64a(slice.to_bytes(mono))
		} else if path, found := speech.voice_file(m.dir, o.voice); found {
			if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
				o.voice_file, o.voice_hash = path, hash.fnv64a(data)
			}
		}
	}
	k := speech.line_key(text, o)
	if prev, ok := s.said[name]; ok && prev.key != k {
		lua.L_error(L, "say(%s) already says something else: give each line its own name", cname)
	}

	line, found := shared_said(s.shared, name, k)
	if !found {
		dir, has_dir := speech.store_dir()
		l: speech.Line
		have := false
		kept: speech.Failure
		if made, ok := s.say_made[k]; ok {
			// made by this load's batch (say_synthesize)
			l, kept, have = made.line, made.kept, true
			delete_key(&s.say_made, k)
		} else if has_dir {
			l, have = speech.store_read(dir, k)
		}
		why := speech.Failure{code = .Unknown_Voice, path = o.voice}
		if !have && (speech.voice_known(o.voice) || o.voice_hash != 0) {
			if s.say_defer {
				// the load's first pass: a stand-in until the batch makes it
				say_miss(s, name, k, text, o)
				l = speech.placeholder(text)
				om.media_add_audio_samples(m, name, l.samples, l.rate, 1)
				om.media_add_captions(m, name, line_captions(l))
				push_line(L, name, text, o, l)
				speech.line_destroy(&l)
				return 1
			}
			// a line only this pass reaches (its first pass took another way)
			speech.log(fmt.tprintf("say(%s): synthesizing the line", name))
			lines: [1]speech.Line
			fails: [1]speech.Failure
			speech.synthesize({{text, o}}, lines[:], fails[:])
			l, why = lines[0], fails[0]
			have = why.code == .None
			s.spoke = true
			if have {
				kept = speech.store_write(dir, k, l) if has_dir else speech.Failure{code = .No_Store_Dir}
			}
		}
		if have && kept.code != .None {
			// This load has the line; the others of the process (clip
			// builds) don't synthesize it again: theirs is silent.
			report_warning(L, s, {code = .Tts_Not_Kept, a = name, b = speech.error_message(kept)})
			speech.failed(k, kept)
		}
		if !have {
			// An error: a render refuses to ship the silent line.
			report_warning(L, s, {code = .Tts_Unavailable, a = name, b = speech.error_message(why)}, .Error)
			l = speech.placeholder(text)
		}
		om.media_add_audio_samples(m, name, l.samples, l.rate, 1)
		om.media_add_captions(m, name, line_captions(l))
		line = shared_said_put(s.shared, name, k, l)
		speech.line_destroy(&l)
	}
	if speech.voice_noncommercial(o.voice) {
		report_warning(L, s, {code = .Tts_Noncommercial, a = name, b = o.voice})
	}
	if name not_in s.said {
		s.said[strings.clone(name)] = {k, strings.clone(text), {voice = strings.clone(o.voice), seed = o.seed, temperature = o.temperature}}
	}
	push_line(L, name, text, o, line)
	return 1
}

// Captions of a line: its words, a cue per sentence (a chunk holds whole
// sentences, often several), so a page never runs from one sentence into
// the next.
line_captions :: proc(l: speech.Line, allocator := context.allocator) -> om.Captions {
	n := len(l.words)
	texts := make([]string, n, context.temp_allocator)
	starts := make([]f32, n, context.temp_allocator)
	stops := make([]f32, n, context.temp_allocator)
	cues := make([]u32, n, context.temp_allocator)
	for w, i in l.words {
		texts[i] = speech.word_text(l, i)
		starts[i], stops[i] = w.start, w.stop
	}
	cue: u32
	for ch, k in l.chunks {
		// Where each word is in the chunk's text; a . ! or ? before the next
		// one ends a sentence.
		text := speech.chunk_text(l, k)
		at := 0
		last := min(int(ch.first + ch.count), n)
		for i in int(ch.first) ..< last {
			if j := strings.index(text[at:], texts[i]); j >= 0 {
				at += j + len(texts[i])
			}
			cues[i] = cue
			if i + 1 < last {
				if j := strings.index(text[at:], texts[i + 1]); j >= 0 && strings.contains_any(text[at:][:j], ".!?") {
					cue += 1
				}
			}
		}
		cue += 1
	}
	return om.captions_from_words(texts, starts, stops, cues, allocator)
}

// The shared rows of line `name` when they are those of key `k`.
@(private = "file")
shared_said :: proc(sh: ^Shared, name: string, k: speech.Key) -> (speech.Line, bool) {
	sync.guard(&sh.lock)
	if l := sh.lines[name]; l != nil && l.key == k {
		return l.line, true
	}
	return {}, false
}

// Copies the words and chunks of `l` into the shared rows as line `name`.
@(private = "file")
shared_said_put :: proc(sh: ^Shared, name: string, k: speech.Key, l: speech.Line) -> speech.Line {
	sync.guard(&sh.lock)
	alloc := virtual.arena_allocator(&sh.arena)
	said := new(Said_Line, alloc)
	said.key = k
	said.line = {
		rate     = l.rate,
		duration = l.duration,
		words    = make([]speech.Word, len(l.words), alloc),
		chunks   = make([]speech.Chunk, len(l.chunks), alloc),
		text     = make([]u8, len(l.text), alloc),
		ready    = l.ready,
	}
	copy(said.line.words, l.words)
	copy(said.line.chunks, l.chunks)
	copy(said.line.text, l.text)
	if name not_in sh.lines {
		sh.lines[strings.clone(name, alloc)] = said
	} else {
		sh.lines[name] = said
	}
	return said.line
}

@(private = "file")
push_line :: proc(L: ^lua.State, name, text: string, o: speech.Options, l: speech.Line) {
	push_str :: proc(L: ^lua.State, key: cstring, v: string) {
		lua.pushlstring(L, cstring(raw_data(v)), c.size_t(len(v)))
		lua.setfield(L, -2, key)
	}
	// Times to a tenth of a millisecond (the rows are f32).
	seconds :: proc(x: f32) -> lua.Number {
		return lua.Number(math.round(f64(x) * 1e4) / 1e4)
	}
	lua.createtable(L, 0, 8)
	push_str(L, "name", name)
	push_str(L, "text", text)
	push_str(L, "voice", o.voice)
	lua.pushinteger(L, lua.Integer(o.seed))
	lua.setfield(L, -2, "seed")
	lua.pushnumber(L, seconds(l.duration))
	lua.setfield(L, -2, "duration")
	lua.pushboolean(L, b32(l.ready))
	lua.setfield(L, -2, "ready")
	lua.createtable(L, c.int(len(l.words)), 0)
	for w, i in l.words {
		lua.createtable(L, 0, 5)
		push_str(L, "text", speech.word_text(l, i))
		lua.pushnumber(L, seconds(w.start))
		lua.setfield(L, -2, "start")
		lua.pushnumber(L, seconds(w.stop))
		lua.setfield(L, -2, "stop")
		lua.pushboolean(L, w.estimated)
		lua.setfield(L, -2, "estimated")
		set_int(L, "chunk", int(w.chunk) + 1)
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	lua.setfield(L, -2, "words")
	lua.createtable(L, c.int(len(l.chunks)), 0)
	for ch, i in l.chunks {
		lua.createtable(L, 0, 5)
		push_str(L, "text", speech.chunk_text(l, i))
		lua.pushnumber(L, seconds(ch.start))
		lua.setfield(L, -2, "start")
		lua.pushnumber(L, seconds(ch.stop))
		lua.setfield(L, -2, "stop")
		set_int(L, "first", int(ch.first) + 1)
		set_int(L, "count", int(ch.count))
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	lua.setfield(L, -2, "chunks")
}

// Tracks playing a spoken line with no bus go on the video's voice bus (the
// first bus of kind voice), or are marked `voice` when it has none: speech
// ducks the music and is never checked against the beat.
@(private)
say_default_buses :: proc(s: ^Script) {
	if len(s.said) == 0 {
		return
	}
	voice_bus := ""
	for b in s.video.buses {
		if b.kind == .Voice {
			voice_bus = b.name
			break
		}
	}
	for &tr in s.tracks {
		if tr.bus != "" || tr.src not_in s.said {
			continue
		}
		if voice_bus != "" {
			tr.bus = voice_bus
		} else {
			tr.voice = true
		}
	}
}
