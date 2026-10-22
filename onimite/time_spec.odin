package onimite

import "core:strconv"
import "core:strings"
import osong "deps:odawg/song"

// Addressing frames and ranges from the command line, as in fframes:
//
// | spec            | meaning                                           |
// |-----------------|---------------------------------------------------|
// | `120`, `120f`   | frame 120                                         |
// | `3.2s`, `1:05.5`| a timestamp (`m:ss` and `h:mm:ss` work too)       |
// | `50%`           | a fraction of the whole video                     |
// | `start`, `end`  | the first / last frame                            |
// | `Intro`         | the first frame of the scene `Intro`              |
// | `#3`            | the first frame of scene index 3                  |
// | `Intro[1]`      | the second scene named `Intro` (0-based)          |
// | `Intro@1.2s`    | 1.2 s into the scene (also `@12`, `@50%`, `@end`) |
// | `drop`          | the frame of the cue or sync id `drop`            |
// | `drop@0.5s`     | 0.5 s after it (`@-0.5s` before, `@12` frames)    |
// | `drop@1m`       | a bar after a song's section or marker `drop`     |
//
// A song's section or marker (a cue, with the media's songs given) also
// takes Tone's lengths on the song's tempo: `@1m`, `@-4n`, `@8n.`, `@8t`
// and `@2:1:0` (bars:quarters:sixteenths), bars in that section's meter.
// Those are musical even when a scene shares the name: a unit `m`, `n` or
// `t`, or three `:` fields. Seconds, frames and `m:ss` keep their meaning,
// so `race@2:2` is 2:02 into the scene `race`, `race@2:1:0` two bars and a
// beat into the section (`h:mm:ss` into such a scene: write seconds).
//
// Ranges are `a..b` (end exclusive, so `b` may be the frame count), `a..`,
// `..b`, `all`, or a scene name for the whole scene. A scene name right of
// `..` means the end of that scene. A name several scenes share needs `[n]`
// or `#index`; a scene's name wins over a cue's. Frames outside the video
// are `.Out_Of_Range`: the valid ones are 0..duration_frames - 1. An offset
// past its scene's end is `.Past_Scene` (it would name a frame of another
// scene).

// A time a spec can name besides the scenes: a cue or another sync id, on
// the video clock.
Named_Time :: struct {
	name:    string,
	seconds: f64,
}

// `m`: the media whose songs' sections and markers take musical offsets.
parse_frame :: proc(t: Timeline, fps: int, spec: string, names: []Named_Time = nil, m: ^Media = nil) -> (frame: int, err: Error) {
	return frame_up_to(t, fps, spec, names, m, t.duration_frames - 1, false)
}

// A frame spec resolving to at most `last`. An offset into a scene must
// land inside it (`.Past_Scene`), or on its end when `scene_end` (the
// exclusive end of a range).
@(private = "file")
frame_up_to :: proc(t: Timeline, fps: int, spec: string, names: []Named_Time, m: ^Media, last: int, scene_end: bool) -> (frame: int, err: Error) {
	s := strings.trim_space(spec)
	name, at, offset := strings.partition(s, "@")
	name = strings.trim_space(name)
	has_offset := at != ""
	scene, serr := scene_spec(t, name)
	named, is_named := named_time(names, name)
	musical, is_musical := 0.0, false
	if is_named && has_offset && is_tone_length(offset) {
		musical, is_musical = song_position(m, name, named, offset)
	}
	switch {
	case is_musical:
		frame = frame_at(musical, fps)
	case serr == nil && has_offset:
		info := t.scenes[scene]
		local := parse_offset(offset, fps, scene_info_frames(info)) or_return
		if local > scene_info_frames(info) || local == scene_info_frames(info) && !scene_end {
			return info.start_frame + local, .Past_Scene
		}
		frame = info.start_frame + local
	case serr == nil:
		frame = t.scenes[scene].start_frame
	case is_named && has_offset:
		// A moment has no length: `@50%` and `@end` mean nothing.
		o := strings.trim_space(offset)
		if o == "end" || strings.has_suffix(o, "%") {
			return 0, .Invalid_Time_Spec
		}
		frame = frame_at(named, fps) + (parse_offset(o, fps, 0) or_return)
	case is_named:
		frame = frame_at(named, fps)
	case has_offset || is_scene_like(s) && !is_keyword(s):
		return 0, serr
	case:
		frame = parse_offset(s, fps, t.duration_frames) or_return
	}
	if frame < 0 || frame > last {
		return frame, .Out_Of_Range
	}
	return frame, nil
}

