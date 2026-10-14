# Media in onimite scripts

SVG documents, Lottie animations, video clips, subtitles and word-level captions. Images are in
[api.md](api.md); sound is in [audio.md](audio.md).

## SVG documents


```lua
svg { src = "bird.svg", x = 100, y = 100, w = 800, h = 600 }
local b = svg_bbox { src = "bird.svg", id = "wing_back" }      -- {x, y, w, h} in the element's own coordinates
local flap = math.sin(f.seconds * 9) * 25
svg(f, { src = "bird.svg", x = 1000, y = 100, w = 800, h = 600, overrides = {
  wing_back = { transform = rotate(flap, b.x + b.w, b.y + b.h) },
  sun = { fill = "#f97316" },
  tail = { opacity = 0.5 },
  head = { stroke = "navy" },
} })
svg { markup = [[<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><circle id="dot" cx="5" cy="5" r="4" fill="#facc15"/></svg>]],
  x = 100, y = 800, w = 200, h = 200, fit = "contain", opacity = 0.8,
  overrides = { dot = { visible = math.floor(f.seconds * 2) % 2 == 0 } } }
```

- Parsed once (media `.svg` files when the media loads, `markup` once, cached by content) and
  drawn as vectors into the box, clipped to its viewport; `fit` / `align` as for images.
- Overrides apply to every element with that id: `transform` (in the element's own
  coordinates, inside its SVG transform: rotate about `svg_bbox` points), `opacity`, `fill`,
  `stroke` (inherited by descendants), `visible`. `visible = true` shows an element the file
  hides with `display="none"`, so one SVG can hold a sprite's alternate parts (eyes open and
  closed, two frames of a spark) for a script to swap (`examples/common/pip.lua`).
- Supported: shapes, paths, groups, `use`/`symbol`/nested `svg`, CSS, gradients, patterns,
  clip paths, masks, every SVG 1.1 filter primitive (feImage of images, not elements), blend
  modes, dashes, text and tspans, embedded or media-relative images. Unsupported (markers,
  textPath, ...) and override
  ids the document lacks are warnings naming the file.

## Lottie animations


```lua
local info = lottie_info("confetti.json")   -- {width, height, fps, frames, duration, markers = {{name, time, duration}, ...}}
lottie { src = "confetti.json", x = 100, y = 100, w = 600 }          -- plays from the scene's start, native fps, loops
lottie(g, { src = "check.json", x = 800, y = 300, w = 200, loop = false })  -- g: a sequence's frame; holds the last frame
lottie { src = "spinner.json", x = 0, y = 0, w = 300, h = 300, speed = 2, offset = 0.5, fit = "cover" }
lottie { src = "wave.json", x = 0, y = 0, frame = 12 }               -- a fixed frame (from the in point)
lottie { data = [[{"v":"5.7.0","fr":30,...}]], x = 0, y = 0, time = f.seconds * 0.5, opacity = 0.8 }
lottie { src = "spinner.json", x = 0, y = 0, w = 300, overrides = {    -- by layer name (`nm`)
  ["Shape Layer 1"] = { fill = "#0ea5e9", stroke = "navy" },
  ["Logo"] = { transform = rotate(f.seconds * 90, 50, 50), opacity = 0.5 },
  ["Badge"] = { visible = false },
  ["Title"] = { text = "Hello" },                                       -- a text layer's string
} }
```

- `.json` files in `media/` that are Lottie files (an object with `"v"` and `"layers"`) parse
  once when the media loads; `data` parses once per renderer. Other `.json` files are ignored.
- Box, `fit`, `align` as for images (0 = the composition's size); the composition's bounds clip.
- Frame shown: `frame`, else `time` seconds, else (clock of `f`, or of the render call: the
  scene's frame inside a scene) × `speed` + `offset` seconds; at the file's own fps. `loop`
  (default true) wraps; `false` holds the first / last frame. Negative `speed` plays backwards.
- Overrides apply to every layer with that name (in any composition), like svg{} overrides:
  `transform` in the layer's own coordinates (inside its transform; layers parented to it
  follow), `opacity` replaces its opacity, `fill` / `stroke` recolour its fills / strokes
  (gradients too; their opacity stays), a solid layer and a precomp's layers, `visible`
  (`true` shows a hidden layer), `text` replaces a text layer's string (its fill / stroke
  follow `fill` / `stroke`). Names the file lacks are warnings naming the file; list the
  names with `jq '.. | .nm? // empty' anim.json`.
- Supported: precomps (time remap, stretch, start time), solid / image / null / shape layers,
  parenting, transforms (separated position, skew), track mattes (alpha, luma, inverted), masks
  (add, subtract, intersect, inverted, opacity, expansion), blend modes, groups, rect, ellipse,
  path, polystar, fill, stroke (caps, joins, dashes), linear / radial gradients (opacity stops,
  highlight), trim paths, repeater, eased / hold / spatial keyframes; effects (gaussian blur,
  drop shadow, fill, tint, tritone; animated); text layers (document keyframes, justification,
  tracking, line height, baseline shift, box text wrapping) laid out with the media's fonts
  (the file's font family: built in, or put its .ttf in `media/`; else DM Sans draws it and
  a missing-font warning names the family) and text animators (range selectors by characters /
  words / lines; per-letter position, scale, rotation, opacity, fill / stroke colour,
  tracking). Other effects, layer styles, merge paths, text on a path, expressions (keyframed
  values play), 3D and mask feather are warnings naming the file: check `onimite inspect`
  after adding a file.

## Video clips


