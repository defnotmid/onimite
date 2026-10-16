package onimite_app

import "base:runtime"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"
import om "../onimite"
import script "../script"
import "../speech"

// `onimite show video.lua [path]`: any part of the video looked at the same
// way, like a debugger's watch window: a summary, its fields (read from the
// Odin structs, so new fields show up by themselves), its children by path a
// page at a time, and the script line that made it. A query builds its rows
// from what the app already has and keeps nothing.
//
//   (empty)                 the video
//   scenes, cues, buses, tracks, clips, nodes      the lists
//   scene/Race              a scene; scene/Race/sounds, scene/Race/nodes
//   cue/drop                a cue and what lands on it
//   bus/sfx                 a bus and its tracks
//   track/12                a placed sound (in time order)
//   clip/tick_1900          a sound clip
//   node/scenes/race.lua:19[2]   what that script line drew (the third), at --at

SHOW_PAGE :: 20

Show_Child :: struct {
	path:    string `json:"path"`,
	kind:    string `json:"kind"`,
	summary: string `json:"summary"`,
}

Show_Result :: struct {
	path:           string       `json:"path"`,
	kind:           string       `json:"kind"`,
	summary:        string       `json:"summary"`,
	source:         string       `json:"source"`,
	fields:         json.Object  `json:"fields"`,
	children:       []Show_Child `json:"children"`,
	total_children: int          `json:"total_children"`,
	page:           int          `json:"page"`,
	pages:          int          `json:"pages"`,
}

@(private = "file")
Show :: struct {
	app:      ^App_State,
	r:        ^om.Renderer,
	fps:      f64,
	at:       string, // --at, "" when not given
	res:      Show_Result,
	children: [dynamic]Show_Child,
}

@(private)
show_print :: proc(app: ^App_State, regs: Command_Regs) -> Error {
	r := renderer_scaled(app, 0.25) or_return
	sh := Show {
		app      = app,
		r        = r,
		fps      = f64(r.video.fps),
		at       = regs.at,
		children = make([dynamic]Show_Child, context.temp_allocator),
	}
	path := strings.trim(regs.spec, "/ ")
	sh.res.path = path
	sh.res.fields = make(json.Object, allocator = context.temp_allocator)
	head, _, rest := strings.partition(path, "/")
	found := false
	for p in SHOW_PATHS {
		if p.head == head {
			p.view(&sh, rest) or_return
			found = true
			break
		}
	}
	if !found {
		return show_unknown(&sh, path)
	}

	// A page of the children.
	total := len(sh.children)
	pages := max((total + SHOW_PAGE - 1) / SHOW_PAGE, 1)
	page := clamp(regs.count if regs.count > 0 else 1, 1, pages)
	lo := min((page - 1) * SHOW_PAGE, total)
	hi := min(lo + SHOW_PAGE, total)
	sh.res.children = sh.children[lo:hi]
	sh.res.total_children, sh.res.page, sh.res.pages = total, page, pages

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s  %s", sh.res.kind, sh.res.summary)
	if sh.res.source != "" && !strings.contains(sh.res.summary, sh.res.source) {
		fmt.sbprintf(&b, "  %s", sh.res.source)
	}
	keys, _ := slice.map_keys(sh.res.fields, context.temp_allocator)
	slice.sort(keys)
	for k in keys {
		v := sh.res.fields[k]
		if show_empty(v) {
			continue
		}
		fmt.sbprintf(&b, "\n  %-16s %s", k, show_value_text(v))
	}
	if total > 0 {
		fmt.sbprintf(&b, "\n%d children", total)
		if pages > 1 {
			fmt.sbprintf(&b, " (page %d of %d: --page N)", page, pages)
		}
		strings.write_byte(&b, ':')
		for c in sh.res.children {
			fmt.sbprintf(&b, "\n  %-30s %s", c.path, c.summary)
		}
	}
	emit(app, sh.res, strings.to_string(b))
	return nil
}

// What a part of the video is; its name is the --json `kind`.
Show_Kind :: enum u8 {
	Video,
	List,
	Scene,
	Cue,
	Bus,
	Track,
	Clip,
	Say,
	Word,
	Node,
	Media,
	Font,
	Body,
}

@(private = "file")
show_kind :: proc(k: Show_Kind) -> string {
	return strings.to_lower(fmt.tprint(k), context.temp_allocator)
}

// Every path `show` answers: its first segment, how a user writes it, and
// the view. Dispatch and the suggestions for an unknown path read it.
@(private = "file")
Show_Path :: struct {
	head:  string,
	usage: string,
	view:  proc(sh: ^Show, rest: string) -> Error,
}

@(private = "file")
SHOW_PATHS := [?]Show_Path {
	{"", "", show_video},
	{"scenes", "scenes", show_scenes},
	{"scene", "scene/NAME", show_scene},
	{"cues", "cues", show_cues},
	{"cue", "cue/NAME", show_cue},
	{"buses", "buses", show_buses},
	{"bus", "bus/NAME", show_bus},
	{"tracks", "tracks", show_tracks},
	{"track", "track/N", show_track},
	{"clips", "clips", show_clips},
	{"clip", "clip/NAME", show_clip},
	{"says", "says", show_says},
	{"say", "say/NAME", show_say},
	{"media", "media, media/FILE", show_media},
	{"fonts", "fonts", show_fonts},
	{"font", "font/FAMILY", show_font},
	{"bodies", "bodies", show_bodies},
	{"body", "body/NAME", show_body},
	{"nodes", "nodes", show_nodes},
	{"node", "node/FILE:LINE", show_node},
}

