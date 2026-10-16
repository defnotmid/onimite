package onimite

import "core:math"

// Audio visualisation, a port of fframes' `visualize_audio_frame`: the
// magnitude spectrum of `sample_size` samples of the clip's stereo mix
// (`0.707 * (L + R)` at MIX_RATE) starting at the frame's position,
// optionally windowed, averaged over neighbouring frames when smoothing. Each frame is computed from scratch,
// so random access and parallel renders agree.

Spectrum_Window :: enum u8 {
	None,
	Hann,
	Hamming,
}

Spectrum_Params :: struct {
	// FFT size, a power of two from 2 to SPECTRUM_MAX. The result has half
	// as many values.
	sample_size: int,
	// Frames averaged on each side.
	smooth:      int,
	window:      Spectrum_Window,
}

SPECTRUM_MAX :: 2048

// Magnitudes for frame `index` at `fps` of `clip`, written to `out` (length
// `sample_size / 2`).
audio_spectrum :: proc(clip: ^Audio_Clip, index, fps: int, p: Spectrum_Params, out: []f32) {
	for &v in out {
		v = 0
	}
	if p.smooth <= 0 {
		spectrum_frame(clip, index, fps, p, out)
		return
	}
	// The average of frames index - smooth ..= index + smooth (from frame 0).
	tmp_buf: [SPECTRUM_MAX / 2]f32
	tmp := tmp_buf[:len(out)]
	count := 0
	for i in max(index - p.smooth, 0) ..= index + p.smooth {
		spectrum_frame(clip, i, fps, p, tmp)
		for v, k in tmp {
			out[k] += v
		}
		count += 1
	}
	for &v in out {
		v /= f32(max(count, 1))
	}
}

@(private = "file")
spectrum_frame :: proc(clip: ^Audio_Clip, index, fps: int, p: Spectrum_Params, out: []f32) {
	n := p.sample_size
	re_buf, im_buf: [SPECTRUM_MAX]f32
	re, im := re_buf[:n], im_buf[:n]
	start := index * MIX_RATE / max(fps, 1)
	// Silent when the window runs past the clip.
	if start >= 0 && start + n <= clip.frames {
		src := clip.samples[start * 2:][:n * 2]
		for k in 0 ..< n {
			re[k] = (src[k * 2] + src[k * 2 + 1]) * 0.70710678
		}
		switch p.window {
		case .None:
		case .Hann:
			for k in 0 ..< n {
				re[k] *= 0.5 * (1 - math.cos(2 * math.PI * f32(k) / f32(n)))
			}
		case .Hamming:
			for k in 0 ..< n {
				re[k] *= 0.54 - 0.46 * math.cos(2 * math.PI * f32(k) / f32(n - 1))
			}
		}
	}
	fft(re, im)
	for k in 0 ..< n / 2 {
		out[k] = math.sqrt(re[k] * re[k] + im[k] * im[k])
	}
}

// In-place iterative radix-2 FFT (len a power of two).
@(private)
fft :: proc(re, im: []f32) {
	n := len(re)
	j := 0
	for i in 1 ..< n {
		bit := n >> 1
		for j & bit != 0 {
			j ~= bit
			bit >>= 1
		}
		j |= bit
		if i < j {
			re[i], re[j] = re[j], re[i]
			im[i], im[j] = im[j], im[i]
		}
	}
	for size := 2; size <= n; size <<= 1 {
		ang := -2 * math.PI / f64(size)
		wr, wi := math.cos(ang), math.sin(ang)
		for start := 0; start < n; start += size {
			cr, ci: f64 = 1, 0
			for k in 0 ..< size / 2 {
				a := start + k
				b := a + size / 2
				tr := f32(cr) * re[b] - f32(ci) * im[b]
				ti := f32(cr) * im[b] + f32(ci) * re[b]
				re[b] = re[a] - tr
				im[b] = im[a] - ti
				re[a] += tr
				im[a] += ti
				cr, ci = cr * wr - ci * wi, cr * wi + ci * wr
			}
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

// Per-frame normalized (0..1) audio envelope and 3-band spectral energy.
Audio_Energy :: struct {
	rms, peak, low, mid, high: f32,
}

audio_energy :: proc(clip: ^Audio_Clip, index, fps: int, smooth := 0) -> (e: Audio_Energy) {
	if clip == nil || clip.frames <= 0 {
		return
	}
	if smooth <= 0 {
		return energy_frame(clip, index, fps)
	}
	count := 0
	for i in max(index - smooth, 0) ..= index + smooth {
		fe := energy_frame(clip, i, fps)
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
energy_frame :: proc(clip: ^Audio_Clip, index, fps: int) -> (e: Audio_Energy) {
	rate_fps := max(fps, 1)
	start := index * MIX_RATE / rate_fps
	n_win := max(MIX_RATE / rate_fps, 1)
	if start < 0 || start >= clip.frames {
		return
	}
	end := min(start + n_win, clip.frames)
	count := end - start
	if count <= 0 {
		return
	}
	sum_sq: f32
	peak: f32
	src := clip.samples[start * 2:][:count * 2]
	for k in 0 ..< count {
		s := (src[k * 2] + src[k * 2 + 1]) * 0.5
		sum_sq += s * s
		if abs(s) > peak {
			peak = abs(s)
		}
	}
	e.rms = clamp(math.sqrt(sum_sq / f32(count)) * 2.0, 0, 1)
	e.peak = clamp(peak, 0, 1)

	N :: 512
	bins: [N / 2]f32
	spectrum_frame(clip, index, rate_fps, {sample_size = N, window = .Hann}, bins[:])
	band_avg :: proc(b: []f32, lo, hi: int, scale: f32) -> f32 {
		sum: f32
		for v in b[lo:hi] {
			sum += v
		}
		return clamp((sum / f32(max(hi - lo, 1))) / scale, 0, 1)
	}
	e.low = band_avg(bins[:], 1, 4, 32.0)
	e.mid = band_avg(bins[:], 4, 30, 12.0)
	e.high = band_avg(bins[:], 30, 140, 4.0)
	return
}

