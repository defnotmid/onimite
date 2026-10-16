package onimite_script

import "core:c"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import om "../onimite"
import lua "vendor:lua/5.4"

// Media functions: synced video frames, subtitles, audio spectra, and the
// time terms durations and audio timestamps are written with.

// audio_add(name, sound): sound the script made becomes media clip `name`,
// used by tracks, `{ audio = name }` durations, audio_spectrum and
// audio_onsets like a file in media/. `sound` is
//   - an audio_buffer (audio_buffer.odin),
//   - samples: `{ left, right, rate = 48000 }`, lists of numbers -1..1
//     (`right` omitted: mono),
//   - file bytes (e.g. a WAV packed with string.pack), decoded by the
//     name's extension,
//   - or a function returning one of these. It runs only when the clip is
//     needed (rendering with sound, the audio commands, `timeline`, the
//     preview, or a script reading the clip) and once per render: frames,
//     strips and inspections of a video don't pay for its music.
// Works at load only; raises a Lua error when bytes can't be decoded.
@(private)
l_audio_add :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	name := string(lua.L_checkstring(L, 1))
	m := s.media
	if m == nil {
		lua.L_error(L, "audio_add() needs the media: the script was loaded without it")
	}
	lua.settop(L, 2)
	if lua.isfunction(L, 2) {
		for &p in s.pending_audio {
			if p.name == name {
				lua.L_unref(L, lua.REGISTRYINDEX, p.ref)
				p.ref = lua.L_ref(L, lua.REGISTRYINDEX)
				return 0
			}
		}
		append(&s.pending_audio, Pending_Audio{strings.clone(name), lua.L_ref(L, lua.REGISTRYINDEX)})
		return 0
	}
	add_sound(L, s, m, name, 2)
	return 0
}

// Makes clip `name` from the sound at `idx` (a buffer, samples or bytes);
// a Lua error when it is none of them or can't be decoded.
@(private)
add_sound :: proc(L: ^lua.State, s: ^Script, m: ^om.Media, name: string, at: c.int) {
	idx := lua.absindex(L, at)
	if b := test_buffer(L, idx); b != nil {
		om.media_add_audio_samples(m, name, buffer_samples(b), om.MIX_RATE, 2)
		return
	}
	#partial switch lua.type(L, idx) {
	case .STRING:
		size: c.size_t
		bytes := lua.tolstring(L, idx, &size)
		if !om.media_add_audio_bytes(m, name, (cast([^]u8)bytes)[:size]) {
			lua.L_error(L, "audio_add(%s): can not decode the audio", strings.clone_to_cstring(name, context.temp_allocator))
		}
	case .TABLE:
		add_audio_samples(L, s, m, name, idx)
	case:
		lua.L_error(L, "audio_add(%s): give an audio_buffer, samples { left, right, rate }, file bytes or a function returning one", strings.clone_to_cstring(name, context.temp_allocator))
	}
}

// `{ left, right, rate }` at index `t` as clip `name`.
@(private = "file")
add_audio_samples :: proc(L: ^lua.State, s: ^Script, m: ^om.Media, name: string, t: c.int) {
	outer := fields_push(L, t)
	rate := int(get_num(L, t, "rate", om.MIX_RATE))
	fields_pop(L, s, t, "audio_add", outer)
	lua.rawgeti(L, t, 1)
	lua.rawgeti(L, t, 2)
	if !lua.istable(L, -2) {
		lua.L_error(L, "audio_add(%s): samples are { left, right, rate }: lists of numbers", strings.clone_to_cstring(name, context.temp_allocator))
	}
	stereo := lua.istable(L, -1)
	n := int(lua.rawlen(L, -2))
	if stereo {
		n = max(n, int(lua.rawlen(L, -1)))
	}
	channels := 2 if stereo else 1
	samples := make([]f32, n * channels)
	defer delete(samples)
	for ch in 0 ..< channels {
		list := lua.absindex(L, -2 + c.int(ch))
		for i in 0 ..< n {
			lua.rawgeti(L, list, lua.Integer(i + 1))
			samples[i * channels + ch] = f32(lua.tonumber(L, -1))
			lua.pop(L, 1)
		}
	}
	lua.pop(L, 2)
	om.media_add_audio_samples(m, name, samples, max(rate, 1), channels)
}

