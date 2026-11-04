package onimite

import "base:runtime"
import "core:strings"
import "core:sync"
import oanalyze "deps:odawg/analyze"
import orender "deps:odawg/render"

// What is measured of the media's clips, with odawg's analysis: onsets
// (analyze/onsets: where sounds start, hits, notes, words, and the steady
// beat they imply, so a script or an agent that can't listen can place cues
// on the music) and analysis tables (render's rows a video frame each: a
// spectrum, an energy), as a song's are (song_table).

// Interleaved stereo as two channels (temp memory), as odawg reads sound.
channels_from_interleaved :: proc(x: []f32) -> (l, r: []f32) {
	n := len(x) / 2
	buf := make([]f32, 2 * n, context.temp_allocator)
	l, r = buf[:n], buf[n:]
	for i in 0 ..< n {
		l[i], r[i] = x[i * 2], x[i * 2 + 1]
	}
	return
}

// The measures of each media clip, made on first use and shared by
// everything that uses the media (every frame builder of a render). A clip
// replaced under the same name (a preview reload) is measured again.
Clip_Analysis :: struct {
	mutex:   sync.Mutex,
	entries: map[string]Clip_Analysis_Entry,
}

@(private)
Clip_Analysis_Entry :: struct {
	samples:    rawptr, // the clip measured
	has_onsets: bool,
	onsets:     oanalyze.Onsets,
	// Heap memory: filled from whichever thread asks first.
	tables:     [dynamic]^Sound_Table,
}

// The onsets of clip `name` (borrowed until the media is destroyed or the
// clip replaced); false when there is no such clip.
media_onsets :: proc(m: ^Media, name: string) -> (r: oanalyze.Onsets, ok: bool) {
	clip, has := media_audio(m, name)
	if !has {
		return {}, false
	}
	c := m.analysis
	sync.guard(&c.mutex)
	e := clip_entry(c, name, clip)
	if !e.has_onsets {
		l, rr := channels_from_interleaved(clip.samples[:clip.frames * 2])
		e.onsets = oanalyze.onsets_from_samples(l, rr, MIX_RATE, c.entries.allocator)
		e.has_onsets = true
	}
	return e.onsets, true
}

// Clip `name`'s table of `kind` (`size`, `shape`: a spectrum's FFT), a row
// a video frame at `fps`, made on first ask, with steps `rows` (first,
// last) filled from the clip; nil when there is no such clip.
media_clip_table :: proc(m: ^Media, name: string, kind: orender.Table_Kind, fps: int, rows: [2]int, size := 0, shape := oanalyze.Window.None) -> ^Sound_Table {
	clip, has := media_audio(m, name)
	if !has {
		return nil
	}
	fps := max(fps, 1)
	st: ^Sound_Table
	{
		c := m.analysis
		sync.guard(&c.mutex)
		e := clip_entry(c, name, clip)
		for x in e.tables {
			t := &x.table
			if t.kind == kind && t.step_num == MIX_RATE && t.step_den == fps && t.size == size && t.shape == shape {
				st = x
				break
			}
		}
		if st == nil {
			a := runtime.heap_allocator()
			if e.tables == nil {
				e.tables = make([dynamic]^Sound_Table, a)
			}
			st = new(Sound_Table, a)
			orender.table_init_frames(&st.table, kind, clip.frames, MIX_RATE, fps, size, shape, a)
			st.filled = make([]u8, st.table.rows, a)
			append(&e.tables, st)
		}
	}
	clip_table_fill(st, clip, rows[0], rows[1])
	return st
}

// Fills the steps `first ..= last` of clip table `st` not filled yet, from
// the clip's samples (odawg's rule for each row: render.table_fill_steps).
@(private = "file")
clip_table_fill :: proc(st: ^Sound_Table, clip: Audio_Clip, first, last: int) {
	lo, hi := max(first, 0), min(last, len(st.filled) - 1)
	for lo <= hi && sync.atomic_load(&st.filled[lo]) != 0 {
		lo += 1
	}
	if lo > hi {
		return
	}
	sync.guard(&st.lock)
	for lo <= hi && st.filled[lo] != 0 {
		lo += 1
	}
	for hi >= lo && st.filled[hi] != 0 {
		hi -= 1
	}
	if lo > hi {
		return
	}
	t := &st.table
	for step := lo; step <= hi; {
		if st.filled[step] != 0 {
			step += 1
			continue
		}
		end := step + 1
		for end <= hi && st.filled[end] == 0 {
			end += 1
		}
		from := orender.row_start(t, step)
		to := min(orender.row_start(t, end - 1) + orender.table_window(t), clip.frames)
		l, r := channels_from_interleaved(clip.samples[2 * from:2 * max(to, from)])
		orender.table_fill_steps(t, step, end, from, l, r)
		for k in step ..< end {
			sync.atomic_store(&st.filled[k], 1)
		}
		step = end
	}
}

// Clip `clip`'s entry under `name` (`c.mutex` held), emptied first when the
// clip there is another than the one measured.
@(private = "file")
clip_entry :: proc(c: ^Clip_Analysis, name: string, clip: Audio_Clip) -> ^Clip_Analysis_Entry {
	if _, seen := c.entries[name]; !seen {
		c.entries[strings.clone(name, c.entries.allocator)] = {}
	}
	e := &c.entries[name]
	if e.samples != raw_data(clip.samples) {
		clip_entry_clear(e)
		e.samples = raw_data(clip.samples)
	}
	return e
}

@(private = "file")
clip_entry_clear :: proc(e: ^Clip_Analysis_Entry) {
	if e.has_onsets {
		oanalyze.onsets_destroy(&e.onsets)
	}
	a := runtime.heap_allocator()
	for st in e.tables {
		orender.table_destroy(&st.table, a)
		delete(st.filled, a)
		free(st, a)
	}
	delete(e.tables)
	e^ = {}
}

@(private)
clip_analysis_destroy :: proc(c: ^Clip_Analysis) {
	for name, &e in c.entries {
		delete(name, c.entries.allocator)
		clip_entry_clear(&e)
	}
	delete(c.entries)
}
