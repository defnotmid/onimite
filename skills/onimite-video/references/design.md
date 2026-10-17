# Designing good-looking onimite videos

Generated videos tend to fail in the same few ways: walls of text, every element moving at
once, linear motion, no hierarchy, cramped margins, arbitrary colours. A plain design that
avoids all of those already reads as finished.

## Matching an existing video

- Probe the reference first: `onimite probe ref.mp4` (size, fps, frame count, duration, audio).
  onimite fps is an integer; for 30000/1001 sources use 30 and keep cut points as integer
  frames. Map every cut and transition in source frames before writing scenes: total length
  alone does not give you the edit.
- Pull consecutive frames around fast effects and cuts
  (a scratch script that draws `video_frame(f, { src = "ref.mp4", ... })` at the reference's size,
  then `onimite frame scratch.lua 96,97,98,...` for the frame numbers around the cut). Sparse contact sheets miss
  sub-second reveals. Compare reference and output at the same frames, text and logos at full
  size (`onimite frame video.lua 96,97,98`).
- Separate camera motion from object motion. One transformed group cannot reproduce cards
  separating at different depths; give each object its own transform (or a shader for real
  perspective). `skew` is a 2D shear, not a 3D rotation.
- Read supplied shaders, SVGs and assets before approximating them; reuse vector logos
  (`svg{}`) instead of enlarging small rasters.
- Inserted screen recordings: check the chosen range for stable window bounds and the
  intended interaction; crop with `fit = "cover"` and `align`, keep playback at 1x.

## Pacing

- Reading time: about 3 words per second plus 1 s to notice the text. A 9-word line needs
  ~4 s on screen after it finishes animating in.
- Scene lengths: title 2.5-4 s, content 4-8 s, outro 2-3 s. Social clips: the first frame
  already shows something (no fade from black) and the hook lands within 1.5 s.
- Entrances 0.3-0.6 s, exits 0.2-0.3 s. Holds of 1-3 s are good; keep a little ambient motion
  (`animate_loop`, a slow drift) so they don't look frozen.
- With music, cut on bars and land entrances on beats (below). With voice, land each card
  just before the words that name it.

## Layout

- Safe margins: 8-10% of the width each side in landscape (x 160..1760 at 1920). Portrait
  keeps content inside x 8-92%, y 12-78%: platform UI covers the top and bottom.
- Pick 2-3 x positions (left edge, centre, 60%) and reuse them in every scene. Left-aligned
  blocks read better than centred paragraphs; centre only short titles.
- One element per scene is fine; whitespace is the cheapest design tool.
- Line height 1.2-1.35x the size (`line_height = 1.3` or measured lines); gaps between groups
  2x the line gap.
- Keep layout numbers in one `ui.lua` module (margins, grid, palette, fonts) that every scene
  requires: consistency comes for free.

## Typography

- One family, two at most (a display face for titles, a text face for body). DM Sans,
  Instrument Serif, Bebas Neue and JetBrains Mono are built in; copy any other font's files
  into `media/`. `inspect` reports missing families and glyphs.
- Sizes at 1920x1080: hero 140-200, title 96-120, subtitle 44-56, body 44-60, caption 28-34;
  never below 28 px. Portrait at 1080 wide uses about the same pixel sizes.
- Weights: titles 600-800, body 400-500 (the nearest available weight is drawn: DM Sans is
  built in at 400, 500 and 700, JetBrains Mono at 400 and 700; ship other weights in
  `media/`). Letter spacing `-1` to `-3` on big titles, `+2` to `+6` on small caps
  labels.
- At most ~8 words per line and ~3 lines per card. Wrap with `text_lines{ max_width = ... }`;
  shrink to fit once at load:

```lua
local function fit_size(str, font, max_w, size, min_size)
  while size > min_size and text_width { str, font = font, size = size, weight = 700 } > max_w do
    size = size - 2
  end
  return size
end
local TITLE = "Ship it on Friday"
local TITLE_SIZE = fit_size(TITLE, "DM Sans", 1600, 160, 72)   -- at load, once
```

- Numbers that change (counters, timers) need tabular figures or a monospace font, and
  `align = "right"`, so digits don't jiggle.

## Colour

- A background, a foreground (text), one accent, one or two supporting tints. Define them
  once (`ui.BG`, `ui.TEXT`, `ui.ACCENT`, `ui.DIM`).
- Contrast: body text at least 4.5:1 against what is behind it, gradients included; check
  suspicious frames at full size.
- Glows and soft shadows: `bloom = {...}` on `group{}` or `view3d{}` (what is bright glows), `group{ blur = n }` under a sharp copy, or `shadow = {...}`; they
  are cheap on small elements because effect layers are content-sized.

