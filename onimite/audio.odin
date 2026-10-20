package onimite

import "core:encoding/json"
import "core:math"
import "core:strings"
import odaudio "deps:odecs/audio"

// Sound: tracks placed on the video (or scene) clock, after fframes'
// `AudioMap`. Files decode once to stereo f32 at MIX_RATE.

MIX_RATE :: 48000

// Seconds; `stop <= start` means "until the file ends".
Audio_Track :: struct {
	src:      string,
	start:    f32,
	stop:     f32,
	// Seconds into the file where playback begins.
	offset:   f32,
	// File seconds per second, tape-style (pitch moves with it); negative
	// plays backwards from `offset`. 0 reads as 1.
	speed:    f32,
	gain_db:  f32,
	// -1 (left) to 1 (right).
	pan:      f32,
	fade_in:  f32,
	fade_out: f32,
	curve:    Fade_Curve,
	// A scene's track fades in over the scene's overlap with the previous
	// scene and out over its overlap with the next (equal power), added to
	// fade_in / fade_out when placed: its sound crosses with the picture.
	crossfade: bool,
	// Plays a stereo file as `0.707 * (L + R)` on both sides, ffmpeg's mono
	// downmix (fframes' include_media_dir! media). Mono files play as is.
	mono:     bool,
	// Voice tracks duck the tracks marked `ducked`.
	voice:    bool,
	ducked:   bool,
	duck:     Ducking,
	// A clip's effects in order, as a song part's `effects` is written
	// (odawg reads them; nil: none). Owned by the script.
	effects:  json.Value,
	// Timestamps made of terms (frames, minutes, audio lengths, sums) take
	// the place of `start` / `stop` when set (fframes' AudioTimestamp).
	start_terms: []Time_Term,
	stop_terms:  []Time_Term,
	// The cue the track's first sound lands on (`cue` in scripts).
	cue:         string,
	// The bus it is mixed through ("" for none): the bus's gain adds to
	// the track's.
	bus:         string,
	// The script line that placed it (its video{} or scene{} call).
	source:      string,
	// The scene that places it (an index into `Video.scenes`), or none for
	// the video's own tracks.
	scene:       Maybe(int),
}

// How many of the video's tracks `scene` places (none: the video's own).
tracks_placed_by :: proc(v: ^Video, scene: Maybe(int)) -> (n: int) {
	for tr in v.audio {
		n += int(tr.scene == scene)
	}
	return
}

Fade_Curve :: enum u8 {
	Linear,
	Equal_Power,
}

// How a ducked track dips under voice. Zero fields take the defaults of
// fframes' `duck_under_voice` (-12 dB, 0.2 s attack before the voice, 0.3 s
// hold, 0.8 s release, gaps under 0.8 s merged).
Ducking :: struct {
	depth_db:  f32,
	attack:    f32,
	hold:      f32,
	release:   f32,
	merge_gap: f32,
}

ducking_resolved :: proc "contextless" (d: Ducking) -> Ducking {
	return {
		depth_db = d.depth_db if d.depth_db != 0 else -12,
		attack = d.attack if d.attack > 0 else 0.2,
		hold = d.hold if d.hold > 0 else 0.3,
		release = d.release if d.release > 0 else 0.8,
		merge_gap = d.merge_gap if d.merge_gap > 0 else 0.8,
	}
}

// Decoded sound: interleaved stereo at MIX_RATE, plus the file's own rate
// and channel count.
Audio_Clip :: struct {
	samples:         []f32,
	frames:          int,
	// The frame `samples` starts at: a window of a longer sound (a song read
	// from its stream, for the analysis); 0 for a whole clip.
	first:           int,
	source_rate:     int,
	source_channels: int,
}

// Decodes any audio file odecs reads (WAV, FLAC, MP3, Ogg Vorbis/Opus,
// MP4/M4A AAC or ALAC, WebM/MKV; the format from its first bytes) and
// converts it to a clip.
audio_decode :: proc(data: []u8) -> (clip: Audio_Clip, ok: bool) {
	a, err := odaudio.decode(data)
	if err != .None {
		return {}, false
	}
	defer odaudio.destroy_audio(&a)
	return clip_from_samples(a.samples, a.rate, a.channels), true
}

audio_clip_destroy :: proc(c: ^Audio_Clip) {
	delete(c.samples)
	c^ = {}
}

audio_clip_seconds :: proc "contextless" (c: Audio_Clip) -> f32 {
	return f32(c.frames) / MIX_RATE
}

