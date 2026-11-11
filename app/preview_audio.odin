package onimite_app

import "core:c"
import "core:sync"
import "core:thread"
import "core:time"
import om "../onimite"
import orender "deps:odawg/render"
import sdl "vendor:sdl3"

// Preview sound, on a thread of ours: the feeder keeps SDL's stream filled
// (SDL's own thread only plays what is queued; no work runs in a callback),
// mixing block after block from the mix (odawg's engine over the placed
// tracks, onimite/audio_mix.odin) at the play position: no mix is made
// ahead, and the samples are the render's. The render worker builds the
// stream after a load and again whenever clips the script builds land, so
// sound joins in as it is made; the clock never waits for it.
//
// Nothing the UI thread does waits on the feeder. The UI writes its rows
// (play state, volume, a seek) as atomics, and the feeder drains them before
// each block; it writes back what is being heard, which the UI reads as the
// playback clock, so picture follows sound. The worker hands over a new mix
// under the feeder's lock (held while a block is mixed): only the worker ever
// waits, for one block.
//
// What it mixes is also analysed as it goes, for the controls' spectrum
// analyzer (preview_spectrum.odin): the mix hands odawg's engine's two sides,
// before the volume, to odawg's streaming Analyzer, which makes a .Bands row
// (the 31 third-octave levels) every ANALYZER_STEP samples on the clock it
// mixes on, into a ring of the last ANALYZER_ROWS rows the UI reads without
// waiting: the feeder publishes the next step it makes, and at a seek or a
// loop back to the start (a run that doesn't follow the last) the first step
// since, with a bump of the generation. The ring holds more than the feeder
// runs ahead of what is heard.

AUDIO_CHUNK :: 2048 // frames mixed per step at most
ANALYZER_STEP :: 1024 // samples from one band row to the next (21 ms)
ANALYZER_ROWS :: 64 // the rows its ring keeps (1.4 s)

Audio_State :: enum u32 {
	Playing,
	Muted,
	Looping,
}

Audio_Shared :: struct {
	// Held while a block is mixed and while the worker swaps the mix.
	lock:          sync.Mutex,
	// Under `lock` (set by the worker, read by the feeder): the mix it
	// streams, owned (nil: silence; it reads the media's clips and songs, so
	// the worker clears it before those change or go), and the video's
	// length in samples.
	stream:        ^om.Mix_Stream,
	total:         i64,
	// The UI's rows (atomics). A seek is `seek_to` published by bumping
	// `seek_gen`; `state` is a bit_set of Audio_State; `gain` the volume
	// as f32 bits.
	seek_to:       i64,
	seek_gen:      u32,
	state:         u32,
	gain:          u32,
	// The feeder's (atomics, read by the UI): the sample being heard as of
	// its last block (handed to SDL minus what waits in the stream and the
	// device's buffer), whether it is advancing (it stops at the end when
	// not looping), the seek it applied last, and the samples handed to SDL
	// so far (diagnostics).
	heard:         i64,
	advancing:     bool,
	applied_gen:   u32,
	fed:           i64,
	// The feeder's own (under `lock`): the next sample handed to SDL, the
	// floor set by the last seek, whether it last played, and scratch.
	position:      i64,
	seek_floor:    i64,
	was_playing:   bool,
	scratch:       [AUDIO_CHUNK * 2]f32,
	// The device's own buffer (frames), the feeder's thread and its stop.
	device_frames: i64,
	feeder:        ^thread.Thread,
	quit:          bool,
	// The feeder's analyzer (the mix pushes into it, om.mix_block) and its
	// ring of rows (ANALYZER_ROWS of BAND_COUNT levels, dB; step k's in slot
	// k % ANALYZER_ROWS), which the UI reads as far as the counters below say
	// they are made.
	analyzer:      orender.Analyzer,
	analyzed:      []f32,
	// The feeder's (atomics, read by the UI): the next step it makes, the
	// first it made since the last seek, and that seek's generation.
	analyzed_next: i64,
	analyzed_from: i64,
	analyzed_gen:  u32,
}

// The analyzer and its ring, before the feeder starts.
audio_analyzer_init :: proc(a: ^Audio_Shared) {
	a.analyzed = make([]f32, ANALYZER_ROWS * om.BAND_COUNT)
	orender.analyzer_init(&a.analyzer, .Bands, ANALYZER_STEP, 1, ANALYZER_ROWS, 0, values = a.analyzed)
}

audio_shared_destroy :: proc(a: ^Audio_Shared) {
	if a.stream != nil {
		om.mix_stream_destroy(a.stream)
		free(a.stream)
		a.stream = nil
	}
	orender.analyzer_destroy(&a.analyzer)
	delete(a.analyzed)
	a.analyzed = nil
}

