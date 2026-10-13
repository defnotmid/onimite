package onimite_app

import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:thread"
import om "../onimite"
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

WAVE_BUCKET :: 256 // mix samples per peak pair at level 0
WAVE_LEVELS :: 20
// Level-0 buckets filled per idle step (about 4 M samples, a few ms).
WAVE_CHUNK :: 16384

// One clip's pyramid in `Wave_Table.peaks`; `levels == 0` while it is being
// computed.
Wave_Clip :: struct {
	frames: int,
	levels: int,
	offset: [WAVE_LEVELS]u32,
	count:  [WAVE_LEVELS]u32,
}

// A placed track: its span on the video timeline and how it is shaped.
Wave_Lane :: struct {
	clip:              int,
	// [start, end) in mix samples from the video start; `file_start` the
	// first clip sample played.
	start, end:        int,
	file_start:        int,
	gain_db:           f32,
	fade_in, fade_out: int, // samples
	curve:             om.Fade_Curve,
	name, scene:       Text_Span,
}

// What a timeline item is: its kind decides how the UI draws it, whether
// it expands and what hovering it says (preview_timeline.odin).
Timeline_Kind :: enum u8 {
	Scenes, // the scene segments with thumbnails
	Cues, // the cues as marks on the time
	Group, // the tracks a bus mixes (or that no bus does): their sound together
	Track, // one placed sound
}

// Items are in drawing order, each group followed by its tracks.
Timeline_Item :: struct {
	kind:     Timeline_Kind,
	parent:   i32, // -1: top level
	children: i32, // tracks in a group: it expands when > 0
	lane:     i32, // Group, Track: the lane drawn (-1: none)
	// As `onimite show` names it ("bus/sfx", "track/12"), what it says.
	path:     Text_Span,
	label:    Text_Span,
	summary:  Text_Span,
}

Timeline_Cue :: struct {
	seconds: f64,
	name:    Text_Span,
}

Wave_Table :: struct {
	clips: [dynamic]Wave_Clip,
	lanes: [dynamic]Wave_Lane,
	peaks: [dynamic][2]i8, // min, max in 1/127
	items: [dynamic]Timeline_Item,
	cues:  [dynamic]Timeline_Cue,
	text:  [dynamic]u8,
}

wave_table_destroy :: proc(t: ^Wave_Table) {
	delete(t.clips)
	delete(t.lanes)
	delete(t.peaks)
	delete(t.items)
	delete(t.cues)
	delete(t.text)
}

wave_table_copy :: proc(dst: ^Wave_Table, src: ^Wave_Table) {
	table_copy(&dst.clips, src.clips[:])
	table_copy(&dst.lanes, src.lanes[:])
	table_copy(&dst.peaks, src.peaks[:])
	table_copy(&dst.items, src.items[:])
	table_copy(&dst.cues, src.cues[:])
	table_copy(&dst.text, src.text[:])
}

// The worker's waveform state: the table it publishes, and which media clip
// each pyramid belongs to (pyramids live until the media reloads). The
// clips from `media_clips` on are groups' pyramids, made again with the
// lanes from their tracks' pyramids.
Wave_Builder :: struct {
	table:       Wave_Table,
	// Parallel to the media clips' pyramids: the clips (headers; the samples
	// are the media's, matched by address since the media's table moves
	// clips as it grows).
	sources:     [dynamic]om.Audio_Clip,
	filled:      [dynamic]int, // level-0 buckets computed, parallel to `sources`
	media_clips: int,
	media_peaks: int,
	// The groups' pyramids: each one's clip and its lanes (in group_lanes).
	groups:      [dynamic]Wave_Group,
	group_lanes: [dynamic]int,
}

Wave_Group :: struct {
	clip:         int,
	first, count: int,
}

// Tracks on no bus show as rows of their own up to this many, else as one
// group.
TIMELINE_LOOSE_TRACKS :: 6

wave_builder_destroy :: proc(b: ^Wave_Builder) {
	wave_table_destroy(&b.table)
	delete(b.sources)
	delete(b.filled)
	delete(b.groups)
	delete(b.group_lanes)
}