@(private = "file")
show_unknown :: proc(sh: ^Show, path: string) -> Error {
	names := make([dynamic]string, context.temp_allocator)
	for p in SHOW_PATHS {
		if p.usage != "" {
			append(&names, p.usage)
		}
	}
	return fail(sh.app, {code = .No_Path, name = path, names = names[:]})
}

@(private = "file")
child :: proc(sh: ^Show, path: string, kind: Show_Kind, summary: string) {
	append(&sh.children, Show_Child{path, show_kind(kind), summary})
}

// ---- the video and its lists ------------------------------------------------------

@(private = "file")
show_video :: proc(sh: ^Show, _: string) -> Error {
	v := sh.r.video
	tl := &sh.r.timeline
	sh.res.kind = show_kind(.Video)
	sh.res.summary = fmt.tprintf("%dx%d @ %d fps, %d frames (%.2fs)", v.width, v.height, v.fps, tl.duration_frames, f64(tl.duration_frames) / sh.fps)
	sh.res.fields = reflect_object(v^, 0)
	// `audio` is what video{} declares; scenes declare theirs.
	sh.res.fields["audio"] = json.Integer(om.tracks_placed_by(v, nil))
	child(sh, "scenes", .List, fmt.tprintf("%d scenes", len(tl.scenes)))
	child(sh, "cues", .List, fmt.tprintf("%d cues", len(sh.app.script.cues)))
	child(sh, "buses", .List, fmt.tprintf("%d buses", len(v.buses)))
	child(sh, "tracks", .List, fmt.tprintf("%d sounds placed", len(v.audio)))
	child(sh, "clips", .List, fmt.tprintf("%d clips (%d made by the script, built when needed)", len(sh.app.media.audio) + len(sh.app.script.pending_audio), len(sh.app.script.pending_audio)))
	if n := len(sh.app.script.said); n > 0 {
		child(sh, "says", .List, fmt.tprintf("%d spoken lines (say)", n))
	}
	m := &sh.app.media
	child(sh, "media", .List, fmt.tprintf("%d media files besides the sounds", len(media_files(m))))
	child(sh, "fonts", .List, fmt.tprintf("%d font faces (%d built in)", len(m.fonts.faces), m.builtin_faces))
	if n := len(script.physics_bodies(&sh.app.script)); n > 0 {
		child(sh, "bodies", .List, fmt.tprintf("%d physics bodies", n))
	}
	child(sh, "nodes", .List, "what is drawn at a time (--at)")
	return nil
}

@(private = "file")
show_scenes :: proc(sh: ^Show, _: string) -> Error {
	sh.res.kind = show_kind(.List)
	sh.res.summary = fmt.tprintf("%d scenes", len(sh.r.timeline.scenes))
	for s in sh.r.timeline.scenes {
		child(sh, fmt.tprintf("scene/%s", s.scene.name), .Scene, scene_summary(s, sh.fps))
	}
	return nil
}

@(private = "file")
find_scene_info :: proc(sh: ^Show, name: string) -> (om.Scene_Info, bool) {
	if strings.has_prefix(name, "#") {
		if i, ok := strconv.parse_int(name[1:]); ok && i >= 0 && i < len(sh.r.timeline.scenes) {
			return sh.r.timeline.scenes[i], true
		}
	}
	if i := om.find_scene(sh.r.timeline, name); i >= 0 {
		return sh.r.timeline.scenes[i], true
	}
	return {}, false
}

@(private = "file")
show_scene :: proc(sh: ^Show, rest: string) -> Error {
	name, _, sub := strings.partition(rest, "/")
	s, ok := find_scene_info(sh, name)
	if !ok {
		return fail(sh.app, spec_failure(&sh.r.timeline, sh.r.video.fps, name, om.Error.Unknown_Scene))
	}
	base := fmt.tprintf("scene/%s", s.scene.name)
	switch sub {
	case "sounds":
		build_audio(sh.app) or_return
		sh.res.kind = show_kind(.List)
		pa := om.placed_audio(&sh.r.ctx)
		placed, order := pa.tracks[:], pa.order[:]
		for k, idx in order {
			if placed[k].track.scene == s.index {
				child(sh, fmt.tprintf("track/%d", idx), .Track, track_summary(placed[k]))
			}
		}
		sh.res.summary = fmt.tprintf("%d sounds placed by scene %s", len(sh.children), s.scene.name)
		return nil
	case "nodes":
		// Default: the middle of the scene.
		if sh.at == "" {
			sh.at = fmt.tprint((s.start_frame + s.end_frame) / 2)
		}
		return show_scene_nodes(sh, s)
	case "":
	case:
		return show_unknown(sh, sh.res.path)
	}
	sh.res.kind = show_kind(.Scene)
	sh.res.summary = scene_summary(s, sh.fps)
	sh.res.source = s.scene.source
	sh.res.fields = reflect_object(s.scene^, 0)
	sounds := om.tracks_placed_by(sh.r.video, s.index)
	sh.res.fields["audio"] = json.Integer(sounds)
	sh.res.fields["start_frame"] = json.Integer(s.start_frame)
	sh.res.fields["end_frame"] = json.Integer(s.end_frame)
	sh.res.fields["start_seconds"] = json.Float(f64(s.start_frame) / sh.fps)
	sh.res.fields["end_seconds"] = json.Float(f64(s.end_frame) / sh.fps)
	if s.scene.cue != "" {
		child(sh, fmt.tprintf("cue/%s", s.scene.cue), .Cue, "the cue it starts on")
	}
	child(sh, fmt.tprintf("%s/sounds", base), .List, fmt.tprintf("%d sounds it places", sounds))
	child(sh, fmt.tprintf("%s/nodes", base), .List, "what it draws (--at, default its middle)")
	return nil
}