```lua
local info = video_info("clip.mp4")            -- {width, height, duration, fps, frames} or nil
video_frame(f, { src = "clip.mp4", x = 100, y = 100, w = 960, h = 540, fit = "cover",
  start_from = 0.5,      -- when playback starts on the frame clock (nothing before)
  clip_start = 1.0,      -- skip into the clip
  looping = true, opacity = 1 })
video_frame(f, { src = "transparent.mov", x = 1200, y = 300, w = 500, h = 500 })   -- ProRes 4444 / VP9 alpha keep alpha
text { string.format("%dx%d %.1fs", info.width, info.height, info.duration),
  x = 100, y = 700, font = "DM Sans", size = 40, fill = "#fff" }
```

`.mp4`, `.mov`, `.m4v`, `.webm` in `media/`. The frame fits its box like an image: `fit`
(`contain` default, `cover`, `fill`, or `preserve_aspect_ratio`), `align = {x, y}` (0..1),
and a missing `w` or `h` follows the clip's aspect (neither: its own size; a rotated phone
clip counts upright). The clock is the frame's (scene-relative in a scene). Past the end the clip disappears unless it loops. A clip's sound is used by putting
its file name in an `audio` list (`offset` to start inside it). Renders wait for exact
frames; the preview shows the nearest decoded one.

## Subtitles


```lua
local cue = subtitle_at(f.global_seconds, "subs.vtt")   -- or subtitle_at(f, ...) for the frame's clock
if cue then
  local a = math.min(cue.progress * 8, 1)               -- progress 0..1 through the cue
  text { cue.text, x = 960, y = 950, align = "center", font = "DM Sans", size = 56, fill = "#fff", opacity = a }
end
local all = subtitles("subs.vtt")                       -- every cue: text, start, stop, progress, index, id, settings
text { #all .. " cues", x = 100, y = 100, font = "DM Sans", size = 32, fill = "#94a3b8" }
```

WebVTT and SRT files in `media/` (or loaded with `captions_load` below). Wrap long cues with `text_lines` and cache the result per
cue text, or draw them with `captions{}` below.

## Word-level captions


```lua
-- media/talk.json: Whisper JSON (segments[].words[] {word, start, end}), whisper.cpp JSON
-- (transcription[].tokens[] {text, offsets}), [{text, start, end}] in seconds or Remotion's
-- [{text, startMs, endMs}]. Every .vtt / .srt works too: inline <00:00:01.200> timestamps
-- time their words, other words share their cue's time evenly.
captions_load("extra.srt")                                  -- a file beside the script (else media/)
captions_load("inline", [[WEBVTT

00:00.000 --> 00:02.000
Hello <00:00.800>world
]])
captions_load("mine", { { text = "Hi", start = 0, stop = 0.4 }, { text = "there", start = 0.4, stop = 0.9 } })
local pages = caption_pages("talk.json", { max_words = 4 })  -- at load too
-- pages[i] = { index, start, stop, text, words = { { text, start, stop }, ... } }

video { width = 1080, height = 1920, fps = 30, duration = 10, render = function(f)
  -- the page showing now (nil between pages)
  local words = caption_words(f, "talk.json", { max_words = 4, hold = 0.3 })
  if words then  -- words[i] = { text, start, stop, active, progress }; words.page/start/stop/time
    text { #words .. " words", x = 80, y = 200, font = "DM Sans", size = 40, fill = "#94a3b8" }
  end
  -- or let captions{} lay out and highlight the page
  captions(f, { src = "talk.json", x = 80, y = 1080, w = 920, valign = "middle",
    font = "DM Sans", weight = 800, size = 96, line_height = 1.25, uppercase = true,
    fill = "#ffffff", highlight = "box", highlight_fill = "#facc15", active_fill = "#111827",
    active_scale = 1.12, max_duration = 1.2, hold = 0.3 })
end }
```

- Pages (Remotion's createTikTokStyleCaptions) never span two source cues (VTT / SRT cues,
  Whisper segments) and end before a word that would break `max_words`, `max_duration`
  (seconds) or `combine_ms` (a word joins while it starts within that many ms of the page's
  start). No limit: cue files page by cue, flat word lists by `combine_ms = 1200`.
- `active` is the word being said and stays through the pause after it; `progress` is 0..1
  through each word (1 once said). `hold` (s) keeps a page up after its last word, never past
  the next page.
- `start` (on `caption_words`, `caption_pages` and `captions{}`): the time on the clock
  where the captions' 0 sits, for captions of a clip that starts later on the video
  (`captions(f.global_seconds, { src = "talk.json", start = 12.5, ... })`); every time they
  return is then on that clock. Nothing shows before it.
- Spoken lines make their own captions: `say("intro", text)` registers captions `intro`, a
  cue per sentence, times from the line's start (audio.md, "Spoken lines"):
  `captions(f.global_seconds, { src = "intro", start = INTRO_AT, ... })`.
- `captions{}` options: `src`, `x`, `y`, `w` (wrap width; default the video's width minus 2x),
  `align` (`center`), `valign` (`top`|`middle`|`bottom` for `y`), `baseline` (`middle`),
  `font`, `size` (64), `weight`, `letter_spacing`, `italic`, `line_height` (1.2),
  `uppercase`, `fill` (white), `active_fill`, `spoken_fill`, `upcoming_fill`, `stroke`,
  `stroke_width` (outline under the fill), `highlight = "fill"|"box"|"underline"`,
  `highlight_fill` (`#facc15`), `box_padding`, `box_radius`, `active_scale` (1.12; the line
  makes room), `spring` (the pop), `slide_spring` (the box), plus the paging options,
  `hold` and `start`. Widths are shaped (`text_width`), cached per page. Clock: `captions(f, ...)`,
  `captions(seconds, ...)` or `captions{...}` (the render call's clock).
- `examples/captions_demo` (box and fill styles), `examples/social_clip_kit` (captions from
  generated WebVTT).
