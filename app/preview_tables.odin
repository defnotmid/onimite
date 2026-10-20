package onimite_app

import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:thread"
import om "../onimite"
import odevice "deps:odawg/device"
import orender "deps:odawg/render"
import osong "deps:odawg/song"
import script "../script"

// What the render worker derives from a load for the preview's panels,
// published through the mailbox as flat tables: rows indexed by id, their
// strings in one byte arena per table (`Text_Span`s into it). The worker
// fills its own copy, copies it into the mailbox when it changes, and the UI
// copies it out when the table's sequence number moved. Copies reuse the
// destination's capacity, so a warm preview allocates nothing for them.
//
// - The Watch: one row per scene, cue, problem and media item, each with
//   what it says (worded by items.odin), a status and the frame a click
//   goes to. Problems are those seen since the last load, grouped like
//   `inspect`'s, so the rows and the status line hold still while frames
//   change.
// - The timeline: its items as a flat tree (scenes, cues, the groups of
//   tracks a bus mixes, the tracks), each a kind the UI draws its own way;
//   one lane per placed audio track and per group, and per audio clip a
//   min/max peak pyramid (level k: one pair per WAVE_BUCKET << k samples),
//   computed once per media load on the worker when it is idle; a group's
//   pyramid is its tracks' together. Any zoom reads the level whose bucket
//   is just under a pixel's samples, in O(pixels).
// - Media: the loaded media in the Watch's order, with small image
//   thumbnails as straight RGBA in a pixel arena.

Text_Span :: struct {
	offset, length: u32,
}

text_push :: proc(buf: ^[dynamic]u8, s: string) -> Text_Span {
	span := Text_Span{u32(len(buf)), u32(len(s))}
	append(buf, s)
	return span
}

text_of :: proc(buf: []u8, span: Text_Span) -> string {
	return string(buf[span.offset:][:span.length])
}

// Copies `src` into `dst`, reusing its capacity.
table_copy :: proc(dst: ^[dynamic]$T, src: []T) {
	resize(dst, len(src))
	copy(dst[:], src)
}

// ---- the timeline ----------------------------------------------------------------------

// A scene of the loaded script on the video's frames.
Preview_Scene :: struct {
	name:        Text_Span,
	start_frame: int,
	end_frame:   int,
}

// The loaded video's size, rate and length, and its scenes in order (all
// zero when its timeline does not resolve).
Preview_Timeline :: struct {
	width, height: int,
	fps:           int,
	frames:        int,
	scenes:        [dynamic]Preview_Scene,
	text:          [dynamic]u8,
}

preview_timeline_destroy :: proc(t: ^Preview_Timeline) {
	delete(t.scenes)
	delete(t.text)
}

preview_timeline_copy :: proc(dst: ^Preview_Timeline, src: ^Preview_Timeline) {
	dst.width, dst.height, dst.fps, dst.frames = src.width, src.height, src.fps, src.frames
	table_copy(&dst.scenes, src.scenes[:])
	table_copy(&dst.text, src.text[:])
}

// Fills `t` from a load: the video and its resolved timeline (nil: it
// did not resolve).
preview_timeline_build :: proc(t: ^Preview_Timeline, v: ^om.Video, tl: ^om.Timeline) {
	clear(&t.scenes)
	clear(&t.text)
	t.width, t.height, t.fps, t.frames = 0, 0, 0, 0
	if tl == nil {
		return
	}
	t.width, t.height, t.fps, t.frames = v.width, v.height, v.fps, tl.duration_frames
	for s in tl.scenes {
		append(&t.scenes, Preview_Scene{text_push(&t.text, s.scene.name), s.start_frame, s.end_frame})
	}
}

scene_name :: proc(t: ^Preview_Timeline, s: Preview_Scene) -> string {
	return text_of(t.text[:], s.name)
}

// ---- waveforms --------------------------------------------------------------------------

WAVE_BUCKET :: om.SONG_BUCKET // mix samples per peak pair at level 0 (a song render's peaks are these)
WAVE_LEVELS :: 20
// Level-0 buckets filled per idle step (about 4 M samples, a few ms).
WAVE_CHUNK :: 16384

// One pyramid in `Wave_Table.peaks`; `levels == 0` until its level 0 has
// anything, `complete` once level 0 is final (a song's grows as its render
// is made).
Wave_Clip :: struct {
	frames:   int,
	levels:   int,
	complete: bool,
	offset:   [WAVE_LEVELS]u32,
	count:    [WAVE_LEVELS]u32,
}

// A stretch of a lane where its source sounds: a view of a pyramid, `at`
// the pyramid's sample at `start` ([start, end) in mix samples). A clip's
// lane is one; a song's or a part's, one per stretch it sounds in; a bus's,
// its tracks' together. Silence has none.
Wave_Region :: struct {
	clip:       int,
	start, end: int,
	at:         int,
	// source samples per video sample (negative: backwards from `at`)
	speed:      f32,
}

// A placed track's lane: its regions, its span on the video timeline and
// how it is shaped.
Wave_Lane :: struct {
	regions:           [2]i32, // first, count into regions
	start, end:        int, // mix samples from the video start
	gain_db:           f32,
	fade_in, fade_out: int, // samples
	curve:             om.Fade_Curve,
	// Whether its start and end cut into its sound (om.track_cuts).
	cuts_in, cuts_out: bool,
	name, scene:       Text_Span,
}

// What a timeline item is: its kind decides how the UI draws it and what
// it holds (TIMELINE_KINDS), each a view of the data under it, as a watch
// window's rows are.
Timeline_Kind :: enum u8 {
	Scenes, // the scene segments with thumbnails
	Cues, // the cues as marks on the time
	Group, // the tracks a bus mixes (or that no bus does): their sound together
	Track, // one placed sound
	Part, // a part of a placed song: its stem where it sounds
	Notes, // a part's pitched notes, by pitch
	Hits, // a part's hits on one pad
	Bands, // a song's third-octave bands over time (a spectrogram)
}

// Items are in drawing order, each item followed by its children.
Timeline_Item :: struct {
	kind:     Timeline_Kind,
	parent:   i32, // -1: top level
	children: i32, // it opens when > 0
	lane:     i32, // the lane drawn (-1: none)
	notes:    [2]i32, // Notes, Hits: first, count into notes
	bands:    [2]i32, // Bands: first, count into band_spans
	// As `onimite show` names it ("bus/sfx", "track/12"), what it says.
	path:     Text_Span,
	label:    Text_Span,
	summary:  Text_Span,
}