// ---- cues ----------------------------------------------------------------------------

@(private = "file")
show_cues :: proc(sh: ^Show, _: string) -> Error {
	sh.res.kind = show_kind(.List)
	sh.res.summary = fmt.tprintf("%d cues", len(sh.app.script.cues))
	for c in sh.app.script.cues {
		child(sh, fmt.tprintf("cue/%s", c.name), .Cue, cue_summary(c, sh.r.video.fps))
	}
	return nil
}

@(private = "file")
show_cue :: proc(sh: ^Show, name: string) -> Error {
	anchors := sync_anchors(sh.app, sh.r) or_return
	found := false
	for c in sh.app.script.cues {
		if c.name == name {
			found = true
			sh.res.kind = show_kind(.Cue)
			sh.res.source = c.at
			sh.res.summary = fmt.tprintf("%s at %.3fs (frame %d)", c.name, c.seconds, om.frame_at(c.seconds, sh.r.video.fps))
			sh.res.fields = reflect_object(c, 0)
		}
	}
	for a in anchors {
		if a.id != name || a.kind == .Cue {
			continue
		}
		found = true
		if sh.res.kind == "" {
			sh.res.kind = show_kind(.Cue)
			sh.res.summary = fmt.tprintf("%s (no cue() names it)", name)
		}
		path := ""
		kind := Show_Kind.Cue
		switch a.kind {
		case .Scene:
			path, kind = fmt.tprintf("scene/%s", strings.trim_prefix(a.label, "scene ")), .Scene
		case .Track:
			path, kind = "tracks", .List
		case .Key:
			path, kind = fmt.tprintf("node/%s", strings.trim_suffix(strings.trim_prefix(a.label, "animate key ("), ")")), .Node
		case .Cue:
		}
		child(sh, path, kind, fmt.tprintf("%s at %.3fs", a.label, a.seconds))
	}
	if !found {
		names := make([dynamic]string, context.temp_allocator)
		for c in sh.app.script.cues {
			append(&names, c.name)
		}
		return fail(sh.app, {code = .No_Path, name = fmt.tprintf("cue/%s", name), names = names[:]})
	}
	return nil
}

// ---- buses, tracks, clips -----------------------------------------------------------------

@(private = "file")
show_buses :: proc(sh: ^Show, _: string) -> Error {
	build_audio(sh.app) or_return
	placed := om.placed_audio(&sh.r.ctx).tracks[:]
	sh.res.kind = show_kind(.List)
	sh.res.summary = fmt.tprintf("%d buses", len(sh.r.video.buses))
	for b in sh.r.video.buses {
		n := 0
		for p in placed {
			if p.track.bus == b.name {
				n += 1
			}
		}
		child(sh, fmt.tprintf("bus/%s", b.name), .Bus, bus_summary(b.name, n, b.gain_db))
	}
	return nil
}

@(private = "file")
show_bus :: proc(sh: ^Show, rest: string) -> Error {
	name, _, sub := strings.partition(rest, "/")
	bus: om.Bus
	found := false
	for b in sh.r.video.buses {
		if b.name == name {
			bus, found = b, true
		}
	}
	if !found {
		names := make([dynamic]string, context.temp_allocator)
		for b in sh.r.video.buses {
			append(&names, b.name)
		}
		return fail(sh.app, {code = .No_Path, name = fmt.tprintf("bus/%s", name), names = names[:]})
	}
	build_audio(sh.app) or_return
	pa := om.placed_audio(&sh.r.ctx)
	placed, order := pa.tracks[:], pa.order[:]
	mine := make([dynamic]int, context.temp_allocator)
	for k, idx in order {
		if placed[k].track.bus == name {
			append(&mine, idx)
		}
	}
	if sub != "" {
		// bus/sfx/12: its 13th track.
		i, ok := strconv.parse_int(sub)
		if !ok || i < 0 || i >= len(mine) {
			return fail(sh.app, {code = .No_Path, name = sh.res.path, names = {fmt.tprintf("bus/%s/0..%d", name, len(mine) - 1)}})
		}
		return show_track(sh, fmt.tprint(mine[i]))
	}
	sh.res.kind = show_kind(.Bus)
	sh.res.summary = bus_summary(name, len(mine), bus.gain_db)
	sh.res.fields = reflect_object(bus, 0)
	for idx in mine {
		child(sh, fmt.tprintf("track/%d", idx), .Track, track_summary(placed[order[idx]]))
	}
	return nil
}

@(private = "file")
show_tracks :: proc(sh: ^Show, _: string) -> Error {
	build_audio(sh.app) or_return
	pa := om.placed_audio(&sh.r.ctx)
	placed, order := pa.tracks[:], pa.order[:]
	missing := missing_audio(sh.app)
	sh.res.kind = show_kind(.List)
	sh.res.summary = fmt.tprintf("%d sounds placed", len(placed))
	if len(missing) > 0 {
		sh.res.summary = fmt.tprintf("%s, %d missing (%s)", sh.res.summary, len(missing), strings.join(missing, ", ", context.temp_allocator))
	}
	for k, idx in order {
		child(sh, fmt.tprintf("track/%d", idx), .Track, track_summary(placed[k]))
	}
	return nil
}

