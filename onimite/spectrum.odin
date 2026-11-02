package onimite

import "core:sync"
import oanalyze "deps:odawg/analyze"
import orender "deps:odawg/render"

// Audio visualisation, a port of fframes' `visualize_audio_frame`: what
// the sound is at a video frame, read from odawg's analysis tables (a row a
// frame: the magnitude spectrum of `size` samples of the mono mix at
// MIX_RATE from the frame's start, windowed, and the frame's energy),
// averaged over neighbouring frames when smoothing. A song's tables are of
// its render (song_table), a clip's of its samples (media_clip_table); each
// row is made once, the same whatever asks for it and in whatever order.

SPECTRUM_MAX :: oanalyze.SPECTRUM_MAX

// A sound's analysis table, its rows filled as they are asked for or as
// the sound is made.
Sound_Table :: struct {
	table:    orender.Table,
	lock:     sync.Mutex, // held while rows are filled
	filled:   []u8, // per step: 1 once filled (atomic); heap memory
	complete: bool, // atomic: every row is filled
}

// Row `i` of a table once filled (nil: not yet, silent, outside the sound,
// or no table).
sound_table_row :: proc(st: ^Sound_Table, i: int) -> []f32 {
	if st == nil || i < 0 || i >= len(st.filled) || sync.atomic_load(&st.filled[i]) == 0 {
		return nil
	}
	return orender.table_row(&st.table, i)
}

sound_table_ready :: proc(st: ^Sound_Table) -> bool {
	return sync.atomic_load(&st.complete)
}

// Magnitudes at frame `index` of a spectrum table, averaged over `smooth`
// frames each side (from frame 0), written to `out` (the table's
// `size / 2`); silence where there's no row.
audio_spectrum :: proc(table: ^Sound_Table, index, smooth: int, out: []f32) {
	for &v in out {
		v = 0
	}
	count := 0
	for i in max(index - smooth, 0) ..= index + max(smooth, 0) {
		if row := sound_table_row(table, i); row != nil {
			for v, k in row[:min(len(row), len(out))] {
				out[k] += v
			}
		}
		count += 1
	}
	if smooth > 0 {
		for &v in out {
			v /= f32(max(count, 1))
		}
	}
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

// Frame `index`'s energy from an energy table (odawg's: RMS, peak, three
// bands, each 0..1), averaged over `smooth` frames each side.
audio_energy :: proc(table: ^Sound_Table, index: int, smooth := 0) -> (e: oanalyze.Energy) {
	count := 0
	for i in max(index - smooth, 0) ..= index + max(smooth, 0) {
		if row := sound_table_row(table, i); row != nil {
			e.rms += row[0]
			e.peak += row[1]
			e.low += row[2]
			e.mid += row[3]
			e.high += row[4]
		}
		count += 1
	}
	if smooth > 0 {
		inv := 1.0 / f32(max(count, 1))
		e.rms *= inv
		e.peak *= inv
		e.low *= inv
		e.mid *= inv
		e.high *= inv
	}
	return
}
