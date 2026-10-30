# fframes parity

Every fframes feature and where onimite stands. ✅ done · 🔨 in progress ·
⬜ to do · ➖ not carried over (with the reason).

## Video, scenes, time

| fframes | onimite | |
| --- | --- | --- |
| `Video` FPS / size / background | `video{ width, height, fps, background }` | ✅ |
| `Duration::Seconds / Frames / Auto` | `duration = s` / `{frames = n}` / omitted | ✅ |
| `Duration::FromAudio / FromVideo`, sums `a + b`, `a - b` | `duration = { audio = "f" }`, `{ video = "f" }`, `{ seconds = .., plus = .., minus = .. }`, lists sum | ✅ |
| Scenes, `Overlap::Previous / Next / PreviousAndNext` | `scene{ overlap = { previous, next } }` | ✅ |
| Scene `name()`, `ctx.render_scenes`, `get_scene_info` | `name`, `render_scenes(f)`, `scene_info(name)` | ✅ |
| `frame.index / global_index / seconds()` | `f.index`, `f.global_index`, `f.seconds` | ✅ |
| Fractional frame rates | integer fps, as fframes | ✅ |

## Animation

| fframes | onimite | |
| --- | --- | --- |
| `timeline!` keyframes, gaps hold, before/after clamp | `animate(f, keys)` | ✅ |
| Easing Linear / EaseIn / EaseOut / EaseInOut / CubicBezier | `ease_in` & co are Odin's cubic curves (fframes' CSS curves via `cubic_bezier`), plus `easing.*` (quad … bounce) | ✅ |
| `Easing::Spring` (natural settle when open-ended, cut by an end) | `spring{...}` | ✅ |
| `animate_loop` | `animate_loop` | ✅ |
| `animate_runtime` / `AnimationRuntime::solve` (runtime start) | `ease(easing, t, duration)` | ✅ |
| Animatable f32, f64, tuples, `Color`, `Transform` | numbers, colors, `{x, y}`, transforms | ✅ |
| `Transform { translate, scale, rotate, skew }` | translate / scale / rotate / skew / origin, or an SVG matrix (`matrix = {a..f}`, transform list strings) | ✅ |

## Drawing (what `svgr!` SVG covers)