@(private = "file")
show_track :: proc(sh: ^Show, rest: string) -> Error {
	build_audio(sh.app) or_return
	pa := om.placed_audio(&sh.r.ctx)
	placed, order := pa.tracks[:], pa.order[:]
	i, ok := strconv.parse_int(rest)
	if !ok || i < 0 || i >= len(order) {
		return fail(sh.app, {code = .No_Path, name = fmt.tprintf("track/%s", rest), names = {fmt.tprintf("track/0..%d", len(order) - 1)}})
	}
	p := placed[order[i]]
	sh.res.path = fmt.tprintf("track/%d", i)
	sh.res.kind = show_kind(.Track)
	sh.res.summary = track_summary(p)
	sh.res.source = p.track.source
	sh.res.fields = reflect_object(p.track, 0)
	sh.res.fields["start_seconds"] = json.Float(f64(p.start) / om.MIX_RATE)
	sh.res.fields["end_seconds"] = json.Float(f64(p.end) / om.MIX_RATE)
	sh.res.fields["scene"] = json.String(p.scene)
	child(sh, fmt.tprintf("clip/%s", p.track.src), .Clip, "the sound it plays")
	if p.scene != "" {
		child(sh, fmt.tprintf("scene/%s", p.scene), .Scene, "the scene that places it")
	}
	return nil
}

@(private = "file")
show_clips :: proc(sh: ^Show, _: string) -> Error {
	build_audio(sh.app) or_return
	names, _ := slice.map_keys(sh.app.media.audio, context.temp_allocator)
	slice.sort(names)
	sh.res.kind = show_kind(.List)
	sh.res.summary = fmt.tprintf("%d clips", len(names))
	for n in names {
		c := sh.app.media.audio[n]
		child(sh, fmt.tprintf("clip/%s", n), .Clip, fmt.tprintf("%.3fs", om.audio_clip_seconds(c)))
	}
	return nil
}

@(private = "file")
show_clip :: proc(sh: ^Show, name: string) -> Error {
	build_audio(sh.app) or_return
	c, ok := sh.app.media.audio[name]
	if !ok {
		return fail(sh.app, {code = .No_Path, name = fmt.tprintf("clip/%s", name), names = {"clips"}})
	}
	sh.res.kind = show_kind(.Clip)
	sh.res.summary = fmt.tprintf("%s  %.3fs  from %d Hz, %d channels", name, om.audio_clip_seconds(c), c.source_rate, c.source_channels)
	sh.res.fields = reflect_object(c, 0)
	if _, spoken := script.said(&sh.app.script, name); spoken {
		child(sh, fmt.tprintf("say/%s", name), .Say, "the spoken line: its words and when they are said")
	}
	pa := om.placed_audio(&sh.r.ctx)
	placed, order := pa.tracks[:], pa.order[:]
	for k, idx in order {
		if placed[k].track.src == name {
			child(sh, fmt.tprintf("track/%d", idx), .Track, track_summary(placed[k]))
		}
	}
	return nil
}

// ---- spoken lines ----------------------------------------------------------------------------

@(private = "file")
show_says :: proc(sh: ^Show, _: string) -> Error {
	s := &sh.app.script
	sh.res.kind = show_kind(.List)
	sh.res.summary = fmt.tprintf("%d spoken lines", len(s.said))
	for name in script.said_names(s) {
		l, _ := script.said_line(s, name)
		said, _ := script.said(s, name)
		child(sh, fmt.tprintf("say/%s", name), .Say, fmt.tprintf("%.3fs  %d words  %s%s", l.duration, len(l.words), said.options.voice, "" if l.ready else "  (placeholder)"))
	}
	return nil
}

// `say/NAME`: a line, its words as children; `say/NAME/i`: word i (from
// 1) and where each track playing the line says it on the video.
@(private = "file")
show_say :: proc(sh: ^Show, rest: string) -> Error {
	s := &sh.app.script
	name, _, word := strings.partition(rest, "/")
	said, ok := script.said(s, name)
	l, have := script.said_line(s, name)
	if !ok || !have {
		return fail(sh.app, {code = .No_Path, name = fmt.tprintf("say/%s", name), names = {"says"}})
	}
	if word != "" {
		i, iok := strconv.parse_int(word)
		if !iok || i < 1 || i > len(l.words) {
			return fail(sh.app, {code = .No_Path, name = fmt.tprintf("say/%s/%s", name, word), names = {fmt.tprintf("say/%s/1..%d", name, len(l.words))}})
		}
		w := l.words[i - 1]
		text := speech.word_text(l, i - 1)
		sh.res.kind = show_kind(.Word)
		sh.res.summary = fmt.tprintf("%q  %.3fs..%.3fs into %s%s", text, w.start, w.stop, name, "  (estimated)" if w.estimated else "")
		sh.res.fields["text"] = json.String(text)
		sh.res.fields["start"] = json.Float(f64(w.start))
		sh.res.fields["stop"] = json.Float(f64(w.stop))
		sh.res.fields["estimated"] = json.Boolean(bool(w.estimated))
		sh.res.fields["chunk"] = json.Integer(i64(w.chunk) + 1)
		pa := om.placed_audio(&sh.r.ctx)
		placed, order := pa.tracks[:], pa.order[:]
		for k, idx in order {
			p := placed[k]
			if p.track.src == name {
				at := f64(p.start - p.file_start) / om.MIX_RATE + f64(w.start)
				child(sh, fmt.tprintf("track/%d", idx), .Track, fmt.tprintf("says it at %.3fs on the video", at))
			}
		}
		child(sh, fmt.tprintf("say/%s", name), .Say, "the line")
		return nil
	}
	sh.res.kind = show_kind(.Say)
	sh.res.summary = fmt.tprintf("%s  %.3fs  %d words in %d chunks  voice %s, seed %d%s", name, l.duration, len(l.words), len(l.chunks), said.options.voice, said.options.seed, "" if l.ready else "  (placeholder: not synthesized yet)")
	// The line's rows and what it says, how; the key as hex.
	sh.res.fields = reflect_object(l, 0)
	for k, v in reflect_object(said, 0) {
		sh.res.fields[k] = v
	}
	sh.res.fields["key"] = json.String(string(hex.encode(said.key[:], context.temp_allocator)))
	child(sh, fmt.tprintf("clip/%s", name), .Clip, "its audio and the tracks that play it")
	for w, i in l.words {
		child(sh, fmt.tprintf("say/%s/%d", name, i + 1), .Word, fmt.tprintf("%.3fs..%.3fs  %s%s", w.start, w.stop, speech.word_text(l, i), "  (estimated)" if w.estimated else ""))
	}
	return nil
}

