package onimite

import "core:container/lru"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "base:runtime"
import "core:thread"
import vg "deps:ovg"
import webp "deps:odecs/codec/webp"
import stbi "vendor:stb/image"

// Fonts and images a video can reference by name. Fonts are found by
// family and weight (`Text.font`, `Text.weight`), images by file name
// (`Image.src`).
Media :: struct {
	fonts:    vg.Font_Collection,
	// Image files by name, decoded on first use (`media_image`). The map
	// only changes while the media loads; entries never move.
	images:   map[string]^Media_Image,
	// Which decoded images stay; shared by copies of the media.
	cache:    ^Image_Cache,
	audio:    map[string]Audio_Clip,
	// Bumped when `audio` gains or loses a clip: placed tracks point into
	// it, and contexts place theirs again (`placed_audio`).
	audio_gen: u64,
	// Onsets of the audio clips, analysed on first use (`media_onsets`);
	// shared by copies of the media.
	onsets:   ^Onset_Cache,
	// Decodes audio formats the core doesn't (set by the host).
	decoder:  Audio_Decoder,
	// Video clips (decoded by `videos.source`, set by the host).
	videos:   Video_Clips,
	subtitles: map[string]Subtitles,
	// Word timings by name: every subtitle file's, caption .json files and
	// the script's `captions_load`.
	captions:  map[string]Captions,
	// Shader sources by file name: SkSL (.sksl) and Shadertoy GLSL (.glsl).
	shaders:  map[string]string,
	// Parsed SVG documents and their laid out text by file name (.svg).
	svgs:     map[string]^Svg_Asset,
	// Parsed Lottie documents by file name (.json files that are Lottie).
	lotties:  map[string]^vg.Lottie_Document,
	// The directory `media_load_dir` read (SVG <image> files resolve
	// against it).
	dir:      string,
	// Owned file contents (font data must outlive the fonts).
	blobs:    [dynamic][]u8,
	// Content hashes of the audio clips scripts added from memory
	// (`media_add_audio_bytes`), by name.
	added_audio:   map[string]u64,
	// Files of the folder `media_load_dir` could not read or decode
	// (warnings, strings owned): the load's findings carry them.
	problems:      [dynamic]Diagnostic,
}

// An image: its size (from the file's header when the media loads) and
// straight-alpha RGBA8 pixels, decoded from `path` the first time a frame,
// shader or the media table asks (`media_image`). Every renderer shares the
// decode: `once` runs it a single time while the others wait, and after it
// readers see `pixels` without locking until the image is evicted
// (`Image_Cache`), which resets `once` so the next use decodes it again.
Media_Image :: struct {
	pixels:        []u8,
	// The premultiplied copy for shader children (`media_premultiplied`),
	// nil for an opaque image; `alpha_checked` once looked at.
	premultiplied: []u8,
	alpha_checked: bool,
	width, height: int,
	// The file (owned); "" for images added from bytes (decoded at once,
	// never evicted).
	path:          string,
	once:          sync.Once,
	// The file could not be read or decoded.
	failed:        bool,
	// Unique to this decode, 0 while not decoded: the key the canvas
	// textures of the pixels are shared under (`| 1`: the premultiplied
	// ones). Renderers compare it to drop textures of evicted pixels.
	key:           u64,
	// The latest frame that used the image; frames still in flight pin it.
	last_use:      int,
}

// The decoded images by last use, within a byte budget (pixels and
// premultiplied copies). Frames touch what they draw (`media_image`);
// between frames `media_evict` frees the least recently used until the rest
// fit. One lock guards the cache and the images' cache fields.
Image_Cache :: struct {
	lock:      sync.Mutex,
	// Values: the image's decoded bytes.
	lru:       lru.Cache(^Media_Image, int),
	bytes:     int,
	budget:    int,
	allocator: runtime.Allocator,
	// The last `Media_Image.key` handed out (keys step by 2).
	key:       u64,
	// Bumped by every eviction: renderers then drop stale canvas images.
	evictions: u64,
	// Where `media_evict` puts the evicted texture keys while it runs.
	evicted:   ^[dynamic]u64,
}

// 1 GiB of decoded pixels (`--image-cache MB`).
IMAGE_BUDGET_DEFAULT :: 1 << 30