// A note on the video timeline (mix samples).
Timeline_Note :: struct {
	start, end: int,
	pitch:      f32,
	velocity:   f32,
}

Timeline_Cue :: struct {
	seconds: f64,
	name:    Text_Span,
}

Wave_Table :: struct {
	clips:   [dynamic]Wave_Clip,
	regions: [dynamic]Wave_Region,
	lanes:   [dynamic]Wave_Lane,
	peaks:   [dynamic][2]i8, // min, max in 1/127
	items:   [dynamic]Timeline_Item,
	notes:   [dynamic]Timeline_Note,
	cues:    [dynamic]Timeline_Cue,
	// Where each Bands item's source plays: its placements on the video.
	band_spans: [dynamic]Band_Span,
	text:    [dynamic]u8,
}

// A placement of a band source (a song's mix): [start, end) on the video
// (mix samples), `zero` the video sample of the song's sample 0.
Band_Span :: struct {
	source:     i32, // into the worker's band sources, and the published textures
	start, end: int,
	zero:       int,
}

wave_table_destroy :: proc(t: ^Wave_Table) {
	delete(t.clips)
	delete(t.regions)
	delete(t.lanes)
	delete(t.peaks)
	delete(t.items)
	delete(t.notes)
	delete(t.cues)
	delete(t.band_spans)
	delete(t.text)
}

wave_table_copy :: proc(dst: ^Wave_Table, src: ^Wave_Table) {
	table_copy(&dst.clips, src.clips[:])
	table_copy(&dst.regions, src.regions[:])
	table_copy(&dst.lanes, src.lanes[:])
	table_copy(&dst.peaks, src.peaks[:])
	table_copy(&dst.items, src.items[:])
	table_copy(&dst.notes, src.notes[:])
	table_copy(&dst.cues, src.cues[:])
	table_copy(&dst.band_spans, src.band_spans[:])
	table_copy(&dst.text, src.text[:])
}

// Where a pyramid's level 0 comes from, as rows: a region is a view of a
// pyramid, and a pyramid of a source; only its kind's rule
// (WAVE_SOURCE_KINDS) differs. A clip's are its samples, a song's (its mix
// or a part's stem, over one stretch it sounds in) its peaks table's rows
// there, built by the music's builder, a group's its tracks' regions.
Wave_Source_Kind :: enum u8 {
	Clip,
	Song,
	Group,
}

Wave_Source :: struct {
	kind:       Wave_Source_Kind,
	clip:       int, // its pyramid (into table.clips)
	audio:      om.Audio_Clip, // Clip: the header (the samples are the media's, matched by address)
	song:       ^om.Song_Clip, // Song
	part:       i32, // Song: one part's peaks (-1: the mix)
	from:       int, // Song: its stretch's first bucket in the render
	filled:     int, // Clip, Song: level-0 buckets so far
	waiting:    bool, // until something lands (a song's segment, a track's pyramid)
	first:      int, // Group: its tracks' lanes, into group_lanes
	count:      int,
	region:     int, // Group: its own
}

// What a step of a source's rule did.
Wave_Fill :: enum u8 {
	Working, // more to do
	Done, // level 0 is complete
	Grew, // level 0 has more, and more comes when something lands
	Waiting, // on something else (a song's render, a track's pyramid)
}

WAVE_SOURCE_KINDS := [Wave_Source_Kind]proc(b: ^Wave_Builder, src: ^Wave_Source) -> Wave_Fill {
	// up to WAVE_CHUNK buckets of its samples a step
	.Clip = proc(b: ^Wave_Builder, src: ^Wave_Source) -> Wave_Fill {
		t := &b.table
		c := &t.clips[src.clip]
		data := src.audio.samples
		n0 := int(c.count[0])
		hi := min(src.filled + WAVE_CHUNK, n0)
		level0 := t.peaks[c.offset[0]:][:n0]
		for bucket in src.filled ..< hi {
			s0 := bucket * WAVE_BUCKET * 2
			s1 := min(s0 + WAVE_BUCKET * 2, len(data))
			mn, mx: f32
			for x in data[s0:s1] {
				mn = min(mn, x)
				mx = max(mx, x)
			}
			level0[bucket] = {i8(clamp(mn, -1, 1) * 127), i8(clamp(mx, -1, 1) * 127)}
		}
		src.filled = hi
		return hi < n0 ? .Working : .Done
	},
	// a view of its stretch of the song's render peaks: the buckets of the
	// segments made so far
	.Song = proc(b: ^Wave_Builder, src: ^Wave_Source) -> Wave_Fill {
		sc := src.song
		om.song_render_want(sc)
		rd := &sc.render
		t := &b.table
		c := &t.clips[src.clip]
		level0 := t.peaks[c.offset[0]:][:c.count[0]]
		row := rd.peaks[int(src.part + 1) * rd.buckets:][:rd.buckets]
		got := 0
		for &pk, k in level0 {
			bucket := src.from + k
			if bucket < rd.buckets && om.song_segment_done(sc, bucket * om.SONG_BUCKET / om.SONG_SEGMENT) {
				pk = row[bucket]
				got += 1
			}
		}
		switch {
		case got == len(level0) || om.song_render_whole(sc):
			return .Done
		case got > src.filled:
			src.filled = got
			return .Grew
		}
		return .Waiting
	},
	// its tracks' regions at their places, shaped by their fades: what
	// their pyramids have so far, complete once theirs all are
	.Group = proc(b: ^Wave_Builder, src: ^Wave_Source) -> Wave_Fill {
		t := &b.table
		lanes := b.group_lanes[src.first:][:src.count]
		complete, any := true, false
		for k in lanes {
			for r in lane_regions(t, k) {
				complete &&= t.clips[r.clip].complete
				any ||= t.clips[r.clip].levels > 0
			}
		}
		if !any {
			return .Waiting
		}
		own := t.regions[src.region]
		c := &t.clips[src.clip]
		level0 := t.peaks[c.offset[0]:][:c.count[0]]
		for k in lanes {
			l := t.lanes[k]
			length := l.end - l.start
			for r in lane_regions(t, k) {
				if r.end <= own.start || r.start >= own.end {
					continue
				}
				tc := t.clips[r.clip]
				from := t.peaks[tc.offset[0]:][:tc.count[0]]
				for tb := max(r.start - own.start, 0) / WAVE_BUCKET; tb < len(level0); tb += 1 {
					at := own.start + tb * WAVE_BUCKET // mix sample
					if at >= r.end {
						break
					}
					cb := (at - r.start + r.at) / WAVE_BUCKET
					if cb < 0 || cb >= len(from) {
						continue
					}
					into := at - l.start
					env := om.track_envelope_peak(into, into + WAVE_BUCKET, length, l.fade_in, l.fade_out, l.curve, l.cuts_in, l.cuts_out)
					pk := from[cb]
					mn, mx := i8(f32(pk[0]) * env), i8(f32(pk[1]) * env)
					level0[tb] = {min(level0[tb][0], mn), max(level0[tb][1], mx)}
				}
			}
		}
		return .Done if complete else .Grew
	},
}

