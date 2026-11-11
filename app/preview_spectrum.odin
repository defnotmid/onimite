package onimite_app

import "core:math"
import "core:sync"
import "core:time"
import om "../onimite"
import ui "../ui"
import vg "deps:ovg"
import orender "deps:odawg/render"

// The controls' spectrum analyzer: the sound as it is heard, a bar per band
// of the feeder's band row (preview_audio.odin: the 31 third-octave levels,
// 20 Hz at the left), from SPECTRUM_FLOOR_DB to SPECTRUM_TOP_DB. A bar jumps
// to its band's level and falls back at SPECTRUM_FALL; its peak mark holds
// SPECTRUM_HOLD seconds, then falls at SPECTRUM_PEAK_FALL. The row read is
// the one whose window ends where the sound is heard; the UI reads it from
// the feeder's ring without waiting, as far as the counters the feeder
// publishes say it is made, and drops it if a seek came in between.

SPECTRUM_FLOOR_DB :: -70
SPECTRUM_TOP_DB :: -10
SPECTRUM_FALL :: 1.5 // of the bar's height a second
SPECTRUM_HOLD :: 0.5 // seconds
SPECTRUM_PEAK_FALL :: 0.6 // of the bar's height a second
SPECTRUM_MARGIN :: 8 // rows kept clear of the slots the feeder writes next

Spectrum :: struct {
	// Each band's bar and peak mark, 0..1 of the height, and the seconds its
	// mark has left to hold.
	levels, peaks: [om.BAND_COUNT]f32,
	held:          [om.BAND_COUNT]f32,
	settled:       time.Tick, // when they last moved
	// The heard sample last read and when it moved: between the feeder's
	// blocks the analyzer runs on real time, at most a device block.
	heard:         i64,
	moved:         time.Tick,
}

// The band row heard at sample `now` (nil: none made, or a seek since): the
// latest made by then, copied out of the feeder's ring.
spectrum_row :: proc(a: ^Audio_Shared, now: f64) -> []f32 {
	if a == nil || a.analyzed == nil {
		return nil
	}
	gen := sync.atomic_load_explicit(&a.analyzed_gen, .Acquire)
	next := sync.atomic_load_explicit(&a.analyzed_next, .Acquire)
	from := sync.atomic_load_explicit(&a.analyzed_from, .Relaxed)
	k := min(i64(math.floor((now - orender.BANDS_FFT) / ANALYZER_STEP)), next - 1)
	if k < max(from, next - ANALYZER_ROWS + SPECTRUM_MARGIN, 0) {
		return nil
	}
	row := make([]f32, om.BAND_COUNT, context.temp_allocator)
	copy(row, a.analyzed[int(k % ANALYZER_ROWS) * om.BAND_COUNT:][:om.BAND_COUNT])
	if sync.atomic_load_explicit(&a.analyzed_gen, .Acquire) != gen {
		return nil
	}
	return row
}

// The bars and marks `dt` seconds on, toward `row` (nil: silence).
spectrum_settle :: proc(sp: ^Spectrum, row: []f32, dt: f32) {
	for b in 0 ..< om.BAND_COUNT {
		v: f32 = 0
		if row != nil {
			v = clamp((row[b] - SPECTRUM_FLOOR_DB) / (SPECTRUM_TOP_DB - SPECTRUM_FLOOR_DB), 0, 1)
		}
		sp.levels[b] = max(v, sp.levels[b] - SPECTRUM_FALL * dt)
		switch {
		case sp.levels[b] >= sp.peaks[b]:
			sp.peaks[b], sp.held[b] = sp.levels[b], SPECTRUM_HOLD
		case sp.held[b] > 0:
			sp.held[b] -= dt
		case:
			sp.peaks[b] = max(sp.levels[b], sp.peaks[b] - SPECTRUM_PEAK_FALL * dt)
		}
	}
}

// The analyzer as a box at `at` in its parent, `size` big.
spectrum_view :: proc(pv: ^Preview_State, s: ^ui.State, at, size: [2]f32) {
	sp := &pv.spectrum
	row: []f32
	if pv.audio != nil {
		pos, advancing, _ := audio_position(pv.audio)
		if pos != sp.heard {
			sp.heard, sp.moved = pos, time.tick_now()
		}
		now := f64(pos)
		if advancing {
			block := f64(pv.audio.device_frames) if pv.audio.device_frames > 0 else 0.05 * om.MIX_RATE
			now += min(time.duration_seconds(time.tick_since(sp.moved)) * om.MIX_RATE, block)
		}
		row = spectrum_row(pv.audio, now)
	}
	dt := f32(min(time.duration_seconds(time.tick_since(sp.settled)), 0.25)) if sp.settled != {} else 0
	sp.settled = time.tick_now()
	spectrum_settle(sp, row, dt)
	ui.set_next_fixed_x(s, at.x); ui.set_next_fixed_y(s, at.y)
	ui.set_next_fixed_width(s, size.x); ui.set_next_fixed_height(s, size.y)
	box := ui.build_box(s, {}, "###spectrum")
	ui.box_equip_custom_draw(box, spectrum_draw, new_clone(sp^, context.temp_allocator))
}

// A bar per band across the box, a fifth of each slot between them, its
// colour the timeline's band heat at its level; a peak mark over each.
@(private = "file")
spectrum_draw :: proc(s: ^ui.State, box: ^ui.Box, c: ^vg.Canvas) {
	sp := (^Spectrum)(box.custom_data)
	r := box.rect
	w, h := r.max.x - r.min.x, r.max.y - r.min.y
	if w <= 0 || h <= 0 {
		return
	}
	slot := w / om.BAND_COUNT
	bar := math.max(math.floor(slot * 0.8), 1)
	mark := math.max(math.round(s.p.dpi_scale * 2), 1)
	for b in 0 ..< om.BAND_COUNT {
		x := math.round(r.min.x + f32(b) * slot + (slot - bar) * 0.5)
		if top := math.round(sp.levels[b] * h); top >= 1 {
			cr, cg, cb, _ := heat(0.25 + 0.75 * sp.levels[b])
			ui.box_path(&s.path, x, r.max.y - top, bar, top, {})
			vg.fill_path(c, &s.path, vg.paint_color(ui.color({cr, cg, cb, 255}, box.opacity)))
		}
		if peak := math.round(sp.peaks[b] * (h - mark)); sp.peaks[b] > 0 {
			ui.box_path(&s.path, x, r.max.y - mark - peak, bar, mark, {})
			vg.fill_path(c, &s.path, vg.paint_color(ui.color(COLOR_TEXT, box.opacity)))
		}
	}
}