// ---- media, fonts, physics bodies --------------------------------------------------------

// The media files besides the sounds (`clips`) and fonts (`fonts`), by
// name, and what the folder could not read. A file's fields say what it is
// (its size, length, cues), not how the engine stores its parse.
@(private = "file")
show_media :: proc(sh: ^Show, rest: string) -> Error {
	m := &sh.app.media
	if rest != "" {
		return show_media_file(sh, rest)
	}
	files := media_files(m)
	sh.res.kind = show_kind(.List)
	sh.res.summary = fmt.tprintf("%d media files besides the sounds (clips)", len(files))
	if len(m.problems) > 0 {
		sh.res.summary = fmt.tprintf("%s; %d could not be read (`inspect` lists them)", sh.res.summary, len(m.problems))
	}
	sh.res.source = m.dir
	for it in files {
		child(sh, fmt.tprintf("media/%s", it.name), .Media, media_item_summary(it))
	}
	return nil
}

// The media items `show media` lists, by name: all but sounds and fonts.
@(private = "file")
media_files :: proc(m: ^om.Media) -> []Media_Item {
	files := make([dynamic]Media_Item, context.temp_allocator)
	for it in media_items(m) {
		if it.kind != .Audio && it.kind != .Font {
			append(&files, it)
		}
	}
	slice.sort_by(files[:], proc(a, b: Media_Item) -> bool {return a.name < b.name})
	return files[:]
}

@(private = "file")
show_media_file :: proc(sh: ^Show, name: string) -> Error {
	m := &sh.app.media
	it: Media_Item
	for f in media_files(m) {
		if f.name == name {
			it = f
			break
		}
	}
	if it.name == "" {
		if name in m.audio {
			return show_clip(sh, name)
		}
		return fail(sh.app, {code = .No_Path, name = fmt.tprintf("media/%s", name), names = {"media"}})
	}
	sh.res.kind = show_kind(.Media)
	sh.res.summary = fmt.tprintf("%s  %s", name, media_item_summary(it))
	#partial switch it.kind {
	case .Image:
		img := m.images[name]
		sh.res.fields["width"] = json.Integer(img.width)
		sh.res.fields["height"] = json.Integer(img.height)
		sh.res.fields["path"] = json.String(img.path)
		sh.res.fields["decoded"] = json.Boolean(img.pixels != nil)
		sh.res.fields["failed"] = json.Boolean(img.failed)
	case .Video:
		i := m.videos.by_name[name]
		sh.res.fields = reflect_object(m.videos.infos[i], 0)
		sh.res.fields["path"] = json.String(m.videos.paths[i])
		if m.videos.handles[i] < 0 {
			sh.res.fields["failure"] = json.String(om.video_failure_message(m.videos.failures[i], context.temp_allocator))
		}
	case .Svg:
		doc := &m.svgs[name].doc
		sh.res.fields["width"] = json.Float(f64(doc.width))
		sh.res.fields["height"] = json.Float(f64(doc.height))
		sh.res.fields["elements"] = json.Integer(len(doc.nodes))
		sh.res.fields["ids"] = json.Integer(len(doc.ids))
	case .Lottie:
		doc := m.lotties[name]
		sh.res.fields["width"] = json.Float(f64(doc.width))
		sh.res.fields["height"] = json.Float(f64(doc.height))
		sh.res.fields["fps"] = json.Float(f64(doc.fps))
		sh.res.fields["in_frame"] = json.Float(f64(doc.in_frame))
		sh.res.fields["out_frame"] = json.Float(f64(doc.out_frame))
		sh.res.fields["seconds"] = json.Float(lottie_seconds(doc))
		sh.res.fields["layers"] = json.Integer(len(doc.layers))
	case .Shader:
		sh.res.fields["bytes"] = json.Integer(len(m.shaders[name]))
	case .Model:
		// The animations by name and length, and morph targets by name:
		// what `animation =` and `morphs =` pick.
		model := &m.view3d.models[name]
		clips := make(json.Array, 0, len(model.animations), context.temp_allocator)
		for a in model.animations {
			append(&clips, json.String(fmt.tprintf("%s (%.3fs)", a.name, a.duration)))
		}
		morphs := make(json.Array, 0, len(model.target_names), context.temp_allocator)
		for tname in model.target_names {
			if tname == "" {
				continue
			}
			seen := false
			for prev in morphs {
				if prev.(json.String) == json.String(tname) {
					seen = true
					break
				}
			}
			if !seen {
				append(&morphs, json.String(tname))
			}
		}
		sh.res.fields["meshes"] = json.Integer(len(model.meshes))
		sh.res.fields["nodes"] = json.Integer(len(model.nodes))
		sh.res.fields["animations"] = clips
		sh.res.fields["morphs"] = morphs
	case .Subtitles, .Captions:
		c := &m.captions[name]
		n := om.caption_count(c)
		if c.from_subtitles {
			sh.res.fields["cues"] = json.Integer(len(c.subtitles.starts))
		} else {
			sh.res.fields["segmented"] = json.Boolean(c.segmented)
		}
		sh.res.fields["words"] = json.Integer(n)
		sh.res.fields["first_seconds"] = json.Float(f64(c.starts[0]) / 1000 if n > 0 else 0)
		sh.res.fields["last_seconds"] = json.Float(f64(c.stops[n - 1]) / 1000 if n > 0 else 0)
	}
	return nil
}

