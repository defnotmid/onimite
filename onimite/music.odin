package onimite

import "base:intrinsics"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:mem/virtual"
import "core:simd"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import oanalyze "deps:odawg/analyze"
import oassets "deps:odawg/assets"
import obase "deps:odawg/base"
import odevice "deps:odawg/device"
import orender "deps:odawg/render"
import osong "deps:odawg/song"
import ospec "deps:odawg/spec"
import otempo "deps:odawg/tempo"
import otheory "deps:odawg/theory"

// Songs: odawg's composed songs (`song{}`, `sound{}` in scripts) as media
// sounds a track plays by name, like a clip. A song is data (its form, its
// tracks and every note). Its sound is made once, when something needs all
// of it (a lane's peaks, a table a frame reads): its render, kept with it,
// made a segment at a time on every core (the preview's playhead first);
// lanes and tables are views of it. The mix streams songs from odawg's
// engine. The video's sample sets (what its Samplers play) are one bank,
// shared by its songs.

Music :: struct {
	lock:    sync.Mutex, // the songs, the queue
	// Held while the bank changes (a song's sets declared, its zones loaded):
	// loading takes seconds, and finding a song must not wait for it.
	// Taken after `lock`, never before it.
	bank_lock: sync.Mutex,
	songs:   map[string]^Song_Clip,
	// Songs replaced under their name: a script state may still read them
	// (its song object), so they go with the media.
	retired: [dynamic]^Song_Clip,
	// The sample sets the songs' Samplers play (by index): declared when a
	// song is composed, and only the zones its notes reach loaded, when its
	// sound is first wanted (music_load).
	bank:    odevice.Bank,
	// The renderers (threads making songs' renders: started by music_drain,
	// ending when no segment is left), how many run, whether they must stop
	// (the media goes), the video sample nearest which they render first
	// (atomic), segments landed and songs whole since the host looked
	// (atomic), what a waiting command hears a segment land on, and who
	// they tell.
	renderers: [dynamic]^thread.Thread,
	running:   int,
	stopping:  bool,
	focus:     i64,
	landed:    int,
	whole:     int,
	landing:   sync.Cond,
	// The media folder: where songs' own files are (their sets, SFZ and
	// style files), under bank_lock.
	host_root: string,
	// Loading fetches what the songs' sources serve that isn't pinned yet,
	// and keeps its pin (music_pin; `onimite audio pin`).
	pinning:   bool,
	// Songs whose sample sets loaded since the host looked (atomic): a mix
	// made before has them silent.
	banks:     int,
	wake:      proc(data: rawptr),
	wake_data: rawptr,
}

// A composed song in the media. Everything but the bank is in `arena`.
Song_Clip :: struct {
	name:     string,
	// The content of the spec it was composed from (with onimite's times
	// resolved): the same key in the same media is the same song.
	key:      u64,
	arena:    virtual.Arena,
	spec:     ospec.Spec,
	song:     osong.Song,
	// What reading the spec and composing found (odawg's codes and paths).
	findings: obase.Findings,
	// Seconds of sound past its last section (release tails, reverbs).
	tail:     f64,
	ok:       bool,
	// The keys of each sample set its notes play, and whether they are in
	// the bank yet.
	needs:    [dynamic]odevice.Sample_Need,
	loaded:   bool,
	music:    ^Music, // whose bank it plays
	// Its render and the tables read from it: heap memory, freed with it.
	render:   Song_Render,
	tables:   [dynamic]^Song_Table,
}

@(private)
music_init :: proc(mu: ^Music) {
	mu.songs = make(map[string]^Song_Clip)
	mu.retired = make([dynamic]^Song_Clip)
	mu.renderers = make([dynamic]^thread.Thread)
	a := runtime.heap_allocator()
	mu.bank.sets = make([dynamic]odevice.Sample_Set, a)
	mu.bank.zones = make([dynamic]odevice.Zone, a)
	mu.bank.zone_file = make([dynamic]i32, a)
	mu.bank.samples = make([dynamic]odevice.Sample, a)
	mu.bank.f32s = make([dynamic][]f32, a)
	mu.bank.i16s = make([dynamic][]i16, a)
	mu.bank.owned = make([dynamic]odevice.Chunk, a)
}

@(private)
music_destroy :: proc(mu: ^Music) {
	// the renderers finish the segment they are on
	sync.mutex_lock(&mu.lock)
	mu.stopping = true
	sync.mutex_unlock(&mu.lock)
	for t in mu.renderers {
		thread.join(t)
		thread.destroy(t)
	}
	delete(mu.renderers)
	for name, sc in mu.songs {
		delete(name)
		song_clip_free(sc)
	}
	delete(mu.songs)
	for sc in mu.retired {
		song_clip_free(sc)
	}
	delete(mu.retired)
	odevice.bank_destroy(&mu.bank) // the sets' names are the register's
}