media_init :: proc(m: ^Media) {
	vg.font_collection_init(&m.fonts)
	// Colour emoji out of the box (Noto Color Emoji COLRv1, vector).
	vg.font_collection_set_emoji(&m.fonts, vg.EMOJI_FONT_DATA)
	m.images = make(map[string]^Media_Image)
	m.cache = new(Image_Cache)
	m.cache.budget = IMAGE_BUDGET_DEFAULT
	m.cache.allocator = m.images.allocator
	lru.init(&m.cache.lru, max(int))
	m.cache.lru.on_remove = image_evicted
	m.cache.lru.on_remove_user_data = m.cache
	m.audio = make(map[string]Audio_Clip)
	m.onsets = new(Onset_Cache)
	m.onsets.entries = make(map[string]Onset_Cache_Entry)
	m.subtitles = make(map[string]Subtitles)
	m.captions = make(map[string]Captions)
	m.shaders = make(map[string]string)
	m.svgs = make(map[string]^Svg_Asset)
	m.lotties = make(map[string]^vg.Lottie_Document)
	m.blobs = make([dynamic][]u8)
	m.added_audio = make(map[string]u64)
}

media_destroy :: proc(m: ^Media) {
	vg.font_collection_destroy(&m.fonts)
	lru.destroy(&m.cache.lru, false)
	free(m.cache)
	onset_cache_destroy(m.onsets)
	free(m.onsets)
	for name, img in m.images {
		delete(name)
		delete(img.pixels)
		delete(img.premultiplied)
		delete(img.path)
		free(img)
	}
	delete(m.images)
	for name, &clip in m.audio {
		delete(name)
		audio_clip_destroy(&clip)
	}
	delete(m.audio)
	for b in m.blobs {
		delete(b)
	}
	delete(m.blobs)
	video_clips_destroy(&m.videos)
	for name, &s in m.subtitles {
		delete(name)
		subtitles_destroy(&s)
	}
	delete(m.subtitles)
	for name, &c in m.captions {
		delete(name)
		captions_destroy(&c)
	}
	delete(m.captions)
	for name, src in m.shaders {
		delete(name)
		delete(src)
	}
	delete(m.shaders)
	for name, a in m.svgs {
		delete(name)
		svg_asset_destroy(a)
	}
	delete(m.svgs)
	for name, doc in m.lotties {
		delete(name)
		vg.lottie_destroy(doc)
		free(doc)
	}
	delete(m.lotties)
	for name in m.added_audio {
		delete(name)
	}
	delete(m.added_audio)
	diagnostics_free(m.problems[:])
	delete(m.problems)
	delete(m.dir)
	m^ = {}
}

// Image `name` with premultiplied color, made once per decode and shared by
// every renderer (the frame builders of a render): nil if the image is
// opaque (its pixels serve as they are) or missing. The pixels live as long
// as the image stays decoded.
media_premultiplied :: proc(m: ^Media, name: string, frame := -1) -> []u8 {
	img, ok := media_image(m, name, frame)
	if !ok {
		return nil
	}
	c := m.cache
	sync.guard(&c.lock)
	if img.alpha_checked {
		return img.premultiplied
	}
	img.alpha_checked = true
	opaque := true
	for i := 3; i < len(img.pixels); i += 4 {
		if img.pixels[i] != 255 {
			opaque = false
			break
		}
	}
	if opaque {
		return nil
	}
	pm := make([]u8, len(img.pixels), c.allocator)
	for i := 0; i < len(pm); i += 4 {
		a := u32(img.pixels[i + 3])
		pm[i] = u8((u32(img.pixels[i]) * a + 127) / 255)
		pm[i + 1] = u8((u32(img.pixels[i + 1]) * a + 127) / 255)
		pm[i + 2] = u8((u32(img.pixels[i + 2]) * a + 127) / 255)
		pm[i + 3] = u8(a)
	}
	img.premultiplied = pm
	if node, cached := c.lru.entries[img]; cached {
		node.value += len(pm)
		c.bytes += len(pm)
	}
	return pm
}