// The font faces text can use, by family.
@(private = "file")
show_fonts :: proc(sh: ^Show, _: string) -> Error {
	m := &sh.app.media
	sh.res.kind = show_kind(.List)
	sh.res.summary = fmt.tprintf("%d font faces, %d of them built in (text without one of these families draws with %s)", len(m.fonts.faces), m.builtin_faces, m.fonts.fallback.family)
	for f, i in m.fonts.faces {
		child(sh, fmt.tprintf("font/%s", f.family), .Font, fmt.tprintf("weight %d%s%s", f.weight, " italic" if f.italic else "", ", built in" if om.media_face_builtin(m, i) else ""))
	}
	return nil
}

// A family's faces (`text{ font = ... }` matches the family in any case).
@(private = "file")
show_font :: proc(sh: ^Show, family: string) -> Error {
	sh.res.kind = show_kind(.Font)
	faces := make(json.Array, 0, 4, context.temp_allocator)
	for f, i in sh.app.media.fonts.faces {
		if strings.equal_fold(f.family, family) {
			face := make(json.Object, allocator = context.temp_allocator)
			face["weight"] = json.Integer(f.weight)
			face["italic"] = json.Boolean(f.italic)
			face["built_in"] = json.Boolean(om.media_face_builtin(&sh.app.media, i))
			append(&faces, face)
		}
	}
	if len(faces) == 0 {
		return fail(sh.app, {code = .No_Path, name = fmt.tprintf("font/%s", family), names = {"fonts"}})
	}
	sh.res.summary = fmt.tprintf("%s  %d faces", family, len(faces))
	sh.res.fields["family"] = json.String(family)
	sh.res.fields["faces"] = faces
	return nil
}

// The bodies physics{} simulated at load: `body/NAME` (`NAME[k]` when
// simulations share a name).
@(private = "file")
show_bodies :: proc(sh: ^Show, _: string) -> Error {
	bodies := script.physics_bodies(&sh.app.script)
	paths := body_paths(bodies)
	sh.res.kind = show_kind(.List)
	sh.res.summary = fmt.tprintf("%d physics bodies", len(bodies))
	for b, i in bodies {
		child(sh, paths[i], .Body, body_summary(b))
	}
	return nil
}

@(private = "file")
show_body :: proc(sh: ^Show, rest: string) -> Error {
	bodies := script.physics_bodies(&sh.app.script)
	paths := body_paths(bodies)
	want := fmt.tprintf("body/%s", rest)
	for b, i in bodies {
		if paths[i] == want {
			sh.res.kind = show_kind(.Body)
			sh.res.summary = body_summary(b)
			sh.res.source = b.at
			sh.res.fields = reflect_object(b, 0)
			return nil
		}
	}
	return fail(sh.app, {code = .No_Path, name = want, names = {"bodies"}})
}

@(private = "file")
body_paths :: proc(bodies: []script.Physics_Body_Info) -> []string {
	paths := make([]string, len(bodies), context.temp_allocator)
	for b, i in bodies {
		k := 0
		for o in bodies[:i] {
			k += 1 if o.label == b.label else 0
		}
		shared := k > 0
		for o in bodies[i + 1:] {
			shared ||= o.label == b.label
		}
		paths[i] = fmt.tprintf("body/%s[%d]", b.label, k) if shared else fmt.tprintf("body/%s", b.label)
	}
	return paths
}

@(private = "file")
body_summary :: proc(b: script.Physics_Body_Info) -> string {
	if b.is_3d {
		return fmt.tprintf("(%.2f, %.2f, %.2f) -> (%.2f, %.2f, %.2f) over %.2fs%s  %s", b.start.x, b.start.y, b.start.z, b.stop.x, b.stop.y, b.stop.z, b.duration, "  still moving" if b.moving else "", b.at)
	}
	return fmt.tprintf("(%.0f, %.0f) -> (%.0f, %.0f) over %.2fs%s  %s", b.start.x, b.start.y, b.stop.x, b.stop.y, b.duration, "  still moving" if b.moving else "", b.at)
}

// ---- nodes -----------------------------------------------------------------------------------