// Loads what the media's songs play that isn't in the bank yet: each
// song's needed zones (fetched on first use), findings onto the song. Call
// before streaming a song or a mix of songs.
music_load :: proc(m: ^Media) {
	if m == nil || m.music == nil {
		return
	}
	for sc in media_songs(m) {
		song_clip_load(sc)
	}
}

// Loads what one song plays that isn't in the bank yet (once).
song_clip_load :: proc(sc: ^Song_Clip) {
	if sc == nil || sc.loaded || !sc.ok || sc.music == nil {
		return
	}
	mu := sc.music
	sync.guard(&mu.bank_lock)
	if sc.loaded {
		return
	}
	context.allocator = runtime.heap_allocator()
	host := oassets.Bank_Host{root = mu.host_root, pinning = mu.pinning}
	oassets.bank_load(&mu.bank, sc.needs[:], &sc.findings, oassets.progress_stderr, &host)
	sc.loaded = true
	sync.atomic_add(&mu.banks, 1)
}

@(private = "file")
song_clip_free :: proc(sc: ^Song_Clip) {
	for st in sc.tables {
		orender.table_destroy(&st.table, runtime.heap_allocator())
		delete(st.filled, runtime.heap_allocator())
		free(st, runtime.heap_allocator())
	}
	delete(sc.tables)
	a := runtime.heap_allocator()
	delete(sc.render.samples, a)
	delete(sc.render.peaks, a)
	delete(sc.render.state, a)
	virtual.arena_destroy(&sc.arena)
	free(sc)
}

// Song `name` of the media, or nil.
media_song :: proc(m: ^Media, name: string) -> ^Song_Clip {
	if m == nil || m.music == nil {
		return nil
	}
	sync.guard(&m.music.lock)
	return m.music.songs[name]
}

// Whether the media has a sound named `name`: a clip or a song.
media_has_sound :: proc(m: ^Media, name: string) -> bool {
	return name in m.audio || media_song(m, name) != nil
}

// The media's songs, sorted by name (temp memory).
media_songs :: proc(m: ^Media) -> []^Song_Clip {
	out := make([dynamic]^Song_Clip, context.temp_allocator)
	if m == nil || m.music == nil {
		return nil
	}
	sync.guard(&m.music.lock)
	for _, sc in m.music.songs {
		append(&out, sc)
	}
	slice.sort_by(out[:], proc(a, b: ^Song_Clip) -> bool {return a.name < b.name})
	return out[:]
}

// Song `name` composed from spec `v` (`key`: its value's content,
// value_key). A song is what it is made of: the spec and the content of
// every file it reads (its sample sets' files, an SFZ, a style file, an
// instrument file), all
// in its key, so the same song in the same media is the one already there
// (its render with it) and anything changed is a new song. Its sample sets
// are declared in the video's bank (read from the media folder: WAV and
// FLAC, loops from the files). A song it replaces is retired. `fresh` is
// true when it was composed now (its findings are new). The song's start
// is the spec's (the video's clock).
media_song_put :: proc(m: ^Media, name: string, v: json.Value, key: u64) -> (sc: ^Song_Clip, fresh: bool) {
	mu := m.music
	sync.guard(&mu.lock)
	made_with := context.allocator
	sc = new(Song_Clip)
	sc.music = mu
	sc.tables = make([dynamic]^Song_Table, runtime.heap_allocator())
	_ = virtual.arena_init_growing(&sc.arena)
	host := oassets.Bank_Host{root = m.dir}
	full := key
	{
		context.allocator = virtual.arena_allocator(&sc.arena)
		sc.name = strings.clone(name)
		sc.findings = make(obase.Findings)
		if ospec.spec_from_value(v, &sc.spec, &sc.findings) {
			// the files beside the spec first (style files, the instrument
			// files they and it name): their parts may name sets
			files := make([dynamic]string, context.temp_allocator)
			{
				sync.guard(&mu.bank_lock)
				mu.host_root = m.dir
				oassets.spec_read_files(&sc.spec, &sc.findings, &host, &files, &mu.bank)
				context.allocator = runtime.heap_allocator()
				oassets.bank_declare_spec(&mu.bank, &sc.spec, &sc.findings, &host, &files)
			}
			for path in files {
				stamp := file_stamp(oassets.host_path(&host, path))
				full = hash.fnv64a(transmute([]u8)path, full)
				full = hash.fnv64a(slice.bytes_from_ptr(&stamp, size_of(stamp)), full)
			}
			if old := mu.songs[name]; old != nil && old.key == full {
				// the same song: nothing of this compose is kept
				virtual.arena_destroy(&sc.arena)
				delete(sc.tables)
				free(sc, made_with)
				return old, false
			}
			sc.ok = osong.song_from_spec(&sc.spec, &sc.song, &mu.bank)
			append(&sc.findings, ..sc.song.findings[:])
			if sc.ok {
				sc.tail = orender.tail_from_song(&sc.song)
				sc.needs = make([dynamic]odevice.Sample_Need)
				osong.sample_needs(&sc.song, &sc.needs)
				sc.loaded = len(sc.needs) == 0
			}
		}
	}
	sc.key = full
	if old, seen := mu.songs[name]; seen {
		append(&mu.retired, old)
		mu.songs[name] = sc
	} else {
		mu.songs[strings.clone(name)] = sc
	}
	return sc, true
}

