package onimite_app

import "core:fmt"
import "core:hash"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import om "../onimite"
import script "../script"

// Problems grouped across frames: one finding per key (text moving around
// stays one finding), with the frames and scenes it was seen in. inspect,
// render and the preview's problems panel fill one the same way, from the
// frames they draw (every drawn frame is checked, onimite/check.odin) and
// from what the load found (`load_diagnostics`, as LOAD_FRAME).

// The frame of a finding the load made: seen in no frame.
LOAD_FRAME :: -1

Finding_Row :: struct {
	key:         u64,
	// The first diagnostic seen (strings in the table's arena).
	diagnostic:  om.Diagnostic,
	// The script line that made the node it is about ("" when none).
	source:      string,
	// The first and last frame it was seen in (frames may come in any
	// order), and in how many; LOAD_FRAME and 0 for the load's.
	first, last: int,
	frames:      int,
	counted:     int,
}

Finding_Table :: struct {
	rows:   [dynamic]Finding_Row,
	by_key: map[u64]int,
	// (row, scene index) pairs: the scenes each finding was seen in.
	scenes: [dynamic][2]i32,
	arena:  virtual.Arena,
}

finding_table_destroy :: proc(t: ^Finding_Table) {
	delete(t.rows)
	delete(t.by_key)
	delete(t.scenes)
	virtual.arena_destroy(&t.arena)
	t^ = {}
}

finding_table_clear :: proc(t: ^Finding_Table) {
	clear(&t.rows)
	clear(&t.by_key)
	clear(&t.scenes)
	virtual.arena_free_all(&t.arena)
}

// Adds diagnostic `d` seen in `frame` (LOAD_FRAME: found by the load; `tl`
// may then be nil) and returns whether that made a new finding or widened
// one's frames.
finding_add :: proc(t: ^Finding_Table, tl: ^om.Timeline, frame: int, d: om.Diagnostic, source := "") -> (changed: bool) {
	key := om.diagnostic_key(d, context.temp_allocator)
	h := hash.fnv64a(transmute([]u8)key, u64(d.severity) << 1 | u64(frame == LOAD_FRAME))
	idx, seen := t.by_key[h]
	if !seen {
		a := virtual.arena_allocator(&t.arena)
		kept := d
		kept.scene = ""
		kept.name = strings.clone(d.name, a)
		kept.a = strings.clone(d.a, a)
		kept.b = strings.clone(d.b, a)
		kept.shader.name = strings.clone(d.shader.name, a)
		kept.shader.a = strings.clone(d.shader.a, a)
		kept.shader.b = strings.clone(d.shader.b, a)
		kept.shader.c = strings.clone(d.shader.c, a)
		idx = len(t.rows)
		t.by_key[h] = idx
		append(&t.rows, Finding_Row{key = h, diagnostic = kept, source = strings.clone(source, a), first = frame, last = frame, counted = LOAD_FRAME})
		changed = true
	}
	row := &t.rows[idx]
	if frame == LOAD_FRAME || row.counted == frame {
		return
	}
	if frame < row.first || frame > row.last {
		row.first, row.last = min(row.first, frame), max(row.last, frame)
		changed = true
	}
	row.frames += 1
	row.counted = frame
	if tl == nil {
		return
	}
	for s, k in tl.scenes {
		if frame < s.start_frame || frame >= s.end_frame {
			continue
		}
		pair := [2]i32{i32(idx), i32(k)}
		if !slice.contains(t.scenes[:], pair) {
			append(&t.scenes, pair)
		}
	}
	return
}

// The worst severity among the findings (ok = false when there are none).
findings_worst :: proc(t: ^Finding_Table) -> (worst: om.Severity, ok: bool) {
	for row in t.rows {
		if !ok || row.diagnostic.severity > worst {
			worst, ok = row.diagnostic.severity, true
		}
	}
	return
}

