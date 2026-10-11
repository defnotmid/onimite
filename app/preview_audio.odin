package onimite_app

import "base:runtime"
import "core:c"
import "core:sync"
import om "../onimite"
import sdl "vendor:sdl3"

// Preview sound. SDL's audio thread asks for samples through a callback,
// which mixes them there and then from the placed tracks at the play
// position (a stream: no mix is made ahead). The render worker publishes the
// tracks after a load and again whenever clips built on the pool land, so
// sound joins in as it is made; the clock never waits for it. Playing,
// muted, looping and seeks are written by the UI thread's command handlers;
// the position is read back by the UI as the playback clock, so picture
// follows sound. The volume is an atomic (f32 bits) the callback reads
// without taking the mutex.

AUDIO_CHUNK :: 2048 // frames mixed per step inside the callback

Audio_Shared :: struct {
	mutex:    sync.Mutex,
	// The placed tracks the callback mixes, owned; their clips point into
	// `clips` (copies of the clips' headers: the samples belong to the
	// worker's media, which outlives them).
	tracks:   []om.Placed_Track,
	clips:    []om.Audio_Clip,
	opts:     om.Mix_Options,
	stream_state: om.Mix_Stream,
	total:    i64, // the video's length in samples
	position: i64, // next sample handed to SDL
	playing:  bool,
	muted:    bool,
	looping:  bool,
	// Samples handed to SDL so far (diagnostics: compare with the playhead).
	fed:      i64,
	// The volume as f32 bits; written by the UI, read by the callback
	// (atomic, outside the mutex).
	gain:     u32,
	scratch:  [AUDIO_CHUNK * 2]f32,
	// The stream and the device's own buffer (frames): what is handed to SDL
	// is heard only after both, so the playhead stays behind by that much.
	stream:        ^sdl.AudioStream,
	device_frames: i64,
}

audio_shared_destroy :: proc(a: ^Audio_Shared) {
	delete(a.tracks)
	delete(a.clips)
	a.tracks, a.clips = nil, nil
}

// Publishes the tracks to mix (`placed` is copied; nil stops every sound:
// before the media they play from goes) and the video's length.
audio_set_tracks :: proc(a: ^Audio_Shared, placed: []om.Placed_Track, total: i64, opts: om.Mix_Options) {
	tracks := make([]om.Placed_Track, len(placed))
	clips := make([dynamic]om.Audio_Clip, 0, len(placed))
	from := make(map[^om.Audio_Clip]int, len(placed), context.temp_allocator)
	for p, i in placed {
		k, seen := from[p.clip]
		if !seen {
			k = len(clips)
			from[p.clip] = k
			append(&clips, p.clip^)
		}
		tracks[i] = p
	}
	// Point the tracks at the copies only once `clips` stops growing.
	for &t, i in tracks {
		t.clip = &clips[from[placed[i].clip]]
	}
	sync.mutex_lock(&a.mutex)
	old_tracks, old_clips := a.tracks, a.clips
	a.tracks, a.clips = tracks, clips[:]
	a.opts = opts
	a.total = total
	a.position = clamp(a.position, 0, max(total - 1, 0))
	sync.mutex_unlock(&a.mutex)
	delete(old_tracks)
	delete(old_clips)
}

// Stops every sound until tracks are published again (before the samples
// they play from change or go).
audio_clear_tracks :: proc(a: ^Audio_Shared) {
	sync.mutex_lock(&a.mutex)
	old_tracks, old_clips := a.tracks, a.clips
	a.tracks, a.clips = nil, nil
	sync.mutex_unlock(&a.mutex)
	delete(old_tracks)
	delete(old_clips)
}

audio_set_state :: proc(a: ^Audio_Shared, playing, muted, looping: bool) {
	sync.mutex_lock(&a.mutex)
	a.playing, a.muted, a.looping = playing, muted, looping
	sync.mutex_unlock(&a.mutex)
}

audio_set_gain :: proc(a: ^Audio_Shared, gain: f32) {
	sync.atomic_store_explicit(&a.gain, transmute(u32)gain, .Relaxed)
}

audio_seek :: proc(a: ^Audio_Shared, sample: i64) {
	sync.mutex_lock(&a.mutex)
	// Before the first load (total 0) the position is kept as asked, so a
	// start time given on the command line survives until the tracks arrive
	// (audio_set_tracks clamps it then).
	a.position = clamp(sample, 0, a.total - 1) if a.total > 0 else max(sample, 0)
	sync.mutex_unlock(&a.mutex)
}

// The sample being heard now and whether it is still advancing (it stops at
// the end when not looping): the next sample handed to SDL minus what waits
// in the stream and the device's buffer, so the picture shows what you hear.
audio_position :: proc(a: ^Audio_Shared) -> (sample: i64, playing: bool, fed: i64) {
	queued: i64
	if a.stream != nil {
		queued = i64(sdl.GetAudioStreamQueued(a.stream)) / (2 * size_of(f32))
	}
	sync.mutex_lock(&a.mutex)
	defer sync.mutex_unlock(&a.mutex)
	sample = a.position
	if a.playing {
		sample = max(a.position - queued - a.device_frames, 0)
	}
	return sample, a.playing, a.fed
}

// Called on SDL's audio thread whenever the device wants `additional`
// bytes: mixes them from the tracks at the play position. Silence while
// paused or muted; muted playback still advances.
audio_callback :: proc "c" (userdata: rawptr, stream: ^sdl.AudioStream, additional, total: c.int) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	a := (^Audio_Shared)(userdata)
	frames := int(additional) / (2 * size_of(f32))
	gain := transmute(f32)sync.atomic_load_explicit(&a.gain, .Relaxed)
	for frames > 0 {
		n := min(frames, AUDIO_CHUNK)
		sync.mutex_lock(&a.mutex)
		buf := a.scratch[:n * 2]
		for &x in buf {
			x = 0
		}
		// Up to the end, then (looping) on from the start.
		for k := 0; a.playing && a.total > 0 && k < n; {
			if a.position >= a.total {
				if !a.looping {
					a.playing = false
					break
				}
				a.position = 0
			}
			run := min(n - k, int(a.total - a.position))
			if !a.muted && len(a.tracks) > 0 {
				part := buf[k * 2:][:run * 2]
				om.mix_block(a.tracks, int(a.position), part, a.opts, &a.stream_state)
				for &x in part {
					x *= gain
				}
			}
			a.position += i64(run)
			k += run
		}
		a.fed += i64(n)
		sdl.PutAudioStreamData(stream, raw_data(buf), c.int(n * 2 * size_of(f32)))
		sync.mutex_unlock(&a.mutex)
		frames -= n
	}
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
	a.stream = stream
	sdl.ResumeAudioStreamDevice(stream)
	return stream
}

audio_close :: proc(stream: ^sdl.AudioStream) {
	if stream != nil {
		sdl.DestroyAudioStream(stream)
	}
}