// The analyzer for a run of the mix from sample `at` (nil: none): it starts
// again there when the run doesn't follow the last, and that is published.
audio_analyzer_at :: proc(a: ^Audio_Shared, at: i64) -> ^orender.Analyzer {
	if a.analyzed == nil {
		return nil
	}
	if at != a.analyzer.pos {
		orender.analyzer_seek(&a.analyzer, at)
		sync.atomic_store_explicit(&a.analyzed_from, i64(a.analyzer.next), .Relaxed)
		sync.atomic_add_explicit(&a.analyzed_gen, 1, .Release)
	}
	return &a.analyzer
}

// The rows made so far, published once they are written.
audio_analyzer_publish :: proc(a: ^Audio_Shared) {
	sync.atomic_store_explicit(&a.analyzed_next, i64(a.analyzer.next), .Release)
}

// Builds the mix of `placed` (nil or none stops every sound: before the
// media they play from goes) and publishes it with the video's length.
// The mix is built before the swap, so the feeder waits for nothing; it
// never waits for songs' sample sets either (the music's builder loads
// them, and the worker publishes again when they land).
audio_set_tracks :: proc(a: ^Audio_Shared, placed: []om.Placed_Track, total: i64, opts: om.Mix_Options) {
	stream: ^om.Mix_Stream
	if len(placed) > 0 {
		stream = new(om.Mix_Stream)
		om.mix_stream_init(stream, placed, opts, load = false)
	}
	audio_swap(a, stream, total)
}

// Stops every sound until tracks are published again (before the samples
// they play from change or go).
audio_clear_tracks :: proc(a: ^Audio_Shared) {
	audio_swap(a, nil, -1)
}

// Puts `stream` (and `total`, unless negative) where the feeder reads
// them, then frees the one it replaces: after the swap the feeder can't
// be using it.
@(private = "file")
audio_swap :: proc(a: ^Audio_Shared, stream: ^om.Mix_Stream, total: i64) {
	sync.mutex_lock(&a.lock)
	old := a.stream
	a.stream = stream
	if total >= 0 {
		a.total = total
		a.position = clamp(a.position, 0, max(total - 1, 0))
		a.seek_floor = min(a.seek_floor, a.position)
	}
	sync.mutex_unlock(&a.lock)
	if old != nil {
		om.mix_stream_destroy(old)
		free(old)
	}
}

audio_set_state :: proc(a: ^Audio_Shared, playing, muted, looping: bool) {
	s: bit_set[Audio_State;u32]
	if playing {
		s += {.Playing}
	}
	if muted {
		s += {.Muted}
	}
	if looping {
		s += {.Looping}
	}
	sync.atomic_store_explicit(&a.state, transmute(u32)s, .Release)
}

audio_set_gain :: proc(a: ^Audio_Shared, gain: f32) {
	sync.atomic_store_explicit(&a.gain, transmute(u32)gain, .Relaxed)
}

// Asks for sample `sample` next (the feeder clamps it to the video once
// it knows its length: a start time given on the command line survives
// until the tracks arrive).
audio_seek :: proc(a: ^Audio_Shared, sample: i64) {
	sync.atomic_store_explicit(&a.seek_to, sample, .Relaxed)
	sync.atomic_add_explicit(&a.seek_gen, 1, .Release)
}

// The sample being heard now and whether it is still advancing (it stops
// at the end when not looping). A seek the feeder hasn't taken yet is
// what will be heard next.
audio_position :: proc(a: ^Audio_Shared) -> (sample: i64, playing: bool, fed: i64) {
	state := transmute(bit_set[Audio_State;u32])sync.atomic_load_explicit(&a.state, .Acquire)
	fed = sync.atomic_load_explicit(&a.fed, .Relaxed)
	if sync.atomic_load_explicit(&a.applied_gen, .Acquire) != sync.atomic_load_explicit(&a.seek_gen, .Acquire) {
		return max(sync.atomic_load_explicit(&a.seek_to, .Relaxed), 0), .Playing in state, fed
	}
	return sync.atomic_load_explicit(&a.heard, .Relaxed), sync.atomic_load_explicit(&a.advancing, .Relaxed), fed
}