lane_regions :: proc(t: ^Wave_Table, lane: $I) -> []Wave_Region {
	if lane < 0 || int(lane) >= len(t.lanes) {
		return nil
	}
	l := t.lanes[lane]
	return t.regions[l.regions[0]:][:l.regions[1]]
}

// The worker's waveform state: the table it publishes and the sources of
// its pyramids. The media's sources (clips, songs' stretches) live until
// the media reloads; those from `media_sources` on are groups', made again
// with the lanes.
Wave_Builder :: struct {
	table:         Wave_Table,
	sources:       [dynamic]Wave_Source,
	media_sources: int,
	media_clips:   int,
	media_peaks:   int,
	group_lanes:   [dynamic]int, // the lanes of each group (Wave_Source.first, count)
	// The songs whose bands Bands items show, by source (the worker's side
	// of Band_Span.source).
	band_songs:    [dynamic]^om.Song_Clip,
}

// Tracks on no bus show as rows of their own up to this many, else as one
// group.
TIMELINE_LOOSE_TRACKS :: 6

wave_builder_destroy :: proc(b: ^Wave_Builder) {
	wave_table_destroy(&b.table)
	delete(b.sources)
	delete(b.group_lanes)
	delete(b.band_songs)
}

// Forgets every pyramid (the media they came from is gone).
wave_builder_reset :: proc(b: ^Wave_Builder) {
	clear(&b.table.clips)
	clear(&b.table.regions)
	clear(&b.table.peaks)
	clear(&b.table.lanes)
	clear(&b.table.items)
	clear(&b.table.notes)
	clear(&b.table.cues)
	clear(&b.table.band_spans)
	clear(&b.table.text)
	clear(&b.band_songs)
	clear(&b.sources)
	clear(&b.group_lanes)
	b.media_sources, b.media_clips, b.media_peaks = 0, 0, 0
}

// Room for a pyramid of `frames` samples at the end of the peaks.
@(private = "file")
pyramid_reserve :: proc(t: ^Wave_Table, frames: int) -> int {
	wc := Wave_Clip{frames = frames}
	total := 0
	n := max((frames + WAVE_BUCKET - 1) / WAVE_BUCKET, 1)
	for k in 0 ..< WAVE_LEVELS {
		wc.offset[k] = u32(len(t.peaks) + total)
		wc.count[k] = u32(n)
		total += n
		if n <= 1 {
			break
		}
		n = (n + 1) / 2
	}
	resize(&t.peaks, len(t.peaks) + total)
	append(&t.clips, wc)
	return len(t.clips) - 1
}

// Fills a pyramid's upper levels from its level 0.
@(private = "file")
pyramid_levels :: proc(t: ^Wave_Table, c: ^Wave_Clip) {
	levels := 1
	for k in 1 ..< WAVE_LEVELS {
		if c.count[k] == 0 {
			break
		}
		below := t.peaks[c.offset[k - 1]:][:c.count[k - 1]]
		level := t.peaks[c.offset[k]:][:c.count[k]]
		for &pk, j in level {
			a := below[j * 2]
			z := below[min(j * 2 + 1, len(below) - 1)]
			pk = {min(a[0], z[0]), max(a[1], z[1])}
		}
		levels += 1
	}
	c.levels = levels
}

// The pyramid of a media source, made the first time a region shows it.
@(private = "file")
media_source :: proc(b: ^Wave_Builder, want: Wave_Source, frames: int) -> int {
	for src in b.sources[:b.media_sources] {
		if src.kind != want.kind {
			continue
		}
		switch src.kind {
		case .Clip:
			if raw_data(src.audio.samples) == raw_data(want.audio.samples) {
				return src.clip
			}
		case .Song:
			if src.song == want.song && src.part == want.part && src.from == want.from {
				return src.clip
			}
		case .Group:
		}
	}
	src := want
	src.clip = pyramid_reserve(&b.table, frames)
	inject_at(&b.sources, b.media_sources, src)
	b.media_sources += 1
	return src.clip
}

// The timeline is built by its kinds' rules: each adds its item, the lane
// it draws (regions, each a view of a source's pyramid) and its children,
// each built by its own kind's rule: a bus's group holds its tracks, a song
// track its parts, a part the views of its notes. Only the roots are placed
// by wave_builder_lanes: the scenes, the cues, the buses (and the tracks on
// none, loose when they are few).
Timeline_Build :: struct {
	b:      ^Wave_Builder,
	placed: []om.Placed_Track,
	order:  []int, // the tracks in time order (Placed_Audio's)
	rank:   []int, // a track's place in time: its path, `track/N`
	video:  ^om.Video,
	scenes: int,
	cues:   []script.Cue,
	buses:  []string, // a Group's: the bus it mixes ("": the tracks on none)
}

// What an item shows, as its kind reads it: a bus, a placed track, a part
// of its song, a pad of that part.
Timeline_Ref :: struct {
	bus:   int,
	track: int,
	part:  int,
	pad:   u32, // base.name_id of a pad (0: the pitched notes)
}

