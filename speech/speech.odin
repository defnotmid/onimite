// Spoken lines for `say()`: text to speech with word timings by ottis
// (Kyutai's Pocket TTS through ONNX Runtime, words placed by forced
// alignment), kept on disk by content.
//
// A line is a build artifact: its key hashes everything its samples
// depend on (ottis's output version, the runtime and model pins, the text,
// the voice and the options), so a stored line is the line synthesis would
// make. Synthesis runs one line at a time per process on its caller (the
// app's driver thread); ONNX Runtime's own threads (`pocket.THREADS` per
// graph) are its dedicated resource, like a hardware encoder.
package onimite_speech

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"
import "deps:ottis/assets"
import "deps:ottis/pocket"

DEFAULT_VOICE :: assets.DEFAULT_VOICE
DEFAULT_TEMPERATURE :: pocket.DEFAULT_OPTIONS.temperature
// ottis's output rate; placeholders use it too.
SAMPLE_RATE :: 24000

// What a line is spoken with (besides its text).
Options :: struct {
	voice:       string,
	seed:        u64,
	temperature: f32,
}

// A word of the line: when it is said (seconds into the line), where its
// text ends in `Line.text`, its chunk, and whether the time is an estimate
// (not aligned letter by letter: a number or symbol, or a placeholder).
Word :: struct {
	start, stop: f32,
	text_end:    u32,
	chunk:       u32,
	estimated:   b32,
}

// A generated chunk (a sentence group): its span and its words.
Chunk :: struct {
	start, stop:  f32,
	text_end:     u32,
	first, count: u32,
}

// A spoken line. `text` holds the words' texts, then the chunks' texts,
// each ending at its `text_end`. `ready` is false for a placeholder.
Line :: struct {
	samples:  []f32, // mono, `rate`
	rate:     int,
	duration: f32,
	words:    []Word,
	chunks:   []Chunk,
	text:     []u8,
	ready:    bool,
}

line_destroy :: proc(l: ^Line, allocator := context.allocator) {
	delete(l.samples, allocator)
	delete(l.words, allocator)
	delete(l.chunks, allocator)
	delete(l.text, allocator)
	l^ = {}
}

word_text :: proc(l: Line, i: int) -> string {
	begin := l.words[i - 1].text_end if i > 0 else 0
	return string(l.text[begin:l.words[i].text_end])
}

chunk_text :: proc(l: Line, i: int) -> string {
	begin: u32
	if i > 0 {
		begin = l.chunks[i - 1].text_end
	} else if len(l.words) > 0 {
		begin = l.words[len(l.words) - 1].text_end
	}
	return string(l.text[begin:l.chunks[i].text_end])
}

Key :: [sha2.DIGEST_SIZE_256]u8

// The key of `text` spoken with `o`: everything its samples depend on.
line_key :: proc(text: string, o: Options) -> (k: Key) {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	put :: proc(ctx: ^sha2.Context_256, s: string) {
		n := u64(len(s))
		sha2.update(ctx, mem.ptr_to_bytes(&n))
		sha2.update(ctx, transmute([]u8)s)
	}
	put(&ctx, fmt.tprintf("onimite say %d ottis %d", STORE_FORMAT, pocket.VERSION))
	put(&ctx, assets.ORT_VERSION)
	for pin in assets.BUNDLE {
		put(&ctx, pin.sha256)
	}
	put(&ctx, assets.ALIGNER.sha256)
	if pin, ok := assets.voice_pin(o.voice); ok {
		put(&ctx, pin.sha256)
	}
	d := pocket.DEFAULT_OPTIONS
	put(&ctx, fmt.tprintf("%s %d %v %d %d", o.voice, o.seed, transmute(u32)o.temperature, d.lsd_steps, d.frames_after_eos))
	put(&ctx, text)
	sha2.final(&ctx, k[:])
	return
}

// Whether ottis has voice `name`.
voice_known :: proc(name: string) -> bool {
	_, ok := assets.voice_pin(name)
	return ok
}

// Voices whose source recordings are licensed for non-commercial use only
// (huggingface.co/kyutai/tts-voices: Expresso, EARS).
voice_noncommercial :: proc(name: string) -> bool {
	return name == "cosette" || name == "jean"
}

// Every voice, comma separated (temp memory).
voice_names :: proc() -> string {
	names := make([dynamic]string, context.temp_allocator)
	for v in assets.VOICES {
		append(&names, v.name)
	}
	return strings.join(names[:], ", ", context.temp_allocator)
}