// Runs the build function of clip `name` and adds the clip: once per
// render, the frame builders of a render share it.
// Inside a binding the Lua error propagates; `protected` catches it and
// returns it as an `.Audio_Build` failure instead (strings in temp memory).
@(private)
build_pending :: proc(L: ^lua.State, s: ^Script, name: string, protected := false) -> (failure: Failure) {
	m := s.ctx.media if s.ctx != nil else s.media
	if m == nil {
		return
	}
	for i := 0; i < len(s.pending_audio); {
		p := s.pending_audio[i]
		if p.name != name {
			i += 1
			continue
		}
		ordered_remove(&s.pending_audio, i)
		defer delete(p.name)
		sh := s.shared
		sync.lock(&sh.lock)
		done := p.name in sh.audio
		sync.unlock(&sh.lock)
		if done {
			lua.L_unref(L, lua.REGISTRYINDEX, p.ref)
			continue
		}
		top := lua.gettop(L)
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(p.ref))
		lua.L_unref(L, lua.REGISTRYINDEX, p.ref)
		if protected {
			lua.pushcfunction(L, message_handler)
			lua.insert(L, -2)
			if lua.pcall(L, 0, 1, -2) != 0 {
				failure = build_failure(L, p.name)
				lua.settop(L, top)
				return
			}
			lua.pushcfunction(L, protected_add)
			lua.pushstring(L, strings.clone_to_cstring(p.name, context.temp_allocator))
			lua.pushvalue(L, -3)
			lua.pushcfunction(L, message_handler)
			lua.insert(L, -4)
			if lua.pcall(L, 2, 0, -4) != 0 {
				failure = build_failure(L, p.name)
				lua.settop(L, top)
				return
			}
		} else {
			lua.call(L, 0, 1)
			add_sound(L, s, m, p.name, -1)
		}
		lua.settop(L, top)
		sync.lock(&sh.lock)
		if p.name not_in sh.audio {
			sh.audio[strings.clone(p.name)] = true
		}
		sync.unlock(&sh.lock)
	}
	return
}

// The failure of clip `name`'s build: the Lua error on top of the stack.
@(private = "file")
build_failure :: proc(L: ^lua.State, name: string) -> Failure {
	return {code = .Audio_Build, path = strings.clone(name, context.temp_allocator), lua = strings.clone(string(lua.tostring(L, -1)), context.temp_allocator)}
}

// add_sound as a Lua function (name, sound), for the protected call.
@(private = "file")
protected_add :: proc "c" (L: ^lua.State) -> c.int {
	s := host_of_state(L)
	context = s.odin_context
	m := s.ctx.media if s.ctx != nil else s.media
	add_sound(L, s, m, string(lua.tostring(L, 1)), 2)
	return 0
}

// Whether clip `name` is one audio_add deferred and nobody built yet.
@(private = "file")
audio_deferred :: proc(s: ^Script, name: string) -> bool {
	for p in s.pending_audio {
		if p.name == name {
			sh := s.shared
			sync.lock(&sh.lock)
			defer sync.unlock(&sh.lock)
			return name not_in sh.audio
		}
	}
	return false
}

// Whether audio_add deferred clips that are not built yet.
audio_pending :: proc(s: ^Script) -> bool {
	return len(s.pending_audio) > 0
}

// The names of the clips audio_add deferred and nobody built yet (in
// `allocator`, borrowed strings).
audio_pending_names :: proc(s: ^Script, allocator := context.temp_allocator) -> []string {
	names := make([dynamic]string, 0, len(s.pending_audio), allocator)
	for p in s.pending_audio {
		append(&names, p.name)
	}
	return names[:]
}

// Builds deferred clip `name` and takes it out of the script's media: the
// caller owns it (another state's media adds it). `failure` is a failing
// build (`.Audio_Build`, strings in temp memory); `ok` is false when there
// is no such clip.
audio_build_clip :: proc(s: ^Script, name: string) -> (clip: om.Audio_Clip, ok: bool, failure: Failure) {
	if s.L == nil || s.media == nil {
		return
	}
	context = s.odin_context
	if failure = build_pending(s.L, s, name, protected = true); failure.code != .None {
		return
	}
	clip, ok = om.media_take_audio(s.media, name)
	return
}

// Marks clip `name` as built elsewhere (its samples were added to this
// script's media): asking for it no longer runs its function.
audio_mark_built :: proc(s: ^Script, name: string) {
	sh := s.shared
	sync.lock(&sh.lock)
	defer sync.unlock(&sh.lock)
	if name not_in sh.audio {
		sh.audio[strings.clone(name)] = true
	}
}

// The frame table's clock: (scene-relative index, fps, seconds).
@(private = "file")
frame_clock :: proc(L: ^lua.State, idx: c.int) -> (index: int, fps: int, seconds: f32) {
	if lua.isnumber(L, idx) {
		// A plain time in seconds at the video's rate.
		s := host(L)
		seconds = f32(lua.tonumber(L, idx))
		fps = max(s.video.fps, 1)
		return om.frame_at(f64(seconds), fps), fps, seconds
	}
	lua.L_checktype(L, idx, i32(lua.Type.TABLE))
	index = int(get_num(L, idx, "index", 0))
	fps = max(int(get_num(L, idx, "fps", 30)), 1)
	return index, fps, f32(index) / f32(fps)
}