// A kind's rule: the item for `ref` under `parent`, returning it.
TIMELINE_KINDS := [Timeline_Kind]proc(x: ^Timeline_Build, parent: int, ref: Timeline_Ref) -> int {
	.Scenes = proc(x: ^Timeline_Build, parent: int, ref: Timeline_Ref) -> int {
		return timeline_item(x, .Scenes, parent, -1, "scenes", "scenes", fmt.tprintf("%d scenes", x.scenes))
	},
	.Cues = proc(x: ^Timeline_Build, parent: int, ref: Timeline_Ref) -> int {
		t := &x.b.table
		for c in x.cues {
			append(&t.cues, Timeline_Cue{c.seconds, text_push(&t.text, c.name)})
		}
		return timeline_item(x, .Cues, parent, -1, "cues", "cues", fmt.tprintf("%d cues", len(x.cues)))
	},
	// the bus's tracks together: a region where any of them sounds
	.Group = proc(x: ^Timeline_Build, parent: int, ref: Timeline_Ref) -> int {
		b, t := x.b, &x.b.table
		name := x.buses[ref.bus]
		start, end, n := max(int), 0, 0
		for k in x.order {
			if p := x.placed[k]; p.track.bus == name {
				start, end, n = min(start, p.start), max(end, p.end), n + 1
			}
		}
		gain: f32
		for bus in x.video.buses {
			if bus.name == name {
				gain = bus.gain_db
			}
		}
		label := fmt.tprintf("bus %s", name) if name != "" else "tracks"
		lane := len(t.lanes)
		append(&t.lanes, Wave_Lane{start = start, end = end, name = text_push(&t.text, label)})
		path := fmt.tprintf("bus/%s", name) if name != "" else "tracks"
		g := timeline_item(x, .Group, parent, lane, path, label, bus_summary(name, n, gain))
		first := len(b.group_lanes)
		for k in x.order {
			if x.placed[k].track.bus == name && placements(x, k)[0] == k {
				it := timeline_add(x, .Track, g, {track = k})
				append(&b.group_lanes, int(t.items[it].lane))
			}
		}
		// its regions: its tracks' merged (pyramids reserved after the media's)
		spans := make([dynamic][2]int, context.temp_allocator)
		for k in b.group_lanes[first:] {
			for r in lane_regions(t, k) {
				append(&spans, [2]int{r.start, r.end})
			}
		}
		slice.sort_by(spans[:], proc(a, b: [2]int) -> bool {return a[0] < b[0]})
		t.lanes[lane].regions[0] = i32(len(t.regions))
		for sp in spans {
			if n := len(t.regions); n > int(t.lanes[lane].regions[0]) && sp[0] <= t.regions[n - 1].end {
				t.regions[n - 1].end = max(t.regions[n - 1].end, sp[1])
				continue
			}
			append(&t.regions, Wave_Region{clip = -1, start = sp[0], end = sp[1]})
		}
		t.lanes[lane].regions[1] = i32(len(t.regions)) - t.lanes[lane].regions[0]
		for r in t.lanes[lane].regions[0] ..< t.lanes[lane].regions[0] + t.lanes[lane].regions[1] {
			append(&b.sources, Wave_Source{kind = .Group, clip = -1, first = first, count = len(b.group_lanes) - first, region = int(r)})
		}
		return g
	},
	// a sound and every place it plays on its bus: a clip's, or a song's mix
	// where it sounds, a region each time; and the song's parts
	.Track = proc(x: ^Timeline_Build, parent: int, ref: Timeline_Ref) -> int {
		ks := placements(x, ref.track)
		p := x.placed[ref.track]
		what := sound_kind(p)
		lane := placed_lane(x, ks, -1, what)
		summary := track_summary(p)
		if p.track.source != "" {
			summary = fmt.tprintf("%s  %s", summary, p.track.source)
		}
		path := fmt.tprintf("track/%d", x.rank[ref.track])
		if len(ks) > 1 {
			summary = fmt.tprintf("%s  %d times from %.3fs", what, len(ks), f64(p.start) / om.MIX_RATE)
		}
		it := timeline_item(x, .Track, parent, lane, path, what, summary)
		if p.song != nil && p.song.ok {
			timeline_add(x, .Bands, it, ref)
		}
		// the parts that play (a region or more)
		if p.song != nil && p.song.ok && len(p.song.song.parts) > 1 {
			for _, i in p.song.song.parts {
				for r in p.song.song.regions {
					if int(r.part) == i {
						timeline_add(x, .Part, it, {track = ref.track, part = i})
						break
					}
				}
			}
		}
		return it
	},
	// a part of a placed song: its stem where it sounds, and its notes'
	// views: its pitched notes, its hits per pad
	.Part = proc(x: ^Timeline_Build, parent: int, ref: Timeline_Ref) -> int {
		p := x.placed[ref.track]
		s := &p.song.song
		name := s.parts[ref.part]
		lane := placed_lane(x, placements(x, ref.track), i32(ref.part), name)
		pitched := false
		pads := make([dynamic]u32, context.temp_allocator)
		notes := 0
		for tr in s.tracks {
			if int(tr.part) != ref.part {
				continue
			}
			for i in tr.notes.first ..< tr.notes.first + tr.notes.count {
				if s.notes.kind[i] != .Attack {
					continue // made at compose (a release trigger's, a keyswitch)
				}
				notes += 1
				if pad := s.notes.pad[i]; pad != 0 {
					if !slice.contains(pads[:], pad) {
						append(&pads, pad)
					}
				} else {
					pitched = true
				}
			}
		}
		it := timeline_item(x, .Part, parent, lane, fmt.tprintf("song/%s/parts/%s", p.song.name, name), name, fmt.tprintf("part %s of %s  %d notes", name, p.song.name, notes))
		if pitched {
			timeline_add(x, .Notes, it, ref)
		}
		for pad in pads {
			r := ref
			r.pad = pad
			timeline_add(x, .Hits, it, r)
		}
		return it
	},
	.Notes = proc(x: ^Timeline_Build, parent: int, ref: Timeline_Ref) -> int {
		it := timeline_item(x, .Notes, parent, int(x.b.table.items[parent].lane), strings.clone(text_of(x.b.table.text[:], x.b.table.items[parent].path), context.temp_allocator), "notes", "")
		part_notes(x, it, ref)
		return it
	},
	// a song's bands where it plays: a view of its band rows (requested
	// while the row is shown)
	.Bands = proc(x: ^Timeline_Build, parent: int, ref: Timeline_Ref) -> int {
		t := &x.b.table
		it := timeline_item(x, .Bands, parent, int(t.items[parent].lane), strings.clone(text_of(t.text[:], t.items[parent].path), context.temp_allocator), "bands", "third-octave bands, 20 Hz (bottom) to 20 kHz")
		source := i32(len(x.b.band_songs))
		append(&x.b.band_songs, x.placed[ref.track].song)
		t.items[it].bands[0] = i32(len(t.band_spans))
		for k in placements(x, ref.track) {
			p := x.placed[k]
			append(&t.band_spans, Band_Span{source = source, start = p.start, end = p.end, zero = p.start - p.file_start})
		}
		t.items[it].bands[1] = i32(len(t.band_spans)) - t.items[it].bands[0]
		return it
	},
	.Hits = proc(x: ^Timeline_Build, parent: int, ref: Timeline_Ref) -> int {
		name := osong.pad_name(&x.placed[ref.track].song.song, ref.pad)
		it := timeline_item(x, .Hits, parent, int(x.b.table.items[parent].lane), strings.clone(text_of(x.b.table.text[:], x.b.table.items[parent].path), context.temp_allocator), name, "")
		part_notes(x, it, ref)
		return it
	},
}

