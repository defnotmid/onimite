package onimite

import "core:container/lru"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "base:runtime"
import "core:thread"
import vg "deps:ovg"
import odimg "deps:odecs/image"

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
	// The songs scripts compose (`song{}`, `sound{}`) and the video's
	// sample sets (music.odin); shared by copies of the media.
	music:    ^Music,
	// Video clips (decoded by `videos.source`, set by the host).
	videos:   Video_Clips,
	// Timed text by name: subtitle files (their cues and their words),
	// caption .json files and the script's `captions_load`.
	captions:  map[string]Captions,
	// Shader sources by file name: SkSL (.sksl), Shadertoy GLSL (.glsl) and
	// GLSL ES fragment shaders (.frag).
	shaders:  map[string]string,
	// Parsed SVG documents and their laid out text by file name (.svg).
	svgs:     map[string]^Svg_Asset,
	// Parsed Lottie documents by file name (.json files that are Lottie).
	lotties:  map[string]^vg.Lottie_Document,
	// What 3D layers draw from: glTF models by file name (.glb, .gltf),
	// their geometry and textures, media images used as textures.
	view3d:   View3d_Media,
	// The directory `media_load_dir` read (SVG <image> files resolve
	// against it).
	dir:      string,
	// Owned file contents (font data must outlive the fonts).
	blobs:    [dynamic][]u8,
	// How many of `fonts.faces`, at the end, are BUILTIN_FONTS.
	builtin_faces: int,
	// Content hashes of the audio clips scripts added from memory
	// (`media_add_audio_bytes`), by name.
	added_audio:   map[string]u64,
	// Files of the folder `media_load_dir` could not read or decode
	// (warnings, strings owned): the load's findings carry them.
	problems:      [dynamic]Diagnostic,
}

// What a media file is. The loader picks it by the file's extension
// (`media_kind_of`); listings word and tag the files by it.
Media_Kind :: enum u8 {
	Image,
	Video,
	Audio,
	Font,
	Svg,
	Lottie,
	Shader,
	Subtitles,
	Captions,
	Model,
}

Media_Kind_Info :: struct {
	// What listings call it ("image", "SVG").
	label:       string,
	// Three letters for the media rows of the preview's Watch.
	tag:         string,
	// The file extensions it loads from (lower case). A .json file is
	// Lottie or captions by its content, other JSON the script's own data.
	exts:        []string,
	// What a file of this kind that does not decode was meant to be, for
	// its warning; "" for none (a video's sound is optional).
	undecodable: string,
}

@(rodata)
MEDIA_KINDS := [Media_Kind]Media_Kind_Info {
	.Image     = {"image", "IMG", {".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tga", ".qoi", ".webp", ".hdr"}, "an image"},
	.Video     = {"video", "VID", {".mp4", ".mov", ".m4v", ".webm"}, ""},
	.Audio     = {"sound", "AUD", {".wav", ".wave", ".ogg", ".oga", ".opus", ".m4a", ".aac", ".mp3", ".flac"}, "audio"},
	.Font      = {"font", "FNT", {".ttf", ".otf", ".ttc"}, "a font"},
	.Svg       = {"SVG", "SVG", {".svg"}, "SVG"},
	.Lottie    = {"Lottie", "LOT", {".json"}, "Lottie"},
	.Shader    = {"shader", "SHD", {".sksl", ".glsl", ".frag"}, ""},
	.Subtitles = {"subtitles", "SUB", {".vtt", ".srt"}, "subtitles (WebVTT or SRT)"},
	.Captions  = {"captions", "CAP", {".json"}, ""},
	.Model     = {"model", "MDL", {".glb", ".gltf", ".3mf", ".obj", ".usdz", ".usdc"}, "a 3D model"},
}

