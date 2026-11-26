package onimite_app

import "base:runtime"
import "core:slice"
import "core:sync"
import om "../onimite"
import render "../render"

// The timeline's bands rows, on the worker: a row shown asks for its
// source (the UI's bands_shown, through the mailbox); the worker asks the
// song for its band rows (a .Bands table read from its render, made as
// the render lands, om.song_bands) and draws the rows made so far into the
// source's picture, which the UI draws a stretch of. The picture is a view
// of the rows: a row a column, a band a texel (20 Hz at the bottom), the
// rows in strips BAND_STRIP wide stacked down (every GPU takes 4096 wide).
// A texel is a level (R8: 0 no row yet, 1..255 -100..-10 dB), coloured as
// heat by the UI's shader.

BAND_STRIP :: 4096

// A source's picture as the UI draws it: `rows` band rows a `step` of
// song samples apart, in strips of BAND_STRIP columns, BAND_COUNT high.
Band_Texture :: struct {
	picture:       render.Picture,
	rows, step:    int,
	width, height: int,
}

// A shown source on the worker: its song, its table, its texture, and the
// texture's levels with the rows written into them (made with the
// texture: a row is written once, when it lands).
Band_View :: struct {
	source:  i32,
	song:    ^om.Song_Clip,
	table:   ^om.Sound_Table,
	texture: Band_Texture,
	levels:  []u8,
	drawn:   []bool,
}

// The latest request rows: views for the sources shown, no others. True
// when the published textures change.
@(private)
worker_bands_take :: proc(w: ^Render_Worker) -> bool {
	sync.mutex_lock(&w.mb.mutex)
	seq := w.mb.bands_wanted_seq
	if seq != w.bands_wanted_seq {
		table_copy(&w.bands_wanted, w.mb.bands_wanted[:])
	}
	sync.mutex_unlock(&w.mb.mutex)
	if seq == w.bands_wanted_seq {
		return false
	}
	w.bands_wanted_seq = seq
	for src in w.bands_wanted {
		if src < 0 || int(src) >= len(w.waves.band_songs) {
			continue
		}
		found := false
		for v in w.band_views {
			found ||= v.source == src
		}
		if !found {
			sc := w.waves.band_songs[src]
			append(&w.band_views, Band_View{source = src, song = sc, table = om.song_bands(sc)})
		}
	}
	return true
}

// Whether a request is new, or rows landed since the views were drawn.
// `asked`: the mailbox's bands_wanted_seq, read under its lock by the caller.
@(private)
bands_pending :: proc(w: ^Render_Worker, asked: u64) -> bool {
	return asked != w.bands_wanted_seq || (w.bands_landed && len(w.band_views) > 0)
}

// One step: the requests taken, each view's song asked for its rows (its
// render, om.song_table_later), the rows made since drawn into its
// texture; the textures published when any changed.
@(private)
worker_bands :: proc(w: ^Render_Worker) {
	w.bands_landed = false
	changed := worker_bands_take(w)
	for &v in w.band_views {
		om.song_table_later(v.song, v.table)
		if bands_draw(w, &v) {
			changed = true
		}
	}
	if !changed {
		return
	}
	sync.mutex_lock(&w.mb.mutex)
	clear(&w.mb.band_textures)
	resize(&w.mb.band_textures, len(w.waves.band_songs))
	for v in w.band_views {
		if int(v.source) < len(w.mb.band_textures) {
			w.mb.band_textures[v.source] = v.texture
		}
	}
	w.mb.bands_seq += 1
	sync.mutex_unlock(&w.mb.mutex)
}

// The rows filled since the view was drawn written into its levels (the
// texture, levels and rows drawn made the first time, all clear), and the
// columns they touched uploaded, a strip at a time. True when it changed.
@(private = "file")
bands_draw :: proc(w: ^Render_Worker, v: ^Band_View) -> bool {
	t := &v.table.table
	rows := len(v.table.filled)
	if rows == 0 {
		return false
	}
	bt := &v.texture
	if bt.picture == {} {
		strips := (rows + BAND_STRIP - 1) / BAND_STRIP
		bt^ = {rows = rows, step = t.step_num / max(t.step_den, 1), width = min(rows, BAND_STRIP), height = strips * om.BAND_COUNT}
		bt.picture = render.picture_make(w.pictures, {u32(bt.width), u32(bt.height)})
		if bt.picture == {} {
			return false
		}
		v.levels = make([]u8, bt.width * bt.height)
		v.drawn = make([]bool, rows)
		upload_levels(w.pictures, bt, v.levels, {0, 0, bt.width, bt.height})
	}
	// each strip's columns written: [lo, hi]
	touched := make([][2]int, bt.height / om.BAND_COUNT, context.temp_allocator)
	for &c in touched {
		c = {BAND_STRIP, -1}
	}
	for k in 0 ..< rows {
		if v.drawn[k] {
			continue
		}
		row := om.sound_table_row(v.table, k)
		if row == nil {
			continue
		}
		strip, x := k / BAND_STRIP, k % BAND_STRIP
		for b in 0 ..< om.BAND_COUNT {
			y := strip * om.BAND_COUNT + (om.BAND_COUNT - 1 - b)
			v.levels[y * bt.width + x] = u8(1.5 + 254 * clamp((row[b] + 100) / 90, 0, 1))
		}
		v.drawn[k] = true
		touched[strip] = {min(touched[strip][0], x), max(touched[strip][1], x)}
	}
	changed := false
	for c, strip in touched {
		if c[1] >= c[0] {
			upload_levels(w.pictures, bt, v.levels, {c[0], strip * om.BAND_COUNT, c[1] - c[0] + 1, om.BAND_COUNT})
			changed = true
		}
	}
	return changed
}

// The levels in `rect` (x, y, w, h) into the picture as their heat colours
// (a level 0 is no reading: clear; 1..255 the ramp's 0..1, opaque), not
// waited on (the picture's queue runs it before any frame it is published
// to).
@(private = "file")
upload_levels :: proc(ps: ^render.Pictures, bt: ^Band_Texture, levels: []u8, rect: [4]int) {
	x, y, w, h := rect[0], rect[1], rect[2], rect[3]
	dst := make([][4]u8, w * h, context.temp_allocator)
	for r in 0 ..< h {
		for level, i in levels[(y + r) * bt.width + x:][:w] {
			px := [4]u8{}
			if level > 0 {
				px.r, px.g, px.b, px.a = heat(f32(level - 1) / 254)
			}
			dst[r * w + i] = px
		}
	}
	render.picture_write(ps, bt.picture, slice.to_bytes(dst), {u32(x), u32(y), u32(w), u32(h)})
}

// Every view goes (a load: the sources are numbered again); the pictures
// retire with the thumbnails' generation, so the UI drawing them is done.
@(private)
worker_bands_retire :: proc(w: ^Render_Worker) {
	for v in w.band_views {
		if v.texture.picture != {} {
			append(&w.band_retired, v.texture.picture)
		}
		delete(v.levels)
		delete(v.drawn)
	}
	clear(&w.band_views)
	w.bands_wanted_seq = 0
	sync.mutex_lock(&w.mb.mutex)
	clear(&w.mb.band_textures)
	w.mb.bands_seq += 1
	sync.mutex_unlock(&w.mb.mutex)
}
