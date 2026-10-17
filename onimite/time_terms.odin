package onimite

// Durations and audio timestamps that depend on media, after fframes'
// `Duration::{FromAudio, FromVideo, +, -}` and `AudioTimestamp`. A value is
// a flat list of signed terms summed in order; the result never goes below
// zero (fframes subtracts saturating).

Time_Term_Kind :: enum u8 {
	Seconds,
	Frames,
	// The length of an audio file in the media, or of a song (`value`
	// unused).
	Audio,
	// The length of a video clip in the media.
	Video,
}

Time_Term :: struct {
	kind:  Time_Term_Kind,
	// -1 subtracts the term.
	sign:  f32,
	value: f32,
	name:  string,
}

// A duration made of terms (`{ audio = "vo.wav" }`, `{ seconds = 2, plus = ... }`).
Duration_Terms :: distinct []Time_Term

// Length in seconds of a media file named by a term.
@(private = "file")
term_media_seconds :: proc(t: Time_Term, m: ^Media) -> (f64, bool) {
	if m == nil {
		return 0, false
	}
	#partial switch t.kind {
	case .Audio:
		if clip, found := m.audio[t.name]; found {
			return f64(clip.frames) / MIX_RATE, true
		}
		// a song lasts to the end of its last section
		if sc := media_song(m, t.name); sc != nil && sc.ok {
			return sc.song.duration, true
		}
		return 0, false
	case .Video:
		info, found := media_video_info(m, t.name)
		return info.duration, found
	}
	return 0, false
}

// Frames in `terms` at `fps`. Media lengths need `m`; `ok = false` names
// the first missing file in `missing`.
terms_frames :: proc(terms: []Time_Term, fps: int, m: ^Media) -> (frames: int, missing: string, ok: bool) {
	total: f64 = 0
	for t in terms {
		f: f64
		switch t.kind {
		case .Seconds:
			f = f64(frame_at(f64(t.value), fps))
		case .Frames:
			f = f64(t.value)
		case .Audio, .Video:
			secs, found := term_media_seconds(t, m)
			if !found {
				return 0, t.name, false
			}
			// fframes floors a file's length to whole frames.
			f = f64(frame_at(secs, fps))
		}
		total += f64(t.sign) * f
	}
	return max(int(total), 0), "", true
}

// Seconds in `terms`, for audio timestamps (exact, not floored to frames).
terms_seconds :: proc(terms: []Time_Term, fps: int, m: ^Media) -> (seconds: f64, missing: string, ok: bool) {
	total: f64 = 0
	for t in terms {
		s: f64
		switch t.kind {
		case .Seconds:
			s = f64(t.value)
		case .Frames:
			s = f64(t.value) / f64(max(fps, 1))
		case .Audio, .Video:
			secs, found := term_media_seconds(t, m)
			if !found {
				return 0, t.name, false
			}
			s = secs
		}
		total += f64(t.sign) * s
	}
	return max(total, 0), "", true
}