// The kind file `name` loads as, by its extension (a .json file as Lottie
// until its content says otherwise); false for files the media skips.
media_kind_of :: proc(name: string) -> (kind: Media_Kind, ok: bool) {
	ext := strings.to_lower(file_ext(name), context.temp_allocator)
	for info, k in MEDIA_KINDS {
		if slice.contains(info.exts, ext) {
			return k, true
		}
	}
	return {}, false
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

// The fonts every video has without a file in media/ (SIL OFL 1.1), after
// the media's own faces. DM Sans draws text that names no family when the
// media has no fonts, and a family nothing matches.
BUILTIN_FONTS := [?][]u8 {
	#load("../assets/fonts/DMSans-Regular.ttf"),
	#load("../assets/fonts/DMSans-Medium.ttf"),
	#load("../assets/fonts/DMSans-Bold.ttf"),
	#load("../assets/fonts/InstrumentSerif-Regular.ttf"),
	#load("../assets/fonts/InstrumentSerif-Italic.ttf"),
	#load("../assets/fonts/BebasNeue-Regular.ttf"),
	#load("../assets/fonts/JetBrainsMono-Regular.ttf"),
	#load("../assets/fonts/JetBrainsMono-Bold.ttf"),
}

media_init :: proc(m: ^Media) {
	vg.font_collection_init(&m.fonts, BUILTIN_FONTS[0])
	for data in BUILTIN_FONTS {
		m.builtin_faces += vg.font_collection_add(&m.fonts, data)
	}
	m.fonts.default_family = "DM Sans"
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
	m.music = new(Music)
	music_init(m.music)
	m.captions = make(map[string]Captions)
	m.shaders = make(map[string]string)
	m.svgs = make(map[string]^Svg_Asset)
	m.lotties = make(map[string]^vg.Lottie_Document)
	view3d_media_init(&m.view3d)
	m.blobs = make([dynamic][]u8)
	m.added_audio = make(map[string]u64)
}

media_destroy :: proc(m: ^Media) {
	vg.font_collection_destroy(&m.fonts)
	lru.destroy(&m.cache.lru, false)
	free(m.cache)
	onset_cache_destroy(m.onsets)
	free(m.onsets)
	if m.music != nil {
		music_destroy(m.music)
		free(m.music)
	}
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
	view3d_media_destroy(&m.view3d)
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

// Premultiplied RGBA8 to straight alpha (what PNG files hold), rounded to
// the nearest, in `allocator`.
straight_alpha :: proc(pixels: []u8, allocator := context.temp_allocator) -> []u8 {
	out := make([]u8, len(pixels), allocator)
	for i := 0; i < len(pixels); i += 4 {
		a := pixels[i + 3]
		if a == 255 || a == 0 {
			copy(out[i:i + 4], pixels[i:i + 4])
			continue
		}
		for k in 0 ..< 3 {
			out[i + k] = u8(min((u32(pixels[i + k]) * 255 + u32(a) / 2) / u32(a), 255))
		}
		out[i + 3] = a
	}
	return out
}

// Adds a font from memory (TTF/OTF; every face of a TTC). The data must stay
// alive as long as the media. Family and weight come from the font's tables.
media_add_font :: proc(m: ^Media, data: []u8) -> bool {
	n := vg.font_collection_add(&m.fonts, data)
	// Before the built-in faces, so its first face is the default; a family
	// the media has replaces the built-in one of that name.
	first := len(m.fonts.faces) - n - m.builtin_faces
	slice.rotate_right(m.fonts.faces[first:], n)
	for i := len(m.fonts.faces) - 1; i >= len(m.fonts.faces) - m.builtin_faces; i -= 1 {
		face := &m.fonts.faces[i]
		for added in m.fonts.faces[first:][:n] {
			if strings.equal_fold(face.family, added.family) {
				delete(face.family)
				vg.font_destroy(&face.font)
				ordered_remove(&m.fonts.faces, i)
				m.builtin_faces -= 1
				break
			}
		}
	}
	// Text that names no family: the media's first font's.
	if n > 0 {
		m.fonts.default_family = m.fonts.faces[0].family
	}
	return n > 0
}

// The faces of the media's font files (not the built-in ones).
media_font_faces :: proc(m: ^Media) -> []vg.Font_Face {
	return m.fonts.faces[:len(m.fonts.faces) - m.builtin_faces]
}

// Whether face `i` of `fonts.faces` is a built-in one.
media_face_builtin :: proc(m: ^Media, i: int) -> bool {
	return i >= len(m.fonts.faces) - m.builtin_faces
}

// The face used when a family is missing (built-in DM Sans).
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
		pic, derr := odimg.decode(bytes)
		if err == nil && derr == .None {
			d.img.pixels, d.img.width, d.img.height = pic.pixels, pic.width, pic.height
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
	if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		if info, info_err := odimg.info(data); info_err == .None {
			img.width, img.height = info.width, info.height
		}
	}
	if img.width == 0 {
		media_problem(m, {code = .Undecodable_Media, name = name, a = MEDIA_KINDS[.Image].undecodable})
	}
	put_image(m, name, img)
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

// Adds WebVTT or SRT subtitles (the text is copied): their cues and their
// words, as captions. False when it doesn't parse.
media_add_subtitles :: proc(m: ^Media, name, text: string) -> bool {
	subs := parse_subtitles(text) or_return
	media_add_captions(m, name, captions_from_subtitles(subs))
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
	clip, ok := audio_decode(data)
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

// Loads every font, image, SVG, Lottie, audio, video, subtitle and glTF
// file in `dir` (not recursive); everything but fonts is named by file name.
// Touches only `m` (and the thread-safe video source), so it can run on a
// loader thread for a Media no other thread uses, handed over when done.
// Images only read their size here and decode on first use
// (`media_image`); audio, SVG and Lottie files decode as tasks on `pool`
// (borrowed; nil decodes here) and are added in directory order.
media_load_dir :: proc(m: ^Media, dir: string, pool: ^thread.Pool = nil) -> Error {
	// A file in place of a directory is the media alone (a video file
	// previewed or rendered as itself): its folder's other files stay unread.
	dir, only := dir, ""
	if os.is_file(dir) {
		dir, only = filepath.split(dir)
	}
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
		if only != "" && fi.name != only {
			continue
		}
		// a link counts as the file it points to (a large model linked in
		// rather than copied)
		if fi.type == .Symlink {
			target, stat_err := os.stat(fi.fullpath, context.temp_allocator)
			if stat_err != nil || target.type != .Regular {
				continue
			}
		} else if fi.type != .Regular {
			continue
		}
		kind := media_kind_of(fi.name) or_continue
		switch kind {
		case .Image:
			add_image_file(m, fi.name, fi.fullpath)
		case .Model:
			if what, why, ok := view3d_add_model(&m.view3d, fi.name, fi.fullpath); !ok {
				media_problem(m, {code = .Undecodable_Media, name = fi.name, a = fmt.tprintf("%s (%s)", what, why)})
			}
		case .Font, .Shader, .Subtitles:
			data, read_err := os.read_entire_file(fi.fullpath, context.allocator)
			if read_err != nil {
				media_problem(m, {code = .Unreadable_Media, name = fi.name, b = fmt.tprint(read_err)})
				continue
			}
			if !add_whole_file(m, kind, fi.name, data) {
				media_problem(m, {code = .Undecodable_Media, name = fi.name, a = MEDIA_KINDS[kind].undecodable})
			}
		case .Video:
			// A clip, and its sound when it has an audio track.
			media_add_video(m, fi.name, fi.fullpath)
			append(&jobs, Decode_Job{name = fi.name, path = fi.fullpath, kind = .Video, media = m})
		case .Audio, .Svg, .Lottie, .Captions:
			// Decoded once every file is listed: SVG text is measured with
			// all the fonts.
			append(&jobs, Decode_Job{name = fi.name, path = fi.fullpath, kind = kind, media = m})
		}
	}
	return nil
}

// Adds a font, shader or subtitle file read whole (`data`, taken): false
// when it does not decode.
@(private = "file")
add_whole_file :: proc(m: ^Media, kind: Media_Kind, name: string, data: []u8) -> (ok: bool) {
	#partial switch kind {
	case .Font:
		// Font data lives as long as the media.
		if media_add_font(m, data) {
			append(&m.blobs, data)
			return true
		}
	case .Shader:
		media_add_shader(m, name, string(data))
		ok = true
	case .Subtitles:
		ok = media_add_subtitles(m, name, string(data))
	}
	delete(data)
	return ok
}

// One file to read and decode off the loading thread: a video's sound, a
// sound, an SVG or a .json file (Lottie, else captions when it is).
@(private)
Decode_Job :: struct {
	name, path: string,
	// What the file is; a .json file that is not Lottie turns `.Captions`.
	kind:       Media_Kind,
	// Read only while the jobs run (its decoder, folder and fonts).
	media:      ^Media,
	ok:         bool,
	// The file could not be read (else a failed job could not be decoded).
	read:       os.Error,
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
			case MEDIA_KINDS[j.kind].undecodable != "":
				media_problem(m, {code = .Undecodable_Media, name = j.name, a = MEDIA_KINDS[j.kind].undecodable})
			}
			continue
		}
		#partial switch j.kind {
		case .Audio, .Video:
			put_audio(m, j.name, j.clip)
		case .Svg:
			put_svg(m, j.name, j.svg_asset)
		case .Lottie:
			put_lottie(m, j.name, j.lottie_doc)
		case .Captions:
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
	if j.kind == .Lottie && !vg.lottie_sniff(data) {
		j.kind = .Captions
	}
	#partial switch j.kind {
	case .Audio, .Video:
		j.clip, j.ok = audio_decode(data)
	case .Svg:
		err: vg.Svg_Error
		j.svg_asset, err = svg_asset_make(data, j.media.dir, &j.media.fonts)
		j.ok = err == nil
	case .Lottie:
		j.lottie_doc, j.ok = lottie_parse_media(data, j.media.dir)
	case .Captions:
		j.captions, j.ok = captions_parse_json(string(data))
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