// An item by its kind's rule, its children counted.
timeline_add :: proc(x: ^Timeline_Build, kind: Timeline_Kind, parent: int, ref: Timeline_Ref) -> int {
	it := TIMELINE_KINDS[kind](x, parent, ref)
	items := x.b.table.items[:]
	n: i32
	for c in items[it + 1:] {
		n += i32(c.parent == i32(it))
	}
	items[it].children = n
	return it
}

@(private = "file")
timeline_item :: proc(x: ^Timeline_Build, kind: Timeline_Kind, parent, lane: int, path, label, summary: string) -> int {
	t := &x.b.table
	append(&t.items, Timeline_Item{kind = kind, parent = i32(parent), lane = i32(lane), path = text_push(&t.text, path), label = text_push(&t.text, label), summary = text_push(&t.text, summary)})
	return len(t.items) - 1
}

// Every placement on `k`'s bus of what `k` plays, in time order (`k`'s
// first): one effect is one row however often, and at whatever pitch, it
// plays.
@(private = "file")
placements :: proc(x: ^Timeline_Build, k: int) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	p := x.placed[k]
	what := sound_kind(p)
	for q in x.order {
		if o := x.placed[q]; o.track.bus == p.track.bus && sound_kind(o) == what {
			append(&out, q)
		}
	}
	return out[:]
}

// What a placement plays: a sound (a one-track song) is its instrument
// ("tick", "Synth"), a clip or a song its own name.
sound_kind :: proc(p: om.Placed_Track) -> string {
	if p.song != nil && p.song.ok && len(p.song.song.tracks) == 1 {
		s := &p.song.song
		return s.labels[s.tracks[0].instrument]
	}
	return p.track.src
}

// A lane for the placements `ks` of one sound (a song's part: `part`; -1
// its mix, or a clip): its span and shape (the first's), and a region per
// stretch its source sounds in, each time it plays.
@(private = "file")
placed_lane :: proc(x: ^Timeline_Build, ks: []int, part: i32, name: string) -> int {
	t := &x.b.table
	first := x.placed[ks[0]]
	tr := first.track
	l := Wave_Lane {
		start = first.start,
		end = first.end,
		gain_db = tr.gain_db,
		fade_in = om.seconds_to_samples(tr.fade_in),
		fade_out = om.seconds_to_samples(tr.fade_out),
		curve = tr.curve,
		name = text_push(&t.text, name),
		scene = text_push(&t.text, first.scene),
	}
	l.cuts_in, l.cuts_out = om.track_cuts(first)
	l.regions[0] = i32(len(t.regions))
	for k in ks {
		p := x.placed[k]
		l.end = max(l.end, p.end)
		switch {
		case p.clip != nil:
			clip := media_source(x.b, {kind = .Clip, audio = p.clip^}, p.clip.frames)
			append(&t.regions, Wave_Region{clip, p.start, p.end, p.file_start, om.track_speed(p.track)})
		case p.song != nil && p.song.ok:
			// the song's sample 0 on the video
			zero := p.start - p.file_start
			for sp in orender.sounding_from_song(&p.song.song, part) {
				// whole render buckets: the stretch's view of them
				first := int(sp[0] * om.MIX_RATE) / om.SONG_BUCKET
				last := (int(math.ceil(sp[1] * om.MIX_RATE)) + om.SONG_BUCKET - 1) / om.SONG_BUCKET
				a, z := zero + first * om.SONG_BUCKET, zero + last * om.SONG_BUCKET
				start, end := max(a, p.start), min(z, p.end)
				if end <= start {
					continue
				}
				clip := media_source(x.b, {kind = .Song, song = p.song, part = part, from = first}, z - a)
				append(&t.regions, Wave_Region{clip, start, end, start - a, 1})
			}
		}
	}
	l.regions[1] = i32(len(t.regions)) - l.regions[0]
	append(&t.lanes, l)
	return len(t.lanes) - 1
}

// A notes view's notes: the part's pitched ones, or its hits on one pad,
// where the track lets them through.
@(private = "file")
part_notes :: proc(x: ^Timeline_Build, it: int, ref: Timeline_Ref) {
	t := &x.b.table
	first := len(t.notes)
	for k in placements(x, ref.track) {
		p := x.placed[k]
		s := &p.song.song
		zero := p.start - p.file_start
		for tr in s.tracks {
			if int(tr.part) != ref.part {
				continue
			}
			for i in tr.notes.first ..< tr.notes.first + tr.notes.count {
				n := s.notes[i]
				if n.pad != ref.pad || n.kind != .Attack {
					continue
				}
				a := zero + int(n.time * om.MIX_RATE)
				z := a + max(int(n.duration * om.MIX_RATE), 1)
				if z <= p.start || a >= p.end {
					continue
				}
				append(&t.notes, Timeline_Note{a, z, n.pitch, n.velocity})
			}
		}
	}
	t.items[it].notes = {i32(first), i32(len(t.notes) - first)}
	what := "notes" if ref.pad == 0 else osong.pad_name(&x.placed[ref.track].song.song, ref.pad)
	t.items[it].summary = text_push(&t.text, fmt.tprintf("%d %s of %s", len(t.notes) - first, what, x.placed[ref.track].song.song.parts[ref.part]))
}