// video_frame(f, { src, x, y, w, h, start_from, clip_start, looping, fit, align, opacity })
@(private)
l_video_frame :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	ctx := render_ctx(L, s)
	index, fps, _ := frame_clock(L, 1)
	lua.L_checktype(L, 2, i32(lua.Type.TABLE))
	fields_begin(L, 2)
	field(L, 2, "looping")
	looping := bool(lua.toboolean(L, -1))
	lua.pop(L, 1)
	om.video_clip(
		ctx,
		om.Frame{index = index, global_index = ctx.frame.global_index, fps = fps},
		{
			src = get_str(L, 2, "src", ""),
			x = get_num(L, 2, "x", 0),
			y = get_num(L, 2, "y", 0),
			w = get_num(L, 2, "w", get_num(L, 2, "width", 0)),
			h = get_num(L, 2, "h", get_num(L, 2, "height", 0)),
			start_from = get_num(L, 2, "start_from", 0),
			clip_start = get_num(L, 2, "clip_start", 0),
			looping = looping,
			fit = read_fit(L, 2),
			align = read_align(L, 2),
			opacity = get_maybe(L, 2, "opacity"),
		},
	)
	fields_end(L, s, 2, "video_frame")
	return 0
}

// video_info("clip.mp4") -> { width, height, duration, fps, frames } or nil
@(private)
l_video_info :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	ctx := render_ctx(L, s)
	info, ok := om.media_video_info(ctx.media, string(lua.L_checkstring(L, 1)))
	if !ok {
		lua.pushnil(L)
		return 1
	}
	lua.createtable(L, 0, 5)
	set_int(L, "width", info.width)
	set_int(L, "height", info.height)
	set_num(L, "duration", f32(info.duration))
	set_num(L, "fps", f32(info.fps))
	set_int(L, "frames", info.frames)
	return 1
}

@(private = "file")
find_subtitles :: proc(L: ^lua.State, ctx: ^om.Context, name: string) -> ^om.Subtitles {
	caps, ok := &ctx.media.captions[name]
	if !ok || !caps.from_subtitles {
		om.report(ctx, .Error, {code = .Missing_Subtitles, name = name})
		return nil
	}
	return &caps.subtitles
}

@(private = "file")
push_cue :: proc(L: ^lua.State, subs: ^om.Subtitles, i: int, ms: u32) {
	lua.createtable(L, 0, 7)
	text := subs.texts[i]
	lua.pushlstring(L, cstring(raw_data(text)), c.size_t(len(text)))
	lua.setfield(L, -2, "text")
	start, stop := subs.starts[i], subs.stops[i]
	set_num(L, "start", f32(start) / 1000)
	set_num(L, "stop", f32(stop) / 1000)
	span := max(stop - start, 1)
	set_num(L, "progress", clamp(f32(ms - min(ms, start)) / f32(span), 0, 1))
	set_int(L, "index", i + 1)
	id := subs.ids[i]
	lua.pushlstring(L, cstring(raw_data(id)), c.size_t(len(id)))
	lua.setfield(L, -2, "id")
	settings := subs.settings[i]
	lua.pushlstring(L, cstring(raw_data(settings)), c.size_t(len(settings)))
	lua.setfield(L, -2, "settings")
}

// subtitle_at(f, "subs.vtt") -> { text, start, stop, progress, index, id, settings } or nil
@(private)
l_subtitle_at :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	ctx := render_ctx(L, s)
	_, _, seconds := frame_clock(L, 1)
	subs := find_subtitles(L, ctx, string(lua.L_checkstring(L, 2)))
	if subs == nil {
		lua.pushnil(L)
		return 1
	}
	ms := u32(max(seconds, 0) * 1000)
	i := om.subtitle_cue_at(subs, ms)
	if i < 0 {
		lua.pushnil(L)
		return 1
	}
	push_cue(L, subs, i, ms)
	return 1
}

// subtitles("subs.vtt") -> every cue, in file order
@(private)
l_subtitles :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	ctx := render_ctx(L, s)
	subs := find_subtitles(L, ctx, string(lua.L_checkstring(L, 1)))
	if subs == nil {
		lua.pushnil(L)
		return 1
	}
	lua.createtable(L, c.int(len(subs.starts)), 0)
	for i in 0 ..< len(subs.starts) {
		push_cue(L, subs, i, subs.starts[i])
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	return 1
}

// ---- word-level captions ----------------------------------------------------------------

// Captions `name` from the media (subtitle files, caption .json files,
// `captions_load`). Missing: an Error diagnostic while rendering (nil), a
// Lua error at load.
@(private = "file")
find_captions :: proc(L: ^lua.State, s: ^Script, cname, fn: cstring) -> ^om.Captions {
	m := measure_media(L, s, fn)
	name := string(cname)
	if cap, ok := &m.captions[name]; ok {
		return cap
	}
	if s.ctx == nil {
		load_error(L, fn, {code = .Missing_Captions, name = name})
	}
	om.report(s.ctx, .Error, {code = .Missing_Captions, name = name})
	return nil
}

