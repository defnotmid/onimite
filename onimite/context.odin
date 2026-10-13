package onimite

import "core:strings"

// Passed to render procs: where nodes go, plus the video, its timeline and
// its media.
Context :: struct {
	video:       ^Video,
	timeline:    ^Timeline,
	media:       ^Media,
	// The clip table frames show clips from: the media's, or a renderer's
	// own (the preview's thumbnails decode on their own readers).
	videos:      ^Video_Clips,
	tree:        Tree,
	diagnostics: [dynamic]Diagnostic,
	// The frame being built (video level).
	frame:       Frame,
	// Compiled shaders, kept across frames (shader.odin).
	shaders:     Shader_Library,
	// Per shader program, its layers so far in the frame being built
	// (their feedback instances); cleared by `build_frame`.
	shader_uses: [dynamic]u32,
	// SVG markup parsed by this context, kept across frames (svg.odin).
	svgs:        Svg_Cache,
	// Lottie JSON parsed by this context, kept across frames (lottie.odin).
	lotties:     Lottie_Cache,
	// Built off the playing thread (a recording renderer): clip frames are
	// asked for when the frame is played, in frame order, so building
	// sends the decoders no hints.
	recording:   bool,
	// The first node of each scene `render_scenes` built this frame, in
	// order (cleared by `build_frame`): which scene drew a node.
	scene_starts: [dynamic]i32,
	// The node being drawn, index + 1 (0 outside drawing): `report` puts it
	// on what it reports.
	node:         i32,
	// The video's tracks placed on `timeline` (`placed_audio`).
	placed:       Placed_Audio,
	// Sound the frame asked for that is still being built (the preview
	// draws it again when it lands); cleared by `build_frame`.
	audio_pending: int,
}

// Renders the scenes active at `f` (a video-level frame), earlier scenes
// below later ones. Inside, each scene sees its own frame numbering.
render_scenes :: proc(f: Frame, ctx: ^Context) {
	for &info in ctx.timeline.scenes {
		if f.global_index < info.start_frame || f.global_index >= info.end_frame {
			continue
		}
		if info.scene.render == nil {
			continue
		}
		sf := Frame {
			index        = f.global_index - info.start_frame,
			global_index = f.global_index,
			fps          = f.fps,
			scene        = &info,
		}
		append(&ctx.scene_starts, i32(len(ctx.tree.nodes)))
		info.scene.render(sf, ctx)
	}
}

// The scene's position on the timeline, e.g. to start an outro relative to
// its end. `ok = false` if no scene has that name.
scene_info :: proc(ctx: ^Context, name: string) -> (info: Scene_Info, ok: bool) {
	i := find_scene(ctx.timeline^, name)
	if i < 0 {
		return {}, false
	}
	return ctx.timeline.scenes[i], true
}

// Records a diagnostic for the current frame (`d`'s severity, frame and
// scene are filled in; its strings are cloned).
report :: proc(ctx: ^Context, severity: Severity, d: Diagnostic) {
	d := d
	d.severity = severity
	d.frame = ctx.frame.global_index
	if d.node == 0 {
		d.node = ctx.node
	}
	d.scene = ""
	for info in ctx.timeline.scenes {
		if ctx.frame.global_index >= info.start_frame && ctx.frame.global_index < info.end_frame {
			d.scene = info.scene.name
		}
	}
	d.name = strings.clone(d.name)
	d.a = strings.clone(d.a)
	d.b = strings.clone(d.b)
	e := &d.shader
	e.name, e.a, e.b, e.c = strings.clone(e.name), strings.clone(e.a), strings.clone(e.b), strings.clone(e.c)
	append(&ctx.diagnostics, d)
}

// Frees the strings `report` cloned.
diagnostics_free :: proc(list: []Diagnostic) {
	for d in list {
		delete(d.name)
		delete(d.a)
		delete(d.b)
		delete(d.shader.name)
		delete(d.shader.a)
		delete(d.shader.b)
		delete(d.shader.c)
	}
}

diagnostics_clear :: proc(ctx: ^Context) {
	diagnostics_free(ctx.diagnostics[:])
	clear(&ctx.diagnostics)
}

// Whether the current frame has a `code` diagnostic about `name`.
@(private)
has_diagnostic :: proc(ctx: ^Context, code: Diagnostic_Code, name: string) -> bool {
	for d in ctx.diagnostics {
		if d.frame == ctx.frame.global_index && d.code == code && d.name == name {
			return true
		}
	}
	return false
}