// One block of `frames` into `stream`, with `lock` held: drains the UI's
// rows, then streams the mix at the play position, analysed before the
// volume. Silence while paused or muted; muted playback still advances, and
// is still mixed and analysed (the analyzer shows it). A seek, or playing
// stopping, drops what is still queued, so it is heard at once.
audio_step :: proc(a: ^Audio_Shared, stream: ^sdl.AudioStream, frames: int) {
	gen := sync.atomic_load_explicit(&a.seek_gen, .Acquire)
	state := transmute(bit_set[Audio_State;u32])sync.atomic_load_explicit(&a.state, .Acquire)
	gain := transmute(f32)sync.atomic_load_explicit(&a.gain, .Relaxed)
	playing := .Playing in state
	// applied_gen is only written here (under `lock`): a relaxed load reads it.
	if gen != sync.atomic_load_explicit(&a.applied_gen, .Relaxed) {
		to := sync.atomic_load_explicit(&a.seek_to, .Relaxed)
		a.position = clamp(to, 0, a.total - 1) if a.total > 0 else max(to, 0)
		a.seek_floor = a.position
		sdl.ClearAudioStream(stream)
	} else if a.was_playing && !playing {
		sdl.ClearAudioStream(stream)
	}
	frames := frames
	for frames > 0 {
		n := min(frames, AUDIO_CHUNK)
		buf := a.scratch[:n * 2]
		for &x in buf {
			x = 0
		}
		// Up to the end, then (looping) on from the start.
		for k := 0; playing && a.total > 0 && k < n; {
			if a.position >= a.total {
				if .Looping not_in state {
					playing = false
					break
				}
				a.position = 0
				a.seek_floor = 0
			}
			run := min(n - k, int(a.total - a.position))
			if a.stream != nil {
				part := buf[k * 2:][:run * 2]
				om.mix_block(a.stream, int(a.position), part, audio_analyzer_at(a, a.position))
				audio_analyzer_publish(a)
				g := gain if .Muted not_in state else 0
				for &x in part {
					x *= g
				}
			}
			a.position += i64(run)
			k += run
		}
		sdl.PutAudioStreamData(stream, raw_data(buf), c.int(n * 2 * size_of(f32)))
		sync.atomic_add_explicit(&a.fed, i64(n), .Relaxed)
		frames -= n
	}
	heard := a.position
	if playing {
		queued := i64(sdl.GetAudioStreamQueued(stream)) / (2 * size_of(f32))
		heard = max(a.position - queued - a.device_frames, a.seek_floor, 0)
	}
	a.was_playing = playing
	sync.atomic_store_explicit(&a.heard, heard, .Relaxed)
	sync.atomic_store_explicit(&a.advancing, playing, .Relaxed)
	sync.atomic_store_explicit(&a.applied_gen, gen, .Release)
}

// The feeder's thread: keeps the device's buffer and half a block more
// queued (what the device takes at once, and the margin it has to wake
// and mix again before the next take), mixing whenever less is, else
// sleeping until about half the margin has played. Its temp memory is its
// own, freed after each block.
@(private)
audio_feed :: proc(a: ^Audio_Shared, stream: ^sdl.AudioStream) {
	FRAME :: 2 * size_of(f32)
	target := int(a.device_frames) + AUDIO_CHUNK / 2
	for !sync.atomic_load(&a.quit) {
		queued := int(sdl.GetAudioStreamQueued(stream)) / FRAME
		if queued < target {
			sync.mutex_lock(&a.lock)
			audio_step(a, stream, min(target - queued, AUDIO_CHUNK))
			sync.mutex_unlock(&a.lock)
			free_all(context.temp_allocator)
			continue
		}
		ahead := time.Duration(i64(queued - target / 2) * i64(time.Second) / om.MIX_RATE)
		time.sleep(clamp(ahead, time.Millisecond, 10 * time.Millisecond))
	}
}

// Opens the default playback device and starts the feeder; nil when there
// is no audio device (the preview then runs on its own clock).
audio_open :: proc(a: ^Audio_Shared) -> ^sdl.AudioStream {
	if !sdl.InitSubSystem({.AUDIO}) {
		return nil
	}
	spec := sdl.AudioSpec{format = .F32, channels = 2, freq = om.MIX_RATE}
	stream := sdl.OpenAudioDeviceStream(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, nil, nil)
	if stream == nil {
		return nil
	}
	spec_out: sdl.AudioSpec
	frames: c.int
	if sdl.GetAudioDeviceFormat(sdl.GetAudioStreamDevice(stream), &spec_out, &frames) {
		a.device_frames = i64(frames) * om.MIX_RATE / i64(max(spec_out.freq, 1))
	}
	audio_analyzer_init(a)
	// high, as SDL's own audio thread is: a late block is a gap heard
	a.feeder = thread.create_and_start_with_poly_data2(a, stream, audio_feed, priority = .High)
	sdl.ResumeAudioStreamDevice(stream)
	return stream
}

// Stops the feeder, then the device.
audio_close :: proc(a: ^Audio_Shared, stream: ^sdl.AudioStream) {
	if a.feeder != nil {
		sync.atomic_store(&a.quit, true)
		thread.join(a.feeder)
		thread.destroy(a.feeder)
		a.feeder = nil
	}
	if stream != nil {
		sdl.DestroyAudioStream(stream)
	}
}
