package onimite_app

import "core:fmt"
import "core:strings"
import om "../onimite"

// What the video's parts are called and what they say, for every view of
// them: `onimite show` (text and --json are two prints of one result) and
// the preview's timeline rows. A view never words an item itself.

// A placed track in one line: its file, span, scene, bus, level, pan,
// fades, where in the file it starts, voice and ducking, and its cue.
track_summary :: proc(p: om.Placed_Track) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s  %.3fs..%.3fs", p.track.src, f64(p.start) / om.MIX_RATE, f64(p.end) / om.MIX_RATE)
	if p.scene != "" {
		fmt.sbprintf(&b, "  scene %s", p.scene)
	}
	if p.track.bus != "" {
		fmt.sbprintf(&b, "  bus %s", p.track.bus)
	}
	if p.track.gain_db != 0 {
		fmt.sbprintf(&b, "  %+.1f dB", p.track.gain_db)
	}
	if p.track.pan != 0 {
		fmt.sbprintf(&b, "  pan %+.2f", p.track.pan)
	}
	if p.track.fade_in > 0 || p.track.fade_out > 0 {
		fmt.sbprintf(&b, "  fades %.2fs/%.2fs", p.track.fade_in, p.track.fade_out)
	}
	if p.track.offset > 0 {
		fmt.sbprintf(&b, "  from %.2fs of the file", p.track.offset)
	}
	if p.track.voice {
		strings.write_string(&b, "  voice")
	}
	if p.track.ducked {
		strings.write_string(&b, "  ducked")
	}
	if p.track.cue != "" {
		fmt.sbprintf(&b, "  cue %s", p.track.cue)
	}
	return strings.to_string(b)
}

// A bus in one line ("" is the tracks on no bus).
bus_summary :: proc(name: string, tracks: int, gain_db: f32) -> string {
	if name == "" {
		return fmt.tprintf("tracks  %d sounds on no bus", tracks)
	}
	if gain_db != 0 {
		return fmt.tprintf("bus %s  %d sounds  %+.1f dB", name, tracks, gain_db)
	}
	return fmt.tprintf("bus %s  %d sounds", name, tracks)
}