// Adds a font from memory (TTF/OTF; every face of a TTC). The data must stay
// alive as long as the media. Family and weight come from the font's tables.
media_add_font :: proc(m: ^Media, data: []u8) -> bool {
	return vg.font_collection_add(&m.fonts, data) > 0
}

// The bundled face used when a family is missing.
media_fallback_font :: proc(m: ^Media) -> ^vg.Font {
	return &m.fonts.fallback.font
}

// Image `name`, decoded on the first call (by one caller while any others
// wait) and again after an eviction, used by frame `frame` (-1: no frame).
// `img` is nil when the media has no such image; `ok` is false when its
// file does not read or decode. The pixels stay until an eviction spares
// no frame from `frame` on (`media_evict`).
media_image :: proc(m: ^Media, name: string, frame := -1) -> (img: ^Media_Image, ok: bool) {
	img = m.images[name] or_return
	if img.path == "" {
		return img, !img.failed
	}
	c := m.cache
	sync.lock(&c.lock)
	img.last_use = max(img.last_use, frame)
	_, cached := lru.get(&c.lru, img)
	sync.unlock(&c.lock)
	if cached {
		return img, true
	}
	Decode :: struct {
		m:   ^Media,
		img: ^Media_Image,
	}
	d := Decode{m, img}
	sync.once_do_with_data(&img.once, proc(data: rawptr) {
		d := (^Decode)(data)
		context.allocator = d.m.cache.allocator
		bytes, err := os.read_entire_file(d.img.path, context.allocator)
		defer delete(bytes)
		pixels, w, h, decoded := decode_image(bytes)
		if err == nil && decoded {
			d.img.pixels, d.img.width, d.img.height = pixels, w, h
		} else {
			d.img.failed = true
		}
	}, &d)
	if img.failed {
		return img, false
	}
	sync.guard(&c.lock)
	if !lru.exists(&c.lru, img) {
		c.key += 2
		img.key = c.key
		lru.set(&c.lru, img, len(img.pixels))
		c.bytes += len(img.pixels)
	}
	return img, true
}

// Frees the least recently used decoded images until the rest fit the
// budget, sparing those used by frame `keep_from` or later (frames still
// being built or played). With the default no frame is in flight: nothing
// is spared and the pins are dropped. Call between frames. The texture keys
// of the evicted images (`key` and `key | 1`) are appended to `evicted`,
// for shared textures the caller frees (`vg.shared_images_remove`).
media_evict :: proc(m: ^Media, keep_from := max(int), evicted: ^[dynamic]u64 = nil) {
	c := m.cache
	sync.guard(&c.lock)
	c.evicted = evicted
	for node := c.lru.tail; node != nil && c.bytes > c.budget; {
		prev := node.prev
		if node.key.last_use < keep_from {
			lru.remove(&c.lru, node.key)
		}
		node = prev
	}
	c.evicted = nil
	if keep_from == max(int) {
		for node := c.lru.head; node != nil; node = node.next {
			node.key.last_use = 0
		}
	}
}

// The cache's `on_remove`: frees the pixels so the next use decodes again.
@(private = "file")
image_evicted :: proc(img: ^Media_Image, bytes: int, user: rawptr) {
	c := (^Image_Cache)(user)
	if c.evicted != nil {
		append(c.evicted, img.key, img.key | 1)
	}
	delete(img.pixels, c.allocator)
	delete(img.premultiplied, c.allocator)
	img.pixels, img.premultiplied, img.alpha_checked = nil, nil, false
	img.once = {}
	img.key = 0
	img.last_use = 0
	c.bytes -= bytes
	c.evictions += 1
}

// Records image file `path` under `name` with the size its header gives
// (0 when it doesn't read), to decode on first use.
@(private)
add_image_file :: proc(m: ^Media, name, path: string) {
	img := Media_Image{path = strings.clone(path)}
	if strings.to_lower(file_ext(name), context.temp_allocator) == ".webp" {
		if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
			if ft, ft_err := webp.get_features(data); ft_err == nil {
				img.width, img.height = ft.width, ft.height
			}
		}
	} else {
		w, h, channels: i32
		if stbi.info(strings.clone_to_cstring(path, context.temp_allocator), &w, &h, &channels) != 0 {
			img.width, img.height = int(w), int(h)
		}
	}
	if img.width == 0 {
		media_problem(m, {code = .Undecodable_Media, name = name, a = "an image"})
	}
	put_image(m, name, img)
}