// A file's content as the loader tells it apart (its size and time, odawg's
// rule): 0 when it can't be read.
@(private = "file")
file_stamp :: proc(path: string) -> u64 {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return 0
	}
	return hash.fnv64a(transmute([]u8)fmt.tprintf("%d %d", info.size, info.modification_time._nsec))
}

// The content key of a spec value: its kinds, keys (sorted) and values.
value_key :: proc(v: json.Value) -> u64 {
	h: u64 = 0xcbf29ce484222325
	mix :: proc(h: ^u64, data: []u8) {
		h^ = hash.fnv64a(data, h^)
	}
	walk :: proc(h: ^u64, v: json.Value) {
		tag := [1]u8{}
		switch x in v {
		case json.Null:
			tag[0] = 'n'
			mix(h, tag[:])
		case json.Integer:
			// numbers by value: 2 and 2.0 are one number
			tag[0] = 'f'
			mix(h, tag[:])
			f := f64(x)
			mix(h, slice.bytes_from_ptr(&f, size_of(f)))
		case json.Float:
			tag[0] = 'f'
			mix(h, tag[:])
			f := x
			mix(h, slice.bytes_from_ptr(&f, size_of(f)))
		case json.Boolean:
			tag[0] = x ? 't' : 'F'
			mix(h, tag[:])
		case json.String:
			tag[0] = 's'
			mix(h, tag[:])
			n := len(x)
			mix(h, slice.bytes_from_ptr(&n, size_of(n)))
			mix(h, transmute([]u8)x)
		case json.Array:
			tag[0] = '['
			mix(h, tag[:])
			for y in x {
				walk(h, y)
			}
			tag[0] = ']'
			mix(h, tag[:])
		case json.Object:
			tag[0] = '{'
			mix(h, tag[:])
			keys := make([dynamic]string, 0, len(x), context.temp_allocator)
			for k in x {
				append(&keys, k)
			}
			slice.sort(keys[:])
			for k in keys {
				n := len(k)
				mix(h, slice.bytes_from_ptr(&n, size_of(n)))
				mix(h, transmute([]u8)k)
				walk(h, x[k])
			}
			tag[0] = '}'
			mix(h, tag[:])
		}
	}
	walk(&h, v)
	return h
}

// ---- questions on the video's clock --------------------------------------------------

// Where song seconds `t` are on the video.
song_video_seconds :: proc(sc: ^Song_Clip, t: f64) -> f64 {
	return sc.song.start + t
}

// The song's notes that start a sound: one onset per start time (song
// seconds), its strength the loudest velocity there relative to the
// song's loudest: what onsets of its samples would find, exactly.
song_onsets :: proc(sc: ^Song_Clip, allocator := context.allocator) -> (r: oanalyze.Onsets) {
	r.onsets = make([dynamic]oanalyze.Onset, allocator)
	s := &sc.song
	loudest: f32
	for i in s.by_time {
		loudest = max(loudest, s.notes.velocity[i])
	}
	for i in s.by_time {
		t := f32(s.notes.time[i])
		v := s.notes.velocity[i] / max(loudest, 1e-6)
		if n := len(r.onsets); n > 0 && abs(r.onsets[n - 1].time - t) < 0.5e-3 {
			r.onsets[n - 1].strength = max(r.onsets[n - 1].strength, v)
			continue
		}
		append(&r.onsets, oanalyze.Onset{t, v})
	}
	if len(s.sections) > 0 {
		r.bpm = f32(s.sections[0].bpm0)
	}
	return
}

// The song's beat times (song seconds) to its end, every beat of its tempo
// map (temp memory).
song_beats :: proc(sc: ^Song_Clip) -> []f64 {
	s := &sc.song
	out := make([dynamic]f64, context.temp_allocator)
	total := osong.total_beats(s)
	for b := 0.0; b < total - 1e-9; b += 1 {
		append(&out, otempo.seconds_from_beat(&s.tempo, b))
	}
	return out[:]
}

