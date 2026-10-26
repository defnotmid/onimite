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
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import oanalyze "deps:odawg/analyze"
import oassets "deps:odawg/assets"
import obase "deps:odawg/base"
import ocheck "deps:odawg/check"
import odevice "deps:odawg/device"
import orender "deps:odawg/render"
import osong "deps:odawg/song"
import ospec "deps:odawg/spec"

// Songs: odawg's composed songs (`song{}`, `sound{}` in scripts) as media
// sounds a track plays by name, like a clip. A song is data (its form, its
// tracks and every note). Its sound is made once, when something needs all
// of it (a lane's peaks, a table a frame reads): its render, kept with it,
// made in one pass, odawg's stream on the host's background pool;
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
	// Where songs render: the host's background pool (music_set_pool; nil:
	// on their caller) and odawg's engine's view of it. The driver renders
	// the wanted songs one after another (started by music_drain, ending
	// when none is left); whether it runs, whether it must stop (the media
	// goes), the video sample whose song it renders first (atomic), spans
	// landed and songs whole since the host looked (atomic), what a
	// waiting command hears a span land on, and who they tell.
	pool:      ^thread.Pool,
	work:      Pool_Work,
	driver:    Pool_Job,
	running:   bool,
	stopping:  bool,
	focus:     i64,
	landed:    int,
	whole:     int,
	landing:   sync.Cond,
	// The media folder: where songs' own files are (their sets, SFZ and
	// style files), under bank_lock.
	host_root: string,
	// Making and loading songs fetches what their sources serve that isn't
	// pinned yet, and keeps its pin (music_set_pinning before the script
	// loads; music_pin writes the pins; `onimite audio pin`).
	pinning:   bool,
	// Songs whose sample sets loaded since the host looked (atomic): a mix
	// made before has them silent.
	banks:     int,
	wake:      proc(data: rawptr),
	wake_data: rawptr,
	// What songs' renders measure as they are made (music_set_measures):
	// only what the command reads, since a meter costs as much as a song.
	measures:  bit_set[Song_Measure],
}

Song_Measure :: enum u8 {
	Mix, // as odawg's checks measure the mix (`inspect`'s song check)
	Parts, // each part's loudness meter and peak (`audio parts`)
}

