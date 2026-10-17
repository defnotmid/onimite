package onimite

import oanalyze "deps:odawg/analyze"

// Audio visualisation, a port of fframes' `visualize_audio_frame`: what
// the sound is at a video frame, from odawg's analysis (analyze/spectrum:
// the magnitude spectrum of `sample_size` samples of the clip's mono mix
// at MIX_RATE from the frame's position, windowed, and the frame's energy),
// averaged over neighbouring frames when smoothing. Each frame is computed
// from scratch, so random access and parallel renders agree. A song's
// frames are rows of its table (song_table: the same measure, made once).

Spectrum_Params :: struct {
	// FFT size, a power of two from 2 to SPECTRUM_MAX. The result has half
	// as many values.
	sample_size: int,
	// Frames averaged on each side.
	smooth:      int,
	window:      oanalyze.Window,
}

SPECTRUM_MAX :: oanalyze.SPECTRUM_MAX

// Magnitudes for frame `index` at `fps` of `clip` (or of a song's `table`
// of them, built at `fps` and `p`), written to `out` (length
// `sample_size / 2`).
audio_spectrum :: proc(clip: ^Audio_Clip, index, fps: int, p: Spectrum_Params, out: []f32, table: ^Song_Table = nil) {
	for &v in out {
		v = 0
	}
	if p.smooth <= 0 {
		spectrum_frame(clip, index, fps, p, out, table)
		return
	}
	// The average of frames index - smooth ..= index + smooth (from frame 0).
	tmp_buf: [SPECTRUM_MAX / 2]f32
	tmp := tmp_buf[:len(out)]
	count := 0
	for i in max(index - p.smooth, 0) ..= index + p.smooth {
		spectrum_frame(clip, i, fps, p, tmp, table)
		for v, k in tmp {
			out[k] += v
		}
		count += 1
	}
	for &v in out {
		v /= f32(max(count, 1))
	}
}

// The clip's frames `[start, start + n)` that it has (or its window
// holds), as two channels (temp memory): what the analysis reads.
@(private = "file")
clip_channels :: proc(clip: ^Audio_Clip, start, n: int) -> (l, r: []f32) {
	lo := max(start, clip.first, 0)
	hi := min(start + n, clip.frames, clip.first + len(clip.samples) / 2)
	if hi <= lo || lo != start {
		return nil, nil
	}
	buf := make([]f32, 2 * (hi - lo), context.temp_allocator)
	l, r = buf[:hi - lo], buf[hi - lo:]
	for i in 0 ..< hi - lo {
		k := (lo + i - clip.first) * 2
		l[i], r[i] = clip.samples[k], clip.samples[k + 1]
	}
	return
}

@(private = "file")
spectrum_frame :: proc(clip: ^Audio_Clip, index, fps: int, p: Spectrum_Params, out: []f32, table: ^Song_Table) {
	if table != nil {
		row := song_table_row(table, index)
		copy(out, row)
		if row == nil {
			for &v in out {
				v = 0
			}
		}
		return
	}
	start := index * MIX_RATE / max(fps, 1)
	l, r := clip_channels(clip, start, p.sample_size)
	// silent when the window runs past the clip
	oanalyze.spectrum_from_samples(l, r, 0, p.window, out)
}

// fframes' `center_spectrum_low_frequencies`: low frequencies in the middle,
// higher ones alternating out to both edges.
spectrum_centered :: proc(spectrum: []f32, out: []f32) {
	n := len(spectrum)
	if n < 2 {
		copy(out, spectrum)
		return
	}
	mid := n / 2 - 1
	for i in 0 ..< n {
		switch {
		case i < mid:
			out[i] = spectrum[(mid - i) * 2]
		case i == mid:
			out[i] = spectrum[0]
		case:
			out[i] = spectrum[(i - mid) * 2 - 1]
		}
	}
}

// Frame `index`'s energy (odawg's: RMS, peak, three bands, each 0..1),
// averaged over `smooth` frames each side (a song's from its `table`).
audio_energy :: proc(clip: ^Audio_Clip, index, fps: int, smooth := 0, table: ^Song_Table = nil) -> (e: oanalyze.Energy) {
	if table == nil && (clip == nil || clip.frames <= 0) {
		return
	}
	if smooth <= 0 {
		return energy_frame(clip, index, fps, table)
	}
	count := 0
	for i in max(index - smooth, 0) ..= index + smooth {
		fe := energy_frame(clip, i, fps, table)
		e.rms += fe.rms
		e.peak += fe.peak
		e.low += fe.low
		e.mid += fe.mid
		e.high += fe.high
		count += 1
	}
	inv := 1.0 / f32(max(count, 1))
	e.rms *= inv
	e.peak *= inv
	e.low *= inv
	e.mid *= inv
	e.high *= inv
	return
}

@(private = "file")
energy_frame :: proc(clip: ^Audio_Clip, index, fps: int, table: ^Song_Table) -> oanalyze.Energy {
	if table != nil {
		row := song_table_row(table, index)
		if row == nil {
			return {}
		}
		return {row[0], row[1], row[2], row[3], row[4]}
	}
	f := max(fps, 1)
	start := index * MIX_RATE / f
	n := max(MIX_RATE / f, 1)
	// the frame's samples, and what its 512-sample spectrum reads
	l, r := clip_channels(clip, start, max(n, 512))
	return oanalyze.energy_from_samples(l, r, 0, n)
}