// Renders the frame at --at (default the first) noting each node's script
// line; returns the frame.
@(private = "file")
nodes_at :: proc(sh: ^Show) -> (frame: int, err: Error) {
	if sh.at != "" {
		_, frames := resolve_frames(sh.app, &sh.r.timeline, int(sh.fps), sh.at) or_return
		frame = frames[0]
	}
	s := &sh.app.script
	script.node_sources_reset(s)
	s.node_sources_on = true
	defer s.node_sources_on = false
	om.render_frame(sh.r, frame, readback = false)
	return frame, nil
}

// A node's path: its script line, with [k] when that line drew several.
@(private = "file")
node_paths :: proc(sh: ^Show) -> []string {
	nodes := sh.r.ctx.tree.nodes[:]
	paths := make([]string, len(nodes), context.temp_allocator)
	count := make(map[string]int, allocator = context.temp_allocator)
	for i in 1 ..< len(nodes) {
		count[script.node_source(&sh.app.script, i)] += 1
	}
	seen := make(map[string]int, allocator = context.temp_allocator)
	for i in 1 ..< len(nodes) {
		src := script.node_source(&sh.app.script, i)
		if src == "" {
			src = fmt.tprintf("#%d", i)
		}
		k := seen[src]
		seen[src] = k + 1
		paths[i] = fmt.tprintf("node/%s", src) if count[src] <= 1 else fmt.tprintf("node/%s[%d]", src, k)
	}
	return paths
}

@(private = "file")
node_summary :: proc(sh: ^Show, i: int) -> string {
	box := om.node_frame_box(sh.r, i32(i))
	where_ := ""
	if box.w >= 0 {
		where_ = fmt.tprintf("  at (%.0f, %.0f) %.0fx%.0f", box.x, box.y, box.w, box.h)
	}
	label := om.node_label(&sh.r.ctx.tree, i32(i))
	// Drawn by a helper: the line in the scene (or video) that asked.
	via := ""
	if v := script.node_via(&sh.app.script, i); v != "" {
		at_file, _, _ := strings.partition(script.node_source(&sh.app.script, i), ":")
		via_file, _, _ := strings.partition(v, ":")
		if !strings.has_prefix(at_file, "scenes/") && via_file != "video.lua" {
			via = fmt.tprintf("  via %s", v)
		}
	}
	return strings.concatenate({label, where_, via}, context.temp_allocator)
}

@(private = "file")
show_nodes :: proc(sh: ^Show, _: string) -> Error {
	frame := nodes_at(sh) or_return
	paths := node_paths(sh)
	nodes := sh.r.ctx.tree.nodes[:]
	sh.res.kind = show_kind(.List)
	sh.res.summary = fmt.tprintf("what is drawn at frame %d (%.3fs): the top-level nodes", frame, f64(frame) / sh.fps)
	for c := nodes[0].first_child; c != om.NO_NODE; c = nodes[c].next {
		child(sh, paths[c], .Node, node_summary(sh, int(c)))
	}
	return nil
}

// What a scene draws: the nodes made while it rendered (its own lines and
// the helpers it calls), listed from the top of that set, at --at.
@(private = "file")
show_scene_nodes :: proc(sh: ^Show, s: om.Scene_Info) -> Error {
	frame := nodes_at(sh) or_return
	paths := node_paths(sh)
	nodes := sh.r.ctx.tree.nodes[:]
	parent := make([]i32, len(nodes), context.temp_allocator)
	for &p in parent {
		p = om.NO_NODE
	}
	for n, k in nodes {
		for c := n.first_child; c != om.NO_NODE; c = nodes[c].next {
			parent[c] = i32(k)
		}
	}
	own := make([]bool, len(nodes), context.temp_allocator)
	for i in 1 ..< len(nodes) {
		own[i] = script.node_scene(&sh.app.script, i) == s.scene.name
	}
	sh.res.kind = show_kind(.List)
	sh.res.summary = fmt.tprintf("what scene %s draws at frame %d (%.3fs)", s.scene.name, frame, f64(frame) / sh.fps)
	for i in 1 ..< len(nodes) {
		if own[i] && !(parent[i] > 0 && own[parent[i]]) {
			child(sh, paths[i], .Node, node_summary(sh, i))
		}
	}
	return nil
}

@(private = "file")
show_node :: proc(sh: ^Show, rest: string) -> Error {
	frame := nodes_at(sh) or_return
	paths := node_paths(sh)
	want := fmt.tprintf("node/%s", rest)
	idx := -1
	for p, i in paths {
		if p == want || (i > 0 && p == fmt.tprintf("%s[0]", want)) {
			idx = i
			break
		}
	}
	if idx < 0 {
		near := make([dynamic]string, context.temp_allocator)
		file, _, _ := strings.partition(rest, ":")
		for p in paths {
			if p != "" && strings.has_prefix(p, fmt.tprintf("node/%s", file)) && len(near) < 12 {
				append(&near, p)
			}
		}
		if len(near) == 0 {
			append(&near, fmt.tprintf("nodes --at %d (what is drawn there)", frame))
		}
		return fail(sh.app, {code = .No_Path, name = want, names = near[:]})
	}
	n := sh.r.ctx.tree.nodes[idx]
	sh.res.path = paths[idx]
	sh.res.kind = show_kind(.Node)
	sh.res.summary = fmt.tprintf("%s  (frame %d, %.3fs)", node_summary(sh, idx), frame, f64(frame) / sh.fps)
	sh.res.source = script.node_source(&sh.app.script, idx)
	sh.res.fields = reflect_object(reflect.get_union_variant(n.kind), 0)
	if via := script.node_via(&sh.app.script, idx); via != "" {
		sh.res.fields["via"] = json.String(via)
	}
	if scene := script.node_scene(&sh.app.script, idx); scene != "" {
		sh.res.fields["scene"] = json.String(scene)
	}
	box := om.node_frame_box(sh.r, i32(idx))
	if box.w >= 0 {
		fb := make(json.Array, 4, context.temp_allocator)
		fb[0], fb[1], fb[2], fb[3] = json.Float(box.x), json.Float(box.y), json.Float(box.w), json.Float(box.h)
		sh.res.fields["frame_box"] = fb
	}
	for c := n.first_child; c != om.NO_NODE; c = sh.r.ctx.tree.nodes[c].next {
		child(sh, paths[c], .Node, node_summary(sh, int(c)))
	}
	return nil
}