// What the renders made from now on measure; set before they start.
music_set_measures :: proc(m: ^Media, measures: bit_set[Song_Measure]) {
	sync.guard(&m.music.lock)
	m.music.measures = measures
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
	// What loading its samples found (files its notes reach that can't be
	// had: not pinned, offline). The load comes on first use, after the
	// script's report, so these are read once `loaded` is set (heap).
	load_findings: obase.Findings,
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
	mu.driver.procedure = music_driver
	pool_work_init(&mu.work, nil)
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
	// the driver finishes the song it is on
	sync.mutex_lock(&mu.lock)
	mu.stopping = true
	sync.mutex_unlock(&mu.lock)
	pool_join(&mu.driver)
	pool_work_destroy(&mu.work)
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

// Loads what one song plays that isn't in the bank yet (once), then tells
// the host (the preview's worker) that it is in.
song_clip_load :: proc(sc: ^Song_Clip) {
	if sc == nil || sync.atomic_load(&sc.loaded) || !sc.ok || sc.music == nil {
		return
	}
	mu := sc.music
	{
		sync.guard(&mu.bank_lock)
		if sync.atomic_load(&sc.loaded) {
			return
		}
		context.allocator = runtime.heap_allocator()
		host := oassets.Bank_Host{root = mu.host_root, pinning = mu.pinning}
		sc.load_findings = make(obase.Findings)
		oassets.bank_load(&mu.bank, sc.needs[:], &sc.load_findings, oassets.progress_stderr, &host)
		sync.atomic_store(&sc.loaded, true)
		sync.atomic_add(&mu.banks, 1)
	}
	if mu.wake != nil {
		mu.wake(mu.wake_data)
	}
}

// Whether a song's sample sets are still to load (fetched on first use):
// until then its notes that reach them are silent. A set that can't be had
// counts as loaded (its finding says so).
song_clip_loading :: proc(sc: ^Song_Clip) -> bool {
	return sc != nil && sc.ok && !sync.atomic_load(&sc.loaded)
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
	for f in sc.load_findings {
		delete(f.path, a)
		delete(f.message, a)
	}
	delete(sc.load_findings)
	delete(sc.render.samples, a)
	delete(sc.render.peaks, a)
	delete(sc.render.state, a)
	for &m in sc.render.part_meters {
		oanalyze.meter_destroy(&m)
	}
	delete(sc.render.part_meters, a)
	delete(sc.render.part_peaks, a)
	delete(sc.render.stems, a)
	if .Mix in sc.render.measured {
		// what measuring_destroy leaves: the per-part slices, made with `a`
		ocheck.measuring_destroy(&sc.render.measuring)
		delete(sc.render.measuring.peak_steps, a)
		delete(sc.render.measuring.parts, a)
	}
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
	host := oassets.Bank_Host{root = m.dir, pinning = mu.pinning}
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

// ---- a song's render, and the tables read from it -----------------------------------

// Samples a render segment covers: what lands at once (the tables' rows it
// completes filled, the host told), whole peak buckets so none straddles
// two segments.
SONG_SEGMENT :: 4 * MIX_RATE
// Samples a render peak covers (min and max, the lanes' level 0).
SONG_BUCKET :: 256

Segment_State :: enum u8 {
	Todo,
	Done,
}

// A song's render: what it sounds like, made once and kept. Its mix as its
// master puts it out (16-bit stereo interleaved) and, per bucket, the
// peaks of the mix and of each part (row 0 the mix, row p + 1 part p: what
// lanes draw; the parts' sound itself is not kept). It is made in one
// pass from the start, landing a segment at a time: `state` is per segment
// (Segment_State, atomic), `left` how many are not done (atomic). Memory
// once something wants it (song_render_want), heap.
Song_Render :: struct {
	samples:   []i16,
	peaks:     [][2]i8,
	buckets:   int, // per row of peaks
	frames:    int,
	state:     []u8,
	left:      int,
	wanted:    bool, // the driver makes it (under the music's lock)
	taken:     bool, // the driver is making it, or made it (under the music's lock)
	// What the render measured as it was made, before it was rounded to 16
	// bits: each part's loudness meter and peak (`audio parts`), and the mix
	// and its stems as odawg's checks measure them; read once the render is
	// whole.
	part_meters: []oanalyze.Meter,
	part_peaks:  []f32,
	measuring:   ocheck.Measuring,
	measured:    bit_set[Song_Measure],
	// A chunk's stems cut to the samples it keeps (one row a part), as the
	// checks are handed them.
	stems:       [][2][]f32,
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
// the driver makes it (music_drain).
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
	rd.measured = mu.measures
	if .Parts in rd.measured {
		rd.part_meters = make([]oanalyze.Meter, len(sc.song.parts), a)
		rd.part_peaks = make([]f32, len(sc.song.parts), a)
		for &m in rd.part_meters {
			oanalyze.meter_init(&m, orender.RATE)
		}
	}
	if .Mix in rd.measured {
		ocheck.measuring_init(&rd.measuring, &sc.song, a)
		rd.stems = make([][2][]f32, len(sc.song.parts), a)
	}
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
// driver fills it as it goes and tells the host, Music.wake).
song_table_later :: proc(sc: ^Song_Clip, st: ^Song_Table) -> bool {
	if song_table_ready(st) {
		return true
	}
	song_render_want(sc)
	return false
}

// Has the song's render made now (the driver on the background pool, or
// here without one; this thread waiting) and `st` filled: what a command
// reading the whole song does.
song_table_build :: proc(sc: ^Song_Clip, st: ^Song_Table) {
	if song_table_ready(st) {
		return
	}
	song_render_build(sc)
}

// Has the song's render made now, whole, with its measures (this thread
// waiting).
song_render_build :: proc(sc: ^Song_Clip) {
	song_render_want(sc)
	mu := sc.music
	music_start(mu)
	sync.guard(&mu.lock)
	for !mu.stopping && sync.atomic_load(&sc.render.left) > 0 {
		sync.cond_wait(&mu.landing, &mu.lock)
	}
}

// Makes the song's render: odawg's stream from the start with the parts'
// stems, its nodes on the background pool, each chunk landing in order
// (song_take). Whatever the stream leaves (the render rounds the song's
// length up) lands as silence.
@(private = "file")
render_song :: proc(sc: ^Song_Clip) {
	mu := sc.music
	song_clip_load(sc)
	orender.export_song(&sc.song, {stems = true, pool = &mu.work.work_pool}, {data = sc, take = song_take})
	land_through(sc, sc.render.frames)
}

// A chunk of the stream from sample `at`: into the render (16-bit), its
// buckets' peaks (the mix's and each part's), then what it completes lands.
@(private = "file")
song_take :: proc(data: rawptr, at: i64, l, r: []f32, stems: [][2][]f32) {
	sc := (^Song_Clip)(data)
	rd := &sc.render
	from := int(at)
	n := min(len(l), rd.frames - from)
	if n <= 0 {
		return
	}
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
	// a bucket a chunk starts inside of keeps what the last chunk found
	merge :: proc(p: ^[2]i8, x: [2]i8, inside: bool) {
		p^ = {min(p[0], x[0]), max(p[1], x[1])} if inside else x
	}
	parts := stems[:min(len(stems), len(sc.song.parts))]
	// measured in float, in order (the sink is called one chunk at a time)
	if .Mix in rd.measured {
		// the mix and the stems: the checks' per-part rules (a part silent,
		// one buried under the mix) read the stems
		for st, p in parts {
			rd.stems[p] = {st[0][:n], st[1][:n]}
		}
		ocheck.measuring_push(&rd.measuring, l[:n], r[:n], rd.stems[:len(parts)])
	}
	if .Parts in rd.measured {
		for st, p in parts {
			oanalyze.meter_push(&rd.part_meters[p], st[0][:n], st[1][:n])
			rd.part_peaks[p] = max(rd.part_peaks[p], orender.peak_from_samples(st[0][:n], st[1][:n]))
		}
	}
	out := rd.samples[2 * from:][:2 * n]
	#no_bounds_check {
		for i in 0 ..< n {
			out[2 * i] = i16(clamp(l[i], -1, 1) * 32767)
			out[2 * i + 1] = i16(clamp(r[i], -1, 1) * 32767)
		}
		for k := 0; k < n; {
			b := (from + k) / SONG_BUCKET
			z := min((b + 1) * SONG_BUCKET - from, n)
			inside := (from + k) % SONG_BUCKET != 0
			merge(&rd.peaks[b], peak(l[k:z], r[k:z]), inside)
			for st, p in parts {
				merge(&rd.peaks[(p + 1) * rd.buckets + b], peak(st[0][k:z], st[1][k:z]), inside)
			}
			k = z
		}
	}
	land_through(sc, from + n)
}

// Lands the segments the render now holds up to sample `upto`: marked
// done, the mix tables' rows they complete filled, the host told.
@(private = "file")
land_through :: proc(sc: ^Song_Clip, upto: int) {
	rd := &sc.render
	mu := sc.music
	for g in 0 ..< len(rd.state) {
		from := g * SONG_SEGMENT
		to := min(from + SONG_SEGMENT, rd.frames)
		if to > upto {
			break
		}
		if sync.atomic_load(&rd.state[g]) == u8(Segment_State.Done) {
			continue
		}
		sync.atomic_store(&rd.state[g], u8(Segment_State.Done))
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
	// the driver may be using the music's own view of the pool
	work: Pool_Work
	pool_work_init(&work, sc.music.pool)
	defer pool_work_destroy(&work)
	orender.export_into(&sc.song, {from = f64(from) / MIX_RATE, to = f64(to) / MIX_RATE, pool = &work.work_pool}, {l, r})
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

// Starts the driver on the renders wanted so far, unless it runs (it
// takes what is wanted meanwhile too). The host drains once it has asked
// for everything a pass needs (a frame, the lanes).
music_drain :: proc(m: ^Media) {
	if m == nil || m.music == nil {
		return
	}
	music_start(m.music)
}

// The driver, on the background pool, or here (returning when every
// wanted song is made) when there is none.
@(private = "file")
music_start :: proc(mu: ^Music) {
	sync.mutex_lock(&mu.lock)
	if mu.running || mu.stopping || next_song(mu) == nil {
		sync.mutex_unlock(&mu.lock)
		return
	}
	mu.running = true
	sync.mutex_unlock(&mu.lock)
	// the last run may still be returning from its procedure
	pool_join(&mu.driver)
	pool_spawn(mu.pool, &mu.driver, runtime.heap_allocator())
}

// The pool the media's songs render on (nil: their caller), lent by the
// host; set while no song renders.
music_set_pool :: proc(m: ^Media, pool: ^thread.Pool) {
	mu := m.music
	pool_join(&mu.driver)
	pool_work_destroy(&mu.work)
	mu.pool = pool
	pool_work_init(&mu.work, pool)
}

// Whether renders wait for music_drain.
music_queued :: proc(m: ^Media) -> bool {
	if m == nil || m.music == nil {
		return false
	}
	mu := m.music
	sync.guard(&mu.lock)
	return !mu.running && next_song(mu) != nil
}

// The video sample the driver makes first (the preview's playhead): the
// song sounding there, else the nearest.
music_focus :: proc(m: ^Media, sample: int) {
	if m != nil && m.music != nil {
		sync.atomic_store(&m.music.focus, i64(sample))
	}
}

// The wanted song not yet taken nearest the focus, among the media's
// current songs (not retired ones); under the music's lock.
@(private = "file")
next_song :: proc(mu: ^Music) -> (best: ^Song_Clip) {
	focus := int(sync.atomic_load(&mu.focus))
	nearest := max(int)
	for _, sc in mu.songs {
		rd := &sc.render
		if !rd.wanted || rd.taken || sync.atomic_load(&rd.left) == 0 {
			continue
		}
		a := int(math.round(sc.song.start * MIX_RATE))
		z := a + rd.frames
		d := focus < a ? a - focus : (focus >= z ? focus - z + 1 : 0)
		if d < nearest {
			best, nearest = sc, d
		}
	}
	return
}

// The driver: the wanted song nearest the focus, one at a time, until none
// is left.
@(private = "file")
music_driver :: proc(job: ^Pool_Job) {
	mu := container_of(job, Music, "driver")
	for {
		sync.mutex_lock(&mu.lock)
		sc := next_song(mu) if !mu.stopping else nil
		if sc == nil {
			mu.running = false
			sync.mutex_unlock(&mu.lock)
			return
		}
		sc.render.taken = true
		sync.mutex_unlock(&mu.lock)
		// scoped: without a pool this is the caller's thread
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		render_song(sc)
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
	// Why its pins weren't written ("" when they were).
	error:   string `json:"error,omitempty"`,
}

// Pins what the media's songs play from their sources: the songs, made
// with pinning on (music_set_pinning before the script loaded: a file not
// pinned yet is fetched over https and trusted as it comes), load their
// sample sets, then each source's pins file is written beside the song
// with what was fetched merged in. Odawg refuses a pins file outside the
// media folder (a finding on the song). Temp memory.
music_pin :: proc(m: ^Media) -> []Source_Pins {
	out := make([dynamic]Source_Pins, context.temp_allocator)
	if m == nil || m.music == nil {
		return nil
	}
	mu := m.music
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
			// the pins file's folder made first (a new source's `pins/x.pins`)
			path := oassets.host_path(&host, u.pins_path)
			failed := ""
			if err := os.make_directory_all(filepath.dir(path)); err != nil && err != .Exist {
				failed = fmt.tprintf("can't make the folder for %s: %v", path, err)
			} else if err := os.write_entire_file(path, transmute([]u8)u.text); err != nil {
				failed = fmt.tprintf("can't write %s: %v", path, err)
			}
			append(&out, Source_Pins{u.source, u.licence, u.pins_path, u.total, u.added, failed})
		}
	}
	return out[:]
}

// Whether songs made from now on fetch what their sources haven't pinned
// (`onimite audio pin` only: a render plays what is pinned).
music_set_pinning :: proc(m: ^Media, on: bool) {
	if m.music != nil {
		m.music.pinning = on
	}
}

// Who the renderers tell when segments land (the preview's worker).
music_set_wake :: proc(m: ^Media, wake: proc(data: rawptr), data: rawptr) {
	if m == nil || m.music == nil {
		return
	}
	sync.guard(&m.music.lock)
	m.music.wake, m.music.wake_data = wake, data
}
