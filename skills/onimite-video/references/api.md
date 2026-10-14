# onimite Lua API

The core script API (`script/*.odin` are the bindings, `script/std.lua` the standard library).
Snippets that are not whole scripts run inside a `render = function(f) ... end`. File names
(`photo.jpg`, `bird.svg`, `music.mp3`, ...) stand for files in your `media/`.

The rest is in topic files; read one when the video needs it:

| file | |
| --- | --- |
| [audio.md](audio.md) | tracks, mixing, loudness, onsets and the beat, spectra, generated audio |
| [media.md](media.md) | SVG documents, Lottie, video clips, subtitles, word-level captions |
| [shaders.md](shaders.md) | SkSL, Shadertoy and GLSL shaders, multipass passes in any dialect |
| [filters.md](filters.md) | SVG filter primitives on groups |
| [problems.md](problems.md) | every problem code and `--json` field |

## Video and scenes


```lua
video {
  width = 1920, height = 1080, fps = 30,     -- integer fps
  background = "#0b0d12",                    -- painted under every frame (default black)
  duration = 12,                             -- optional: default = the scenes' total
  audio = { { "music.mp3", start = 0, gain_db = -10, fade_out = 2 } },  -- see audio.md
  master_gain_db = 0,                        -- master bus gain before the limiter
  limiter = { ceiling_db = -1 },             -- default -1 dBFS; `limiter = false` turns it off
  render = function(f)                       -- optional video-level pass
    rect { x = 0, y = 0, w = f.width, h = f.height, fill = "#0b0d12" }
    render_scenes(f)                         -- draws the active scene(s)
  end,
}

scene { "Intro", duration = 3, render = function(f)
  text { "Intro " .. f.index, x = 160, y = 540, font = "DM Sans", size = 96, fill = "#fff" }
end }

scene { "Main", duration = 5, overlap = { previous = 0.5 },
  audio = { { "pop.wav", start = 1.0, gain_db = -10 } },   -- scene-relative
  render = function(f)
    local info = f.scene                     -- name, index, start_frame, end_frame, frames, duration, is_last
    text { info.name, x = 160, y = 540, font = "DM Sans", size = 96, fill = "#fff",
      opacity = animate(f, { { start = 0, stop = 0.5, from = 0, to = 1 } }) }
  end }
```

- Without a video `render`, a frame is the background plus the active scenes.
- `start = t` (video seconds) lands the scene at `t` instead of right after the previous one:
  put scenes on cues (`start = clock.time(32)`). Without a `duration` the scene lasts until the
  next scene's `start` (the last one until the video's `duration`). A transition or
  `overlap.previous` reaches back from `t`, and the scene's own clock starts where it first
  appears: with a 0.5 s transition, `f.seconds` is 0.5 at `t`.