## Motion

`animate(f, keys)` is the default for every value with fixed timing. Good easing presets:

```lua
local SPRING_SNAPPY = spring { mass = 1, stiffness = 300, damping = 26 }   -- UI-like, tiny overshoot
local SPRING_SOFT   = spring { mass = 1, stiffness = 150, damping = 18 }   -- noticeable, friendly
local SPRING_BOUNCY = spring { mass = 1, stiffness = 220, damping = 12 }   -- playful, use rarely
local EASE_OUT_EXPO = cubic_bezier(0.16, 1, 0.3, 1)                        -- fast then settles: slides
local EASE_IN_OUT   = cubic_bezier(0.65, 0, 0.35, 1)                       -- camera moves, morphs
```

Starting rules for lively motion:
- Enter with a spring or ease-out from a short distance (40-120 px) plus opacity 0 -> 1.
  Exit faster with ease-in, to a shorter distance or just opacity.
- Stagger related items by 60-120 ms (list rows, words; letters 20-40 ms).
- Animate transforms and opacity on a wrapping group; not font sizes or layout.
- Scale from 0.9-0.96, not from 0. Rotation within ±6°.
- One focal movement at a time; secondary elements move less and later.
- Ambient loops (`animate_loop`) are long (6-12 s) and small.

### Recipes

Staggered title and subtitle (the subtitle follows by 90 ms):

```lua
local function rise(f, at, dist)
  local y = animate(f, { { start = at, from = dist, to = 0, easing = spring { stiffness = 150, damping = 18 } } })
  local a = animate(f, { { start = at, stop = at + 0.3, from = 0, to = 1, easing = ease_out } })
  return translate(0, y), a
end

scene { "Title", duration = 4, render = function(f)
  local t1, a1 = rise(f, 0.4, 60)
  group({ transform = t1, opacity = a1 }, function()
    text { "Shader mode", x = 160, y = 460, font = "DM Sans", size = 120, weight = 700, fill = "#fff" }
  end)
  local t2, a2 = rise(f, 0.49, 40)
  group({ transform = t2, opacity = a2 }, function()
    text { "Made with onimite", x = 160, y = 550, font = "DM Sans", size = 48, fill = "#94a3b8" }
  end)
end }
```

- **Word-by-word reveal**: split the line into words, measure each with `text_width` at load
  (plus a space width), place them at accumulated x, and give word `i` the `rise` above at
  `0.3 + i * 0.05`.
- **Counter** (0 -> 12,480): `animate` a number with `EASE_OUT_EXPO` over 1.2-1.8 s, format
  with thousands separators, monospace or tabular digits, `align = "right"`.
- **Growing bar**: animate `w` from a small positive value (zero-size rects are reported) to
  its target with `EASE_IN_OUT`.
- **Line draw-on**: `path_length = 1, stroke_dasharray = {1, 1}` and animate
  `stroke_dashoffset` 1 -> 0.
- **Cross-fade**: `overlap = { previous = 0.4 }` on the incoming scene, fade it in over
  0.4 s and fade the outgoing scene out over its last 0.4 s
  (`animate(f, { { start = f.scene.duration - 0.4, stop = f.scene.duration, from = 1, to = 0 } })`). A **push** moves
  the outgoing scene -80 px while the incoming comes from +80 px.
- **Lower third**: a bar slides in from the left (`EASE_OUT_EXPO`, 0.5 s), the name fades up
  0.15 s later, the role 0.1 s after that, hold, then everything exits together in 0.25 s.
- **Glitch cut**: for 2-3 frames after a cut, draw the scenes several times in horizontal
  clipped bands shifted sideways by a hash of the frame index (`examples/why_onimite/video.lua`,
  `energy`).

## Beat-synced motion

Music makes a video feel edited. Put the tempo and every cue in one place that the scenes
and the audio both read, in beats, so changing the BPM or moving a hit moves picture and
sound together. The pattern of `examples/why_onimite` (and `suite`, `motion_poster`, `data_story`):

```lua
-- beat.lua: the clock
local M = {}
M.FPS, M.BPM = 60, 120
M.BEAT = 60 / M.BPM                                         -- seconds per beat
function M.beat_frame(b) return math.floor(b * M.BEAT * M.FPS + 0.5) end   -- cuts never drift
function M.gbeat(f) return f.global_index / M.FPS / M.BEAT end            -- position on the grid
function M.pulse(b, sharp) return b < 0 and 0 or math.exp(-(b - math.floor(b)) * sharp) end
return M
```