// A note sounding at a moment of a song: its part, what it plays (a pad
// name or a pitch), where it started (song seconds), and whether it is
// still held (else its release rings).
Sounding_Note :: struct {
	part:     string,
	note:     string,
	time:     f64,
	velocity: f32,
	held:     bool,
}

// The notes sounding at song seconds `t`, by track (temp memory).
song_notes_at :: proc(sc: ^Song_Clip, t: f64) -> []Sounding_Note {
	s := &sc.song
	out := make([dynamic]Sounding_Note, context.temp_allocator)
	for tr in s.tracks {
		kind := s.devices[tr.instrument]
		p := s.params[tr.instrument]
		for i in tr.notes.first ..< tr.notes.first + tr.notes.count {
			n := orender.note_from_row(s, int(i))
			if n.kind != .Attack {
				continue // made at compose: it sounds as the played note's tail
			}
			env := odevice.Voice_Env{bank = &sc.music.bank}
			if n.time <= t && t < n.time + odevice.note_tail(kind, &p, n, &env) {
				append(&out, Sounding_Note{s.parts[tr.part], note_name(s, n.pad, n.pitch), n.time, n.velocity, t < n.time + n.duration})
			}
		}
	}
	return out[:]
}

// A note as odawg names it: a drum pad ("kick") or a pitch ("A2").
note_name :: proc(s: ^osong.Song, pad: u32, pitch: f32) -> string {
	if pad != 0 {
		return osong.pad_name(s, pad)
	}
	return otheory.string_from_pitch(pitch)
}

// Where song seconds `t` are in the song's form (false outside it).
song_place :: proc(sc: ^Song_Clip, t: f64) -> (osong.Place, bool) {
	return osong.place_from_seconds(&sc.song, t)
}

// How far song seconds `t` are from the song's half-beat grid ("8n" from
// its section's start), and how long a beat lasts there: where a sound
// over the song belongs. Not ok where the song has no beat: a section no
// drum (a pad) plays in, where sounds go with the words, not the grid.
song_off_grid :: proc(sc: ^Song_Clip, t: f64) -> (off, beat: f64, ok: bool) {
	s := &sc.song
	beaten := false
	for sec in s.sections {
		if t < sec.start || t >= sec.stop {
			continue
		}
		for i in 0 ..< len(s.notes) {
			n := s.notes[i]
			beaten ||= n.pad != 0 && n.time >= sec.start && n.time < sec.stop
		}
	}
	if !beaten {
		return
	}
	snapped := osong.seconds_snapped(s, t, "8n") or_return
	b := otempo.beat_from_seconds(&s.tempo, t)
	return t - snapped, 60 / otempo.bpm_from_beat(&s.tempo, b), true
}

// ---- a song's render, and the tables read from it -----------------------------------

// Samples a render segment covers: whole peak buckets, so none straddles
// two segments. Long enough that the exact seek starting each run (its
// effects' memory, seconds) costs little against it; short enough that the
// segment at a jump lands in well under a second.
SONG_SEGMENT :: 16 * MIX_RATE
// Samples a render peak covers (min and max, the lanes' level 0).
SONG_BUCKET :: 256

Segment_State :: enum u8 {
	Todo,
	Taken, // a renderer is making it
	Done,
}

// A song's render: what it sounds like, made once and kept. Its mix as its
// master puts it out (16-bit stereo interleaved) and, per bucket, the
// peaks of the mix and of each part (row 0 the mix, row p + 1 part p: what
// lanes draw; the parts' sound itself is not kept). It is made a segment
// at a time, each from an exact seek, so any segment can be made first:
// `state` is per segment (Segment_State, atomic), `left` how many are not
// done (atomic). Memory once something wants it (song_render_want), heap.
Song_Render :: struct {
	samples:   []i16,
	peaks:     [][2]i8,
	buckets:   int, // per row of peaks
	frames:    int,
	state:     []u8,
	left:      int,
	wanted:    bool, // the renderers make it (under the music's lock)
}

// A song's band rows (a spectrogram) are a .Bands table of its mix, a row
// every SONG_BAND_STEP samples (85 ms: a row a pixel or two across a whole
// song), filled from its render like any table.
SONG_BAND_STEP :: 4096
// Values a band row holds: odawg's third-octave bands (render.BAND_HZ).
BAND_COUNT :: len(orender.BAND_HZ)

song_bands :: proc(sc: ^Song_Clip) -> ^Song_Table {
	return song_table(sc, .Bands, SONG_BAND_STEP, 1)
}