// ---- the store ---------------------------------------------------------------------------

STORE_FORMAT :: 1
@(private)
STORE_MAGIC :: [4]u8{'O', 'S', 'A', 'Y'}

@(private)
Store_Header :: struct {
	magic:                   [4]u8,
	format, rate:            u32,
	samples, words, chunks:  u32,
	text:                    u32,
}

// Where lines are kept: the user data directory's onimite/say (temp memory).
store_dir :: proc() -> (string, bool) {
	base, err := os.user_data_dir(context.temp_allocator)
	if err != nil {
		return "", false
	}
	dir, _ := filepath.join({base, "onimite", "say"}, context.temp_allocator)
	return dir, true
}

@(private)
store_path :: proc(dir: string, k: Key) -> string {
	k := k
	name := strings.concatenate({string(hex.encode(k[:], context.temp_allocator)), ".line"}, context.temp_allocator)
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	return path
}

// The line `k` kept in `dir` (store_dir), if there is one.
store_read :: proc(dir: string, k: Key, allocator := context.allocator) -> (l: Line, ok: bool) {
	path := store_path(dir, k)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(data) < size_of(Store_Header) {
		return
	}
	h := (^Store_Header)(raw_data(data))^
	if h.magic != STORE_MAGIC || h.format != STORE_FORMAT {
		return
	}
	sizes := [4]int{int(h.words) * size_of(Word), int(h.chunks) * size_of(Chunk), int(h.text), int(h.samples) * size_of(f32)}
	if size_of(Store_Header) + sizes[0] + sizes[1] + sizes[2] + sizes[3] != len(data) {
		return
	}
	at := size_of(Store_Header)
	take :: proc(data: []u8, at: ^int, n: int) -> []u8 {
		b := data[at^:][:n]
		at^ += n
		return b
	}
	l.words = make([]Word, h.words, allocator)
	l.chunks = make([]Chunk, h.chunks, allocator)
	l.text = make([]u8, h.text, allocator)
	l.samples = make([]f32, h.samples, allocator)
	copy(mem.slice_to_bytes(l.words), take(data, &at, sizes[0]))
	copy(mem.slice_to_bytes(l.chunks), take(data, &at, sizes[1]))
	copy(l.text, take(data, &at, sizes[2]))
	copy(mem.slice_to_bytes(l.samples), take(data, &at, sizes[3]))
	l.rate = int(h.rate)
	l.duration = f32(f64(h.samples) / f64(max(h.rate, 1)))
	l.ready = true
	return l, true
}

// Keeps line `l` under `k` in `dir` (written whole, then renamed into
// place).
store_write :: proc(dir: string, k: Key, l: Line) -> Failure {
	path := store_path(dir, k)
	if e := os.make_directory_all(filepath.dir(path)); e != nil && e != .Exist {
		return {code = .Store_Create, path = filepath.dir(path), os = e}
	}
	h := Store_Header{STORE_MAGIC, STORE_FORMAT, u32(l.rate), u32(len(l.samples)), u32(len(l.words)), u32(len(l.chunks)), u32(len(l.text))}
	b := make([dynamic]u8, 0, size_of(Store_Header) + len(l.words) * size_of(Word) + len(l.chunks) * size_of(Chunk) + len(l.text) + len(l.samples) * size_of(f32), context.temp_allocator)
	append(&b, ..mem.ptr_to_bytes(&h))
	append(&b, ..mem.slice_to_bytes(l.words))
	append(&b, ..mem.slice_to_bytes(l.chunks))
	append(&b, ..l.text)
	append(&b, ..mem.slice_to_bytes(l.samples))
	part := strings.concatenate({path, ".part"}, context.temp_allocator)
	if e := os.write_entire_file(part, b[:]); e != nil {
		return {code = .Store_Write, path = part, os = e}
	}
	if e := os.rename(part, path); e != nil {
		os.remove(part)
		return {code = .Store_Rename, path = part, os = e}
	}
	return {}
}

// ---- placeholders --------------------------------------------------------------------------

// Speaking rate of a placeholder (characters of text a second) and the
// pause between its sentences: about ottis's voices.
PLACEHOLDER_CHARS_PER_SECOND :: 15.0
PLACEHOLDER_PAUSE :: 0.35

