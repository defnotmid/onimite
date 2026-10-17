package onimite

import "base:runtime"
import "core:encoding/json"
import "core:hash"
import "core:math"
import "core:mem/virtual"
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
// tracks and every note); its samples are never kept: the mix, the preview
// and the analysis stream them from odawg's engine. The video's sample sets
// (what its Samplers play) are one bank, shared by its songs.

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
	// The tables waiting to be built in the background, the builder's
	// thread (building while it runs), how many landed since the host
	// looked (atomic), and who it tells.
	queue:     [dynamic]Queued_Table,
	builder:   ^thread.Thread,
	building:  bool,
	landed:    int,
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
	// Its tables (song_table): heap memory, freed with it.
	tables:   [dynamic]^Song_Table,
}

@(private)
music_init :: proc(mu: ^Music) {
	mu.songs = make(map[string]^Song_Clip)
	mu.retired = make([dynamic]^Song_Clip)
	mu.queue = make([dynamic]Queued_Table)
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
	// the builder finishes the song it is on, then finds the queue empty
	sync.mutex_lock(&mu.lock)
	clear(&mu.queue)
	sync.mutex_unlock(&mu.lock)
	if mu.builder != nil {
		thread.join(mu.builder)
		thread.destroy(mu.builder)
	}
	delete(mu.queue)
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
	oassets.bank_load(&mu.bank, sc.needs[:], &sc.findings, oassets.progress_stderr)
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

// Song `name` composed from spec `v` (`key`: its content, `value_key`):
// the media's when it already has that song, else read, its sample sets
// loaded into the video's bank, composed and kept under the name (one it
// replaces is retired). `fresh` is true when it was composed now (its
// findings are new). The song's start is the spec's (the video's clock).
media_song_put :: proc(m: ^Media, name: string, v: json.Value, key: u64) -> (sc: ^Song_Clip, fresh: bool) {
	mu := m.music
	sync.guard(&mu.lock)
	if old := mu.songs[name]; old != nil && old.key == key {
		return old, false
	}
	sc = new(Song_Clip)
	sc.key = key
	sc.music = mu
	sc.tables = make([dynamic]^Song_Table, runtime.heap_allocator())
	_ = virtual.arena_init_growing(&sc.arena)
	{
		context.allocator = virtual.arena_allocator(&sc.arena)
		sc.name = strings.clone(name)
		sc.findings = make(obase.Findings)
		if ospec.spec_from_value(v, &sc.spec, &sc.findings) {
			names := make([dynamic]string, context.temp_allocator)
			ospec.asset_names(&sc.spec, &names)
			if len(names) > 0 {
				context.allocator = runtime.heap_allocator()
				sync.guard(&mu.bank_lock)
				oassets.bank_declare(&mu.bank, names[:], &sc.findings)
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
	if old, seen := mu.songs[name]; seen {
		append(&mu.retired, old)
		mu.songs[name] = sc
	} else {
		mu.songs[strings.clone(name)] = sc
	}
	return sc, true
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
			if n.time <= t && t < n.time + odevice.note_tail(kind, &p, n) {
				append(&out, Sounding_Note{s.parts[tr.part], note_name(n.pad, n.pitch), n.time, n.velocity, t < n.time + n.duration})
			}
		}
	}
	return out[:]
}

// A note as odawg names it: a drum pad ("kick") or a pitch ("A2").
note_name :: proc(pad: odevice.Pad, pitch: f32) -> string {
	if pad != .None {
		return odevice.PAD_NAMES[pad]
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
			beaten ||= n.pad != .None && n.time >= sec.start && n.time < sec.stop
		}
	}
	if !beaten {
		return
	}
	snapped := osong.seconds_snapped(s, t, "8n") or_return
	b := otempo.beat_from_seconds(&s.tempo, t)
	return t - snapped, 60 / otempo.bpm_from_beat(&s.tempo, b), true
}

// ---- a song's tables (the analysis, the lanes) ---------------------------------------

// What is read of a song at random (a frame's spectrum or energy, a lane's
// peaks): odawg's tables of it, one per kind and step, shared by every
// script state and worker. A table is built once from one streamed export
// of the song (every core): by the first reader that needs it, or while
// the preview draws by the music's builder in the background (a frame reads
// silence until it lands and is drawn again). Nothing of the sound is kept.
Song_Table :: struct {
	table:  orender.Table,
	lock:   sync.Mutex, // held while it is built
	built:  bool, // atomic: after it, readers read without locking
	queued: bool, // waiting for the builder (under the music's lock)
	// Before it is built: the steps filled one at a time (a command drawing
	// a few frames: song_table_fill_rows), 1 each (atomic), heap memory.
	filled: []u8,
}

// A table waiting for the builder, and whose song it is.
@(private)
Queued_Table :: struct {
	clip:  ^Song_Clip,
	table: ^Song_Table,
}

// Song `sc`'s table of `kind` over `part` (-1: the mix), a row every
// `step_num / step_den` samples (a video frame: MIX_RATE / fps), made on
// first ask (not built yet: song_table_build, song_table_later).
song_table :: proc(sc: ^Song_Clip, kind: orender.Table_Kind, part: i32, step_num, step_den: int, size := 0, shape := oanalyze.Window.None) -> ^Song_Table {
	mu := sc.music
	sync.guard(&mu.lock)
	for st in sc.tables {
		t := &st.table
		if t.kind == kind && t.part == part && t.step_num == step_num && t.step_den == step_den && t.size == size && t.shape == shape {
			return st
		}
	}
	st := new(Song_Table, runtime.heap_allocator())
	orender.table_init(&st.table, &sc.song, kind, part, step_num, step_den, size, shape, runtime.heap_allocator())
	append(&sc.tables, st)
	return st
}

// Row `i` of a built table, or a row filled alone (nil: not built yet, or
// outside the song).
song_table_row :: proc(st: ^Song_Table, i: int) -> []f32 {
	if !song_table_ready(st) && !(i >= 0 && i < len(st.filled) && sync.atomic_load(&st.filled[i]) != 0) {
		return nil
	}
	return orender.table_row(&st.table, i)
}

// Whether filling `rows` rows for each of `frames` frames alone makes less
// sound than building the whole table: each fill renders its rows' windows
// and the pre-roll before them (an exact seek).
song_table_rows_cheaper :: proc(sc: ^Song_Clip, st: ^Song_Table, frames, rows: int) -> bool {
	if song_table_ready(st) {
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
	steps := t.frames * t.step_den / max(t.step_num, 1) + 1
	if len(st.filled) == 0 {
		st.filled = make([]u8, steps, runtime.heap_allocator())
	}
	lo, hi := max(first, 0), min(last, steps - 1)
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
		// a window running past the song stays silent (as the build does)
		if out != nil && !(row.whole && start + window > t.frames) {
			a, z := start - from, min(start + window, to) - from
			row.fill(t, out, l[a:z], r[a:z])
		}
		sync.atomic_store(&st.filled[step], 1)
	}
}

song_table_ready :: proc(st: ^Song_Table) -> bool {
	return sync.atomic_load(&st.built)
}

// Builds `st` now (the bank's zones the song plays first); another reader
// asking meanwhile waits for it.
song_table_build :: proc(sc: ^Song_Clip, st: ^Song_Table) {
	if song_table_ready(st) {
		return
	}
	sync.guard(&st.lock)
	if st.built {
		return
	}
	song_clip_load(sc)
	orender.tables_build(&sc.song, {&st.table})
	sync.atomic_store(&st.built, true)
}

// Whether `st` is built; if not, it is queued for the music's builder
// (started by music_drain), which tells the host (Music.wake) when it
// lands.
song_table_later :: proc(sc: ^Song_Clip, st: ^Song_Table) -> bool {
	if song_table_ready(st) {
		return true
	}
	mu := sc.music
	sync.guard(&mu.lock)
	if !st.queued {
		st.queued = true
		append(&mu.queue, Queued_Table{sc, st})
	}
	return false
}

// Starts the builder on the tables queued so far, unless it is running
// (it takes what is queued meanwhile too). The host drains once it has
// asked for everything a pass needs (a frame, the lanes), so a song's
// tables are built in one export of it, not one per request.
music_drain :: proc(m: ^Media) {
	if m == nil || m.music == nil {
		return
	}
	mu := m.music
	sync.guard(&mu.lock)
	if len(mu.queue) == 0 || mu.building {
		return
	}
	if mu.builder != nil {
		thread.join(mu.builder)
		thread.destroy(mu.builder)
	}
	mu.building = true
	mu.builder = thread.create_and_start_with_data(mu, music_builder)
}

// Whether tables wait for music_drain.
music_queued :: proc(m: ^Media) -> bool {
	if m == nil || m.music == nil {
		return false
	}
	mu := m.music
	sync.guard(&mu.lock)
	return len(mu.queue) > 0 && !mu.building
}

// The builder: the queued tables, one song at a time and all of its
// queued tables in one pass, until none is left.
@(private = "file")
music_builder :: proc(data: rawptr) {
	mu := (^Music)(data)
	for {
		sync.mutex_lock(&mu.lock)
		if len(mu.queue) == 0 {
			mu.building = false
			sync.mutex_unlock(&mu.lock)
			break
		}
		sc := mu.queue[0].clip
		mine := make([dynamic]^Song_Table, context.temp_allocator)
		for i := 0; i < len(mu.queue); {
			if mu.queue[i].clip == sc {
				append(&mine, mu.queue[i].table)
				ordered_remove(&mu.queue, i)
			} else {
				i += 1
			}
		}
		sync.mutex_unlock(&mu.lock)
		song_clip_load(sc)
		todo := make([dynamic]^orender.Table, context.temp_allocator)
		for st in mine {
			sync.mutex_lock(&st.lock)
			if !st.built {
				append(&todo, &st.table)
			}
		}
		orender.tables_build(&sc.song, todo[:])
		for st in mine {
			sync.atomic_store(&st.built, true)
			sync.mutex_unlock(&st.lock)
		}
		sync.atomic_add(&mu.landed, len(mine))
		if mu.wake != nil {
			mu.wake(mu.wake_data)
		}
		free_all(context.temp_allocator)
	}
}

// Tables built in the background since the last call.
music_landed :: proc(m: ^Media) -> int {
	if m == nil || m.music == nil {
		return 0
	}
	return sync.atomic_exchange(&m.music.landed, 0)
}

// Songs whose sample sets loaded since the last call.
music_banks_landed :: proc(m: ^Media) -> int {
	if m == nil || m.music == nil {
		return 0
	}
	return sync.atomic_exchange(&m.music.banks, 0)
}

// Who the builder tells when tables land (the preview's worker).
music_set_wake :: proc(m: ^Media, wake: proc(data: rawptr), data: rawptr) {
	if m == nil || m.music == nil {
		return
	}
	sync.guard(&m.music.lock)
	m.music.wake, m.music.wake_data = wake, data
}