| fframes / SVG | onimite | |
| --- | --- | --- |
| rect (rx/ry), circle, ellipse, line, polyline/polygon, path `d` | `rect` (`rx`, `ry`), `circle`, `ellipse`, `line`, `path`, `polygon` / `polyline` (`points`) | ✅ |
| fill, stroke, width, cap, join, miter limit | `fill`, `stroke`, `stroke_width`, `line_cap`, `line_join`, `miter_limit` | ✅ |
| fill-opacity, stroke-opacity, opacity | `fill_opacity`, `stroke_opacity`, `opacity` | ✅ |
| fill-rule, clip-rule | ✅ | ✅ |
| stroke-dasharray / dashoffset / pathLength | `stroke_dasharray`, `stroke_dashoffset`, `path_length` | ✅ |
| linear / radial gradients, stops with opacity | ✅ `units = "bbox"`, `transform`, `spread`; radial `fx`/`fy` (focal point) and `fr` | ✅ |
| `<pattern>` | `pattern{ x, y, w, h, units, transform, content }` | ✅ |
| group transform / opacity (as a layer) | ✅ | ✅ |
| `transform="matrix(..) translate(..) rotate(..) scale(..) skewX(..) skewY(..)"` | the same string, or `{ matrix = {a, b, c, d, e, f} }` | ✅ |
| colours `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa` | CSS colour strings (hex, named colours, `rgb()` / `rgba()`, `hsl()` / `hsla()`; others: an Error diagnostic), `rgb(r, g, b)` / `rgba(..)` | ✅ |
| clip-path | `clip_path`, `clip` (rect) | ✅ |
| mask (luminance, mask-type alpha) | `mask = function() ... end`, `mask_type = "luminance"` (default) \| `"alpha"` | ✅ |
| feGaussianBlur | `blur` | ✅ |
| feDropShadow, feOffset, feFlood, feComposite, feMerge, feBlend, feColorMatrix, feComponentTransfer, feMorphology, feTurbulence, feDiffuseLighting, feSpecularLighting (distant / point / spot lights), feTile, feDisplacementMap, feConvolveMatrix, feImage, filter regions and subregions | group `filter = { {...}, region = { x, y, w, h, units } }` (userSpaceOnUse / objectBoundingBox, SVG's -10%/120% default); `component_transfer`, `morphology`, `turbulence`, `diffuse_lighting`, `specular_lighting`, `tile`, `displacement_map`, `convolve_matrix`, `image`, `subregion = {x, y, w, h}` | ✅ gaps: feImage of an element (images only), kernelUnitLength ignored (as resvg), convolve kernels up to 36 values |
| mix-blend-mode | group `blend` | ✅ |
| `<image href>` (png/jpeg/webp/svg), preserveAspectRatio | `image{ src, x, y, w, h, fit, align }` (png, jpeg, bmp, gif, tga, webp); SVG files with `svg{}` | ✅ |
| SVG documents: `.svg` assets and inline markup (usvg import) | `svg{ src = "logo.svg" \| markup, x, y, w, h, fit, align, opacity, overrides = { id = { transform, opacity, fill, stroke, visible } } }`: parsed once (media load / per renderer), drawn as vectors (ovg `svg.odin`); `svg_bbox{ src, id }` | ✅ gaps: markers, feImage referencing elements, bicubic image sampling, non-uniform stroke transforms |
| `<use>` / defs reuse | Lua functions | ✅ |
| Static subtree caching (speed) | | ➖ not needed: frames build and draw well within budget (BENCHMARK.md) |

## Text

| fframes | onimite | |
| --- | --- | --- |
| `<text>` family, size, weight, fill, stroke, letter-spacing | ✅ vector outlines | ✅ |
| text-anchor (start/middle/end) | `align` | ✅ |
| font-style italic | `italic = true` (or `style = "italic"`) | ✅ |
| dominant-baseline / alignment-baseline | `baseline = "alphabetic"\|"middle"\|"central"\|"hanging"\|"top"\|"bottom"` | ✅ |
| `<tspan>` (mixed styles in a line, multi-line) | `spans = { {"text", font, size, weight, italic, fill, letter_spacing, features, dx, dy}, ... }`, `"\n"` line breaks with `line_height` | ✅ |
| Shaping (ligatures, GPOS kerning, complex scripts) via rustybuzz | oglyph's OpenType shaper (`oglyph/shape`, HarfBuzz's rules; ovg `text_layout`): GSUB / GPOS per font, script and direction segment, bidi visual order, legacy `kern` for fonts without GPOS, shaped segments cached across frames | ✅ gaps: explicit bidi controls, RTL paragraph direction |
| Font fallback per glyph | through every loaded face, then the bundled emoji and text faces (ovg `font_collection`); glyphs no font has are reported | ✅ |
| Colour emoji (usvg / resvg ≥ 0.42 draw COLRv0, COLRv1, sbix, CBDT and SVG glyphs) | COLR v0 / v1 drawn as vector fills at output resolution (ovg `colr.odin`: layers, solid, linear / radial / sweep gradients, transforms, ColrGlyph, ClipBox); Noto Color Emoji COLRv1 embedded as the emoji fallback (+5 MB binary); ZWJ sequences, skin tones, flags, keycaps and U+FE0F kept in one face | ✅ gaps: sbix / CBDT bitmap and SVG glyphs, PaintComposite blend modes (backdrop only), group opacity of layered glyphs |
| `text_width`, `text_fit` (ellipsis), `text_break_lines` | `text_width`, `text_fit`, `text_lines` | ✅ (also usable outside a render: at script load, with the media's fonts) |

## Media

| fframes | onimite | |
| --- | --- | --- |
| `include_media_dir!`, runtime media folders | `media/` beside the script, `--media DIR` | ✅ |
| Images | png, jpeg, bmp, gif, tga, qoi, webp (oicut: one decoder for every format; webp lossy, lossless, alpha) | ✅ |
| Fonts by family | by family + nearest weight + style (ttf, otf, ttc) | ✅ |
| Audio files: mp3, wav, flac, aac, ogg, m4a | wav, ogg (Vorbis, Opus), mp3, flac, m4a/aac (oicut) | ✅ |
| Synced video frames (`get_synced_video_frame`, looping, start_from) | `video_frame(f, { src, x, y, w, h, start_from, looping, clip_start, fit })`, `video_info(name)`; oicut `video` on a decode thread per clip; .mp4 / .mov / .m4v / .webm, alpha (ProRes 4444, VP9 alpha WebM) composited premultiplied | ✅ |
| Subtitles (WebVTT, `get_subtitle_phrase` / cues) | `subtitle_at(f, name)` (text, start, stop, progress, id, settings), `subtitles(name)`; SRT too | ✅ |
| Word-level captions (beyond fframes; Remotion's `@remotion/captions`) | word timings from Whisper / whisper.cpp JSON, `[{text, start, end}]` / Remotion `[{text, startMs, endMs}]` lists, WebVTT inline timestamps, plain VTT / SRT cues (words spread evenly); `captions_load(name [, source])`, `caption_pages(name, { max_words, max_duration, combine_ms })` (createTikTokStyleCaptions), `caption_words(f, name, opts)` (`text, start, stop, active, progress`), and the `captions{}` node: shaped layout and wrapping, active word by colour, sliding box or underline, spring pop (onimite/captions.odin, script/std.lua) | ✅ |
| Lottie animations (beyond fframes; Remotion / HyperFrames have them) | `lottie{ src = "anim.json" \| data = [[...]], x, y, w, h, fit, align, opacity, frame \| time \| speed, offset, loop }` (also `lottie(f, {...})`), `lottie_info(name)`: `.json` media that are Lottie files parse once (ovg `lottie.odin`) and draw as vectors at the frame the clock maps to: precomps, time remap / stretch, parenting, shapes, gradients, dashes, trim paths, repeater, merge paths, masks, track mattes, blend modes, spatial and eased keyframes, effects (gaussian blur, drop shadow, fill, tint, tritone), text layers with the media's fonts (box text, text animators: range selectors, per-letter transforms / opacity / colours / tracking; `overrides = { ["Title"] = { text = "Hello" } }`) | ✅ gaps: other effects and layer styles, other shape modifiers, text on a path, expressions (keyframed values are used), 3D, mask feather; each a warning naming the file |
| Audio visualisation (`visualize_audio_frame`, `center_spectrum_low_frequencies`) | `audio_spectrum(f, { src, sample_size, smooth, window, bands })` on the 48 kHz stereo mix (fframes analyses the file at its own rate, its left channel for `MediaDirectory` media, and its Hamming window is a ramp: magnitudes differ), `spectrum_centered(list)` | ✅ |

## Audio

| fframes | onimite | |
| --- | --- | --- |
| `AudioMap`, tracks with start..end, offset | `audio = { {...} }` on video and scenes | ✅ |
| Timestamps Second / Frame / Time / Eof / DurationOfAudio, `+`/`-` | seconds, `{ frame = n }`, `{ minutes, seconds }`, `{ audio = "f" }`, `plus` / `minus`; `stop` omitted = Eof | ✅ |
| gain_db, pan, fade in/out, fade curves | ✅ linear, equal power | ✅ |
| `include_media_dir!` mono decoding (`0.707 * (L + R)`) | track `mono = true` | ✅ |
| voice + duck_under_voice / custom Ducking | `voice`, `ducked` (bool or table) | ✅ |
| Master bus limiter -1 dBFS, de-click fades, master gain | ✅ | `video{ master_gain_db, limiter = { ceiling_db } }` (or `limiter = false`) ✅ |
| AAC track in renders | ✅ | ✅ |

## Shaders

| fframes | onimite | |
| --- | --- | --- |
| `Shader::sksl` (`half4 main(float2)`, premultiplied, top-left origin) | the same SkSL source, compiled by oksl (`sksl = [[...]]` or a `.sksl` file) | ✅ |
| `Shader::shadertoy` (`shadertoy_to_sksl`: object-like `#define`s expanded, `precision` dropped, uniforms declared, bottom-left origin, opaque output) | oksl's GLSL dialect (`oksl.compile_shadertoy`; `shadertoy = [[...]]` or a `.glsl` file): a token preprocessor (function-like macros, `#if`), `switch`, `discard`, `texture(iChannelN, uv)`, all Shadertoy inputs, bottom-left origin, opaque output; multipass programs (Common + Buffer A-D + Image, feedback in RGBA16F buffers, exact when seeking: `shadertoy = { common, buffer_a = { src, channels }, ..., image }`, one spelling of `passes`, which mixes SkSL, Shadertoy and GLSL passes), which fframes lacks | ✅ (more) |
| `Shader::draw(&frame, uniforms)` placed with `<image x y width height>` | `shader(f, { src \| sksl \| shadertoy, x, y, w, h, uniforms, time, opacity })`, composed with transforms, clips, masks, filters, opacity | ✅ |
| Declared iResolution (element size in its units), iTime (scene-relative), iTimeDelta, iFrame filled automatically | same, plus iFrameRate; iMouse / iDate zero (as fframes) | ✅ |
| `.float/.float2/.float3/.float4/.int/.color` uniforms | numbers, `{x, y, ...}`, colors (`"#hex"`, `rgb()`, animated), matrices and arrays as flat lists | ✅ |
| `.image(name, img)` children (`uniform shader name; name.eval(coord)` in image pixels, bilinear, clamped, premultiplied) | same SkSL; `uniforms = { name = "photo.jpg" }` binds media images or synced video clips (up to four children) | ✅ |
| Compile errors logged once, layer skipped; `compile_shader` in tests | errors as diagnostics with `file:line:col` (inspect / `--fail-on`), compiled once per source (by hash), unset / undeclared uniforms warn | ✅ |
| Rendered at device resolution | rendered at the box's on-screen pixel size (ovg `run_program`) | ✅ |
| Shaders on the CPU backend (fframes: tiny-skia draws nothing) | oksl CPU interpreter, row bands across all cores | ✅ |
| A group rendered to a layer as a shader input (fframes binds only images: content goes in as an image rendered beforehand, sampled in its pixels) | `uniforms = { name = function() ... end }` or `{ group = function, w, h }`: the nodes render offscreen (pooled ovg layer image, at the box's on-screen pixel size) before the shader; its pixel space is the box's units (or `w x h`), origin top-left, so `.eval(coord)` shows it where it was drawn; nests (shader in a group child of a shader) | ✅ |

## Command line

| fframes | onimite | |
| --- | --- | --- |
| `render [range] -o --draft` (default command) | ✅ .mp4 or PNG directory; `onimite video.lua` renders | ✅ |
| `frame specs -o` (+ `--svg`) | ✅ `--svg` writes the node tree as SVG next to each PNG (`svg_export`) | ✅ |
| `strip [range] -n --columns --width -o` | ✅ | ✅ |
| `onion range -n -o` | ✅ | ✅ |
| `timeline` (scenes + audio tracks) | ✅ | ✅ |
| `inspect [range] --every --all-frames --info --fail-on` | ✅ grouped findings, exit 2 | ✅ |
| Diagnostics: missing media/font/glyph, text clipped / off canvas, NaN, empty frame, panic | ✅ (+ invalid path data, zero-size shapes) | ✅ |
| `snapshot specs --dir --update --threshold --max-diff` | ✅ `.actual.png`, `.diff.png`, exit 2 | ✅ |
| `audio render [--float] / analyze --waveform / at` | ✅ | ✅ |
| `preview [at] --paused --no-loop --mute` | ✅ window with sound, scrub, hot reload, threaded; editor timeline (ruler, zoom/pan/follow, scene thumbnails, audio lanes with waveforms), bookmark (magnet, persisted), volume, Dock keys, fullscreen, collapsible timeline, panels with draggable tabs (oasic's workspace), a Watch of scenes, cues, problems and media (thumbnails) that jumps to the broken ones, resolution/latency/fps in the status | ✅ |
| `--json`, `--scale` | ✅ | ✅ |
| Time specs (frames, s, m:ss, %, start/end, scenes, `@`, `Name[n]`, `all`, ranges) | ✅ | ✅ |

## Encoding

| fframes | onimite | |
| --- | --- | --- |
| H.264 / H.265 MP4, hardware when available | ✅ oicut (Vulkan Video or native) | ✅ |
| WebM (VP9/AV1), alpha video output | | ➖ oicut has no VP9/AV1/ProRes encoder (WebM and alpha clips decode as inputs) |

## Examples

All 20 fframes examples are ported, each making the same video, for parity checks and the benchmark
(BENCHMARK.md), in `examples/fframes/`. Their media, fonts and shaders are
fframes' own and not ours to redistribute, so they are not committed:
`examples/fframes/fetch.sh` copies them (the list is `assets.tsv`) from the
fframes checkout pinned in `third_party/fetch.sh`.

| fframes `examples/` | port | |
| --- | --- | --- |
| `audio-announce` | `audio_announce` | ✅ |
| `beta` | `beta` | ✅ |
| `conference-splash-screen` | `conference_splash_screen` | ✅ |
| `fframes-intro` | `fframes_intro` | ✅ |
| `hello-world` | `hello_world` | ✅ |
| `low-poly-art` | `low_poly_art` | ✅ |
| `made-of-motion` | `made_of_motion` | ✅ |
| `marketing` | `marketing` | ✅ |
| `motion-graphics` | `motion_graphics` | ✅ |
| `neon-triangle` | `neon_triangle` | ✅ |
| `pixel-memory` | `pixel_memory` | ✅ |
| `podcast` | `podcast` | ✅ |
| `shader-mode` | `shader_mode` | ✅ |
| `shaders` | `shaders` | ✅ |
| `signal-lab` | `signal_lab` | ✅ |
| `teej-podcast` | `teej_podcast` | ✅ |
| `tiktok` | `tiktok` | ✅ |

## Not carried over

- The browser editor (ReScript + WASM): replaced by `onimite preview` with hot reload; its timeline, magnet, media list, volume and Dock keys are carried over (the native player's digit keys and `g` are not: 0 goes to the start, G is Shift+G).
- `cargo fframes new` project templates: a video is one Lua file.
