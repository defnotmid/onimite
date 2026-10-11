package onimite_app

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
import script "../script"

// What the render worker derives from a load for the preview's panels,
// published through the mailbox as flat tables: rows indexed by id, their
// strings in one byte arena per table (`Text_Span`s into it). The worker
// fills its own copy, copies it into the mailbox when it changes, and the UI
// copies it out when the table's sequence number moved. Copies reuse the
// destination's capacity, so a warm preview allocates nothing for them.
//
// - Problems: diagnostics seen since the last load, grouped by key like
//   `inspect`, with the frame range they were seen in. The status line and
//   the problems list read these, so they hold still while frames change.
// - The timeline: its items as a flat tree (scenes, cues, the groups of
//   tracks a bus mixes, the tracks), each a kind the UI draws its own way;
//   one lane per placed audio track and per group, and per audio clip a
//   min/max peak pyramid (level k: one pair per WAVE_BUCKET << k samples),
//   computed once per media load on the worker when it is idle; a group's
//   pyramid is its tracks' together. Any zoom reads the level whose bucket
//   is just under a pixel's samples, in O(pixels).
// - Media: the loaded media as rows (kind, name, details, first use), with
//   small image thumbnails as straight RGBA in a pixel arena.

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

// ---- problems ---------------------------------------------------------------------------

Preview_Problem :: struct {
	severity:    om.Severity,
	code:        om.Diagnostic_Code,
	// The first and last frame it was seen in (renders arrive in any
	// order); LOAD_FRAME for what the load found.
	first, last: int,
	scene:       Text_Span,
	message:     Text_Span,
}

Problem_Table :: struct {
	rows: [dynamic]Preview_Problem,
	text: [dynamic]u8,
}

problem_table_clear :: proc(t: ^Problem_Table) {
	clear(&t.rows)
	clear(&t.text)
}

problem_table_destroy :: proc(t: ^Problem_Table) {
	delete(t.rows)
	delete(t.text)
}

problem_table_copy :: proc(dst: ^Problem_Table, src: ^Problem_Table) {
	table_copy(&dst.rows, src.rows[:])
	table_copy(&dst.text, src.text[:])
}