// The paging options of table `t` (absent: the defaults): max_words,
// max_duration (s), combine_ms; hold (s); and start, the time on the
// caller's clock where the captions' 0 sits.
@(private = "file")
read_page_options :: proc(L: ^lua.State, t: c.int) -> (opts: om.Caption_Page_Options, hold: u32, start: f32) {
	if !lua.istable(L, t) {
		return
	}
	start = get_num(L, t, "start", 0)
	opts.max_words = int(get_num(L, t, "max_words", 0))
	opts.max_duration = u32(max(get_num(L, t, "max_duration", 0), 0) * 1000)
	opts.combine_ms = u32(max(get_num(L, t, "combine_ms", 0), 0))
	hold = u32(max(get_num(L, t, "hold", 0), 0) * 1000)
	return
}

@(private = "file")
caption_pages_of :: proc(L: ^lua.State, cap: ^om.Captions, t: c.int) -> (firsts: []u32, hold: u32, start: f32) {
	opts: om.Caption_Page_Options
	opts, hold, start = read_page_options(L, t)
	list := make([dynamic]u32, context.temp_allocator)
	om.caption_pages(cap, opts, &list)
	return list[:], hold, start
}

@(private = "file")
push_word_text :: proc(L: ^lua.State, cap: ^om.Captions, i: int) {
	w := om.caption_word(cap, i)
	lua.pushlstring(L, cstring(raw_data(w)), c.size_t(len(w)))
	lua.setfield(L, -2, "text")
}

// caption_words(f, "talk.json", { max_words, max_duration, combine_ms, hold, start })
// -> the words of the page showing at f's time, each { text, start, stop,
// active, progress }, the list also holding page = index, start, stop and
// time (the clock read, seconds); or nil between pages. With `start` the
// captions begin at that time of the clock, and every time returned is on
// the clock. `active` is the word being said (or the last one,
// through a pause), `progress` 0..1 through each word. f may be a time in
// seconds, or nil for the render call's clock.
@(private)
l_caption_words :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	render_ctx(L, s)
	seconds := f32(s.frame.index) / f32(max(s.frame.fps, 1))
	if !lua.isnoneornil(L, 1) {
		_, _, seconds = frame_clock(L, 1)
	}
	cap := find_captions(L, s, lua.L_checkstring(L, 2), "caption_words")
	if cap == nil {
		lua.pushnil(L)
		return 1
	}
	firsts, hold, at := caption_pages_of(L, cap, 3)
	ms := u32(max(seconds - at, 0) * 1000)
	if seconds < at {
		lua.pushnil(L)
		return 1
	}
	k := om.caption_page_at(cap, firsts, ms, hold)
	if k < 0 {
		lua.pushnil(L)
		return 1
	}
	first, last := om.caption_page_words(cap, firsts, k)
	active := om.caption_active_word(cap, first, last, ms)
	lua.createtable(L, c.int(last - first), 4)
	for i in first ..< last {
		lua.createtable(L, 0, 5)
		push_word_text(L, cap, i)
		start, stop := cap.starts[i], cap.stops[i]
		set_num(L, "start", at + f32(start) / 1000)
		set_num(L, "stop", at + f32(stop) / 1000)
		lua.pushboolean(L, b32(i == active))
		lua.setfield(L, -2, "active")
		set_num(L, "progress", clamp(f32(ms - min(ms, start)) / f32(max(stop - start, 1)), 0, 1))
		lua.rawseti(L, -2, lua.Integer(i - first + 1))
	}
	set_num(L, "time", seconds)
	set_int(L, "page", k + 1)
	set_num(L, "start", at + f32(cap.starts[first]) / 1000)
	set_num(L, "stop", at + f32(cap.stops[last - 1]) / 1000)
	return 1
}