// A table of a song's mix (a frame's spectrum or energy): odawg's rows,
// one table per kind and step, shared by every script state and worker,
// read from the render: a row is filled once the render holds its window.
Song_Table :: struct {
	table:    orender.Table,
	lock:     sync.Mutex, // held while rows are filled
	filled:   []u8, // per step: 1 once filled (atomic); heap memory
	complete: bool, // atomic: every row is filled
}

// Song `sc`'s mix table of `kind`, a row every `step_num / step_den`
// samples (a video frame: MIX_RATE / fps), made on first ask with the rows
// the render already holds.
song_table :: proc(sc: ^Song_Clip, kind: orender.Table_Kind, step_num, step_den: int, size := 0, shape := oanalyze.Window.None) -> ^Song_Table {
	mu := sc.music
	st: ^Song_Table
	{
		sync.guard(&mu.lock)
		for x in sc.tables {
			t := &x.table
			if t.kind == kind && t.step_num == step_num && t.step_den == step_den && t.size == size && t.shape == shape {
				return x
			}
		}
		st = new(Song_Table, runtime.heap_allocator())
		orender.table_init(&st.table, &sc.song, kind, -1, step_num, step_den, size, shape, runtime.heap_allocator())
		t := &st.table
		st.filled = make([]u8, t.frames * t.step_den / max(t.step_num, 1) + 1, runtime.heap_allocator())
		append(&sc.tables, st)
	}
	if sc.render.samples != nil {
		table_fill_held(sc, st, 0, sc.render.frames)
		if sync.atomic_load(&sc.render.left) == 0 {
			sync.atomic_store(&st.complete, true)
		}
	}
	return st
}

// Row `i` of a table once filled (nil: not yet, silent, or outside the
// song).
song_table_row :: proc(st: ^Song_Table, i: int) -> []f32 {
	if i < 0 || i >= len(st.filled) || sync.atomic_load(&st.filled[i]) == 0 {
		return nil
	}
	return orender.table_row(&st.table, i)
}

song_table_ready :: proc(st: ^Song_Table) -> bool {
	return sync.atomic_load(&st.complete)
}

// Asks for the song's render: its memory and segments now, the sound as
// the renderers make it (music_drain).
song_render_want :: proc(sc: ^Song_Clip) {
	mu := sc.music
	sync.guard(&mu.lock)
	rd := &sc.render
	rd.wanted = true
	if rd.samples != nil {
		return
	}
	a := runtime.heap_allocator()
	rd.frames = orender.frames_from_song(&sc.song)
	rd.samples = make([]i16, 2 * rd.frames, a)
	rd.buckets = (rd.frames + SONG_BUCKET - 1) / SONG_BUCKET
	rd.peaks = make([][2]i8, (1 + len(sc.song.parts)) * rd.buckets, a)
	segments := (rd.frames + SONG_SEGMENT - 1) / SONG_SEGMENT
	rd.state = make([]u8, segments, a)
	rd.left = segments
}

// Whether segment `g` of the render is made (its samples and peaks may be
// read).
song_segment_done :: proc(sc: ^Song_Clip, g: int) -> bool {
	rd := &sc.render
	return g >= 0 && g < len(rd.state) && sync.atomic_load(&rd.state[g]) == u8(Segment_State.Done)
}

// Whether every segment is made.
song_render_whole :: proc(sc: ^Song_Clip) -> bool {
	return sc.render.samples != nil && sync.atomic_load(&sc.render.left) == 0
}

// Whether `st` is complete; if not, the song's render is asked for (the
// renderers fill it as they go and tell the host, Music.wake).
song_table_later :: proc(sc: ^Song_Clip, st: ^Song_Table) -> bool {
	if song_table_ready(st) {
		return true
	}
	song_render_want(sc)
	return false
}

// Has the song's render made now (the renderers on every core, this thread
// waiting) and `st` filled: what a command reading the whole song does.
song_table_build :: proc(sc: ^Song_Clip, st: ^Song_Table) {
	if song_table_ready(st) {
		return
	}
	song_render_want(sc)
	mu := sc.music
	sync.guard(&mu.lock)
	music_start(mu)
	for sync.atomic_load(&sc.render.left) > 0 {
		sync.cond_wait(&mu.landing, &mu.lock)
	}
}

// Makes the song's render from segment `g` (taken): one engine from an
// exact seek, a block at a time, the mix into the render and every
// bucket's peaks (the mix's and each part's, from the block's stems), each
// segment landed as it is made; on into the next while nobody has taken it
// (no seek again: the pre-roll is paid once a run).
@(private = "file")
render_run :: proc(sc: ^Song_Clip, g: int) {
	mu := sc.music
	song_clip_load(sc)
	run: Song_Run
	if !orender.engine_init(&run.engine, &sc.song) {
		return
	}
	defer orender.engine_destroy(&run.engine)
	orender.engine_seek(&run.engine, i64(g * SONG_SEGMENT), true)
	parts := len(sc.song.parts)
	BLOCK :: orender.BLOCK
	run.buf = make([]f32, 2 * BLOCK * (1 + parts), context.temp_allocator)
	run.stems = make([][2][]f32, parts, context.temp_allocator)
	for g := g; ; g += 1 {
		render_segment(sc, &run, g)
		sync.guard(&mu.lock)
		if mu.stopping || g + 1 >= len(sc.render.state) || sc.render.state[g + 1] != u8(Segment_State.Todo) {
			break
		}
		sc.render.state[g + 1] = u8(Segment_State.Taken)
	}
}

