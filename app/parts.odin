package onimite_app

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import oanalyze "deps:odawg/analyze"
import obase "deps:odawg/base"
import osong "deps:odawg/song"
import om "../onimite"
import script "../script"

// `audio parts`: each song the script makes, rendered alone, part by part:
// how many notes it plays, the first of them, its loudness and peak. With
// `--against FILE` (an earlier `--json` of it) it says what drifted and
// fails: the check that an odawg release (or an edit) leaves a song as it
// was, read without listening.

// How many of a part's notes are listed (in time order).
PART_FIRST_NOTES :: 8

// How far a part's loudness may move before it drifts, in LU.
PART_DRIFT_LU :: 1.0

Part_Row :: struct {
	name:    string   `json:"name"`,
	notes:   int      `json:"notes"`,
	first:   []string `json:"first"`,
	lufs:    f64      `json:"lufs"`, // integrated, to 0.1; -100 when silent
	peak_db: f64      `json:"peak_db"`,
}

Song_Parts :: struct {
	name:  string     `json:"name"`,
	at:    string     `json:"at"`,
	parts: []Part_Row `json:"parts"`,
}

Audio_Parts_Result :: struct {
	songs: []Song_Parts `json:"songs"`,
	drift: []string     `json:"drift"`,
}

@(private)
audio_parts :: proc(app: ^App_State, regs: Command_Regs) -> Error {
	// songs' renders meter each part
	om.music_set_measures(&app.media, {.Parts})
	build_audio(app) or_return
	s := &app.script
	songs := make([dynamic]Song_Parts, context.temp_allocator)
	for x in s.songs {
		if x.sound {
			continue
		}
		append(&songs, song_parts(x))
	}
	res := Audio_Parts_Result{songs = songs[:]}
	b := strings.builder_make(context.temp_allocator)
	for sp in songs {
		fmt.sbprintf(&b, "song %s  %s\n", sp.name, sp.at)
		for p in sp.parts {
			fmt.sbprintf(&b, "  %-12s %5s notes  %6s LUFS  %6s dB peak  %s\n", p.name, fmt.tprint(p.notes), fmt.tprintf("%.1f", p.lufs), fmt.tprintf("%.1f", p.peak_db), strings.join(p.first, " ", context.temp_allocator))
		}
	}
	if len(songs) == 0 {
		strings.write_string(&b, "no songs (sound{} one-shots aren't listed)\n")
	}
	if regs.path != "" {
		drift, ok := parts_drift(songs[:], regs.path)
		if !ok {
			return fail(app, {code = .Parts_Read, path = regs.path})
		}
		res.drift = drift
		for d in drift {
			fmt.sbprintf(&b, "drift: %s\n", d)
		}
		if len(drift) == 0 {
			fmt.sbprintf(&b, "no drift from %s\n", regs.path)
		} else {
			app.exit_code = 1
		}
	}
	emit(app, res, strings.trim_right(strings.to_string(b), "\n"))
	return nil
}

// One song's parts' rows, from its render (made once, alone: the song's
// own render, which measured each part as it was made).
@(private = "file")
song_parts :: proc(x: script.Script_Song) -> Song_Parts {
	om.song_render_build(x.clip)
	rd := &x.clip.render
	g := &x.clip.song
	n := len(g.parts)
	rows := make([]Part_Row, n, context.temp_allocator)
	for name, i in g.parts {
		l := oanalyze.loudness_from_meter(&rd.part_meters[i], context.temp_allocator)
		row := Part_Row{name = name, lufs = -100, peak_db = -100}
		if !math.is_inf(l.integrated) && l.integrated > -100 {
			row.lufs = math.round(l.integrated * 10) / 10
		}
		if rd.part_peaks[i] > 0 {
			row.peak_db = math.round(obase.gain_to_db(f64(rd.part_peaks[i])) * 10) / 10
		}
		// its played notes in time order (not the ones made at compose: a
		// release trigger's, a keyswitch), named as odawg names them
		Timed :: struct {
			time: f64,
			name: string,
		}
		notes := make([dynamic]Timed, context.temp_allocator)
		for tr in g.tracks {
			if int(tr.part) != i {
				continue
			}
			for k in tr.notes.first ..< tr.notes.first + tr.notes.count {
				if g.notes.kind[k] != .Attack {
					continue
				}
				append(&notes, Timed{g.notes.time[k], osong.note_name(g, g.notes.pad[k], g.notes.pitch[k])})
			}
		}
		slice.stable_sort_by(notes[:], proc(a, b: Timed) -> bool {return a.time < b.time})
		row.notes = len(notes)
		first := make([]string, min(len(notes), PART_FIRST_NOTES), context.temp_allocator)
		for &f, k in first {
			f = notes[k].name
		}
		row.first = first
		rows[i] = row
	}
	slice.sort_by(rows, proc(a, b: Part_Row) -> bool {return a.name < b.name})
	return {x.name, x.at, rows}
}

// What changed from an earlier `--json` of the same script: parts gone or
// new, other note counts or first notes, a level moved by more than
// PART_DRIFT_LU, a part gone silent or heard. False when the file can't be
// read as one.
@(private = "file")
parts_drift :: proc(now: []Song_Parts, path: string) -> (out: []string, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return nil, false
	}
	was: Audio_Parts_Result
	if json.unmarshal(data, &was, allocator = context.temp_allocator) != nil {
		return nil, false
	}
	drift := make([dynamic]string, context.temp_allocator)
	find_song :: proc(list: []Song_Parts, name: string) -> ^Song_Parts {
		for &x in list {
			if x.name == name {
				return &x
			}
		}
		return nil
	}
	find_part :: proc(list: []Part_Row, name: string) -> ^Part_Row {
		for &x in list {
			if x.name == name {
				return &x
			}
		}
		return nil
	}
	for &w in was.songs {
		n := find_song(now, w.name)
		if n == nil {
			append(&drift, fmt.tprintf("song %s is gone", w.name))
			continue
		}
		for &a in w.parts {
			b := find_part(n.parts, a.name)
			if b == nil {
				append(&drift, fmt.tprintf("%s/%s is gone", w.name, a.name))
				continue
			}
			if a.notes != b.notes {
				append(&drift, fmt.tprintf("%s/%s plays %d notes, was %d", w.name, a.name, b.notes, a.notes))
			} else if !slice.equal(a.first, b.first) {
				append(&drift, fmt.tprintf("%s/%s starts %s, was %s", w.name, a.name, strings.join(b.first, " ", context.temp_allocator), strings.join(a.first, " ", context.temp_allocator)))
			}
			switch {
			case (a.lufs <= -100) != (b.lufs <= -100):
				append(&drift, fmt.tprintf("%s/%s is %s, was %s", w.name, a.name, "silent" if b.lufs <= -100 else "heard", "silent" if a.lufs <= -100 else "heard"))
			case abs(b.lufs - a.lufs) > PART_DRIFT_LU:
				append(&drift, fmt.tprintf("%s/%s is %.1f LUFS, was %.1f (%+.1f)", w.name, a.name, b.lufs, a.lufs, b.lufs - a.lufs))
			}
		}
		for b in n.parts {
			if find_part(w.parts, b.name) == nil {
				append(&drift, fmt.tprintf("%s/%s is new", w.name, b.name))
			}
		}
	}
	for n in now {
		if find_song(was.songs, n.name) == nil {
			append(&drift, fmt.tprintf("song %s is new", n.name))
		}
	}
	return drift[:], true
}