// caption_pages("talk.json", { max_words, max_duration, combine_ms, start }) ->
// { { index, start, stop, text, words = { { text, start, stop }, ... } }, ... }
// (works at load).
@(private)
l_caption_pages :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	cap := find_captions(L, s, lua.L_checkstring(L, 1), "caption_pages")
	if cap == nil {
		lua.pushnil(L)
		return 1
	}
	firsts, _, at := caption_pages_of(L, cap, 2)
	lua.createtable(L, c.int(len(firsts)), 0)
	for k in 0 ..< len(firsts) {
		first, last := om.caption_page_words(cap, firsts, k)
		lua.createtable(L, 0, 5)
		set_int(L, "index", k + 1)
		set_num(L, "start", at + f32(cap.starts[first]) / 1000)
		set_num(L, "stop", at + f32(cap.stops[last - 1]) / 1000)
		b := strings.builder_make(context.temp_allocator)
		lua.createtable(L, c.int(last - first), 0)
		for i in first ..< last {
			if i > first {
				strings.write_byte(&b, ' ')
			}
			strings.write_string(&b, om.caption_word(cap, i))
			lua.createtable(L, 0, 3)
			push_word_text(L, cap, i)
			set_num(L, "start", at + f32(cap.starts[i]) / 1000)
			set_num(L, "stop", at + f32(cap.stops[i]) / 1000)
			lua.rawseti(L, -2, lua.Integer(i - first + 1))
		}
		lua.setfield(L, -2, "words")
		text := strings.to_string(b)
		lua.pushlstring(L, cstring(raw_data(text)), c.size_t(len(text)))
		lua.setfield(L, -2, "text")
		lua.rawseti(L, -2, lua.Integer(k + 1))
	}
	return 1
}

// captions_load(name [, source]) -> word count. `source`: caption text
// (WebVTT, SRT or JSON, by shape), or a list of words { { text, start,
// stop }, ... } in seconds; without it, the file `name` beside the script
// (or absolute), else in the media directory. The words become captions
// `name` for caption_words / caption_pages / captions{}. Works at load only;
// raises a Lua error when the source doesn't parse.
@(private)
l_captions_load :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	m := measure_media(L, s, "captions_load")
	cname := lua.L_checkstring(L, 1)
	name := string(cname)
	caps: om.Captions
	ok: bool
	switch {
	case lua.istable(L, 2):
		n := int(lua.rawlen(L, 2))
		texts := make([]string, n, context.temp_allocator)
		starts := make([]f32, n, context.temp_allocator)
		stops := make([]f32, n, context.temp_allocator)
		for i in 0 ..< n {
			lua.rawgeti(L, 2, lua.Integer(i + 1))
			if !lua.istable(L, -1) {
				lua.L_error(L, "captions_load(%s): word %d is not a table { text, start, stop }", cname, c.int(i + 1))
			}
			captions_fields := fields_push(L, -1)
			texts[i] = strings.clone(get_str(L, -1, "text", ""), context.temp_allocator)
			starts[i] = get_num(L, -1, "start", 0)
			stops[i] = get_num(L, -1, "stop", get_num(L, -1, "end", starts[i]))
			fields_pop(L, s, -1, "captions_load word", captions_fields)
			lua.pop(L, 1)
		}
		caps, ok = om.captions_from_words(texts, starts, stops), true
	case lua.type(L, 2) == .STRING:
		size: c.size_t
		text := lua.tolstring(L, 2, &size)
		caps, ok = om.captions_parse(string(text)[:size])
	case:
		path := name
		if !filepath.is_abs(name) {
			path, _ = filepath.join({filepath.dir(s.path), name}, context.temp_allocator)
		}
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil && m.dir != "" {
			path, _ = filepath.join({m.dir, name}, context.temp_allocator)
			data, err = os.read_entire_file(path, context.temp_allocator)
		}
		if err != nil {
			lua.L_error(L, "captions_load(%s): can not read the file", cname)
		}
		caps, ok = om.captions_parse(string(data))
	}
	if !ok {
		lua.L_error(L, "captions_load(%s): not WebVTT, SRT or caption JSON", cname)
	}
	n := om.caption_count(&caps)
	om.media_add_captions(m, name, caps)
	lua.pushinteger(L, lua.Integer(n))
	return 1
}