// A run: its engine, a block of the mix and of each part's stem. Temp
// memory.
@(private = "file")
Song_Run :: struct {
	engine: orender.Engine,
	buf:    []f32,
	stems:  [][2][]f32,
}

// The run's next `n` samples (at most a block): the mix and the stems into
// its block. Returns the mix.
@(private = "file")
run_block :: proc(run: ^Song_Run, n: int) -> (l, r: []f32) {
	BLOCK :: orender.BLOCK
	l, r = run.buf[:n], run.buf[BLOCK:][:n]
	for &st, p in run.stems {
		st = {run.buf[2 * BLOCK * (p + 1):][:n], run.buf[2 * BLOCK * (p + 1) + BLOCK:][:n]}
	}
	orender.engine_process(&run.engine, l, r, run.stems)
	return
}

// Segment `g` from the run (at its start), then landed: marked done and
// the mix tables' rows the render now holds filled.
@(private = "file")
render_segment :: proc(sc: ^Song_Clip, run: ^Song_Run, g: int) {
	rd := &sc.render
	from := g * SONG_SEGMENT
	to := min(from + SONG_SEGMENT, rd.frames)
	BLOCK :: orender.BLOCK
	// Eight samples a step, the rest one at a time.
	peak :: proc(l, r: []f32) -> [2]i8 {
		V :: #simd[8]f32
		vlo, vhi: V
		lo, hi: f32
		for side in ([2][]f32{l, r}) {
			i := 0
			for ; i + 8 <= len(side); i += 8 {
				v := intrinsics.unaligned_load((^V)(raw_data(side[i:])))
				vlo, vhi = simd.min(vlo, v), simd.max(vhi, v)
			}
			for x in side[i:] {
				lo, hi = min(lo, x), max(hi, x)
			}
		}
		lo, hi = min(lo, simd.reduce_min(vlo)), max(hi, simd.reduce_max(vhi))
		return {i8(clamp(lo, -1, 1) * 127), i8(clamp(hi, -1, 1) * 127)}
	}
	#no_bounds_check for at := from; at < to; at += BLOCK {
		n := min(BLOCK, to - at)
		l, r := run_block(run, n)
		out := rd.samples[2 * at:][:2 * n]
		for i in 0 ..< n {
			out[2 * i] = i16(clamp(l[i], -1, 1) * 32767)
			out[2 * i + 1] = i16(clamp(r[i], -1, 1) * 32767)
		}
		for k := 0; k < n; k += SONG_BUCKET {
			b := (at + k) / SONG_BUCKET
			z := min(k + SONG_BUCKET, n)
			rd.peaks[b] = peak(l[k:z], r[k:z])
			for st, p in run.stems {
				rd.peaks[(p + 1) * rd.buckets + b] = peak(st[0][k:z], st[1][k:z])
			}
		}
	}
	sync.atomic_store(&rd.state[g], u8(Segment_State.Done))
	mu := sc.music
	tables: []^Song_Table
	{
		sync.guard(&mu.lock)
		tables = slice.clone(sc.tables[:], context.temp_allocator)
	}
	for st in tables {
		table_fill_held(sc, st, from, to)
	}
	if sync.atomic_sub(&rd.left, 1) == 1 {
		for st in tables {
			sync.atomic_store(&st.complete, true)
		}
		sync.atomic_add(&mu.whole, 1)
	}
	sync.atomic_add(&mu.landed, 1)
	sync.mutex_lock(&mu.lock)
	sync.cond_broadcast(&mu.landing)
	sync.mutex_unlock(&mu.lock)
	if mu.wake != nil {
		mu.wake(mu.wake_data)
	}
}