// The problems panel's rows from the worker's findings, their text made
// here (`tl` names the scenes; nil before there is a timeline).
problem_table_set :: proc(t: ^Problem_Table, f: ^Finding_Table, tl: ^om.Timeline) {
	problem_table_clear(t)
	for row, i in f.rows {
		scenes := finding_scenes(f, tl, i) if tl != nil else nil
		message := om.diagnostic_message(row.diagnostic, context.temp_allocator)
		append(&t.rows, Preview_Problem{row.diagnostic.severity, row.diagnostic.code, row.first, row.last, text_push(&t.text, strings.join(scenes, " + ", context.temp_allocator)), text_push(&t.text, message)})
	}
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

Media_Kind :: enum u8 {
	Image,
	Video,
	Audio,
	Font,
	Subtitles,
	Shader,
}

MEDIA_THUMB :: 64 // image thumbnails fit this square

Media_Row :: struct {
	kind:         Media_Kind,
	name, detail: Text_Span,
	// The first frame the item plays on the timeline (-1: unknown or unused).
	first_frame:  int,
	// Straight RGBA in `Media_Table.pixels` (images; size 0 otherwise).
	thumb:        u32,
	thumb_size:   [2]u16,
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

// Fills `t` from the media; first uses come from the placed tracks. Runs on
// the worker; image thumbnails are reserved and filled in later steps by
// media_table_thumbs.
media_table_build :: proc(t: ^Media_Table, m: ^om.Media, placed: []om.Placed_Track, fps: int) {
	clear(&t.rows)
	clear(&t.text)
	clear(&t.pixels)
	t.thumbs_ready = 0
	sorted_keys :: proc(keys: []string) -> []string {
		slice.sort(keys)
		return keys
	}
	first_use :: proc(placed: []om.Placed_Track, name: string, fps: int) -> int {
		best := -1
		for p in placed {
			if p.track.src == name {
				f := int(i64(p.start) * i64(fps) / om.MIX_RATE)
				best = f if best < 0 else min(best, f)
			}
		}
		return best
	}
	clock :: proc(seconds: f64) -> string {
		return fmt.tprintf("%d:%04.1f", int(seconds) / 60, math.mod(seconds, 60))
	}

	names := make([dynamic]string, context.temp_allocator)
	for name in m.images {
		append(&names, name)
	}
	for name in sorted_keys(names[:]) {
		img := m.images[name]
		row := Media_Row{kind = .Image, first_frame = -1}
		row.name = text_push(&t.text, name)
		row.detail = text_push(&t.text, fmt.tprintf("%d×%d", img.width, img.height) if img.width > 0 else "can not read")
		tw, th := img.width, img.height
		if tw > MEDIA_THUMB || th > MEDIA_THUMB {
			s := f32(MEDIA_THUMB) / f32(max(tw, th))
			tw, th = max(int(f32(tw) * s), 1), max(int(f32(th) * s), 1)
		}
		// Reserved here, filled by media_table_thumbs.
		row.thumb = u32(len(t.pixels))
		row.thumb_size = {u16(tw), u16(th)}
		resize(&t.pixels, len(t.pixels) + tw * th * 4)
		append(&t.rows, row)
	}

	v := &m.videos
	clear(&names)
	for name in v.names {
		append(&names, name)
	}
	for name in sorted_keys(names[:]) {
		i := v.by_name[name]
		info := v.infos[i]
		detail := fmt.tprintf("%d×%d · %s · %.3g fps", info.width, info.height, clock(info.duration), info.fps)
		if v.handles[i] < 0 {
			detail = fmt.tprintf("can not open: %s", om.video_failure_message(v.failures[i], context.temp_allocator))
		}
		append(&t.rows, Media_Row{kind = .Video, name = text_push(&t.text, name), detail = text_push(&t.text, detail), first_frame = first_use(placed, name, fps)})
	}

	clear(&names)
	for name in m.audio {
		if _, is_video := v.by_name[name]; !is_video {
			append(&names, name)
		}
	}
	for name in sorted_keys(names[:]) {
		clip := m.audio[name]
		detail := fmt.tprintf("%s · %d Hz · %s", clock(f64(om.audio_clip_seconds(clip))), clip.source_rate, "mono" if clip.source_channels == 1 else "stereo")
		append(&t.rows, Media_Row{kind = .Audio, name = text_push(&t.text, name), detail = text_push(&t.text, detail), first_frame = first_use(placed, name, fps)})
	}

	for face in m.fonts.faces {
		detail := fmt.tprintf("%s %d%s", weight_name(face.weight), face.weight, " italic" if face.italic else "")
		append(&t.rows, Media_Row{kind = .Font, name = text_push(&t.text, face.family), detail = text_push(&t.text, detail), first_frame = -1})
	}

	clear(&names)
	// Every subtitle file has captions too; caption .json files only captions.
	for name in m.captions {
		append(&names, name)
	}
	for name in sorted_keys(names[:]) {
		caps := &m.captions[name]
		detail := fmt.tprintf("%d words", om.caption_count(caps))
		if subs, ok := m.subtitles[name]; ok {
			detail = fmt.tprintf("%d cues, %s", len(subs.starts), detail)
		}
		append(&t.rows, Media_Row{kind = .Subtitles, name = text_push(&t.text, name), detail = text_push(&t.text, detail), first_frame = -1})
	}

	clear(&names)
	for name in m.shaders {
		append(&names, name)
	}
	for name in sorted_keys(names[:]) {
		lines := strings.count(m.shaders[name], "\n") + 1
		append(&t.rows, Media_Row{kind = .Shader, name = text_push(&t.text, name), detail = text_push(&t.text, fmt.tprintf("%d lines", lines)), first_frame = -1})
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

@(private = "file")
weight_name :: proc(weight: int) -> string {
	switch {
	case weight <= 150:
		return "Thin"
	case weight <= 250:
		return "Extra Light"
	case weight <= 350:
		return "Light"
	case weight <= 450:
		return "Regular"
	case weight <= 550:
		return "Medium"
	case weight <= 650:
		return "Semi Bold"
	case weight <= 750:
		return "Bold"
	case weight <= 850:
		return "Extra Bold"
	}
	return "Black"
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