// Rebuilds the timeline from the placed tracks: its roots, each built by
// its kind's rule with everything under it.
wave_builder_lanes :: proc(b: ^Wave_Builder, placed: []om.Placed_Track, order: []int, v: ^om.Video, scenes: int, cues: []script.Cue) {
	t := &b.table
	// the media's sources and pyramids are kept (first in the tables), the
	// groups' made again after them
	resize(&b.sources, b.media_sources)
	resize(&t.clips, b.media_clips)
	resize(&t.peaks, b.media_peaks)
	clear(&t.regions)
	clear(&t.lanes)
	clear(&t.items)
	clear(&t.notes)
	clear(&t.cues)
	clear(&t.text)
	clear(&b.group_lanes)
	rank := make([]int, len(placed), context.temp_allocator)
	for k, i in order {
		rank[k] = i
	}
	x := Timeline_Build{b = b, placed = placed, order = order, rank = rank, video = v, scenes = scenes, cues = cues}
	// Buses by when they first play (then by name: a script's table of
	// buses has no order), then the tracks on none.
	Named :: struct {
		name:  string,
		first: int,
	}
	named := make([dynamic]Named, 0, len(v.buses) + 1, context.temp_allocator)
	for bus in v.buses {
		n := Named{bus.name, max(int)}
		for p in placed {
			if p.track.bus == bus.name {
				n.first = min(n.first, p.start)
			}
		}
		if n.first < max(int) {
			append(&named, n)
		}
	}
	slice.sort_by(named[:], proc(a, b: Named) -> bool {return a.first < b.first || (a.first == b.first && a.name < b.name)})
	buses := make([dynamic]string, 0, len(named) + 1, context.temp_allocator)
	for n in named {
		append(&buses, n.name)
	}
	loose := 0
	for p in placed {
		loose += int(p.track.bus == "")
	}
	if loose > TIMELINE_LOOSE_TRACKS {
		append(&buses, "")
	}
	x.buses = buses[:]
	timeline_add(&x, .Scenes, -1, {})
	if len(cues) > 0 {
		timeline_add(&x, .Cues, -1, {})
	}
	for _, i in x.buses {
		timeline_add(&x, .Group, -1, {bus = i})
	}
	if loose <= TIMELINE_LOOSE_TRACKS {
		for k in order {
			if placed[k].track.bus == "" && placements(&x, k)[0] == k {
				timeline_add(&x, .Track, -1, {track = k})
			}
		}
	}
	// pyramids for the sources made from others, after the media's
	b.media_clips, b.media_peaks = len(t.clips), len(t.peaks)
	for &src in b.sources[b.media_sources:] {
		r := &t.regions[src.region]
		src.clip = pyramid_reserve(t, r.end - r.start)
		r.clip = src.clip
	}
	// the songs' renders asked now, with the first frame's tables (the
	// worker drains after it)
	for src in b.sources {
		if src.kind == .Song {
			om.song_render_want(src.song)
		}
	}
}

// Whether a source has a step to take (not complete, not waiting).
wave_builder_pending :: proc(b: ^Wave_Builder) -> bool {
	for src in b.sources {
		if !b.table.clips[src.clip].complete && !src.waiting {
			return true
		}
	}
	return false
}

// Something a source waited for landed (a song's table): it steps again.
wave_builder_landed :: proc(b: ^Wave_Builder) {
	for &src in b.sources {
		src.waiting = false
	}
}

// One bounded step of pyramid work: the first source with work, by its
// kind's rule; its upper levels once its level 0 is complete or grew. True
// when a pyramid changed (the table should be published).
wave_builder_step :: proc(b: ^Wave_Builder) -> (changed: bool) {
	t := &b.table
	for &src in b.sources {
		c := &t.clips[src.clip]
		if c.complete || src.waiting {
			continue
		}
		switch WAVE_SOURCE_KINDS[src.kind](b, &src) {
		case .Working:
			return false
		case .Done:
			pyramid_levels(t, c)
			c.complete = true
			return true
		case .Grew:
			pyramid_levels(t, c)
			src.waiting = true
			return true
		case .Waiting:
			src.waiting = true
		}
	}
	return false
}

// Min and max of a clip's samples [s0, s1) from the level whose bucket is
// at most the span (so a pixel reads one to three pairs).
wave_peak :: proc(t: ^Wave_Table, c: ^Wave_Clip, s0, s1: int) -> (lo, hi: f32, ok: bool) {
	if c.levels == 0 || s1 <= 0 || s0 >= c.frames {
		return
	}
	span := max(s1 - s0, 1)
	k := 0
	for k + 1 < c.levels && (WAVE_BUCKET << uint(k + 1)) <= span {
		k += 1
	}
	size := WAVE_BUCKET << uint(k)
	count := int(c.count[k])
	b0 := clamp(max(s0, 0) / size, 0, count - 1)
	b1 := clamp((min(s1, c.frames) + size - 1) / size, b0 + 1, count)
	mn, mx: i8
	for pk in t.peaks[int(c.offset[k]) + b0:][:b1 - b0] {
		mn = min(mn, pk[0])
		mx = max(mx, pk[1])
	}
	return f32(mn) / 127, f32(mx) / 127, true
}

// ---- media ------------------------------------------------------------------------------

MEDIA_THUMB :: 64 // image thumbnails fit this square

Media_Row :: struct {
	kind:       om.Media_Kind,
	name:       Text_Span,
	// Straight RGBA in `Media_Table.pixels` (images; size 0 otherwise).
	thumb:      u32,
	thumb_size: [2]u16,
}

Media_Table :: struct {
	rows:         [dynamic]Media_Row,
	text:         [dynamic]u8,
	pixels:       [dynamic]u8,
	// Image rows whose thumbnail pixels are filled (images come first).
	thumbs_ready: int,
}

media_table_destroy :: proc(t: ^Media_Table) {
	delete(t.rows)
	delete(t.text)
	delete(t.pixels)
}

media_table_copy :: proc(dst: ^Media_Table, src: ^Media_Table) {
	table_copy(&dst.rows, src.rows[:])
	table_copy(&dst.text, src.text[:])
	table_copy(&dst.pixels, src.pixels[:])
	dst.thumbs_ready = src.thumbs_ready
}

// Fills `t` from the media, in `media_items`' order (the Watch's). Runs on
// the worker; image thumbnails are reserved and filled in later steps by
// media_table_thumbs.
media_table_build :: proc(t: ^Media_Table, m: ^om.Media) {
	clear(&t.rows)
	clear(&t.text)
	clear(&t.pixels)
	t.thumbs_ready = 0
	// Images come first (`media_items` goes by kind).
	for it in media_items(m) {
		row := Media_Row{kind = it.kind, name = text_push(&t.text, it.name)}
		if it.kind == .Image {
			img := m.images[it.name]
			tw, th := img.width, img.height
			if tw > MEDIA_THUMB || th > MEDIA_THUMB {
				s := f32(MEDIA_THUMB) / f32(max(tw, th))
				tw, th = max(int(f32(tw) * s), 1), max(int(f32(th) * s), 1)
			}
			// Reserved here, filled by media_table_thumbs.
			row.thumb = u32(len(t.pixels))
			row.thumb_size = {u16(tw), u16(th)}
			resize(&t.pixels, len(t.pixels) + tw * th * 4)
		}
		append(&t.rows, row)
	}
}