// Fills `st`'s rows near `[from, to)` whose whole window the render now
// holds, from the render.
@(private = "file")
table_fill_held :: proc(sc: ^Song_Clip, st: ^Song_Table, from, to: int) {
	rd := &sc.render
	t := &st.table
	row := orender.TABLE_KINDS[t.kind]
	window := row.window(t)
	sync.guard(&st.lock)
	buf := make([]f32, 2 * window, context.temp_allocator)
	first := (max(from - window + 1, 0) * t.step_den + t.step_num - 1) / max(t.step_num, 1)
	rows: for step := first; step < len(st.filled); step += 1 {
		start := orender.row_start(t, step)
		if start >= to {
			break
		}
		if st.filled[step] != 0 {
			continue
		}
		end := min(start + window, rd.frames)
		for g in start / SONG_SEGMENT ..= max(end - 1, start) / SONG_SEGMENT {
			if !song_segment_done(sc, g) {
				continue rows
			}
		}
		if dst := orender.table_row(t, step); dst != nil {
			// a window running past the song reads nothing: the kind's
			// own silence (bands at the floor, not 0 dB)
			k := 0 if row.whole && start + window > t.frames else end - start
			l, r := buf[:k], buf[window:][:k]
			for i in 0 ..< k {
				l[i] = f32(rd.samples[2 * (start + i)]) / 32767
				r[i] = f32(rd.samples[2 * (start + i) + 1]) / 32767
			}
			row.fill(t, dst, l, r)
		}
		sync.atomic_store(&st.filled[step], 1)
	}
}

// Whether filling `rows` rows for each of `frames` frames alone makes less
// sound than the render: each fill renders its rows' windows and the
// pre-roll before them (an exact seek). A render already made costs none.
song_table_rows_cheaper :: proc(sc: ^Song_Clip, st: ^Song_Table, frames, rows: int) -> bool {
	if song_table_ready(st) || song_render_whole(sc) {
		return false
	}
	t := &st.table
	window := orender.TABLE_KINDS[t.kind].window(t)
	preroll := int(orender.preroll_from_song(&sc.song) * MIX_RATE)
	each := orender.row_start(t, max(rows, 1)) + window + preroll
	return frames * each < t.frames
}

// Fills steps `first ..= last` of `st` alone (a command drawing a few
// frames): renders only the samples they read, from an exact seek, instead
// of the whole song. Steps already filled are left.
song_table_fill_rows :: proc(sc: ^Song_Clip, st: ^Song_Table, first, last: int) {
	if song_table_ready(st) || last < first {
		return
	}
	sync.guard(&st.lock)
	t := &st.table
	lo, hi := max(first, 0), min(last, len(st.filled) - 1)
	for lo <= hi && st.filled[lo] != 0 {
		lo += 1
	}
	for hi >= lo && st.filled[hi] != 0 {
		hi -= 1
	}
	if lo > hi {
		return
	}
	row := orender.TABLE_KINDS[t.kind]
	window := row.window(t)
	from := orender.row_start(t, lo)
	to := min(orender.row_start(t, hi) + window, t.frames)
	if to <= from {
		return
	}
	song_clip_load(sc)
	buf := make([]f32, 2 * (to - from), context.temp_allocator)
	l, r := buf[:to - from], buf[to - from:]
	orender.export_into(&sc.song, {from = f64(from) / MIX_RATE, to = f64(to) / MIX_RATE}, {l, r})
	for step in lo ..= hi {
		out := orender.table_row(t, step)
		start := orender.row_start(t, step)
		// a window running past the song reads nothing: the kind's own
		// silence (as the render does)
		if out != nil {
			a, z := start - from, min(start + window, to) - from
			if row.whole && start + window > t.frames {
				z = a
			}
			row.fill(t, out, l[a:z], r[a:z])
		}
		sync.atomic_store(&st.filled[step], 1)
	}
}

// Starts the renderers on the renders wanted so far, unless they run (they
// take what is wanted meanwhile too). The host drains once it has asked
// for everything a pass needs (a frame, the lanes).
music_drain :: proc(m: ^Media) {
	if m == nil || m.music == nil {
		return
	}
	sync.guard(&m.music.lock)
	music_start(m.music)
}

// The renderers, one per core but two (the window and the worker keep
// theirs), at low priority: they are background work. Started under the
// music's lock.
@(private = "file")
music_start :: proc(mu: ^Music) {
	if mu.running > 0 || mu.stopping || next_segment(mu).song == nil {
		return
	}
	for t in mu.renderers {
		thread.join(t)
		thread.destroy(t)
	}
	clear(&mu.renderers)
	for _ in 0 ..< max(os.get_processor_core_count() - 2, 1) {
		mu.running += 1
		append(&mu.renderers, thread.create_and_start_with_data(mu, music_renderer, priority = .Low, name = "song renderer"))
	}
}

// Whether renders wait for music_drain.
music_queued :: proc(m: ^Media) -> bool {
	if m == nil || m.music == nil {
		return false
	}
	mu := m.music
	sync.guard(&mu.lock)
	return mu.running == 0 && next_segment(mu).song != nil
}