// ---- fields by reflection ---------------------------------------------------------------------

// The fields of a struct value as JSON: numbers, text, flags, enum names,
// optional values (null when unset), small arrays, nested structs (two
// levels), the fields of embedded (`using`) structs as its own; lists as
// their length. Pointers, procedures and maps are left out, as are the
// fields only the engine uses.
reflect_object :: proc(v: any, depth: int) -> json.Object {
	obj := make(json.Object, allocator = context.temp_allocator)
	if v.data == nil || !reflect.is_struct(type_info_of(v.id)) {
		return obj
	}
	for f in reflect.struct_fields_zipped(v.id) {
		switch f.name {
		case "user", "render", "start_terms", "stop_terms", "samples":
			continue
		}
		fv := reflect.struct_field_value(v, f)
		if f.is_using {
			// Its fields read as the struct's own (a shape's style).
			for name, jv in reflect_object(fv, depth) {
				obj[name] = jv
			}
		} else if jv, ok := reflect_value(fv, depth); ok {
			obj[f.name] = jv
		}
	}
	return obj
}

@(private = "file")
reflect_value :: proc(v: any, depth: int) -> (json.Value, bool) {
	if v.data == nil {
		return nil, true
	}
	if v.id == om.Color {
		c := (^om.Color)(v.data)^
		to8 :: proc(x: f32) -> int {return int(math.round(f64(clamp(x, 0, 1)) * 255))}
		if c.a >= 1 {
			return json.String(fmt.tprintf("#%02x%02x%02x", to8(c.r), to8(c.g), to8(c.b))), true
		}
		return json.String(fmt.tprintf("#%02x%02x%02x%02x", to8(c.r), to8(c.g), to8(c.b), to8(c.a))), true
	}
	ti := runtime.type_info_base(type_info_of(v.id))
	#partial switch info in ti.variant {
	case runtime.Type_Info_Integer:
		x, _ := reflect.as_i64(v)
		return json.Integer(x), true
	case runtime.Type_Info_Float:
		x, _ := reflect.as_f64(v)
		return json.Float(x), true
	case runtime.Type_Info_Boolean:
		x, _ := reflect.as_bool(v)
		return json.Boolean(x), true
	case runtime.Type_Info_String:
		x, _ := reflect.as_string(v)
		return json.String(x), true
	case runtime.Type_Info_Enum:
		return json.String(fmt.tprint(v)), true
	case runtime.Type_Info_Union:
		inner := reflect.get_union_variant(v)
		if inner.data == nil {
			return nil, true
		}
		return reflect_value(inner, depth)
	case runtime.Type_Info_Struct:
		if depth >= 2 {
			return nil, false
		}
		return reflect_object(v, depth + 1), true
	case runtime.Type_Info_Array:
		if info.count > 16 {
			return nil, false
		}
		arr := make(json.Array, 0, info.count, context.temp_allocator)
		for k in 0 ..< info.count {
			x, ok := reflect_value(reflect.index(v, k), depth + 1)
			if !ok {
				return nil, false
			}
			append(&arr, x)
		}
		return arr, true
	case runtime.Type_Info_Slice, runtime.Type_Info_Dynamic_Array:
		return json.Integer(reflect.length(v)), true
	}
	return nil, false
}

// Whether a field says nothing worth a text line (zero, empty, unset).
@(private = "file")
show_empty :: proc(v: json.Value) -> bool {
	if v == nil {
		return true
	}
	switch x in v {
	case json.Null:
		return true
	case json.Integer:
		return x == 0
	case json.Float:
		return x == 0
	case json.Boolean:
		return !x
	case json.String:
		return x == ""
	case json.Array:
		return len(x) == 0
	case json.Object:
		for _, e in x {
			if !show_empty(e) {
				return false
			}
		}
		return true
	}
	return false
}

@(private = "file")
show_value_text :: proc(v: json.Value) -> string {
	#partial switch x in v {
	case json.Float:
		return fmt.tprintf("%.4g", x)
	case json.String:
		return fmt.tprintf("%q", x)
	case json.Object:
		b := strings.builder_make(context.temp_allocator)
		keys, _ := slice.map_keys(x, context.temp_allocator)
		slice.sort(keys)
		strings.write_byte(&b, '{')
		first := true
		for k in keys {
			if show_empty(x[k]) {
				continue
			}
			fmt.sbprintf(&b, "%s%s = %s", "" if first else ", ", k, show_value_text(x[k]))
			first = false
		}
		strings.write_byte(&b, '}')
		return strings.to_string(b)
	case json.Array:
		parts := make([dynamic]string, context.temp_allocator)
		for e in x {
			append(&parts, show_value_text(e))
		}
		return fmt.tprintf("[%s]", strings.join(parts[:], ", ", context.temp_allocator))
	}
	return fmt.tprint(v)
}