// A silent stand-in for `text` until it is synthesized: one chunk per
// sentence, words spread by length, every time an estimate.
placeholder :: proc(text: string, allocator := context.allocator) -> (l: Line) {
	spans := pocket.word_spans(text, context.temp_allocator)
	words := make([dynamic]Word, 0, len(spans), allocator)
	chunks := make([dynamic]Chunk, allocator)
	b := make([dynamic]u8, allocator)
	chunk_begins := make([dynamic]int, context.temp_allocator)
	t := f32(0)
	first := 0
	for sp, i in spans {
		if i == first {
			append(&chunk_begins, sp.begin)
		}
		w := text[sp.begin:sp.end]
		dur := f32(len(w) + 1) / PLACEHOLDER_CHARS_PER_SECOND
		append(&b, w)
		append(&words, Word{t, t + dur, u32(len(b)), u32(len(chunks)), true})
		t += dur
		// A sentence ends at . ! ? between this word and the next.
		gap_end := spans[i + 1].begin if i + 1 < len(spans) else len(text)
		gap := text[sp.end:gap_end]
		if strings.contains_any(gap, ".!?") || i + 1 == len(spans) {
			start := words[first].start
			append(&chunks, Chunk{start, t, 0, u32(first), u32(i + 1 - first)})
			first = i + 1
			if i + 1 < len(spans) {
				t += PLACEHOLDER_PAUSE
			}
		}
	}
	for &ch, k in chunks {
		last := spans[ch.first + ch.count - 1]
		append(&b, strings.trim_space(text[chunk_begins[k]:last.end]))
		ch.text_end = u32(len(b))
	}
	l.words, l.chunks, l.text = words[:], chunks[:], b[:]
	l.rate = SAMPLE_RATE
	l.samples = make([]f32, int(math.ceil(t * SAMPLE_RATE)), allocator)
	l.duration = f32(len(l.samples)) / SAMPLE_RATE
	return
}

// ---- synthesis -----------------------------------------------------------------------------

// The process's engine: made on the first line not in the store, freed by
// `release` once its caller has synthesized what it needs (the lines it
// made own their memory) and made again by the next miss. The lock also
// makes synthesis one line at a time.
@(private)
tts: struct {
	lock:    sync.Mutex,
	tried:   bool,
	// Why the engine did not start (owned).
	failure: Failure,
	// Where progress and timings go (`set_log`; nil: nowhere).
	log:     proc(message: string),
	debug:   bool,
	root:    string,
	engine:  pocket.Engine,
	voices:  map[string]^pocket.Voice,
	// Lines that could not be synthesized, by key, and why (owned): not
	// tried again by the other loads of the process.
	failed:  map[Key]Failure,
}

// Where progress (ottis's downloads, the lines being synthesized) goes, and
// with `debug` the timings too; the host prints it.
set_log :: proc(log: proc(message: string), debug: bool) {
	sync.guard(&tts.lock)
	tts.log, tts.debug = log, debug
}

// Passes `message` to the host's log.
log :: proc(message: string) {
	if tts.log != nil {
		tts.log(message)
	}
}

@(private)
progress :: proc(message: string) {
	log(fmt.tprintf("ottis: %s", message))
}

// Speaks `text` with `o` (the first call downloads ottis's files if needed,
// progress to the log, and loads the engine). On failure `f` says why
// (strings in temp memory). The line's memory is the caller's
// (context.allocator).
synthesize :: proc(text: string, o: Options) -> (l: Line, f: Failure) {
	sync.guard(&tts.lock)
	if known, failed := tts.failed[line_key(text, o)]; failed {
		return l, failure_clone(known, context.temp_allocator) // tried before in this process
	}
	began := time.tick_now()
	if !tts.tried {
		tts.tried = true
		tts.failure = engine_start()
		if tts.debug {
			log(fmt.tprintf("say: engine ready in %.0f ms", time.duration_milliseconds(time.tick_since(began))))
			began = time.tick_now()
		}
	}
	voice: ^pocket.Voice
	if tts.failure.code != .None {
		f = tts.failure
	} else {
		voice, f = voice_get(o.voice)
	}
	if f.code == .None {
		opts := pocket.DEFAULT_OPTIONS
		opts.seed, opts.temperature = o.seed, o.temperature
		r: pocket.Result
		defer pocket.result_destroy(&r)
		if e := pocket.synthesize(&tts.engine, voice, text, opts, &r); e != nil {
			f = {code = .Synthesize, detail = fmt.tprintf("%s", e.?)}
		} else {
			if tts.debug {
				ms := time.duration_milliseconds(time.tick_since(began))
				audio := f64(len(r.audio)) / f64(max(r.sample_rate, 1))
				log(fmt.tprintf("say: %.2f s of speech in %.0f ms (%.1fx real time)", audio, ms, audio * 1000 / max(ms, 1)))
			}
			return from_result(&r), {}
		}
	}
	note_failure(line_key(text, o), f)
	return l, failure_clone(f, context.temp_allocator)
}

