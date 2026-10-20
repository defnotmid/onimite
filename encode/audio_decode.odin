package onimite_encode

import "core:strings"
import ma "vendor:miniaudio"
import mp4 "deps:odecs/mp4"
import movie "deps:odecs/movie"

// Decodes the audio formats onimite' core doesn't: AAC in MP4/M4A (odecs'
// movie reader) and MP3/FLAC (miniaudio). Plug into `Media.decoder`.
audio_decoder :: proc(data: []u8, ext: string) -> (samples: []f32, rate: int, channels: int, ok: bool) {
	switch strings.to_lower(ext, context.temp_allocator) {
	case ".m4a", ".mp4", ".aac":
		return decode_mp4_aac(data)
	case ".mp3", ".flac":
		return decode_miniaudio(data)
	}
	return
}

// Decodes at the file's own rate and channels.
@(private)
decode_miniaudio :: proc(data: []u8) -> (samples: []f32, rate: int, channels: int, ok: bool) {
	cfg := ma.decoder_config_init(.f32, 0, 0)
	frames: u64
	pcm: rawptr
	if ma.decode_memory(raw_data(data), len(data), &cfg, &frames, &pcm) != .SUCCESS || pcm == nil || cfg.channels == 0 {
		return
	}
	defer ma.free(pcm, nil)
	rate, channels = int(cfg.sampleRate), int(cfg.channels)
	samples = make([]f32, int(frames) * channels)
	copy(samples, ([^]f32)(pcm)[:len(samples)])
	return samples, rate, channels, true
}

// The first AAC-LC track of an MP4/M4A file through odecs' movie reader,
// which trims encoder priming and padding by the edit list.
@(private)
decode_mp4_aac :: proc(data: []u8) -> (samples: []f32, rate: int, channels: int, ok: bool) {
	m := mp4.Memory_Stream{}
	append(&m.data, ..data)
	defer delete(m.data)
	r: movie.Reader
	if movie.open_reader_stream(&r, mp4.memory_stream(&m), {preference = .Native}) != .None {
		movie.close_reader(&r)
		return
	}
	defer movie.close_reader(&r)
	if !r.audio.present {
		return
	}
	ch := r.audio.channels
	samples = make([]f32, int(r.audio.samples) * ch)
	n, err := movie.read_audio(&r, samples)
	if err != .None && err != .End_Of_Stream && n == 0 {
		delete(samples)
		return nil, 0, 0, false
	}
	return samples[:n * ch], r.audio.sample_rate, ch, true
}