// The scenes finding `row` was seen in, by name (temp memory, borrowed).
@(private)
finding_scenes :: proc(t: ^Finding_Table, tl: ^om.Timeline, row: int) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for p in t.scenes {
		if int(p[0]) == row && int(p[1]) < len(tl.scenes) {
			append(&names, tl.scenes[p[1]].scene.name)
		}
	}
	return names[:]
}

// The findings as printed, most severe first, then by first frame (the
// load's first), in `allocator`.
findings_report :: proc(t: ^Finding_Table, tl: ^om.Timeline, fps: int, allocator := context.temp_allocator) -> []Finding {
	order := make([]int, len(t.rows), context.temp_allocator)
	for &o, i in order {
		o = i
	}
	context.user_ptr = t
	slice.stable_sort_by(order, proc(a, b: int) -> bool {
		rows := (^Finding_Table)(context.user_ptr).rows[:]
		x, y := rows[a], rows[b]
		if x.diagnostic.severity != y.diagnostic.severity {
			return x.diagnostic.severity > y.diagnostic.severity
		}
		return x.first < y.first
	})
	out := make([]Finding, len(order), allocator)
	fps := f32(max(fps, 1))
	for k, i in order {
		row := t.rows[k]
		d := reported(row.diagnostic, row.source, allocator)
		first, last := max(row.first, 0), max(row.last, 0)
		names := finding_scenes(t, tl, k)
		scenes := make([]string, len(names), allocator)
		for n, j in names {
			scenes[j] = strings.clone(n, allocator)
		}
		out[i] = {d.severity, d.code, d.message, d.fields, first, last, f32(first) / fps, f32(last) / fps, row.frames, scenes, d.source}
	}
	return out
}

// The findings, one per line: when (or "at load"), the scenes, the script
// line and the message.
findings_text :: proc(b: ^strings.Builder, findings: []Finding) {
	for f in findings {
		title := fmt.tprintf("%c%s", f.severity[0] - 32, f.severity[1:]) if f.severity != "" else ""
		if f.frames == 0 {
			fmt.sbprintf(b, "\n%s at load: %s", title, f.message)
			continue
		}
		fmt.sbprintf(
			b,
			"\n%s %.2fs..%.2fs (frames %d..%d, seen in %d)%s: %s%s",
			title,
			f.first_seconds,
			f.last_seconds,
			f.first_frame,
			f.last_frame,
			f.frames,
			scenes_label(f.scenes),
			f.source != "" ? fmt.tprintf("%s: ", f.source) : "",
			f.message,
		)
	}
}

// What the load found (temp memory, strings borrowed): the script's
// warnings, the media folder's problems, and tracks playing a sound the
// media lacks or timed by the length of one (the mix leaves them out). `m`
// is nil when the load skipped the media (the preview's first load):
// nothing about the media is checked then.
load_diagnostics :: proc(s: ^script.Script, m: ^om.Media) -> []om.Diagnostic {
	out := make([dynamic]om.Diagnostic, context.temp_allocator)
	append(&out, ..s.load_problems[:])
	if m == nil {
		return out[:]
	}
	append(&out, ..m.problems[:])
	// Clips the script builds later (audio_add with a function) count.
	pending := script.audio_pending_names(s)
	check :: proc(out: ^[dynamic]om.Diagnostic, m: ^om.Media, pending: []string, tracks: []om.Audio_Track, fps: int) {
		for tr in tracks {
			if tr.src != "" && tr.src not_in m.audio && !slice.contains(pending, tr.src) {
				append(out, om.Diagnostic{severity = .Error, code = .Missing_Track, name = tr.source, a = tr.src})
				continue
			}
			for terms in ([2][]om.Time_Term{tr.start_terms, tr.stop_terms}) {
				if _, name, ok := om.terms_seconds(terms, fps, m); !ok && !slice.contains(pending, name) {
					append(out, om.Diagnostic{severity = .Error, code = .Missing_Track_Time, name = tr.source, a = name})
					break
				}
			}
		}
	}
	check(&out, m, pending, s.video.audio, s.video.fps)
	for sc in s.video.scenes {
		check(&out, m, pending, sc.audio, s.video.fps)
	}
	return out[:]
}