// What the engine keeps (the engine, voices, failures) belongs to no caller:
// it is on the heap allocator.

// Frees the engine and its voices (about 1.3 GB); the lines synthesized so
// far are unaffected. Failures are kept: a line that failed is not tried
// again in this process.
release :: proc() {
	sync.guard(&tts.lock)
	context.allocator = os.heap_allocator()
	if !tts.tried || tts.failure.code != .None {
		return // nothing loaded; a failed start is not tried again
	}
	for name, v in tts.voices {
		pocket.voice_destroy(v)
		free(v)
		delete(name)
	}
	clear(&tts.voices)
	pocket.engine_destroy(&tts.engine)
	tts.engine = {}
	delete(tts.root)
	tts.root, tts.tried = "", false
	heap_trim()
}

// Notes that line `k` can't be had in this process (and why): the other
// loads give the placeholder instead of trying again.
failed :: proc(k: Key, f: Failure) {
	sync.guard(&tts.lock)
	note_failure(k, f)
}

@(private)
note_failure :: proc(k: Key, f: Failure) {
	context.allocator = os.heap_allocator()
	if k not_in tts.failed {
		tts.failed[k] = failure_clone(f)
	}
}

// Voice `name`, loaded once (under the lock).
@(private)
voice_get :: proc(name: string) -> (^pocket.Voice, Failure) {
	context.allocator = os.heap_allocator()
	if v := tts.voices[name]; v != nil {
		return v, {}
	}
	if !voice_known(name) {
		return nil, {code = .Unknown_Voice, path = name}
	}
	if e := assets.ensure_voice(tts.root, name, false, progress); e != nil {
		return nil, {code = .Voice_Fetch, path = name, detail = e.?}
	}
	v, e := pocket.voice_load(&tts.engine, tts.root, name)
	if e != nil {
		return nil, {code = .Voice_Load, path = name, detail = e.?}
	}
	voice := new_clone(v)
	tts.voices[strings.clone(name)] = voice
	return voice, {}
}

// Starts the engine; its failure is owned (kept for the process).
@(private)
engine_start :: proc() -> Failure {
	context.allocator = os.heap_allocator()
	root, err := assets.data_dir(context.allocator)
	if err != nil {
		return failure_clone({code = .No_Data_Dir, detail = err.?})
	}
	tts.root = root
	library, ferr := assets.ensure_runtime(root, false, progress)
	if ferr == nil {
		ferr = assets.ensure_bundle(root, false, progress)
	}
	if ferr != nil {
		return failure_clone({code = .Fetch, path = root, detail = ferr.?})
	}
	if e := pocket.engine_init(&tts.engine, root, library); e != nil {
		return failure_clone({code = .Engine, detail = e.?})
	}
	return {}
}

// The line of result `r`, taking its samples (made with the caller's
// allocator) rather than copying them.
@(private)
from_result :: proc(r: ^pocket.Result) -> (l: Line) {
	l.rate = r.sample_rate
	shrink(&r.audio)
	l.samples = r.audio[:]
	r.audio = nil
	l.duration = f32(f64(len(l.samples)) / f64(max(r.sample_rate, 1)))
	l.words = make([]Word, len(r.words))
	l.chunks = make([]Chunk, len(r.chunks))
	b := make([dynamic]u8)
	for w, i in r.words {
		append(&b, w.text)
		l.words[i] = {f32(w.start), f32(w.end), u32(len(b)), 0, b32(w.estimated)}
	}
	for ch, k in r.chunks {
		for i in ch.first_word ..< ch.first_word + ch.word_count {
			l.words[i].chunk = u32(k)
		}
		append(&b, strings.trim_space(ch.text))
		l.chunks[k] = {f32(ch.start), f32(ch.end), u32(len(b)), u32(ch.first_word), u32(ch.word_count)}
	}
	l.text = b[:]
	l.ready = true
	return
}