@(private)
decode_image :: proc(data: []u8) -> (pixels: []u8, width, height: int, ok: bool) {
	if len(data) >= 12 && string(data[0:4]) == "RIFF" && string(data[8:12]) == "WEBP" {
		pic, err := webp.decode(data)
		if err != .None {
			return
		}
		return pic.pixels, pic.width, pic.height, true
	}
	w, h, channels: i32
	px := stbi.load_from_memory(raw_data(data), i32(len(data)), &w, &h, &channels, 4)
	if px == nil {
		return
	}
	defer stbi.image_free(px)
	pixels = make([]u8, int(w * h * 4))
	copy(pixels, px[:w * h * 4])
	return pixels, int(w), int(h), true
}

@(private)
put_image :: proc(m: ^Media, name: string, img: Media_Image) {
	p := new(Media_Image)
	p^ = img
	c := m.cache
	sync.guard(&c.lock)
	if p.path == "" {
		c.key += 2
		p.key = c.key
	}
	if old, ok := m.images[name]; ok {
		lru.remove(&c.lru, old)
		delete(old.pixels)
		delete(old.premultiplied)
		delete(old.path)
		free(old)
		m.images[name] = p
	} else {
		m.images[strings.clone(name)] = p
	}
}

// Adds WebVTT or SRT subtitles (the text is copied), and their words as
// captions. False when it doesn't parse.
media_add_subtitles :: proc(m: ^Media, name, text: string) -> bool {
	subs, ok := parse_vtt(text)
	if !ok {
		subs = parse_srt(text) or_return
	}
	media_add_captions(m, name, captions_from_subtitles(&subs))
	if old, exists := &m.subtitles[name]; exists {
		subtitles_destroy(old)
		old^ = subs
	} else {
		m.subtitles[strings.clone(name)] = subs
	}
	return true
}

// Adds captions under `name` (taking `c`). The same words again change
// nothing, so every frame builder of a render can repeat a script's
// `captions_load` while the others render; other words replace them.
media_add_captions :: proc(m: ^Media, name: string, c: Captions) {
	c := c
	if old, exists := &m.captions[name]; exists {
		if old.hash == c.hash {
			captions_destroy(&c)
			return
		}
		captions_destroy(old)
		old^ = c
	} else {
		m.captions[strings.clone(name)] = c
	}
}

// Adds a shader source (copied) under `name`.
media_add_shader :: proc(m: ^Media, name, source: string) {
	if old, ok := m.shaders[name]; ok {
		delete(old)
		m.shaders[name] = strings.clone(source)
	} else {
		m.shaders[strings.clone(name)] = strings.clone(source)
	}
}

// Adds a sound from encoded bytes; the format comes from the name's
// extension. False when it can't be decoded.
media_add_audio :: proc(m: ^Media, name: string, data: []u8) -> bool {
	clip, ok := audio_decode(data, file_ext(name), m.decoder)
	if ok {
		put_audio(m, name, clip)
	}
	return ok
}

// Adds audio file bytes made in memory (a script's `audio_add`) as clip
// `name`, decoded by its extension like a media file. The same bytes under
// the same name again only read the media and change nothing, so every
// frame builder of a render can repeat the script's call while the others
// render; other bytes replace the clip (a preview reload).
media_add_audio_bytes :: proc(m: ^Media, name: string, data: []u8) -> bool {
	h := hash.fnv64a(data)
	if old, seen := m.added_audio[name]; seen && old == h {
		return true
	}
	media_add_audio(m, name, data) or_return
	if _, seen := m.added_audio[name]; seen {
		m.added_audio[name] = h
	} else {
		m.added_audio[strings.clone(name)] = h
	}
	return true
}

// Adds sound a script made as samples (interleaved, `channels` per frame,
// at `rate`) as clip `name`. Like media_add_audio_bytes, the same samples
// again change nothing; others replace the clip.
media_add_audio_samples :: proc(m: ^Media, name: string, samples: []f32, rate, channels: int) {
	h := hash.fnv64a(slice.to_bytes(samples)) ~ (u64(rate) << 8 | u64(channels))
	if old, seen := m.added_audio[name]; seen && old == h {
		return
	}
	put_audio(m, name, clip_from_samples(samples, rate, channels))
	if _, seen := m.added_audio[name]; seen {
		m.added_audio[name] = h
	} else {
		m.added_audio[strings.clone(name)] = h
	}
}