// Converts to stereo (mono copied to both sides, more than two channels
// folded down) and resamples to MIX_RATE.
clip_from_samples :: proc(samples: []f32, rate, channels: int) -> Audio_Clip {
	n := len(samples) / max(channels, 1)
	stereo := make([]f32, n * 2)
	for i in 0 ..< n {
		frame := samples[i * channels:][:channels]
		switch channels {
		case 1:
			stereo[i * 2], stereo[i * 2 + 1] = frame[0], frame[0]
		case 2:
			stereo[i * 2], stereo[i * 2 + 1] = frame[0], frame[1]
		case:
			// Front left/right plus the rest spread evenly at -3 dB.
			l, r := frame[0], frame[1]
			for x in frame[2:] {
				l += x * 0.7071
				r += x * 0.7071
			}
			stereo[i * 2], stereo[i * 2 + 1] = l, r
		}
	}
	clip := Audio_Clip {
		samples         = stereo,
		frames          = n,
		source_rate     = rate,
		source_channels = channels,
	}
	if rate != MIX_RATE {
		clip.samples, clip.frames = resample_stereo(stereo, rate, MIX_RATE)
		delete(stereo)
	}
	return clip
}

// Windowed-sinc (Lanczos, a = 8) resampling of interleaved stereo. The
// rates' ratio is rational, so output sample i sits at one of `to / gcd`
// fractional phases: the normalized kernel of each phase is computed once and
// the interior is a plain multiply-add sweep. Edges, where the kernel is cut
// off, keep the direct form.
resample_stereo :: proc(src: []f32, from_rate, to_rate: int) -> (out: []f32, frames: int) {
	A :: 8
	n := len(src) / 2
	ratio := f64(to_rate) / f64(from_rate)
	out_n := int(f64(n) * ratio)
	out = make([]f32, out_n * 2)
	// Downsampling widens the kernel to filter out what can't be kept.
	cutoff := min(ratio, 1)
	width := f64(A) / cutoff

	g := gcd(from_rate, to_rate)
	step, phases := from_rate / g, to_rate / g
	if phases > 4096 {
		resample_direct(src, out, 0, out_n, ratio, cutoff, width)
		return out, out_n
	}
	// Per phase: taps at base + first ..< base + first + taps.
	first := int(math.floor(-width)) + 1
	taps := int(math.floor(width)) - first + 2
	weights := make([]f64, phases * taps, context.temp_allocator)
	for p in 0 ..< phases {
		frac := f64(p) / f64(phases)
		row := weights[p * taps:][:taps]
		wsum: f64
		for k in 0 ..< taps {
			x := (f64(first + k) - frac) * cutoff
			row[k] = lanczos(x, A)
			wsum += row[k]
		}
		if wsum != 0 {
			for &w in row {
				w /= wsum
			}
		}
	}
	for i in 0 ..< out_n {
		num := i * step
		base, p := num / phases, num % phases
		lo := base + first
		if lo < 0 || lo + taps > n {
			resample_direct(src, out, i, i + 1, ratio, cutoff, width)
			continue
		}
		row := weights[p * taps:][:taps]
		s := src[lo * 2:][:taps * 2]
		l, r: f64
		for k in 0 ..< taps {
			l += f64(s[k * 2]) * row[k]
			r += f64(s[k * 2 + 1]) * row[k]
		}
		out[i * 2], out[i * 2 + 1] = f32(l), f32(r)
	}
	return out, out_n
}

@(private)
resample_direct :: proc(src, out: []f32, i0, i1: int, ratio, cutoff, width: f64) {
	n := len(src) / 2
	for i in i0 ..< i1 {
		center := f64(i) / ratio
		lo := max(int(math.floor(center - width)) + 1, 0)
		hi := min(int(math.floor(center + width)), n - 1)
		l, r, wsum: f64
		for j in lo ..= hi {
			w := lanczos((f64(j) - center) * cutoff, 8)
			l += f64(src[j * 2]) * w
			r += f64(src[j * 2 + 1]) * w
			wsum += w
		}
		if wsum != 0 {
			l /= wsum
			r /= wsum
		}
		out[i * 2], out[i * 2 + 1] = f32(l), f32(r)
	}
}

@(private)
gcd :: proc "contextless" (a, b: int) -> int {
	a, b := a, b
	for b != 0 {
		a, b = b, a % b
	}
	return a
}

@(private)
lanczos :: proc "contextless" (x: f64, a: f64) -> f64 {
	if x == 0 {
		return 1
	}
	if abs(x) >= a {
		return 0
	}
	px := math.PI * x
	return a * math.sin(px) * math.sin(px / a) / (px * px)
}