- Durations: seconds, `{ frames = 90 }`, `{ seconds = 10, minus = { frames = 15 } }`,
  `{ audio = "vo.wav" }` (the file's length), `{ video = "clip.mp4", plus = { seconds = 2 } }`,
  or a list of these (summed).
- `overlap = { previous = p, next = n }` extends the scene into its neighbour by `p` / `n`
  seconds (a cross-fade window), **added to** `duration`: with `previous = 0.5` the scene
  starts 0.5 s before the previous one ends and runs `duration + 0.5` s. To land scene `i`
  on cue `c[i]` after a 0.5 s transition, use `duration = c[i+1] - c[i]` and
  `overlap = { previous = 0.5 }`. Check with `timeline`.
- The frame `f`: `index`, `seconds` (scene-relative inside a scene), `global_index`,
  `global_seconds`, `fps`, `width`, `height`, and `scene` inside a scene. Functions about the
  thing you are in (`animate(f, ...)`, clips, Lottie, shaders, captions) read `f.seconds`;
  things that live on the video (beat clocks, placed audio tracks) read `f.global_seconds`
  themselves, so pass `f` to both.
- `scene_info("Main")` (while rendering) returns the same table as `f.scene` for any scene,
  or nil.
- Scenes are named by their first entry (or `name =`); the CLI addresses them by it.
- `cue = "drop"` on a scene: its first frame lands on that cue (see Cues).

## Animation


```lua
-- keys: { start, stop, from, to, easing } (seconds on f's clock)
local x = animate(f, {
  { start = 0.0, stop = 0.6, from = -200, to = 0, easing = ease_out },   -- slide in
  { start = 2.4, stop = 2.7, from = 0, to = 200, easing = ease_in },     -- slide out
})
local c = animate(f, { { start = 0, stop = 1, from = "#0ea5e9", to = "#f472b6" } })  -- colours
local p = animate(f, { { start = 0, stop = 1, from = { 100, 100 }, to = { 300, 200 }, easing = ease_in_out } })  -- {x, y}: p[1], p[2] (also p.x, p.y)
local t = animate(f, { { start = 0, from = translate(0, 80), to = translate(0, 0), easing = spring { stiffness = 180, damping = 20 } } })
local wobble = animate_loop(f, { { start = 0, stop = 3, from = -4, to = 4, easing = ease_in_out }, { start = 3, stop = 6, from = 4, to = -4, easing = ease_in_out } })
group({ transform = t }, function()
  rect { x = 160 + x, y = 300, w = 240, h = 120, rx = 20, fill = c,
    opacity = animate(f, { { start = 0, stop = 0.3, from = 0, to = 1 } }) }
  circle { cx = p[1], cy = p[2] + wobble, r = 20, fill = "#fff" }
end)
```

- The value type follows the first key's `from`: number, colour, `{x, y}` or transform.
- Before the first key the value is its `from`; in a gap it holds the previous `to`; after the
  last key it stays at the last `to`.
- `stop` omitted: until the next key's `start`; on the last key a spring runs until it settles
  (an explicit `stop` cuts it), other easings jump to `to` at `start` (`inspect` warns; write
  `stop = start` for a deliberate jump).
- `cue = "drop"` on a key: its start lands on that cue (see Cues).
- `animate(seconds, keys)` also takes a plain time instead of `f` (e.g. a video-time clock
  inside a scene: `animate(f.global_seconds, keys)`).
- `animate_loop` repeats the keys' span (first `start` to last `stop`) forever.

### Easing

```lua
local e1 = ease_out                         -- Odin cubic: ease_in, ease_out, ease_in_out (t^3 curves)
local e2 = linear                           -- the default when easing is omitted
local e3 = cubic_bezier(0.16, 1, 0.3, 1)    -- CSS-style; fframes' EaseOut = cubic_bezier(0, 0, 0.58, 1)
local e4 = spring { mass = 1, stiffness = 300, damping = 26 }   -- or spring(1, 300, 26)
local e5 = easing.back_out                  -- Odin core:math/ease, lowercase
local v = animate(f, { { start = 0, stop = 0.8, from = 0, to = 1, easing = e3 } })
-- runtime-started tween: eased progress t seconds after an event, over `duration`
local hit = 1.2
local k = ease(e4, f.seconds - hit, 0.5)   -- 0 before the hit; springs ignore the duration
text { string.format("%.2f %.2f", v, k), x = 100, y = 200, font = "DM Sans", size = 48, fill = "#fff" }
```

`easing.*` names: `linear`, `quadratic_in/out/in_out`, `cubic_*`, `quartic_*`, `quintic_*`,
`sine_*`, `circular_*`, `exponential_*`, `elastic_*`, `back_*`, `bounce_*` (each with `_in`,
`_out`, `_in_out`). `ease_in`/`ease_out`/`ease_in_out` equal `easing.cubic_in`/... and are
steeper than fframes' CSS curves; use `cubic_bezier(0.42, 0, 1, 1)`, `(0, 0, 0.58, 1)`,
`(0.42, 0, 0.58, 1)` to match fframes exactly. `ease(e, t, d)` clamps `t` to `0..d` (springs: `t < 0` gives 0; they
ignore `d` and run until they settle).

### Transforms

```lua
local a = translate(100, 50)
local b = scale(1.2)                        -- scale(sx, sy, ox, oy) scales about (ox, oy)
local c = rotate(15, 960, 540)              -- degrees, about (ox, oy)
local d = skew(10, 0)                       -- skew(x_deg, y_deg, ox, oy)
local e = { translate = { 100, 0 }, scale = 1.1, rotate = 5, origin = { 960, 540 } }  -- scale, skew, rotate about origin, then translate
local m1 = { matrix = { 1, 0, 0, 1, 40, 20 } }                 -- SVG matrix a b c d e f
local m2 = "translate(960 540) rotate(30) scale(2) translate(-960 -540)"  -- SVG transform list (string)
for i, tf in ipairs { a, b, c, d, e, m1, m2 } do
  group({ transform = tf, opacity = 0.3 }, function()
    rect { x = 900, y = 500, w = 120, h = 80, fill = "#38bdf8" }
  end)
end
```

Transform tables also take `skew_x` / `skew_y` for `skew = {x, y}`. Transforms animate
component-wise (matrices too). Scale or rotate about a point with the
origin arguments rather than translating by hand.

## Composition helpers (standard library)


Plain Lua (`script/std.lua`, loaded before every script), after Remotion's `<Sequence>`,
`<Series>`, `<Loop>`, `<Freeze>`, `@remotion/transitions` and GSAP's staggers.

```lua
-- sequence(f, from, dur, fn): fn(g) only while from <= f.seconds < from + dur (dur nil:
-- open-ended). g is a copy of f with a local clock: g.seconds = f.seconds - from, g.index
-- to match, g.progress = local / dur. global_* fields stay on the video clock.
sequence(f, 0.5, 2, function(g)
  local y = animate(g, { { start = 0, stop = 0.4, from = 60, to = 0, easing = ease_out } })       -- keys from 0, not 0.5
  text { "Title", x = 160, y = 300 + y, font = "DM Sans", size = 96, fill = "#fff" }
  sequence(g, 0.6, nil, function(h)                            -- nested: 1.1 s into f
    rect { x = 160, y = 330, w = 600 * math.min(h.seconds / 0.5, 1), h = 6, fill = "#38bdf8" }
  end)
end)

-- series(f, { {dur, fn}, ... }): back-to-back sequences; the last dur may be nil
series(f, {
  { 1.5, function(g) text { "one", x = 160, y = 540, size = 96, fill = "#fff" } end },
  { 1.5, function(g) text { "two", x = 160, y = 540, size = 96, fill = "#fff" } end },
  { nil, function(g) text { "three", x = 160, y = 540, size = 96, fill = "#fff" } end },
})

loop(f, 2, function(g)        -- g.seconds wraps every 2 s; g.progress 0..1, g.iteration 0, 1, ...
  circle { cx = 200 + 400 * g.progress, cy = 900, r = 20, fill = "#f472b6" }
end)

freeze(f, 1.2, function(g)    -- g's clock stopped at 1.2 s (clips, shaders, animate all read it)
  video_frame(g, { src = "clip.mp4", x = 960, y = 100, w = 800, h = 450 })
end)

-- stagger(i, each, opts): the start offset of item i (1-based) for animate / ease
for i = 1, 7 do
  local d = stagger(i, 0.08, { n = 7, from = "center" })   -- from = "start" (default) | "end" | "center" | an index
  local s = ease(spring { stiffness = 260, damping = 18 }, f.seconds - 0.3 - d)
  if s > 0 then circle { cx = 360 + i * 150, cy = 540, r = 40 * s, fill = "#38bdf8" } end
end
-- opts.amount = total spread instead of `each`; opts.easing spaces the starts (n needed)
local d2 = stagger(3, nil, { n = 7, amount = 0.6, easing = ease_in })
```

```lua
-- math helpers (plain Lua): lerp, clamp(x, lo, hi), clamp01, progress, remap, smoothstep(a, b, x),
-- fract, round (half away from zero), sign, hash(n, seed) (a repeatable random 0..1: use it,
-- not math.random, so every frame builder agrees); and native noise / colour mixing
local x = lerp(100, 900, ease(ease_out, f.seconds, 2))
local p = progress(f.seconds, 1, 3)          -- 0..1 between 1 s and 3 s (clamped)
local y = remap(f.seconds, 0, 4, 200, 800)   -- 0..4 s mapped to 200..800
local wobble = noise(f.seconds * 0.5, 7) * 20   -- smooth -20..20 drift
local tint = mix_color("#ff0040", "#00c8ff", p) -- even OKLab blend; "linear"/"srgb" too
circle { cx = x + wobble, cy = y, r = 40, fill = tint }
```

```lua
-- beat_clock(bpm, offset, per_bar): offset = seconds where beat 0 falls (0), per_bar = 4
local clock = beat_clock(120)
local b = clock.beat(f)                   -- beats on the video clock (from a frame or video seconds)
local bar = clock.bar(f.global_seconds)   -- fractional bars
local hit = clock.time(8)                 -- seconds where beat 8 falls (4.0)
local len = clock.seconds(4)              -- how long 4 beats last (2.0)
local frames = clock.frame(16, f.fps)     -- frame of beat 16 (rounded): scene durations on the grid
local kick = clock.pulse(f, 8)            -- 1 on each beat, decaying (= pulse(b, 8))
-- pulse(x, sharpness): 1 at every whole x, decaying; 0 for x < 0. pulse(b / 4, 6): per bar
group({ transform = { scale = 1 + 0.01 * kick, origin = { 960, 540 } } }, function()
  text { string.format("bar %d", math.floor(bar) + 1), x = 960, y = 540, align = "center",
    font = "DM Sans", size = 96, fill = "#fff" }
end)
```

### Transitions

```lua
-- transition(kind, p, a, b, opts): the switch from a() to b() at progress p (clamped 0..1);
-- p = 0 draws only a, p = 1 only b; either may be nil. opts.x/y/w/h: the area (default the
-- whole video). Kinds and their options:
--   "fade"        a fades out, b fades in
--   "slide"       b pushes a out; from = "right" (default) | "left" | "top" | "bottom"
--   "wipe"        an edge reveals b; from = "left" (default) | ...; softness = edge px (0)
--   "clock_wipe"  a hand sweeps clockwise from 12 o'clock
--   "zoom"        a grows past the viewer and fades, b grows into place; scale = 1.4
--   "glitch"      bands jump sideways, switching to b one by one; bands = 12, amount = 0.12
local p = ease(ease_in_out, f.seconds - 2, 0.6)
transition("wipe", p,
  function() image { src = "before.jpg", x = 0, y = 0, w = 1920, h = 1080, fit = "cover" } end,
  function() image { src = "after.jpg", x = 0, y = 0, w = 1920, h = 1080, fit = "cover" } end,
  { from = "left", softness = 200 })
```

```lua
-- Between scenes: `transition = { kind, duration, easing, options }` on the entering scene.
-- Its overlap.previous defaults to the duration (0.5): the scene starts that much early and
-- enters by the transition while the previous scene leaves by the same one.
scene { "A", duration = 3, render = function(f) rect { x = 0, y = 0, w = 1920, h = 1080, fill = "#0f766e" } end }
scene { "B", duration = 3, transition = { "slide", from = "bottom", duration = 0.6,
  easing = spring { stiffness = 120, damping = 20 } },
  render = function(f) rect { x = 0, y = 0, w = 1920, h = 1080, fill = "#7c3aed" } end }
```

- Implemented with groups (clip, opacity, transform), masks and clip paths. The overlap
  window is both scenes' overlap (previous of the entering one plus next of the leaving one).
  Timing goes through `ease(easing, t, window)`: pick a spring that settles inside it.
- Draw opaque backgrounds inside each scene for slides, wipes and zooms; on a transparent
  scene the video background shows through the moved-out area.
- `examples/transitions` shows every kind.

## Cues

Name the moments picture and sound should share with `cue(name, t)`, put `cue = "name"` on
what should land there (scenes, audio tracks, animate keys), and `inspect` reports whatever
drifts off its cue (a scene pushed late by an overlap, a sound file moved, a key left on old
numbers):

```lua
local MUSIC_AT = 2.0
local o = audio_onsets("music.mp3")            -- see audio.md: hit times and the beat
local beats = {}
for i = 1, #o.beats, 2 do beats[#beats + 1] = MUSIC_AT + o.beats[i] end   -- every second beat
cue("beat", beats)                             -- beat[0], beat[1], ...: video seconds
local DROP = cue("drop", 47.6)                 -- returns the time it names
cue("hit", 12.0, { hit = "music.mp3" })        -- also expects a sound of that track to start there

video { width = 1920, height = 1080, fps = 30,
  audio = { { "music.mp3", start = MUSIC_AT }, { "boom.wav", start = DROP, cue = "drop" } } }
scene { "Title", cue = "drop", duration = 3, render = function(f)
  local s = animate(f.global_seconds, { { start = DROP, stop = DROP + 0.4, from = 0.8, to = 1, easing = ease_out, cue = "drop" } })
end }
```

- A cue is a time on the video clock; a list makes `name[0]`, `name[1]`, ... What lands on it:
  a scene's first frame, a track's first sound (the file's first onset after `offset`), a key's
  `start` on the video clock.
- `inspect` warns `cue_drift` when something is more than a frame off its cue (30 ms when a
  sound is involved), `cue_alone` for a cue name only one thing carries and no `cue()` defines
  (a typo), `cue_no_hit` when a `hit` cue has no sound there. A family off by one amount is one finding
  (`cue "beat[*]": 24 of 24 animate keys: -0.500s off their cues`). Nothing prints when all
  meet.
- Derive times from the same numbers (`DROP`, `MUSIC_AT + o.beats[i]`): moving the music then
  moves everything. Tags catch the places that kept old numbers.
- Cues are times on the command line: `frame video.lua drop`, `audio at video.lua beat[3]`,
  `strip video.lua drop..beat[8]`, with an offset `frame video.lua drop@0.5s,drop@-6`.
  `timeline` lists them (a scene's on its own line).
- Spoken words: `say_cue(line, at, word, { name, nth })` names the moment a `say()` line,
  its track starting at `at`, says `word` (its text, or its index in `line.words`) and
  returns that video time; the cue has `hit = line.name`, so `inspect` checks the voice
  starts there. Put keys and effects that answer the voice on these (audio.md, "Spoken
  lines"):

  ```lua
  local line = say("intro", "Up top, the lamp was dark.")
  local DARK = say_cue(line, 1.0, "dark")               -- cue "dark"
  -- { "thud.wav", start = DARK, cue = "dark" }, animate keys { start = DARK, ..., cue = "dark" }
  ```

## Physics

`physics{}` simulates rigid bodies (Box2D) once, at load, and returns plain data: what falls,
bounces, tumbles, stacks, swings and gets knocked over, with the impacts as times for sound.
Nothing steps per frame (frames build out of order and in parallel); `render` samples the
result with `physics_at`. Call it inside `shared` so a render simulates it once, not once per
frame builder:

```lua
local sim = shared("drop", function()
  return physics { duration = 4, gravity = 2600, bodies = {           -- gravity: px/s² down, or { gx, gy }
    { static = true, layer = "walls", box = { 1920, 40 }, x = 960, y = 1020 },   -- the floor
    { name = "tile", box = { 120, 120 }, x = 600, y = -120, angle = 5, start = 0.3, bounce = 0.2 },
    { name = "ball", circle = 60, x = -300, y = 500, density = 20, start = 2, ignores = { "walls" }, leaves = true },
    { name = "bar", kinematic = true, box = { 300, 20 }, move = function(t) return 400 + 200 * t, 800, 0 end },
    { polygon = { -40, 30, 0, -40, 40, 30 }, x = 1200, y = -60 },     -- convex hull, 3 to 8 points
  },
  joints = { { "rope", b = "ball", from = { 300, -400 } } },          -- no `a`: hung from the world
  kicks = { { t = 3, body = "tile", vx = 600, vy = -900, spin = 360 } } }
end)

local pops = {}                                -- a pop per impact, louder for harder hits
for _, c in ipairs(sim.contacts) do
  if c.speed > 300 then pops[#pops + 1] = { "pop.wav", start = c.t, gain_db = remap(c.speed, 300, 2500, -26, -8) } end
end

scene { "Drop", duration = 4, audio = pops, render = function(f)
  local x, y, angle = physics_at(sim, "tile", f.seconds)   -- its centre and angle (degrees)
  group({ transform = { translate = { x, y }, rotate = angle } }, function()
    rect { x = -60, y = -60, w = 120, h = 120, rx = 16, fill = "#38bdf8" }   -- drawn about its centre
  end)
end }
```

- Options: `duration` (seconds simulated, required), `gravity` (2000), `rate` (60 steps a
  second), `hit_speed` (100: the slowest impact, px/s, that counts as a contact), `bodies`,
  `joints`, `kicks`. Lengths are canvas pixels, angles degrees (clockwise), times seconds
  on the simulation's clock.
- A body: one shape, `box = { w, h }`, `circle = r` or `polygon = { x1, y1, ... }` (about its
  centre); `name` (refer to it by name anywhere a body is asked for), `x`, `y` (its centre),
  `angle`, `vx`, `vy` (px/s), `spin` (degrees/s), `bounce` (restitution, 0), `friction` (0.6),
  `density` (1), `gravity_scale` (1), `damping`, `spin_damping`, `bullet = true` (no
  tunnelling through other moving bodies: fast, small ones).
  - Kinds: dynamic (the default), `static = true` (never moves; without a shape, an anchor),
    `kinematic = true` (pushes, is not pushed): `move = function(t) return x, y, angle end`
    puts it there every step (e.g. from `animate(t, keys)`).
  - Time: `start` (it waits, frozen and touching nothing, until then; then launches with its
    velocity), `stop` (it is removed then), `asleep = true` (it floats where it is, ignoring
    gravity, until something hits it).
  - `layer = "name"` and `ignores = { "name", ... }`: a body passes through the layers it
    ignores (the default layer is `""`), e.g. a ball that swings in through the frame's walls.
- Joints, `{ kind, a = body, b = body, ... }`, anchors in canvas pixels; a missing `a` or `b`
  is the world. `"hinge"` (`at`, default b's centre; `limit = { lo, hi }` degrees, `motor =`
  degrees/s with `torque`), `"weld"` (`at`), `"rod"` (fixed length), `"rope"` (slack up to its
  length), `"spring"` (`hertz` 4, `damping` 0.5): these three join `from` (on a, default its
  centre) to `to` (on b, default its centre), `length` defaulting to their distance. Joined
  bodies pass through each other unless `collide = true`.
- Kicks: `{ t, body, vx, vy, spin }` add to its velocity at `t` (the same for any mass).
- The result: `sim.bodies[i] = { name, settled, moving }` (`settled`: when it came to rest
  for good, nil if it never did; `moving`: it still moved at the end), `sim.names[name] = i`,
  `sim.contacts = { { t, a, b, x, y, speed }, ... }` in time order (`a`, `b` body indices, the
  point, the approach speed in px/s), and `sim.tracks`: the poses, a step each, kept natively
  once per render (every frame builder reads the same copy).
- `physics_at(sim, i, t)` (an index or a name) -> x, y, angle: interpolates between steps and
  holds the ends (angles unwrapped: a rolling wheel keeps counting); `t` is the clock the
  simulation started on (usually the scene's `f.seconds`).
- Timing to the music: simulate, read when things land in `contacts`, move their `start`s by
  how far each missed its beat, and simulate again (a few passes inside `shared`) — the saga's
  NotNeeded scene lands every drop on an eighth note and the smash on a beat.
- Looking at it: `onimite show video.lua bodies` lists every body the load simulated, where
  it starts and ends and whether it still moves at the end; `body/tile` shows one (its
  fields and the line of its `physics{}` call). A body without a `name` is `#i`, its place
  in `bodies` (`body/#3`), and so it is in warnings; when two simulations have a body of
  the same name, the paths are `body/tile[0]`, `body/tile[1]`. Name the bodies you will
  look at or ask about.
- Checks, with the other problems in `inspect` (problems.md): `physics_overlap` (a body
  starts inside another and they fly apart), `physics_offscreen` (a body leaves the canvas
  for good; `leaves = true` when it should), `physics_unsettled` (a frame samples past the
  end while a body still moves: simulate longer).
- Same script, same result: it runs on one thread at load, so renders and previews agree.
  Values computed inside `shared`'s function exist only in the state that ran it: compute
  what `render` needs (spawn times, sizes) outside it, from the same numbers or from the
  returned `contacts`.
- Examples: `examples/physics_demo` (tiles dropped into a word, a ball lobbed along them);
  `examples/onimite_saga/scenes/not_needed.lua` (a stack knocked down by a wrecking ball on a
  rope, the thuds placed from `contacts`); `examples/why_onimite/scenes/ship.lua` (311 crates
  poured into a bin as grains, counters counting what has landed, the soundtrack placing a
  tick per landing).

## Nodes


```lua
rect { x = 100, y = 100, w = 400, h = 200, rx = 24, ry = 24, fill = "#1e293b",
  stroke = "#38bdf8", stroke_width = 4 }
circle { cx = 800, cy = 200, r = 80, fill = "#f472b6", fill_opacity = 0.8 }
ellipse { cx = 1100, cy = 200, rx = 120, ry = 60, fill = "#a3e635" }
line { x1 = 100, y1 = 400, x2 = 600, y2 = 400, stroke = "#fff", stroke_width = 6, line_cap = "round" }
path { d = "M700 350 C 800 250, 900 450, 1000 350 S 1200 250, 1300 350", stroke = "#facc15",
  stroke_width = 8, line_join = "round" }
path { d = "M100 500 h300 v300 h-300 Z M175 575 h150 v150 h-150 Z", fill = "#e2e8f0", fill_rule = "evenodd" }
polygon { points = { 600, 800, 700, 550, 800, 800 }, fill = "#22d3ee" }          -- or {{x, y}, ...}
polyline { points = { { 900, 800 }, { 1000, 600 }, { 1100, 750 } }, stroke = "#fb7185", stroke_width = 5 }
```

Shared shape style: `fill`, `fill_opacity`, `stroke`, `stroke_width` (1 when `stroke` is
set), `stroke_opacity`, `line_cap` (`butt|round|square`), `line_join` (`miter|round|bevel`),
`miter_limit`, `stroke_dasharray`, `stroke_dashoffset`, `path_length`, `opacity`, and
`shape_rendering = "crispEdges"` (no anti-aliasing, for pixel art). `w`/`h` also accept
`width`/`height`.

### Dashes and draw-on

```lua
local draw = animate(f, { { start = 0, stop = 1.2, from = 1, to = 0, easing = cubic_bezier(0.65, 0, 0.35, 1) } })
path { d = "M200 300 C 500 100, 800 500, 1100 300", stroke = "#38bdf8", stroke_width = 10,
  line_cap = "round", path_length = 1, stroke_dasharray = { 1, 1 }, stroke_dashoffset = draw }
line { x1 = 200, y1 = 500, x2 = 1100, y2 = 500, stroke = "#94a3b8", stroke_width = 4,
  stroke_dasharray = { 24, 12 }, stroke_dashoffset = -f.seconds * 60 }   -- marching ants
```

`path_length = 1` makes dash units fractions of the path, so offset 1 -> 0 draws it on.

### Large path data

```lua
-- at load: parse once per render, share across frame builders
local SHAPES = shared("shapes", function()
  local list = {}
  for i = 0, 99 do
    list[#list + 1] = path_data(string.format("M%d 100 l40 0 l-20 40 Z", 100 + i * 17))
  end
  return list
end)

video { width = 1920, height = 1080, fps = 30, duration = 2, render = function(f)
  for i, d in ipairs(SHAPES) do path { d = d, fill = "#38bdf8" } end
end }
```

`path_data(d)` returns a handle (parsed once, by content) that `path{ d = handle }` and
`clip_path` draw without re-parsing. `shared(name, fn)` runs `fn` once per render and gives
every frame builder a copy of its result (tables, strings, numbers, booleans, path handles;
not functions). `gunzip("data.gz")` returns a gzip file's contents (path relative to the
script), e.g. for compressed path archives. `examples/designer_handoff` draws an SVG on from
its own paths parsed once with `shared` + `path_data`.

## Groups


```lua
group({
  transform = translate(100, 0),
  opacity = 0.9,                            -- the group composited as a whole
  clip = { x = 0, y = 0, w = 800, h = 600, rx = 24 },  -- rectangle clip, rounded by rx (or {x, y, w, h})
}, function()
  rect { x = 0, y = 0, w = 1000, h = 700, fill = "#334155" }
end)

group({ clip_path = "M1000 100 L1400 100 L1200 500 Z", clip_rule = "nonzero" }, function()
  image { src = "photo.jpg", x = 1000, y = 100, w = 400, h = 400, fit = "cover" }
end)

-- mask: children show by the mask's luminance x alpha (mask_type = "alpha": alpha only)
group({ mask = function()
  rect { x = 100, y = 650, w = 600, h = 300, fill = linear_gradient {
    x1 = 100, y1 = 0, x2 = 700, y2 = 0, stops = { { 0, "#fff" }, { 1, "#000" } } } }
end }, function()
  rect { x = 100, y = 650, w = 600, h = 300, fill = "#f472b6" }
end)

-- box: what the children should stay in; not clipped, `inspect` reports what spills out
group({ box = { x = 100, y = 240, w = 540, h = 640, name = "card" } }, function()
  rect { x = 100, y = 240, w = 540, h = 640, rx = 36, fill = "#0a0c14" }
  text { "A title that might not fit", x = 136, y = 320, font = "DM Sans", size = 64, fill = "#fff" }
end)

group({ blur = 8 }, function() circle { cx = 1000, cy = 800, r = 80, fill = "#22d3ee" } end)
group({ shadow = { dx = 0, dy = 12, blur = 20, color = "#000", opacity = 0.5 } }, function()
  rect { x = 1300, y = 650, w = 300, h = 200, rx = 24, fill = "#f8fafc" }
end)
group({ blend = "screen" }, function() circle { cx = 1100, cy = 800, r = 80, fill = "#f472b6" } end)
group({ shape_rendering = "crispEdges" }, function() rect { x = 10.5, y = 10.5, w = 50, h = 50, fill = "#fff" } end)
```

Order of group effects is SVG's: filter, clip, mask, opacity. `blend`: all 16 CSS modes
(`multiply`, `screen`, `overlay`, `darken`, `lighten`, `color-dodge`, `color-burn`,
`hard-light`, `soft-light`, `difference`, `exclusion`, `hue`, `saturation`, `color`,
`luminosity`). Effect groups render into layers sized to their content, so blurring a small
element is cheap.

Filters (`filter = { ... }`, every SVG 1.1 primitive) are in [filters.md](filters.md).

## Paints


```lua
rect { x = 0, y = 0, w = 300, h = 100, fill = "#0ea5e9" }           -- "#rgb", "#rgba", "#rrggbb", "#rrggbbaa"
rect { x = 0, y = 120, w = 300, h = 100, fill = "rebeccapurple" }   -- CSS names, "rgb(..)", "hsl(..)", "transparent", "none"
rect { x = 0, y = 240, w = 300, h = 100, fill = rgba(255, 64, 0, 0.5) }   -- rgb(r, g, b) 0..255, alpha 0..1
rect { x = 400, y = 0, w = 600, h = 300, rx = 30, fill = linear_gradient {
  x1 = 0, y1 = 0, x2 = 1, y2 = 1, units = "bbox",             -- fractions of the shape's box
  stops = { { 0, "#22d3ee" }, { 0.5, "#a78bfa" }, { 1, "#f472b6cc" } } } }
circle { cx = 1300, cy = 160, r = 140, fill = radial_gradient {
  cx = 1300, cy = 160, r = 140, fx = 1250, fy = 110, fr = 0,     -- focal point and radius (inner_r = fr)
  stops = { { 0, "#fff" }, { 1, "#1e3a8a" } } } }
rect { x = 400, y = 350, w = 600, h = 120, fill = linear_gradient {
  x1 = 400, y1 = 0, x2 = 460, y2 = 0, spread = "reflect",        -- pad | reflect | repeat
  transform = "rotate(20 700 410)", stops = { { 0, "#facc15" }, { 1, "#ea580c" } } } }
rect { x = 1100, y = 350, w = 400, h = 300, fill = pattern {
  x = 0, y = 0, w = 40, h = 40, transform = rotate(45),
  content = function() circle { cx = 20, cy = 20, r = 8, fill = "#94a3b8" } end } }
```

An invalid colour string is an Error diagnostic while rendering (and a Lua error at load).
Gradients default to user space; `units = "bbox"` uses the shape's box. `pattern{}` must be
called while rendering. Stops take any colour (alpha included).

## Text


```lua
text { "Big title", x = 160, y = 300, font = "DM Sans", size = 120, weight = 700,
  letter_spacing = -2, fill = "#f8fafc" }
text { "centred", x = 960, y = 450, align = "center", baseline = "middle",    -- align: left|center|right
  font = "DM Sans", size = 64, fill = "#94a3b8" }
text { "Line one\nLine two", x = 160, y = 600, font = "DM Sans", size = 56, line_height = 1.3, fill = "#fff" }
text { x = 160, y = 850, font = "DM Sans", size = 64, fill = "#fff", spans = {
  { "Made with " },
  { "onimite", weight = 700, fill = "#38bdf8" },
  { " italic", font = "Instrument Serif", italic = true, dy = -6 },
} }
text { "OUTLINE", x = 1100, y = 300, font = "Bebas Neue", size = 160, fill = "none",
  stroke = "#f472b6", stroke_width = 3 }
```

- Fields: `x`, `y`, `font` (family name of a media font), `size` (16), `weight` (400,
  nearest available), `italic = true` or `style = "italic"`, `align`, `baseline =
  alphabetic|middle|central|hanging|top|bottom`, `letter_spacing`, `line_height` (a factor
  of size), `fill` (default black), `fill_opacity`, `stroke`, `opacity`, `spans`.
- Spans: `{ "text", font, size, weight, italic, fill, fill_opacity, letter_spacing, dx, dy }`.
- Shaped with kb_text_shape: ligatures, kerning, marks, Arabic joining, Indic scripts,
  right-to-left runs. Glyphs missing from a font fall back to other media fonts, then to the
  bundled Noto Color Emoji; glyphs no font has are reported by `inspect`. Drawn as vector
  outlines (sharp under any transform).
- Emoji just work: `text { "Launch day 🚀🔥 👩‍💻 🇯🇵", ... }` draws them in colour (vector
  COLR glyphs, crisp at any size), with ZWJ sequences, skin tones, flags, keycaps and `❤️`
  (U+FE0F) kept whole. `fill` alpha / `opacity` fade them; `fill` colour does not tint
  them. Bitmap (sbix, CBDT) and SVG-in-OpenType emoji fonts are not drawn; add a COLR font
  as media to use another emoji design.

### Measuring (at load or while rendering)

```lua
local FONT = { font = "DM Sans", size = 56, weight = 500 }
local W = text_width { "Measure me", font = "DM Sans", size = 56, weight = 500 }        -- pixels
local fitted = text_fit { "A very long headline that will not fit", font = "DM Sans",
  size = 56, max_width = 600 }                                  -- cut with "…" (ellipsis = "...")
local lines = text_lines { "Wrap this paragraph into lines no wider than the box allows.",
  font = "DM Sans", size = 56, max_width = 700 }               -- list of strings

video { width = 1920, height = 1080, fps = 30, duration = 2, render = function(f)
  rect { x = 160, y = 200, w = W, h = 4, fill = "#38bdf8" }
  text { "Measure me", x = 160, y = 180, font = "DM Sans", size = 56, weight = 500, fill = "#fff" }
  text { fitted, x = 160, y = 320, font = "DM Sans", size = 56, fill = "#fff" }
  for i, l in ipairs(lines) do
    text { l, x = 160, y = 440 + (i - 1) * 56 * 1.3, font = "DM Sans", size = 56, fill = "#fff" }
  end
end }
```

Measure with the same family, size, weight and `letter_spacing` you draw with; results are
kept by text and font, so measuring every frame is cheap.

```lua
local size = text_size { "SHADERS", font = "Bebas Neue", max_width = 1600, size = 260 }  -- largest size that fits
for _, c in ipairs(text_chars { "POP", font = "Bebas Neue", size = 200 }) do  -- { text, x, w } per character
  local s = ease(spring { stiffness = 300, damping = 18 }, f.seconds - c.x / 2000)
  text { c.text, x = 400 + c.x, y = 600 - 60 * (1 - s), font = "Bebas Neue", size = 200, fill = "#fff" }
end
```

`text_size` gives the largest size (at most `size`) at which one line fits `max_width`: titles
that fill a width without leaving the canvas. `text_chars` places each character (kerning
included) for letter-by-letter animation.

## Images


```lua
image { src = "photo.jpg", x = 100, y = 100, w = 600, h = 400 }                  -- contain (default)
image { src = "photo.jpg", x = 800, y = 100, w = 600, h = 400, fit = "cover", align = { 0.5, 0.2 } }
image { src = "photo.jpg", x = 100, y = 600, w = 600, h = 300, fit = "fill", opacity = 0.7 }
image { src = "photo.jpg", x = 800, y = 600, w = 600, h = 300, preserve_aspect_ratio = "xMinYMid slice" }
```

Formats in `media/`: png, jpeg, bmp, gif, tga, webp. `align = {x, y}` (0..1) places the
image inside the box for `contain` / `cover`. Images decode on first use (shared by every
frame builder; `render` decodes a few seconds ahead), so many large photos in `media/` cost
memory only for the ones the video shows. Decoded images stay within a budget
(`--image-cache MB`, default 1024): between frames the least recently used are freed and
decode again when a later frame (or a seek back in the preview) shows them; images the
frames being built use are kept. Rounded images: wrap in a group with
`clip_path` (e.g. a rounded-rect path) or a `mask`.

## Script environment


```lua
local mod = require("scenes.intro")             -- scenes/intro.lua beside the script
local cfg = dofile("config.lua")                -- relative to the script
local fh = io.open(SCRIPT_DIR .. "/data.csv")   -- SCRIPT_DIR: the script's directory
local title = props.title or "Default title"    -- --props data.json, a --batch row, or --set title="Hello"
local raw = arg.title                           -- the --set value as given (a string)
local first = arg[1]                            -- positionals after `--`: onimite render video.lua -- a b
local fh = assert(io.open(SCRIPT_DIR .. "/tokens.json"))
local tokens = json_decode(fh:read("a"))        -- JSON as Lua, like props; invalid JSON is a Lua error
fh:close()
```

`json_decode(text)` converts JSON the same way props are read (objects to tables, arrays
from 1, integers stay integers, `null` is nil): data and design-token files read at load
(`examples/designer_handoff`). `props` is always a table: the `--props` JSON object (objects as tables, arrays from 1,
integers as integers, `null` as nil), the `--batch` row's keys over it, then every
`--set key=value` (a number when it reads as a JSON number, else a string). Batch rows
from CSV are strings and numbers. Read props at load (outside `render`): layouts, durations
and text measurements can depend on them. `onimite render video.lua --batch rows.csv -o
out/{name}.mp4` renders one video per row; see `examples/batch/`.

Lua 5.4 standard libraries are available; `require` returns the module only.

Mistakes that would read as nothing are reported instead:

- Reading a global that was never set is an error naming the closest one
  (`undefined global 'eas_out' (did you mean 'ease_out'?)`); `rawget(_G, "name")` reads one
  that may be unset. Setting globals stays free.
- An option a call does not use is a warning with the script line
  (``video.lua:12: `rect.fil` is not used (did you mean `fill`?)``): on nodes, groups,
  gradients, spans, filter primitives, animate keys, audio tracks, `video{}`, `scene{}` and the
  standard library's options. Load-time ones print on stderr; the rest are `inspect` findings.
