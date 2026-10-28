package onimite_app

import "core:fmt"
import "core:slice"
import "core:strings"
import om "../onimite"
import script "../script"

// `motion`: how fast what is drawn moves at the given times, from the
// frame's motion table (om.build_motion): each draw where it moves most,
// in video pixels a frame, measured over the opening half of a 180°
// shutter, with the script line that drew it; and what appears within
// that half (drawn at the frame, not at the opening).

Motion_Draw :: struct {
	label:  string  `json:"label"`,
	source: string  `json:"source"`,
	// Video pixels a frame where it moves most, and its centre's motion.
	speed:  f32     `json:"speed"`,
	dx:     f32     `json:"dx"`,
	dy:     f32     `json:"dy"`,
}

Motion_Result :: struct {
	spec:     string        `json:"spec"`,
	frame:    int           `json:"frame"`,
	seconds:  f64           `json:"seconds"`,
	scenes:   []string      `json:"scenes"`,
	// Seconds from the frame back to where its motion is measured from.
	shift:    f64           `json:"shift"`,
	moving:   []Motion_Draw `json:"moving"`,
	still:    int           `json:"still"`,
	appears:  []Motion_Draw `json:"appears"`,
	problems: Frame_Report  `json:"problems"`,
}

@(private)
motion_at :: proc(app: ^App_State, regs: Command_Regs) -> Error {
	r := renderer_scaled(app, 1) or_return
	fps := r.video.fps
	specs, frames := resolve_frames(app, &r.timeline, fps, regs.spec) or_return
	results := make([]Motion_Result, len(frames), context.temp_allocator)
	app.script.node_sources_on = true
	defer app.script.node_sources_on = false
	b := strings.builder_make(context.temp_allocator)
	for f, k in frames {
		om.build_motion(r, f, om.motion_shift(fps))
		moving := make([dynamic]Motion_Draw, context.temp_allocator)
		appears := make([dynamic]Motion_Draw, context.temp_allocator)
		still := 0
		for state, i in r.motion.state {
			if state == .None {
				continue
			}
			d := Motion_Draw {
				label  = om.node_label(&r.ctx.tree, i32(i)),
				source = script.node_source(&app.script, i),
			}
			if state == .Unpaired {
				append(&appears, d)
				continue
			}
			speed, dir := om.motion_speed(r, i)
			// Below what the listing shows (0.1 px) it is still.
			if speed < 0.05 {
				still += 1
				continue
			}
			d.speed, d.dx, d.dy = speed, dir.x, dir.y
			append(&moving, d)
		}
		slice.sort_by(moving[:], proc(a, b: Motion_Draw) -> bool {return a.speed > b.speed})
		rep := take_frame_report(app, r, f)
		results[k] = {specs[k], f, f64(rep.seconds), rep.scenes, r.motion.shift, moving[:], still, appears[:], rep}
		if k > 0 {
			strings.write_byte(&b, '\n')
		}
		fmt.sbprintf(&b, "%s frame %d %.2fs%s: %d moving, %d still, %d appearing\n", specs[k], f, rep.seconds, scenes_label(rep.scenes), len(moving), still, len(appears))
		for d in moving {
			fmt.sbprintf(&b, "  %.1f px a frame (%+.1f, %+.1f)  %s  %s\n", d.speed, d.dx, d.dy, d.label, d.source)
		}
		for d in appears {
			fmt.sbprintf(&b, "  appears: %s  %s\n", d.label, d.source)
		}
		strings.write_string(&b, diagnostics_text(rep, "  "))
	}
	emit(app, results, strings.trim_right_space(strings.to_string(b)))
	return nil
}
