package onimite_encode

import "core:fmt"
import video "deps:odecs/video"

// `onimite probe FILE`: what odecs' reader finds in a media file (container,
// video and audio stream), so nothing outside the binary is needed to check
// a rendered or reference video.

Probe_Video :: struct {
	codec:      string  `json:"codec"`,
	width:      int     `json:"width"`,
	height:     int     `json:"height"`,
	rotation:   int     `json:"rotation"`,
	fps:        f64     `json:"fps"`,
	frames:     int     `json:"frames"`,
	duration:   f64     `json:"duration"`,
	bit_depth:  int     `json:"bit_depth"`,
	has_alpha:  bool    `json:"has_alpha"`,
}

Probe_Audio :: struct {
	codec:       string `json:"codec"`,
	sample_rate: int    `json:"sample_rate"`,
	channels:    int    `json:"channels"`,
	duration:    f64    `json:"duration"`,
}

Probe_Result :: struct {
	path:      string       `json:"path"`,
	container: string       `json:"container"`,
	video:     Maybe(Probe_Video) `json:"video"`,
	audio:     Maybe(Probe_Audio) `json:"audio"`,
}

// What odecs' reader finds in `path`; on failure `f` says why (`.Probe_Open`,
// `path` borrowed).
probe :: proc(path: string) -> (res: Probe_Result, f: Failure) {
	r: video.Reader
	// Native: opening only parses headers, so no GPU decoder is set up.
	if e := video.open_reader(&r, path, {preference = .Native}); e != .None {
		f = {code = .Probe_Open, path = path, movie = e, detail = r.error_detail}
		video.close_reader(&r)
		return
	}
	defer video.close_reader(&r)
	res = {path = path, container = fmt.tprint(r.audio.container)}
	if r.video_index >= 0 {
		v := r.video
		fps := f64(v.fps_num) / f64(max(v.fps_den, 1)) if v.fps_num > 0 else 0
		res.video = Probe_Video{fmt.tprint(v.codec), v.width, v.height, v.rotation, fps, v.frame_count, v.duration, v.bit_depth, v.has_alpha}
	}
	if r.audio.track >= 0 || r.audio.codec != .None {
		a := r.audio.info
		dur := f64(a.samples) / f64(a.sample_rate) if a.sample_rate > 0 else 0
		res.audio = Probe_Audio{fmt.tprint(a.codec), a.sample_rate, a.channels, dur}
	}
	return
}