// Takes clip `name` out of the media (the caller owns its samples now).
media_take_audio :: proc(m: ^Media, name: string) -> (clip: Audio_Clip, ok: bool) {
	if name not_in m.audio {
		return
	}
	key, value := delete_key(&m.audio, name)
	delete(key)
	m.audio_gen += 1
	return value, true
}

// Adds a clip built elsewhere (its samples move in). A clip of that name
// already here stays, and `clip` is freed: returns whether it was added.
media_add_clip :: proc(m: ^Media, name: string, clip: Audio_Clip) -> bool {
	if name in m.audio {
		c := clip
		audio_clip_destroy(&c)
		return false
	}
	m.audio[strings.clone(name)] = clip
	m.audio_gen += 1
	return true
}

@(private)
put_audio :: proc(m: ^Media, name: string, clip: Audio_Clip) {
	if old, exists := &m.audio[name]; exists {
		audio_clip_destroy(old)
		old^ = clip
	} else {
		m.audio[strings.clone(name)] = clip
	}
	m.audio_gen += 1
}

// Loads every font, image, SVG, Lottie, audio, video and subtitle file in `dir` (not
// recursive); everything but fonts is named by file name. Touches only `m`
// (and the thread-safe video source), so it can run on a loader thread for a
// Media no other thread uses, handed over when done. Images only read their
// size here and decode on first use (`media_image`); audio, SVG and Lottie
// files decode as tasks on `pool` (borrowed; nil decodes here) and are added
// in directory order.
media_load_dir :: proc(m: ^Media, dir: string, pool: ^thread.Pool = nil) -> Error {
	infos, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		return .Io
	}
	defer os.file_info_slice_delete(infos, context.allocator)
	delete(m.dir)
	m.dir = strings.clone(dir)
	diagnostics_free(m.problems[:])
	clear(&m.problems)
	jobs := make([dynamic]Decode_Job)
	defer {
		decode_jobs(m, jobs[:], pool)
		delete(jobs)
	}
	for fi in infos {
		if fi.type != .Regular {
			continue
		}
		ext := strings.to_lower(file_ext(fi.name), context.temp_allocator)
		switch ext {
		case ".ttf", ".otf", ".ttc":
			data, read_err := os.read_entire_file(fi.fullpath, context.allocator)
			if read_err != nil {
				media_problem(m, {code = .Unreadable_Media, name = fi.name, b = fmt.tprint(read_err)})
				continue
			}
			if media_add_font(m, data) {
				append(&m.blobs, data)
			} else {
				delete(data)
				media_problem(m, {code = .Undecodable_Media, name = fi.name, a = "a font"})
			}
		case ".mp4", ".mov", ".m4v", ".webm":
			// A clip, and its sound when it has an audio track.
			media_add_video(m, fi.name, fi.fullpath)
			append(&jobs, Decode_Job{name = fi.name, path = fi.fullpath, audio = true, optional = true, decoder = m.decoder})
		case ".sksl", ".glsl":
			data, read_err := os.read_entire_file(fi.fullpath, context.allocator)
			if read_err != nil {
				media_problem(m, {code = .Unreadable_Media, name = fi.name, b = fmt.tprint(read_err)})
				continue
			}
			media_add_shader(m, fi.name, string(data))
			delete(data)
		case ".vtt", ".srt":
			data, read_err := os.read_entire_file(fi.fullpath, context.allocator)
			if read_err != nil {
				media_problem(m, {code = .Unreadable_Media, name = fi.name, b = fmt.tprint(read_err)})
				continue
			}
			if !media_add_subtitles(m, fi.name, string(data)) {
				media_problem(m, {code = .Undecodable_Media, name = fi.name, a = "subtitles (WebVTT or SRT)"})
			}
			delete(data)
		case ".wav", ".wave", ".ogg", ".oga", ".m4a", ".aac", ".mp3", ".flac":
			append(&jobs, Decode_Job{name = fi.name, path = fi.fullpath, audio = true, decoder = m.decoder})
		case ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tga", ".webp":
			add_image_file(m, fi.name, fi.fullpath)
		case ".svg":
			// Parsed once into a document (after the fonts above: text
			// boxes are measured with them).
			append(&jobs, Decode_Job{name = fi.name, path = fi.fullpath, svg = true, media = m})
		case ".json":
			// Lottie animations and caption files (other JSON is left to
			// the script).
			append(&jobs, Decode_Job{name = fi.name, path = fi.fullpath, lottie = true, media = m})
		}
	}
	return nil
}