// audio_spectrum(f, { src, sample_size = 256, smooth = 0, window = "hann", bands })
// -> sample_size / 2 magnitudes (or `bands` averaged groups of them)
@(private)
l_audio_spectrum :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	ctx := render_ctx(L, s)
	index, fps, _ := frame_clock(L, 1)
	lua.L_checktype(L, 2, i32(lua.Type.TABLE))
	fields_begin(L, 2)
	src := get_str(L, 2, "src", "")
	later := s.audio_later && audio_deferred(s, src)
	if !later {
		build_pending(L, s, src)
	}
	silence: om.Audio_Clip
	clip, ok := &ctx.media.audio[src]
	if !ok && later {
		// Not built yet: the spectrum of silence until it lands.
		ctx.audio_pending += 1
		clip, ok = &silence, true
	}
	if !ok {
		om.report(ctx, .Error, {code = .Missing_Audio, name = src})
		lua.pushnil(L)
		return 1
	}
	n := int(get_num(L, 2, "sample_size", 256))
	if n < 2 || n > om.SPECTRUM_MAX || n & (n - 1) != 0 {
		lua.L_error(L, "audio_spectrum: sample_size must be a power of two from 2 to 2048")
	}
	window := om.Spectrum_Window.None
	switch get_str(L, 2, "window", "") {
	case "hann":
		window = .Hann
	case "hamming":
		window = .Hamming
	}
	out := make([]f32, n / 2, context.temp_allocator)
	params := om.Spectrum_Params {
		sample_size = n,
		smooth      = int(get_num(L, 2, "smooth", 0)),
		window      = window,
	}
	if lua.istable(L, 1) {
		// A frame: what the track plays at this frame, where it sits on the
		// video (silence while it doesn't play). A clip no track plays reads
		// the frame's clock as before.
		if at, placed := placed_clip_time(ctx, src); placed {
			if t, playing := at.?; playing {
				fps = ctx.video.fps
				index = int(math.round(t * f64(fps)))
				om.audio_spectrum(clip, index, fps, params, out)
			}
		} else {
			om.audio_spectrum(clip, index, fps, params, out)
		}
	} else {
		om.audio_spectrum(clip, index, fps, params, out)
	}
	result := out
	field(L, 2, "log")
	log_bands := bool(lua.toboolean(L, -1))
	lua.pop(L, 1)
	if bands := int(get_num(L, 2, "bands", 0)); bands > 0 && bands < len(out) {
		result = make([]f32, bands, context.temp_allocator)
		for &b, k in result {
			lo := k * len(out) / bands
			hi := max((k + 1) * len(out) / bands, lo + 1)
			if log_bands {
				// Bands an equal pitch step wide, from bin 1 to 12 kHz (half
				// the bins; above is mostly air).
				edge :: proc(i, bands, top: int) -> int {
					return int(math.round(math.pow(f64(top), f64(i) / f64(bands))))
				}
				top := max(len(out) / 2, 2)
				lo = min(edge(k, bands, top), len(out) - 1)
				hi = clamp(edge(k + 1, bands, top), lo + 1, len(out))
			}
			sum: f32
			for v in out[lo:hi] {
				sum += v
			}
			b = sum / f32(hi - lo)
		}
	}
	// `levels = { lo_db, hi_db }`: magnitudes as decibels mapped to 0..1.
	field(L, 2, "levels")
	if lua.istable(L, -1) {
		lua.rawgeti(L, -1, 1)
		lua.rawgeti(L, -2, 2)
		lo_db, hi_db := f32(lua.tonumber(L, -2)), f32(lua.tonumber(L, -1))
		lua.pop(L, 2)
		if hi_db > lo_db {
			if raw_data(result) == raw_data(out) {
				result = slice.clone(out, context.temp_allocator)
			}
			for &v in result {
				db := 20 * math.log10(v + 1e-3)
				v = clamp((db - lo_db) / (hi_db - lo_db), 0, 1)
			}
		}
	}
	lua.pop(L, 1)
	fields_end(L, s, 2, "audio_spectrum")
	push_numbers(L, result)
	return 1
}

// Where in clip `src` the tracks playing it are at the frame being rendered
// (seconds into the file; nil while none plays); placed is false when no
// track plays the clip at all.
@(private = "file")
placed_clip_time :: proc(ctx: ^om.Context, src: string) -> (at: Maybe(f64), placed: bool) {
	sample := om.frames_to_samples(ctx.frame.global_index, ctx.video.fps)
	for p in om.placed_audio(ctx).tracks {
		if p.track.src != src {
			continue
		}
		placed = true
		if sample >= p.start && sample < p.end {
			return f64(p.file_start + sample - p.start) / om.MIX_RATE, true
		}
	}
	return nil, placed
}

