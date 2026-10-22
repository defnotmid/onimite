package onimite

import "core:strings"
import "core:sync"
import oanalyze "deps:odawg/analyze"

// Onsets: where sounds start (hits, notes, words), and the steady beat
// they imply, so a script or an agent that can't listen can place cues on
// the music: odawg's analysis (analyze/onsets) of interleaved stereo at
// MIX_RATE (a clip, a mix).

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

// Onsets of media clips, computed once per clip and shared by everything
// that uses the media (every frame builder of a render). A clip replaced
// under the same name (a preview reload) is analysed again.
Onset_Cache :: struct {
	mutex:   sync.Mutex,
	entries: map[string]Onset_Cache_Entry,
}

@(private)
Onset_Cache_Entry :: struct {
	samples: rawptr, // the clip analysed
	report:  oanalyze.Onsets,
}

// The onsets of clip `name` (borrowed from the cache until the media is
// destroyed or the clip replaced); false when there is no such clip.
media_onsets :: proc(m: ^Media, name: string) -> (r: oanalyze.Onsets, ok: bool) {
	clip, has := m.audio[name]
	if !has {
		return {}, false
	}
	c := m.onsets
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	if e, seen := &c.entries[name]; seen {
		if e.samples == raw_data(clip.samples) {
			return e.report, true
		}
		oanalyze.onsets_destroy(&e.report)
		l, rr := channels_from_interleaved(clip.samples[:clip.frames * 2])
		e^ = {raw_data(clip.samples), oanalyze.onsets_from_samples(l, rr, MIX_RATE, c.entries.allocator)}
		return e.report, true
	}
	l, rr := channels_from_interleaved(clip.samples[:clip.frames * 2])
	e := Onset_Cache_Entry{raw_data(clip.samples), oanalyze.onsets_from_samples(l, rr, MIX_RATE, c.entries.allocator)}
	c.entries[strings.clone(name, c.entries.allocator)] = e
	return e.report, true
}

@(private)
onset_cache_destroy :: proc(c: ^Onset_Cache) {
	for name, &e in c.entries {
		delete(name, c.entries.allocator)
		oanalyze.onsets_destroy(&e.report)
	}
	delete(c.entries)
}
