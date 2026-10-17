package onimite_app

import "base:runtime"
import "core:c"
import "core:sync"
import om "../onimite"
import sdl "vendor:sdl3"

// Preview sound. SDL's audio thread asks for samples through a callback,
// which streams them there and then from the mix (odawg's engine over the
// placed tracks, onimite/audio_mix.odin) at the play position: no mix is
// made ahead, and the samples are the render's. The render worker builds
// the stream after a load and again whenever clips the script builds land,
// so sound joins in as it is made; the clock never waits for it.
//
// Nothing the UI thread does waits on the callback. The UI writes its rows
// (play state, volume, a seek) as atomics, and the callback drains them at
// the start of each request; the callback writes back what is being heard,
// which the UI reads as the playback clock, so picture follows sound. The
// worker hands over a new mix under the SDL stream's lock (SDL holds it
// while the callback runs): only the worker ever waits, for one request.

AUDIO_CHUNK :: 2048 // frames mixed per step inside the callback

Audio_State :: enum u32 {
	Playing,
	Muted,
	Looping,
}

Audio_Shared :: struct {
	// Under the SDL stream's lock (set by the worker, read by the callback):
	// the mix the callback streams, owned (nil: silence; its samples are its
	// own copies, the worker's media may change under it), and the video's
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
	// The callback's (atomics, read by the UI): the sample being heard as
	// of its last request (handed to SDL minus what waits in the stream and
	// the device's buffer), whether it is advancing (it stops at the end
	// when not looping), the seek it applied last, and the samples handed
	// to SDL so far (diagnostics).
	heard:         i64,
	advancing:     bool,
	applied_gen:   u32,
	fed:           i64,
	// The callback's own: the next sample handed to SDL, and scratch.
	position:      i64,
	scratch:       [AUDIO_CHUNK * 2]f32,
	// The SDL stream and the device's own buffer (frames).
	sdl_stream:    ^sdl.AudioStream,
	device_frames: i64,
}

audio_shared_destroy :: proc(a: ^Audio_Shared) {
	if a.stream != nil {
		om.mix_stream_destroy(a.stream)
		free(a.stream)
		a.stream = nil
	}
}

// Builds the mix of `placed` (nil or none stops every sound: before the
// media they play from goes) and publishes it with the video's length.
// The mix is built before the swap, so the callback waits for nothing; it
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

// Puts `stream` (and `total`, unless negative) where the callback reads
// them, then frees the one it replaces: after the swap the callback can't
// be using it.
@(private = "file")
audio_swap :: proc(a: ^Audio_Shared, stream: ^om.Mix_Stream, total: i64) {
	if a.sdl_stream != nil {
		sdl.LockAudioStream(a.sdl_stream)
	}
	old := a.stream
	a.stream = stream
	if total >= 0 {
		a.total = total
		a.position = clamp(a.position, 0, max(total - 1, 0))
	}
	if a.sdl_stream != nil {
		sdl.UnlockAudioStream(a.sdl_stream)
	}
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

// Asks for sample `sample` next (the callback clamps it to the video once
// it knows its length: a start time given on the command line survives
// until the tracks arrive).
audio_seek :: proc(a: ^Audio_Shared, sample: i64) {
	sync.atomic_store_explicit(&a.seek_to, sample, .Relaxed)
	sync.atomic_add_explicit(&a.seek_gen, 1, .Release)
}

// The sample being heard now and whether it is still advancing (it stops
// at the end when not looping). A seek the callback hasn't taken yet is
// what will be heard next.
audio_position :: proc(a: ^Audio_Shared) -> (sample: i64, playing: bool, fed: i64) {
	state := transmute(bit_set[Audio_State;u32])sync.atomic_load_explicit(&a.state, .Acquire)
	fed = sync.atomic_load_explicit(&a.fed, .Relaxed)
	if sync.atomic_load_explicit(&a.applied_gen, .Acquire) != sync.atomic_load_explicit(&a.seek_gen, .Acquire) {
		return max(sync.atomic_load_explicit(&a.seek_to, .Relaxed), 0), .Playing in state, fed
	}
	return sync.atomic_load_explicit(&a.heard, .Relaxed), sync.atomic_load_explicit(&a.advancing, .Relaxed), fed
}

// Called on SDL's audio thread (with the stream's lock held) whenever the
// device wants `additional` bytes: drains the UI's rows, then streams them
// from the mix at the play position. Silence while paused or muted; muted
// playback still advances.
audio_callback :: proc "c" (userdata: rawptr, stream: ^sdl.AudioStream, additional, total: c.int) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	a := (^Audio_Shared)(userdata)
	gen := sync.atomic_load_explicit(&a.seek_gen, .Acquire)
	if gen != a.applied_gen {
		to := sync.atomic_load_explicit(&a.seek_to, .Relaxed)
		a.position = clamp(to, 0, a.total - 1) if a.total > 0 else max(to, 0)
	}
	state := transmute(bit_set[Audio_State;u32])sync.atomic_load_explicit(&a.state, .Acquire)
	gain := transmute(f32)sync.atomic_load_explicit(&a.gain, .Relaxed)
	playing := .Playing in state
	frames := int(additional) / (2 * size_of(f32))
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
			}
			run := min(n - k, int(a.total - a.position))
			if .Muted not_in state && a.stream != nil {
				part := buf[k * 2:][:run * 2]
				om.mix_block(a.stream, int(a.position), part)
				for &x in part {
					x *= gain
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
		heard = max(a.position - queued - a.device_frames, 0)
	}
	sync.atomic_store_explicit(&a.heard, heard, .Relaxed)
	sync.atomic_store_explicit(&a.advancing, playing, .Relaxed)
	sync.atomic_store_explicit(&a.applied_gen, gen, .Release)
}

// Opens the default playback device with the callback; nil when there is
// no audio device (the preview then runs on its own clock).
audio_open :: proc(a: ^Audio_Shared) -> ^sdl.AudioStream {
	if !sdl.InitSubSystem({.AUDIO}) {
		return nil
	}
	spec := sdl.AudioSpec{format = .F32, channels = 2, freq = om.MIX_RATE}
	stream := sdl.OpenAudioDeviceStream(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, audio_callback, a)
	if stream == nil {
		return nil
	}
	spec_out: sdl.AudioSpec
	frames: c.int
	if sdl.GetAudioDeviceFormat(sdl.GetAudioStreamDevice(stream), &spec_out, &frames) {
		a.device_frames = i64(frames)
	}
	a.sdl_stream = stream
	sdl.ResumeAudioStreamDevice(stream)
	return stream
}

audio_close :: proc(stream: ^sdl.AudioStream) {
	if stream != nil {
		sdl.DestroyAudioStream(stream)
	}
}