// The seconds of the time `name` names (case-insensitive; the first of
// several), unless it is a keyword.
@(private = "file")
named_time :: proc(names: []Named_Time, name: string) -> (seconds: f64, ok: bool) {
	if is_keyword(name) {
		return 0, false
	}
	for n in names {
		if equal_fold(n.name, name) {
			return n.seconds, true
		}
	}
	return 0, false
}

// Video seconds of `offset` (a Tone length) from the cue `name` at video
// seconds `at`: the section or marker of the media's song that is there
// (case-insensitive; a sound's sections are no cues, and may share it).
@(private = "file")
song_position :: proc(m: ^Media, name: string, at: f64, offset: string) -> (seconds: f64, ok: bool) {
	for sc in media_songs(m) {
		anchor := ""
		for sec in sc.song.sections {
			if equal_fold(sec.name, name) && abs(sc.song.start + sec.start - at) < 1e-6 {
				anchor = sec.name
				break
			}
		}
		for mk in sc.song.markers {
			if anchor == "" && equal_fold(mk.name, name) && abs(sc.song.start + mk.seconds - at) < 1e-6 {
				anchor = mk.name
			}
		}
		if anchor == "" {
			continue
		}
		text := strings.concatenate({anchor, "@", strings.trim_space(offset)}, context.temp_allocator)
		t := osong.seconds_from_position(&sc.song, text) or_return
		return sc.song.start + t, true
	}
	return 0, false
}

// Whether an offset is a Tone length rather than one of ours: `1m`, `4n`,
// `8n.`, `8t` (signed), or three fields `bars:quarters:sixteenths`.
@(private = "file")
is_tone_length :: proc(offset: string) -> bool {
	s := strings.trim_space(offset)
	if len(s) > 0 && (s[0] == '-' || s[0] == '+') {
		s = s[1:]
	}
	if strings.count(s, ":") == 2 {
		for part in strings.split(s, ":", context.temp_allocator) {
			if _, ok := strconv.parse_f64(part); !ok {
				return false
			}
		}
		return true
	}
	s = strings.trim_suffix(s, ".")
	if len(s) < 2 {
		return false
	}
	unit := s[len(s) - 1]
	if unit != 'm' && unit != 'n' && unit != 't' {
		return false
	}
	_, ok := strconv.parse_f64(s[:len(s) - 1])
	return ok
}

// `[start, end)` frames of a range spec.
parse_range :: proc(t: Timeline, fps: int, spec: string, names: []Named_Time = nil, m: ^Media = nil) -> (start, end: int, err: Error) {
	s := strings.trim_space(spec)
	if s == "all" || s == "" {
		return 0, t.duration_frames, nil if t.duration_frames > 0 else .Out_Of_Range
	}
	dots := strings.index(s, "..")
	if dots < 0 {
		if scene, serr := scene_spec(t, s); serr == nil {
			info := t.scenes[scene]
			return info.start_frame, min(info.end_frame, t.duration_frames), nil
		}
		f := parse_frame(t, fps, s, names, m) or_return
		return f, f + 1, nil
	}
	left, right := s[:dots], s[dots + 2:]
	start = 0
	end = t.duration_frames
	if left != "" {
		start = parse_frame(t, fps, left, names, m) or_return
	}
	if right != "" {
		if scene, serr := scene_spec(t, right); serr == nil {
			end = min(t.scenes[scene].end_frame, t.duration_frames)
		} else if strings.trim_space(right) == "end" {
			end = t.duration_frames
		} else {
			end = frame_up_to(t, fps, right, names, m, t.duration_frames, true) or_return
		}
	}
	if end <= start {
		return start, end, .Out_Of_Range
	}
	return start, end, nil
}