// Forgets every pyramid (the media they came from is gone).
wave_builder_reset :: proc(b: ^Wave_Builder) {
	clear(&b.table.clips)
	clear(&b.table.peaks)
	clear(&b.table.lanes)
	clear(&b.table.items)
	clear(&b.table.cues)
	clear(&b.table.text)
	clear(&b.sources)
	clear(&b.filled)
	clear(&b.groups)
	clear(&b.group_lanes)
	b.media_clips, b.media_peaks = 0, 0
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

// Rebuilds the timeline from the placed tracks: a lane per track (a pyramid
// reserved for each clip not seen before, filled by wave_builder_step), the
// items (scenes, cues, then each bus's tracks as a group, in time order) and
// a lane per group.
wave_builder_lanes :: proc(b: ^Wave_Builder, placed: []om.Placed_Track, order: []int, v: ^om.Video, scenes: int, cues: []script.Cue) {
	t := &b.table
	resize(&t.clips, b.media_clips)
	resize(&t.peaks, b.media_peaks)
	clear(&t.lanes)
	clear(&t.items)
	clear(&t.cues)
	clear(&t.text)
	clear(&b.groups)
	clear(&b.group_lanes)
	for p in placed {
		clip := -1
		for src, i in b.sources {
			if raw_data(src.samples) == raw_data(p.clip.samples) {
				clip = i
				break
			}
		}
		if clip < 0 {
			clip = pyramid_reserve(t, p.clip.frames)
			append(&b.sources, p.clip^)
			append(&b.filled, 0)
		}
		tr := p.track
		append(
			&t.lanes,
			Wave_Lane {
				clip = clip,
				start = p.start,
				end = p.end,
				file_start = p.file_start,
				gain_db = tr.gain_db,
				fade_in = om.seconds_to_samples(tr.fade_in),
				fade_out = om.seconds_to_samples(tr.fade_out),
				curve = tr.curve,
				name = text_push(&t.text, tr.src),
				scene = text_push(&t.text, p.scene),
			},
		)
	}
	b.media_clips, b.media_peaks = len(t.clips), len(t.peaks)

	// A track's place in time (`order`, Placed_Audio's) is its path
	// (`onimite show` names it so).
	rank := make([]int, len(placed), context.temp_allocator)
	for k, i in order {
		rank[k] = i
	}

	item :: proc(t: ^Wave_Table, kind: Timeline_Kind, parent, lane: int, path, label, summary: string) -> int {
		append(&t.items, Timeline_Item{kind, i32(parent), 0, i32(lane), text_push(&t.text, path), text_push(&t.text, label), text_push(&t.text, summary)})
		return len(t.items) - 1
	}
	item(t, .Scenes, -1, -1, "scenes", "scenes", fmt.tprintf("%d scenes", scenes))
	if len(cues) > 0 {
		item(t, .Cues, -1, -1, "cues", "cues", fmt.tprintf("%d cues", len(cues)))
		for c in cues {
			append(&t.cues, Timeline_Cue{c.seconds, text_push(&t.text, c.name)})
		}
	}
	track_item :: proc(t: ^Wave_Table, p: om.Placed_Track, parent, lane, rank: int) {
		summary := track_summary(p)
		if p.track.source != "" {
			summary = fmt.tprintf("%s  %s", summary, p.track.source)
		}
		item(t, .Track, parent, lane, fmt.tprintf("track/%d", rank), p.track.src, summary)
	}
	// Buses by when they first play (then by name: a script's table of
	// buses has no order), then the tracks on none.
	Named :: struct {
		name:  string,
		first: int,
	}
	buses := make([]Named, len(v.buses), context.temp_allocator)
	for bus, i in v.buses {
		buses[i] = {bus.name, max(int)}
		for p in placed {
			if p.track.bus == bus.name {
				buses[i].first = min(buses[i].first, p.start)
			}
		}
	}
	slice.sort_by(buses, proc(a, b: Named) -> bool {return a.first < b.first || (a.first == b.first && a.name < b.name)})
	names := make([dynamic]string, 0, len(v.buses) + 1, context.temp_allocator)
	for bus in buses {
		append(&names, bus.name)
	}
	append(&names, "")
	for name in names {
		first := len(b.group_lanes)
		for k in order {
			if placed[k].track.bus == name {
				append(&b.group_lanes, k)
			}
		}
		mine := b.group_lanes[first:]
		if len(mine) == 0 {
			continue
		}
		if name == "" && len(mine) <= TIMELINE_LOOSE_TRACKS {
			for k in mine {
				track_item(t, placed[k], -1, k, rank[k])
			}
			resize(&b.group_lanes, first)
			continue
		}
		start, end := max(int), 0
		for k in mine {
			start, end = min(start, t.lanes[k].start), max(end, t.lanes[k].end)
		}
		clip := pyramid_reserve(t, end - start)
		append(&b.groups, Wave_Group{clip, first, len(mine)})
		label := fmt.tprintf("bus %s", name) if name != "" else "tracks"
		append(&t.lanes, Wave_Lane{clip = clip, start = start, end = end, name = text_push(&t.text, label)})
		gain: f32
		for bus in v.buses {
			if bus.name == name {
				gain = bus.gain_db
			}
		}
		path := fmt.tprintf("bus/%s", name) if name != "" else "tracks"
		g := item(t, .Group, -1, len(t.lanes) - 1, path, label, bus_summary(name, len(mine), gain))
		t.items[g].children = i32(len(mine))
		for k in mine {
			track_item(t, placed[k], g, k, rank[k])
		}
	}
}

wave_builder_pending :: proc(b: ^Wave_Builder) -> bool {
	for c in b.table.clips {
		if c.levels == 0 {
			return true
		}
	}
	return false
}

// One bounded step of pyramid work: up to WAVE_CHUNK level-0 buckets of the
// first unfinished clip, then its upper levels when level 0 is complete.
// True when a clip finished (the table should be published).
wave_builder_step :: proc(b: ^Wave_Builder) -> (finished: bool) {
	t := &b.table
	for &c, i in t.clips[:b.media_clips] {
		if c.levels > 0 {
			continue
		}
		src := b.sources[i].samples
		n0 := int(c.count[0])
		lo := b.filled[i]
		hi := min(lo + WAVE_CHUNK, n0)
		level0 := t.peaks[c.offset[0]:][:n0]
		for bucket in lo ..< hi {
			s0 := bucket * WAVE_BUCKET * 2
			s1 := min(s0 + WAVE_BUCKET * 2, len(src))
			mn, mx: f32
			for x in src[s0:s1] {
				mn = min(mn, x)
				mx = max(mx, x)
			}
			level0[bucket] = {i8(clamp(mn, -1, 1) * 127), i8(clamp(mx, -1, 1) * 127)}
		}
		b.filled[i] = hi
		if hi < n0 {
			return false
		}
		pyramid_levels(t, &c)
		return true
	}
	// A group's sound once its tracks' is known: each track's level 0 at its
	// place, shaped by its fades.
	for g in b.groups {
		c := &t.clips[g.clip]
		if c.levels > 0 {
			continue
		}
		level0 := t.peaks[c.offset[0]:][:c.count[0]]
		start := max(int)
		for k in b.group_lanes[g.first:][:g.count] {
			start = min(start, t.lanes[k].start)
		}
		for k in b.group_lanes[g.first:][:g.count] {
			l := t.lanes[k]
			tc := t.clips[l.clip]
			src := t.peaks[tc.offset[0]:][:tc.count[0]]
			length := l.end - l.start
			for tb := (l.start - start) / WAVE_BUCKET; tb * WAVE_BUCKET + start < l.end && tb < len(level0); tb += 1 {
				into := max(tb * WAVE_BUCKET + start - l.start, 0)
				cb := (l.file_start + into) / WAVE_BUCKET
				if cb < 0 || cb >= len(src) {
					continue
				}
				env := om.track_envelope_peak(into, into + WAVE_BUCKET, length, l.fade_in, l.fade_out, l.curve)
				pk := src[cb]
				mn, mx := i8(f32(pk[0]) * env), i8(f32(pk[1]) * env)
				level0[tb] = {min(level0[tb][0], mn), max(level0[tb][1], mx)}
			}
		}
		pyramid_levels(t, c)
		return true
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