// The video sample the renderers make first (the preview's playhead): each
// song's segment nearest it on the song's own clock.
music_focus :: proc(m: ^Media, sample: int) {
	if m != nil && m.music != nil {
		sync.atomic_store(&m.music.focus, i64(sample))
	}
}

// A segment to make, and whose.
@(private = "file")
Segment_Ref :: struct {
	song:    ^Song_Clip,
	segment: int,
}

// The segment nearest the focus of every render wanted, among the media's
// current songs (not retired ones); under the music's lock.
@(private = "file")
next_segment :: proc(mu: ^Music) -> (best: Segment_Ref) {
	focus := int(sync.atomic_load(&mu.focus))
	nearest := max(int)
	for _, sc in mu.songs {
		rd := &sc.render
		if !rd.wanted || sync.atomic_load(&rd.left) == 0 {
			continue
		}
		at := focus - int(math.round(sc.song.start * MIX_RATE))
		for x, g in rd.state {
			if x != u8(Segment_State.Todo) {
				continue
			}
			a, z := g * SONG_SEGMENT, (g + 1) * SONG_SEGMENT
			d := at < a ? a - at : (at >= z ? at - z + 1 : 0)
			// one a renderer is running into comes after the rest
			if g > 0 && rd.state[g - 1] == u8(Segment_State.Taken) {
				d += 1 << 40
			}
			if d < nearest {
				best, nearest = {sc, g}, d
			}
		}
	}
	return
}

// A renderer: the segment nearest the focus, one at a time, until none is
// left.
@(private = "file")
music_renderer :: proc(data: rawptr) {
	mu := (^Music)(data)
	for {
		sync.mutex_lock(&mu.lock)
		next := next_segment(mu) if !mu.stopping else {}
		if next.song == nil {
			mu.running -= 1
			sync.mutex_unlock(&mu.lock)
			return
		}
		next.song.render.state[next.segment] = u8(Segment_State.Taken)
		sync.mutex_unlock(&mu.lock)
		render_run(next.song, next.segment)
		free_all(context.temp_allocator)
	}
}

// Segments made since the last call.
music_landed :: proc(m: ^Media) -> int {
	if m == nil || m.music == nil {
		return 0
	}
	return sync.atomic_exchange(&m.music.landed, 0)
}

// Songs whose renders became whole since the last call.
music_whole :: proc(m: ^Media) -> int {
	if m == nil || m.music == nil {
		return 0
	}
	return sync.atomic_exchange(&m.music.whole, 0)
}

// Songs whose sample sets loaded since the last call.
music_banks_landed :: proc(m: ^Media) -> int {
	if m == nil || m.music == nil {
		return 0
	}
	return sync.atomic_exchange(&m.music.banks, 0)
}

// What pinning a source wrote: its pins file (in the media folder), how
// many files it pins and how many are new.
Source_Pins :: struct {
	source:  string `json:"source"`,
	licence: string `json:"licence"`,
	path:    string `json:"path"`,
	total:   int    `json:"total"`,
	added:   int    `json:"added"`,
}

// Pins what the media's songs play from their sources: each song's sample
// sets loaded with pinning on (a file not pinned yet is fetched over https
// and trusted as it comes), then each source's pins file written beside
// the song with what was fetched merged in. Odawg refuses a pins file
// outside the media folder (a finding on the song). Temp memory.
music_pin :: proc(m: ^Media) -> []Source_Pins {
	out := make([dynamic]Source_Pins, context.temp_allocator)
	if m == nil || m.music == nil {
		return nil
	}
	mu := m.music
	mu.pinning = true
	defer mu.pinning = false
	for sc in media_songs(m) {
		song_clip_load(sc)
		host := oassets.Bank_Host{root = m.dir, pinning = true}
		updates: []oassets.Pin_Update
		{
			sync.guard(&mu.bank_lock)
			updates = oassets.pins_update(&mu.bank, &sc.spec, &host, &sc.findings, context.temp_allocator)
		}
		for u in updates {
			seen := false
			for x in out {
				seen ||= x.path == u.pins_path
			}
			if seen {
				continue
			}
			path := oassets.host_path(&host, u.pins_path)
			if err := os.write_entire_file(path, transmute([]u8)u.text); err != nil {
				obase.report(&sc.findings, "write_failed", .Error, u.source, "can't write %s: %v", path, err)
				continue
			}
			append(&out, Source_Pins{u.source, u.licence, u.pins_path, u.total, u.added})
		}
	}
	return out[:]
}

// Who the renderers tell when segments land (the preview's worker).
music_set_wake :: proc(m: ^Media, wake: proc(data: rawptr), data: rawptr) {
	if m == nil || m.music == nil {
		return
	}
	sync.guard(&m.music.lock)
	m.music.wake, m.music.wake_data = wake, data
}