@(private = "file")
is_keyword :: proc(s: string) -> bool {
	return s == "start" || s == "end" || s == "all"
}

@(private = "file")
is_scene_like :: proc(s: string) -> bool {
	return len(s) > 0 && ((s[0] >= 'A' && s[0] <= 'Z') || (s[0] >= 'a' && s[0] <= 'z') || s[0] == '#')
}

// The scene a spec names: `#index`, `Name` or `Name[n]` (case-insensitive).
@(private = "file")
scene_spec :: proc(t: Timeline, s: string) -> (int, Error) {
	if is_keyword(s) {
		return -1, .Unknown_Scene
	}
	if len(s) > 1 && s[0] == '#' {
		i, ok := strconv.parse_int(s[1:])
		if ok && i >= 0 && i < len(t.scenes) {
			return i, nil
		}
		return -1, .Unknown_Scene
	}
	name, nth := s, -1
	if strings.has_suffix(s, "]") {
		if open := strings.last_index_byte(s, '['); open > 0 {
			n, ok := strconv.parse_int(s[open + 1:len(s) - 1])
			if !ok || n < 0 {
				return -1, .Invalid_Time_Spec
			}
			name, nth = s[:open], n
		}
	}
	found, count := -1, 0
	for sc, i in t.scenes {
		if !equal_fold(sc.scene.name, name) {
			continue
		}
		if nth < 0 && count == 0 || count == nth {
			found = i
		}
		count += 1
	}
	switch {
	case count == 0:
		return -1, .Unknown_Scene
	case nth < 0 && count > 1:
		return -1, .Ambiguous_Scene
	case found < 0:
		return -1, .Unknown_Scene
	}
	return found, nil
}

// The scene index a spec's scene part names (`Intro`, `Intro[1]`, `#3`).
find_scene_spec :: proc(t: Timeline, s: string) -> (int, Error) {
	return scene_spec(t, strings.trim_space(s))
}

// A frame offset within `total` frames: `12`, `12f`, `1.5s`, `1:05`, `50%`,
// `start` or `end`.
@(private = "file")
parse_offset :: proc(spec: string, fps: int, total: int) -> (int, Error) {
	s := strings.trim_space(spec)
	switch {
	case s == "start":
		return 0, nil
	case s == "end":
		return max(total - 1, 0), nil
	case strings.has_suffix(s, "%"):
		v, ok := strconv.parse_f64(s[:len(s) - 1])
		if !ok {
			return 0, .Invalid_Time_Spec
		}
		return min(int(v / 100 * f64(total)), max(total - 1, 0)), nil
	case strings.has_suffix(s, "s"):
		v, ok := strconv.parse_f64(s[:len(s) - 1])
		if !ok {
			return 0, .Invalid_Time_Spec
		}
		return frame_at(v, fps), nil
	case strings.contains_rune(s, ':'):
		secs: f64 = 0
		for part in strings.split(s, ":", context.temp_allocator) {
			v, ok := strconv.parse_f64(part)
			if !ok {
				return 0, .Invalid_Time_Spec
			}
			secs = secs * 60 + v
		}
		return frame_at(secs, fps), nil
	case strings.has_suffix(s, "f"):
		v, ok := strconv.parse_int(s[:len(s) - 1])
		return v, nil if ok else .Invalid_Time_Spec
	}
	v, ok := strconv.parse_int(s)
	return v, nil if ok else .Invalid_Time_Spec
}