```lua
-- timeline.lua: where things happen, in beats (4 beats a bar)
return {
  TITLE = 0, MAIN = 16, OUTRO = 32, TOTAL = 40,
  TITLE_SLAM = 4,           -- the hit inside the title section
  ITEMS = { 1, 2, 3, 4 },   -- list rows pop on these beats of MAIN
}
```

```lua
-- video.lua
local beat, T = require("beat"), require("timeline")
video { width = 1920, height = 1080, fps = beat.FPS, background = "#0b0d12",
  audio = { { "music.mp3", start = 0, fade_out = 1 } },
  render = function(f)
    local b = beat.gbeat(f)
    local pump = 1 + 0.01 * beat.pulse(b, 8)                     -- the picture breathes on the kick
    group({ transform = scale(pump, pump, 960, 540) }, function() render_scenes(f) end)
  end }

local function section(name, from, to, render)
  scene { name, duration = { frames = beat.beat_frame(to) - beat.beat_frame(from) },
    render = function(f) render(f, beat.gbeat(f) - from) end }  -- lb: local beat in the section
end

section("Title", T.TITLE, T.MAIN, function(f, lb)
  local s = lb < T.TITLE_SLAM and 0.9 or 0.9 + 0.1 * ease(spring { stiffness = 320, damping = 22 },
    (lb - T.TITLE_SLAM) * beat.BEAT)
  group({ transform = scale(s, s, 960, 540) }, function()
    text { "ON THE BEAT", x = 960, y = 580, align = "center", font = "DM Sans", size = 160, weight = 700, fill = "#fff" }
  end)
end)
```

- Sections are whole bars (multiples of 4 beats); scene durations come from `beat_frame`
  differences so rounding never accumulates.
- Cuts on the downbeat of a bar; entrances, pops and counter ticks on beats; springs released
  on a beat (`ease(spring, (lb - hit) * BEAT)`, 0 before the hit).
- A decaying `pulse` (scale 1.005-1.01, a flash rectangle at low opacity, a HUD dot) adds
  energy without moving the layout. Use it only where the kick plays.
- With a supplied music file, find its BPM and the offset of beat 0 (ask the user, read
  it from the file name, or look at `onimite audio analyze --waveform w.png` for the kick
  pattern) and add the offset in `gbeat`. Check alignment with `audio at` on a cue time and a
  `frame` of the same time.

### An original soundtrack composed with song{}

When no music is supplied (or licensing matters), compose it with `song{}` (audio.md, "Songs and
sounds"), and let the picture follow the song, so every hit is on the music by construction:

1. `track.lua` returns the song: sections named after the scenes (`duration = "4m"`, `style`,
   `energy`, `chords`, a `transition` for risers and impacts), and parts for what the picture
   answers to (a crash on each scene's downbeat, a blip per item that appears).
2. The timeline reads it back: `score.time("race")` for a scene's start, `score.hits { part =
   "ticks", range = "bill" }` for the beats something lands on, `score.snap(t, "8n")` to put a
   computed time on the grid. Scenes start on their sections (`section = "race"`), so `inspect`
   catches a scene that slides off.
3. `video.lua` lists `{ score, start = 0 }` in `audio`; `audio_energy` and `audio_spectrum`
   read it like any track. Sound effects are `sound{}` tracks on their own bus.
4. Set `seed` so every render makes the same music.

`examples/why_onimite/track.lua` (140 BPM, A minor, house into acid) is a complete song to copy
from; `examples/suite/track.lua` is synthwave in D minor; `examples/onimite_saga/music/` is a
long one with tempo ramps, a section per scene. Tell the user the music is composed and offer
to swap in a real track.

## Review checklist

Run `strip` for every scene and `frame` for the key moments, then check:

- [ ] Nothing important within the outer 8% (or the portrait UI areas).
- [ ] Text fits its box and the canvas (cards and panels have a group `box`, so `inspect`
      checks them); no line over ~8 words; nothing below 28 px.
- [ ] Every text stays long enough to read (3 words/s + 1 s after it settles).
- [ ] One thing draws the eye at a time; entrances are staggered.
- [ ] Margins, alignment and colours are consistent across scenes.
- [ ] Contrast is enough on every background, gradients included.
- [ ] Transitions have no empty or flashing frame (`Scene@end`, the next scene's first frame,
      an `onion` of the transition).
- [ ] The first frame is not blank for social formats.
- [ ] With music: cuts land on bars, hits on beats (`inspect` clean of `cue_*`, or `audio at` + `frame` at a cue).
- [ ] `inspect` is clean; audio levels fit (see audio.md).