// One file to read and decode off the loading thread.
@(private)
Decode_Job :: struct {
	name, path: string,
	audio:      bool,
	// A video file's sound: missing audio is not a failure.
	optional:   bool,
	decoder:    Audio_Decoder,
	// An SVG file, parsed with the media's fonts (read-only meanwhile).
	svg:        bool,
	// A .json file: a Lottie document or captions when it is one.
	lottie:     bool,
	media:      ^Media,
	ok:         bool,
	// Why it failed, when that is worth a warning: the file could not be
	// read (`read`), or `what` it could not be decoded as ("" for a .json
	// file that is neither Lottie nor captions: the script's own data).
	read:       os.Error,
	what:       string,
	clip:       Audio_Clip,
	svg_asset:  ^Svg_Asset,
	lottie_doc: ^vg.Lottie_Document,
	captions:   Captions,
}

// Adds the decoded files to `m` in order.
@(private)
decode_jobs :: proc(m: ^Media, jobs: []Decode_Job, pool: ^thread.Pool) {
	pool_run(pool, jobs, decode_task, context.allocator)
	for &j in jobs {
		if !j.ok {
			switch {
			case j.read != nil:
				media_problem(m, {code = .Unreadable_Media, name = j.name, b = fmt.tprint(j.read)})
			case j.what != "" && !j.optional:
				media_problem(m, {code = .Undecodable_Media, name = j.name, a = j.what})
			}
			continue
		}
		switch {
		case j.audio:
			put_audio(m, j.name, j.clip)
		case j.svg:
			put_svg(m, j.name, j.svg_asset)
		case j.lottie && j.lottie_doc != nil:
			put_lottie(m, j.name, j.lottie_doc)
		case j.lottie:
			media_add_captions(m, j.name, j.captions)
		}
	}
}

// Reads and decodes one file into its job row. Results use the task's
// allocator; scratch is scoped to the task.
@(private)
decode_task :: proc(task: thread.Task) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	context.allocator = task.allocator
	j := (^Decode_Job)(task.data)
	data, err := os.read_entire_file(j.path, context.temp_allocator)
	if err != nil {
		j.read = err
		return
	}
	switch {
	case j.audio:
		j.clip, j.ok = audio_decode(data, file_ext(j.name), j.decoder)
		j.what = "audio"
	case j.svg:
		err: vg.Svg_Error
		j.svg_asset, err = svg_asset_make(data, j.media.dir, &j.media.fonts)
		j.ok = err == nil
		j.what = "SVG"
	case j.lottie:
		if vg.lottie_sniff(data) {
			j.lottie_doc, j.ok = lottie_parse_media(data, j.media.dir)
			j.what = "Lottie"
		} else {
			j.captions, j.ok = captions_parse_json(string(data))
		}
	}
}

// Notes a file of the folder that could not be read or decoded.
@(private)
media_problem :: proc(m: ^Media, d: Diagnostic) {
	d := d
	d.severity = .Warning
	d.name = strings.clone(d.name)
	d.a = strings.clone(d.a)
	d.b = strings.clone(d.b)
	append(&m.problems, d)
}

// The best face for `family` (case-insensitive): matching style first, then
// the nearest weight. `ok = false` returns the fallback font.
media_find_font :: proc(m: ^Media, family: string, weight: int, italic := false) -> (font: ^vg.Font, ok: bool) {
	return vg.font_collection_find(&m.fonts, family, weight, italic)
}

@(private)
file_ext :: proc(name: string) -> string {
	if i := strings.last_index_byte(name, '.'); i >= 0 {
		return name[i:]
	}
	return ""
}
