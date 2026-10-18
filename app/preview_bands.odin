package onimite_app

import "core:sync"
import om "../onimite"
import sdl "vendor:sdl3"

// The timeline's bands rows, on the worker: a row shown asks for its
// source (the UI's bands_shown, through the mailbox); the worker asks the
// song for its band rows (a .Bands table read from its render, made as
// the render lands, om.song_bands) and draws the rows made so far into the
// source's texture, which the UI draws a stretch of. The texture is a view
// of the rows: a row a column, a band a pixel (20 Hz at the bottom), the
// rows in strips BAND_STRIP wide stacked down (every GPU takes 4096 wide).

BAND_STRIP :: 4096

// A source's texture as the UI draws it: `rows` band rows a `step` of
// song samples apart, in strips of BAND_STRIP columns, BAND_COUNT high.
Band_Texture :: struct {
	texture:       ^sdl.GPUTexture,
	rows, step:    int,
	width, height: int,
}

// A shown source on the worker: its song, its table, its texture and the
// rows drawn into it.
Band_View :: struct {
	source:  i32,
	song:    ^om.Song_Clip,
	table:   ^om.Song_Table,
	texture: Band_Texture,
	drawn:   int, // rows filled when last drawn
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
@(private)
bands_pending :: proc(w: ^Render_Worker) -> bool {
	return w.mb.bands_wanted_seq != w.bands_wanted_seq || (w.bands_landed && len(w.band_views) > 0)
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
		filled := 0
		for x in v.table.filled {
			filled += int(x)
		}
		if filled == v.drawn {
			continue
		}
		bands_draw(w, &v)
		v.drawn = filled
		changed = true
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

// The view's filled rows coloured into its texture (made the first time),
// an unfilled row left clear.
@(private = "file")
bands_draw :: proc(w: ^Render_Worker, v: ^Band_View) {
	t := &v.table.table
	rows := len(v.table.filled)
	if rows == 0 {
		return
	}
	bt := &v.texture
	if bt.texture == nil {
		strips := (rows + BAND_STRIP - 1) / BAND_STRIP
		bt^ = {rows = rows, step = t.step_num / max(t.step_den, 1), width = min(rows, BAND_STRIP), height = strips * om.BAND_COUNT}
		bt.texture = sdl.CreateGPUTexture(w.device, {type = .D2, format = .R8G8B8A8_UNORM, usage = {.SAMPLER}, width = u32(bt.width), height = u32(bt.height), layer_count_or_depth = 1, num_levels = 1})
		if bt.texture == nil {
			return
		}
	}
	pixels := make([]u8, 4 * bt.width * bt.height, context.temp_allocator)
	for k in 0 ..< rows {
		row := om.song_table_row(v.table, k)
		if row == nil {
			continue
		}
		strip, x := k / BAND_STRIP, k % BAND_STRIP
		for b in 0 ..< om.BAND_COUNT {
			y := strip * om.BAND_COUNT + (om.BAND_COUNT - 1 - b)
			px := pixels[4 * (y * bt.width + x):][:4]
			px[0], px[1], px[2], px[3] = heat(clamp((row[b] + 100) / 90, 0, 1))
		}
	}
	upload_rgba(w.device, bt.texture, {u32(bt.width), u32(bt.height)}, pixels)
}

// Every view goes (a load: the sources are numbered again); the textures
// retire with the thumbnails' generation, so the UI drawing them is done.
@(private)
worker_bands_retire :: proc(w: ^Render_Worker) {
	for v in w.band_views {
		if v.texture.texture != nil {
			append(&w.thumb_retired, v.texture.texture)
		}
	}
	clear(&w.band_views)
	w.bands_wanted_seq = 0
	sync.mutex_lock(&w.mb.mutex)
	clear(&w.mb.band_textures)
	w.mb.bands_seq += 1
	sync.mutex_unlock(&w.mb.mutex)
}