// Fills up to `count` more image thumbnails, decoding their images (on
// first use) as tasks on `pool`; true when all are filled.
media_table_thumbs :: proc(t: ^Media_Table, m: ^om.Media, count: int, pool: ^thread.Pool = nil) -> (done: bool) {
	Thumb_Job :: struct {
		t:   ^Media_Table,
		m:   ^om.Media,
		row: Media_Row,
	}
	jobs := make([dynamic]Thumb_Job, context.temp_allocator)
	for len(jobs) < count && t.thumbs_ready < len(t.rows) && t.rows[t.thumbs_ready].kind == .Image {
		append(&jobs, Thumb_Job{t, m, t.rows[t.thumbs_ready]})
		t.thumbs_ready += 1
	}
	// Each row fills its own reserved pixels.
	om.pool_run(pool, jobs[:], proc(task: thread.Task) {
		j := (^Thumb_Job)(task.data)
		img, ok := om.media_image(j.m, text_of(j.t.text[:], j.row.name))
		tw, th := int(j.row.thumb_size.x), int(j.row.thumb_size.y)
		if ok && tw * th > 0 {
			thumb_filter(j.t.pixels[j.row.thumb:][:tw * th * 4], tw, th, img.pixels, img.width, img.height)
		}
	}, context.allocator)
	return t.thumbs_ready >= len(t.rows) || t.rows[t.thumbs_ready].kind != .Image
}

// Averages up to 4x4 source pixels spread over each destination pixel's
// area: enough for a 64 px thumbnail, and its cost doesn't grow with the
// image.
@(private = "file")
thumb_filter :: proc(dst: []u8, dw, dh: int, src: []u8, sw, sh: int) {
	TAPS :: 4
	for y in 0 ..< dh {
		y0 := y * sh / dh
		y1 := max((y + 1) * sh / dh, y0 + 1)
		ny := min(y1 - y0, TAPS)
		for x in 0 ..< dw {
			x0 := x * sw / dw
			x1 := max((x + 1) * sw / dw, x0 + 1)
			nx := min(x1 - x0, TAPS)
			sum: [4]u32
			for j in 0 ..< ny {
				yy := y0 + j * (y1 - y0) / ny
				for i in 0 ..< nx {
					k := (yy * sw + x0 + i * (x1 - x0) / nx) * 4
					sum += {u32(src[k]), u32(src[k + 1]), u32(src[k + 2]), u32(src[k + 3])}
				}
			}
			n := u32(nx * ny)
			o := (y * dw + x) * 4
			dst[o], dst[o + 1], dst[o + 2], dst[o + 3] = u8(sum[0] / n), u8(sum[1] / n), u8(sum[2] / n), u8(sum[3] / n)
		}
	}
}

// ---- the Watch --------------------------------------------------------------------------

Watch_Section :: enum u8 {
	Scenes,
	Cues,
	Problems,
	Media,
	Marks,
}

Watch_Status :: enum u8 {
	Ok,
	Info,
	Warning,
	Error,
}

Watch_Row :: struct {
	section:       Watch_Section,
	status:        Watch_Status,
	// The frame a click goes to (-1: none).
	frame:         int,
	// Media rows: the media table's row, with its thumbnail (-1: none).
	media:         i32,
	label, detail: Text_Span,
}

// A section's rows (rows are in section order) and its worst status.
Watch_Group :: struct {
	first, count: int,
	worst:        Watch_Status,
}

Watch_Table :: struct {
	rows:     [dynamic]Watch_Row,
	text:     [dynamic]u8,
	sections: [Watch_Section]Watch_Group,
}

watch_table_destroy :: proc(t: ^Watch_Table) {
	delete(t.rows)
	delete(t.text)
}

watch_table_copy :: proc(dst: ^Watch_Table, src: ^Watch_Table) {
	table_copy(&dst.rows, src.rows[:])
	table_copy(&dst.text, src.text[:])
	dst.sections = src.sections
}

// What the Watch's rows are made from: the worker's load.
Watch_Sources :: struct {
	// The scenes (nil when the timeline does not resolve).
	timeline:   ^om.Timeline,
	fps:        int,
	findings:   ^Finding_Table,
	cues:       []script.Cue,
	// The sync findings (`sync_check`); nil while sounds are being built.
	sync:       []om.Diagnostic,
	media:      ^om.Media,
	placed:     []om.Placed_Track,
	// Why the last load failed ("" after a good one).
	load_error: string,
	// The marks a person made in the window, in time order.
	marks:      []Mark,
}

// Fills `t`: the scenes with the problems seen in each, the cues with
// their sync findings, the problems most severe first, the media with
// their first use. Every row is worded by items.odin.
watch_table_build :: proc(t: ^Watch_Table, src: Watch_Sources) {
	clear(&t.rows)
	clear(&t.text)
	t.sections = {}
	add :: proc(t: ^Watch_Table, section: Watch_Section, status: Watch_Status, frame: int, label, detail: string, media := -1) {
		g := &t.sections[section]
		if g.count == 0 {
			g.first = len(t.rows)
		}
		g.count += 1
		g.worst = max(g.worst, status)
		append(&t.rows, Watch_Row{section, status, frame, i32(media), text_push(&t.text, label), text_push(&t.text, detail)})
	}
	status_of :: proc(s: om.Severity) -> Watch_Status {
		switch s {
		case .Info:
			return .Info
		case .Warning:
			return .Warning
		case .Error:
			return .Error
		}
		return .Ok
	}
	fps := max(src.fps, 1)
	empty: om.Timeline
	tl := src.timeline if src.timeline != nil else &empty

	// Scenes: the problems seen in each (pairs of finding and scene).
	problems := make([]int, len(tl.scenes), context.temp_allocator)
	worst := make([]Watch_Status, len(tl.scenes), context.temp_allocator)
	for pair in src.findings.scenes {
		if k := int(pair[1]); k < len(tl.scenes) {
			problems[k] += 1
			worst[k] = max(worst[k], status_of(src.findings.rows[pair[0]].diagnostic.severity))
		}
	}
	for sc, k in tl.scenes {
		label, detail := scene_watch(sc, fps, problems[k])
		add(t, .Scenes, worst[k], sc.start_frame, label, detail)
	}

	// Cues: a sync finding names the cue, or its family (`beat[*]`).
	for c in src.cues {
		finding: string
		status := Watch_Status.Ok
		for d in src.sync {
			family := strings.trim_suffix(d.name, "[*]")
			if d.name == c.name || (family != d.name && family_of(c.name) == family) {
				finding = om.diagnostic_message(d, context.temp_allocator)
				status = status_of(d.severity)
				break
			}
		}
		label, detail := cue_watch(c, fps, finding)
		add(t, .Cues, status, om.frame_at(c.seconds, fps), label, detail)
	}

	// Problems: a failed reload first (its lines), then the findings as
	// `inspect` orders them.
	if src.load_error != "" {
		for line, i in strings.split_lines(src.load_error, context.temp_allocator) {
			add(t, .Problems, .Error, -1, line, "the script failed to load; the last good version plays" if i == 0 else "")
		}
	}
	order := findings_order(src.findings)
	for f, i in findings_report(src.findings, tl, fps) {
		label, detail := finding_watch(f)
		add(t, .Problems, status_of(src.findings.rows[order[i]].diagnostic.severity), f.first_frame if f.frames > 0 else -1, label, detail)
	}

	// Media, in the media table's order (its row k has item k's thumbnail).
	if src.media != nil {
		for it, k in media_items(src.media) {
			first := media_first_frame(src.placed, it.name, fps)
			status := Watch_Status.Ok
			if it.failed {
				status = .Error
			} else if it.kind == .Audio && first < 0 {
				status = .Info
			}
			label, detail := media_watch(it, first, fps)
			add(t, .Media, status, first, label, detail, k)
		}
	}

	for m in src.marks {
		label, detail := mark_watch(m, fps)
		add(t, .Marks, .Info, m.at, label, detail)
	}
}