// audio_energy(f, { src, bus, smooth = 0 }) -> { rms, peak, low, mid, high }:
// how loud the sound is at frame `f`, each 0..1: clip `src` where its
// tracks play it (as audio_spectrum reads it), else the tracks playing then
// (on bus `bus`, or all), summed by their gains. `low`, `mid` and `high` are
// the energy below 375 Hz, to 2.8 kHz and above; `smooth` averages that many
// frames on each side.
@(private)
l_audio_energy :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	ctx := render_ctx(L, s)
	index, fps, _ := frame_clock(L, 1)
	src, bus: string
	smooth := 0
	if lua.istable(L, 2) {
		fields_begin(L, 2)
		src = get_str(L, 2, "src", "")
		bus = get_str(L, 2, "bus", "")
		smooth = max(int(get_num(L, 2, "smooth", 0)), 0)
		fields_end(L, s, 2, "audio_energy")
	}
	// A clip not built yet (audio_add) reads as silence until it lands.
	ready :: proc(L: ^lua.State, s: ^Script, ctx: ^om.Context, src: string) -> bool {
		if s.audio_later && audio_deferred(s, src) {
			if src not_in ctx.media.audio {
				ctx.audio_pending += 1
				return false
			}
			return true
		}
		build_pending(L, s, src)
		return true
	}
	energy: om.Audio_Energy
	if src != "" {
		if !ready(L, s, ctx, src) {
			push_energy(L, energy)
			return 1
		}
		clip, ok := &ctx.media.audio[src]
		if !ok {
			om.report(ctx, .Error, {code = .Missing_Audio, name = src})
			lua.pushnil(L)
			return 1
		}
		if at, placed := placed_clip_time(ctx, src); placed && lua.istable(L, 1) {
			if t, playing := at.?; playing {
				v_fps := max(ctx.video.fps, 1)
				energy = om.audio_energy(clip, int(math.round(t * f64(v_fps))), v_fps, smooth)
			}
		} else {
			energy = om.audio_energy(clip, index, fps, smooth)
		}
		push_energy(L, energy)
		return 1
	}
	// The tracks' clips first: a track is placed once its clip exists.
	for tr in ctx.video.audio {
		if bus == "" || tr.bus == bus {
			ready(L, s, ctx, tr.src)
		}
	}
	sample := om.frames_to_samples(ctx.frame.global_index, ctx.video.fps)
	v_fps := max(ctx.video.fps, 1)
	for p in om.placed_audio(ctx).tracks {
		if (bus != "" && p.track.bus != bus) || sample < p.start || sample >= p.end {
			continue
		}
		clip := &ctx.media.audio[p.track.src]
		t := f64(p.file_start + sample - p.start) / om.MIX_RATE
		te := om.audio_energy(clip, int(math.round(t * f64(v_fps))), v_fps, smooth)
		gain := math.pow_f32(10, p.track.gain_db / 20)
		energy.rms = min(energy.rms + te.rms * gain, 1)
		energy.peak = min(max(energy.peak, te.peak * gain), 1)
		energy.low = min(energy.low + te.low * gain, 1)
		energy.mid = min(energy.mid + te.mid * gain, 1)
		energy.high = min(energy.high + te.high * gain, 1)
	}
	push_energy(L, energy)
	return 1
}

@(private = "file")
push_energy :: proc(L: ^lua.State, e: om.Audio_Energy) {
	lua.createtable(L, 0, 5)
	set_num(L, "rms", e.rms)
	set_num(L, "peak", e.peak)
	set_num(L, "low", e.low)
	set_num(L, "mid", e.mid)
	set_num(L, "high", e.high)
}

// spectrum_centered(list): low frequencies in the middle (fframes'
// center_spectrum_low_frequencies).
@(private)
l_spectrum_centered :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	lua.L_checktype(L, 1, i32(lua.Type.TABLE))
	n := int(lua.rawlen(L, 1))
	src := make([]f32, n, context.temp_allocator)
	for &v, i in src {
		lua.rawgeti(L, 1, lua.Integer(i + 1))
		v = f32(lua.tonumber(L, -1))
		lua.pop(L, 1)
	}
	out := make([]f32, n, context.temp_allocator)
	om.spectrum_centered(src, out)
	push_numbers(L, out)
	return 1
}

@(private = "file")
push_numbers :: proc(L: ^lua.State, v: []f32) {
	lua.createtable(L, c.int(len(v)), 0)
	for x, i in v {
		lua.pushnumber(L, lua.Number(x))
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
}

// ---- time terms -----------------------------------------------------------------------

// Whether the table at `idx` needs terms rather than plain seconds/frames:
// media lengths, minutes, sums.
@(private)
needs_terms :: proc(L: ^lua.State, idx: c.int) -> bool {
	if !lua.istable(L, idx) {
		return false
	}
	if lua.rawlen(L, idx) > 0 {
		return true
	}
	for key in ([?]cstring{"audio", "video", "plus", "minus", "minutes", "frame"}) {
		if has_field(L, idx, key) {
			return true
		}
	}
	return false
}

// Appends the terms of the value at `idx`: a number (seconds), a list
// (summed), or a table with `seconds`, `minutes`, `frames`/`frame`,
// `audio = "file"`, `video = "file"`, `plus = ...`, `minus = ...`.
@(private)
read_time_terms :: proc(s: ^Script, L: ^lua.State, at: c.int, sign: f32, out: ^[dynamic]om.Time_Term) {
	idx := lua.absindex(L, at)
	if lua.isnumber(L, idx) {
		append(out, om.Time_Term{.Seconds, sign, f32(lua.tonumber(L, idx)), ""})
		return
	}
	if !lua.istable(L, idx) {
		return
	}
	if n := int(lua.rawlen(L, idx)); n > 0 {
		for i in 1 ..= n {
			lua.rawgeti(L, idx, lua.Integer(i))
			read_time_terms(s, L, -1, sign, out)
			lua.pop(L, 1)
		}
		return
	}
	// Checked before a clip's build function runs Lua.
	owner_fields := fields_push(L, idx)
	secs := get_num(L, idx, "seconds", 0) + get_num(L, idx, "minutes", 0) * 60
	frames := get_num(L, idx, "frames", get_num(L, idx, "frame", 0))
	clips := #partial [om.Time_Term_Kind]string {
		.Audio = get_str(L, idx, "audio", ""),
		.Video = get_str(L, idx, "video", ""),
	}
	field_used("plus")
	field_used("minus")
	fields_pop(L, s, idx, "time", owner_fields)
	if secs != 0 {
		append(out, om.Time_Term{.Seconds, sign, secs, ""})
	}
	if frames != 0 {
		append(out, om.Time_Term{.Frames, sign, frames, ""})
	}
	for kind in ([2]om.Time_Term_Kind{.Audio, .Video}) {
		name := clips[kind]
		if name != "" && kind == .Audio {
			build_pending(L, s, name) // its length is needed now
		}
		if name != "" {
			owned := strings.clone(name)
			append(&s.owned_strings, owned)
			append(out, om.Time_Term{kind, sign, 0, owned})
		}
	}
	field(L, idx, "plus")
	read_time_terms(s, L, -1, sign, out)
	lua.pop(L, 1)
	field(L, idx, "minus")
	read_time_terms(s, L, -1, -sign, out)
	lua.pop(L, 1)
}

// The terms of field `key` of the table at `t` as an owned slice (nil when
// the field is absent or plain).
@(private)
read_terms_field :: proc(s: ^Script, L: ^lua.State, t: c.int, key: cstring) -> []om.Time_Term {
	field(L, t, key)
	defer lua.pop(L, 1)
	if !needs_terms(L, -1) && !lua.istable(L, -1) {
		return nil
	}
	terms := make([dynamic]om.Time_Term)
	read_time_terms(s, L, -1, 1, &terms)
	owned := terms[:]
	append(&s.owned_terms, owned)
	return owned
}

// Field `duration` as terms when it uses media lengths, minutes or sums.
@(private)
read_terms_duration :: proc(s: ^Script, L: ^lua.State, t: c.int) -> []om.Time_Term {
	field(L, t, "duration")
	use := needs_terms(L, -1)
	lua.pop(L, 1)
	if !use {
		return nil
	}
	return read_terms_field(s, L, t, "duration")
}

// audio_onsets(src) -> { onsets = { { time, strength }, ... }, bpm, offset,
// beats = { ... } }: where sounds start in clip `src` (seconds into the
// file; strength 0..1, the rise in level relative to the largest), and the
// steady beat they imply: `bpm` and `offset` (the first beat, for
// beat_clock(bpm, offset)) and every beat time to the clip's end; bpm is
// nil and beats empty without a steady beat. Analysed once per clip; works
// at load and while rendering. nil when there is no such clip.
@(private)
l_audio_onsets :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	src := string(lua.L_checkstring(L, 1))
	m := s.ctx.media if s.ctx != nil else s.media
	if m == nil {
		lua.L_error(L, "audio_onsets() needs the media: the script was loaded without it")
	}
	if s.ctx != nil && s.audio_later && audio_deferred(s, src) && src not_in m.audio {
		// A frame asking for a clip not built yet: no onsets until it lands.
		s.ctx.audio_pending += 1
		lua.createtable(L, 0, 2)
		lua.createtable(L, 0, 0)
		lua.setfield(L, -2, "onsets")
		lua.createtable(L, 0, 0)
		lua.setfield(L, -2, "beats")
		return 1
	}
	build_pending(L, s, src)
	rep, ok := om.media_onsets(m, src)
	if !ok {
		if s.ctx != nil {
			om.report(s.ctx, .Error, {code = .Missing_Audio, name = src})
		} else {
			load_error(L, "audio_onsets", {code = .Missing_Audio, name = src})
		}
		lua.pushnil(L)
		return 1
	}
	lua.createtable(L, 0, 4)
	lua.createtable(L, c.int(len(rep.onsets)), 0)
	for o, i in rep.onsets {
		lua.createtable(L, 0, 2)
		lua.pushnumber(L, lua.Number(o.time))
		lua.setfield(L, -2, "time")
		lua.pushnumber(L, lua.Number(o.strength))
		lua.setfield(L, -2, "strength")
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	lua.setfield(L, -2, "onsets")
	lua.createtable(L, 0, 0)
	if rep.bpm > 0 {
		lua.pushnumber(L, lua.Number(rep.bpm))
		lua.setfield(L, -3, "bpm")
		lua.pushnumber(L, lua.Number(rep.offset))
		lua.setfield(L, -3, "offset")
		period := 60 / f64(rep.bpm)
		length := f64(om.audio_clip_seconds(m.audio[src]))
		k := 0
		for t := f64(rep.offset); t < length; t = f64(rep.offset) + f64(k) * period {
			k += 1
			lua.pushnumber(L, lua.Number(t))
			lua.rawseti(L, -2, lua.Integer(k))
		}
	}
	lua.setfield(L, -2, "beats")
	return 1
}