// ---- marks file -------------------------------------------------------------------------

// A moment or a range a person marked in the preview for the agent to read:
// frames `at` (to `to`, inclusive; -1: a moment), numbered `n` in the order
// they were made (numbers stay when others go).
Mark :: struct {
	n:      int,
	at, to: int,
}

// Where the marks of a script or clip live: beside it, `video.lua` ->
// `video.marks.json`, `clip.mp4` -> `clip.marks.json`, where the agent
// reads them.
marks_file :: proc(script_path: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({strings.trim_suffix(script_path, filepath.ext(script_path)), MARKS_SUFFIX}, allocator)
}

MARKS_SUFFIX :: ".marks.json"

// A mark in seconds: where it starts and, for a range, the playhead's time
// at its out point (a moment: its start).
mark_seconds :: proc(m: Mark, fps: int) -> (from, to: f64) {
	from = f64(m.at) / f64(fps)
	to = f64(m.to) / f64(fps) if m.to >= 0 else from
	return
}

Marks_File :: struct {
	source: string `json:"source"`,
	fps:    int `json:"fps"`,
	marks:  []Mark_Entry `json:"marks"`,
}

// A mark as the file has it, in seconds: `at` for a moment, `from` and
// `to` for a range.
Mark_Entry :: struct {
	n:    int `json:"n"`,
	at:   Maybe(f64) `json:"at"`,
	from: Maybe(f64) `json:"from"`,
	to:   Maybe(f64) `json:"to"`,
}

// The marks of the script (`fps`: the video's rate, for frames), in time
// order; none when the file is missing or unreadable.
marks_read :: proc(script_path: string, fps: int, allocator := context.allocator) -> [dynamic]Mark {
	out := make([dynamic]Mark, allocator)
	data, err := os.read_entire_file(marks_file(script_path), context.temp_allocator)
	if err != nil {
		return out
	}
	f: Marks_File
	if json.unmarshal(data, &f, allocator = context.temp_allocator) != nil {
		return out
	}
	frame :: proc(s: f64, fps: int) -> int {return max(int(math.round(s * f64(fps))), 0)}
	for e in f.marks {
		if at, ok := e.at.?; ok {
			append(&out, Mark{e.n, frame(at, fps), -1})
		} else if from, ok := e.from.?; ok {
			append(&out, Mark{e.n, frame(from, fps), max(frame(e.to.? or_else from, fps), frame(from, fps))})
		}
	}
	marks_sort(out[:])
	return out
}

marks_sort :: proc(marks: []Mark) {
	slice.sort_by(marks, proc(a, b: Mark) -> bool {return a.at < b.at || (a.at == b.at && a.n < b.n)})
}

// Writes the marks beside the script (or removes the file when there are
// none). Runs on the worker.
marks_write :: proc(script_path: string, marks: []Mark, fps: int) {
	path := marks_file(script_path)
	if len(marks) == 0 {
		_ = os.remove(path)
		return
	}
	// by hand: seconds to the millisecond, a mark a line
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "{{\n  \"source\": %q,\n  \"fps\": %d,\n  \"marks\": [\n", filepath.base(script_path), fps)
	for m, i in marks {
		from, to := mark_seconds(m, fps)
		if m.to < 0 {
			fmt.sbprintf(&b, "    {{ \"n\": %d, \"at\": %.3f }}", m.n, from)
		} else {
			fmt.sbprintf(&b, "    {{ \"n\": %d, \"from\": %.3f, \"to\": %.3f }}", m.n, from, to)
		}
		strings.write_string(&b, ",\n" if i + 1 < len(marks) else "\n")
	}
	strings.write_string(&b, "  ]\n}\n")
	_ = os.write_entire_file(path, transmute([]u8)strings.to_string(b))
}

// ---- bookmark file ----------------------------------------------------------------------

// Where a script's bookmark lives: the user's config directory
// ($XDG_CONFIG_HOME, else ~/.config; %APPDATA% on Windows), under
// onimite/bookmarks/, named by a hash of the script's absolute path. The
// file holds the frame and, for people reading it, the path.
bookmark_file :: proc(script_path: string, allocator := context.temp_allocator) -> string {
	abs, _ := filepath.abs(script_path, context.temp_allocator)
	base := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if base == "" {
		when ODIN_OS == .Windows {
			base = os.get_env("APPDATA", context.temp_allocator)
		} else {
			home := os.get_env("HOME", context.temp_allocator)
			base = filepath.join({home, ".config"}, context.temp_allocator) or_else ""
		}
	}
	if base == "" {
		return ""
	}
	name := fmt.tprintf("%016x.txt", hash.fnv64a(transmute([]u8)abs))
	return filepath.join({base, "onimite", "bookmarks", name}, allocator) or_else ""
}

// The bookmarked frame of the script, -1 when there is none.
bookmark_read :: proc(script_path: string) -> int {
	path := bookmark_file(script_path)
	if path == "" {
		return -1
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return -1
	}
	line := strings.trim_space(string(data))
	if i := strings.index_byte(line, '\n'); i >= 0 {
		line = strings.trim_space(line[:i])
	}
	f, ok := strconv.parse_int(line)
	return f if ok && f >= 0 else -1
}

// Writes the bookmark (or removes the file for -1). Runs on the worker.
bookmark_write :: proc(script_path: string, frame: int) {
	path := bookmark_file(script_path)
	if path == "" {
		return
	}
	if frame < 0 {
		_ = os.remove(path)
		return
	}
	_ = os.make_directory_all(filepath.dir(path))
	abs, _ := filepath.abs(script_path, context.temp_allocator)
	_ = os.write_entire_file(path, transmute([]u8)fmt.tprintf("%d\n%s\n", frame, abs))
}
