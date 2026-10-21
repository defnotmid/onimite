-- onimite' Lua standard library, run before every script: composition
-- helpers after Remotion's <Sequence>, <Series>, <Loop> and <Freeze>,
-- @remotion/transitions and GSAP's staggers, plus a beat clock. Plain Lua
-- over the native API (script/script.odin loads it with #load).

local floor, abs, exp, sin, cos, max, pi, sqrt = math.floor, math.abs, math.exp, math.sin, math.cos, math.max, math.pi, math.sqrt

-- Math helpers: plain Lua, as fast as the arithmetic itself (a call into
-- Odin would cost more than the work). noise() and mix_color() are native.
function clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi end return x end
function clamp01(x) if x < 0 then return 0 elseif x > 1 then return 1 end return x end
function lerp(a, b, t) return a + (b - a) * t end
-- Where x is between a and b, 0..1 (clamped): an inverse lerp.
function progress(x, a, b) return clamp01((x - a) / (b - a)) end
-- x mapped from a..b to c..d (clamped).
function remap(x, a, b, c, d) return c + (d - c) * progress(x, a, b) end
function smoothstep(a, b, x) local t = progress(x, a, b) return t * t * (3 - 2 * t) end
function fract(x) return x - floor(x) end
function round(x) return x >= 0 and floor(x + 0.5) or -floor(-x + 0.5) end
function sign(x) return x > 0 and 1 or (x < 0 and -1 or 0) end

-- 3D vectors as { x, y, z } lists, what view3d positions are: each gives a
-- new list and leaves its arguments alone.
function vec3_add(a, b) return { a[1] + b[1], a[2] + b[2], a[3] + b[3] } end
function vec3_sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
function vec3_scale(a, s) return { a[1] * s, a[2] * s, a[3] * s } end
function vec3_lerp(a, b, t) return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t } end
function vec3_dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
function vec3_cross(a, b) return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] } end
function vec3_length(a) return sqrt(a[1] * a[1] + a[2] * a[2] + a[3] * a[3]) end
function vec3_distance(a, b) return vec3_length(vec3_sub(a, b)) end
-- a at length 1 (a zero vector stays zero).
function vec3_normalize(a)
  local n = vec3_length(a)
  if n == 0 then return { 0, 0, 0 } end
  return { a[1] / n, a[2] / n, a[3] / n }
end

-- Below a frame at any rate: boundaries computed by adding seconds stay put.
local EPS = 1e-6

-- check_fields(t, name, keys): warns about the string keys of option table t
-- that are not in keys (a misspelled option reads as nothing otherwise).
local check_fields = check_fields
_G.check_fields = nil
local EMPTY = {}

-- The video's size (video{} records it): transitions cover it by default.
local W, H = 1920, 1080

local native_video = video
function video(t)
  if type(t) == "table" then W, H = t.width or W, t.height or H end
  return native_video(t) -- a tail call: errors name the script's line
end

-- ---- time --------------------------------------------------------------------

-- A copy of frame `f` whose local clock reads `seconds` (index follows;
-- global_* stay on the video clock).
local function retime(f, seconds)
  local g = {}
  for k, v in next, f do g[k] = v end
  g.seconds = seconds
  g.index = floor(seconds * f.fps + EPS)
  g.progress = nil
  return g
end

-- fn(g) while from <= f.seconds < from + dur (dur nil: open-ended), with
-- g's clock starting at 0 and g.progress = local / dur.
function sequence(f, from, dur, fn)
  local t = f.seconds - from
  if t < -EPS or (dur and t >= dur - EPS) then return end
  if t < 0 then t = 0 end
  local g = retime(f, t)
  if dur then g.progress = t / dur end
  return fn(g)
end

-- Back-to-back sequences: items { {dur, fn}, ... }; the last may have a nil
-- dur (runs to the end).
function series(f, items)
  local at = 0
  for i = 1, #items do
    local it = items[i]
    local d = it[1]
    if d == nil or f.seconds < at + d - EPS then return sequence(f, at, d, it[2]) end
    at = at + d
  end
end

-- fn(g) with g's clock wrapping every `period` seconds (g.progress through
-- the period, g.iteration counting from 0).
function loop(f, period, fn)
  local n = floor((f.seconds + EPS) / period)
  local t = f.seconds - n * period
  if t < 0 then t = 0 end
  local g = retime(f, t)
  g.progress, g.iteration = t / period, n
  return fn(g)
end

-- fn(g) with g's clock stopped at `at` seconds.
function freeze(f, at, fn)
  return fn(retime(f, at))
end

-- The start offset of item i (1-based) when items start `each` seconds
-- apart (GSAP's stagger). opts: n (the item count; needed for from = "end" or
-- "center", amount and easing), from = "start"|"end"|"center"|an index,
-- amount (the total spread instead of each), easing (spaces the starts).
local STAGGER_KEYS = { "n", "from", "amount", "easing" }
function stagger(i, each, opts)
  if opts then check_fields(opts, "stagger", STAGGER_KEYS) else opts = EMPTY end
  local n, from = opts.n, opts.from or "start"
  local origin = 1
  if from ~= "start" then
    assert(n, "stagger: give opts.n (the item count) for from = 'end' or 'center'")
    origin = from == "end" and n or from == "center" and (n + 1) / 2 or from
  end
  local d = abs(i - origin)
  if not (opts.amount or opts.easing) then return d * each end
  assert(n, "stagger: give opts.n (the item count) with amount or easing")
  local far = max(origin - 1, n - origin)
  if far <= 0 then return 0 end
  return ease(opts.easing, d / far, 1) * (opts.amount or far * each)
end

-- Paths through 3D points ({ x, y, z } lists): a centripetal Catmull-Rom
-- curve through every point (no loops or cusps where points bunch up),
-- travelled at an even speed: path_at(points, t) is where it is a
-- fraction t of its length along (0..1, clamped; `closed = true` joins the
-- last point to the first and wraps t). `easing` (any easing ease() takes)
-- reshapes t first. A camera on a path looks ahead with path_at(P, t +
-- 0.02) as its target, or along path_tangent.
local PATH_KEYS = { "closed", "easing" }
local PATH_STEPS = 16 -- samples a segment, measuring its length

-- Point k of the path: wrapped when closed; past an open end, the end
-- mirrored (the curve leaves the end along its first segment).
local function path_point(p, k, closed)
  local n = #p
  if closed then return p[(k - 1) % n + 1] end
  if k < 1 then local a, b = p[1], p[2] return { 2 * a[1] - b[1], 2 * a[2] - b[2], 2 * a[3] - b[3] } end
  if k > n then local a, b = p[n], p[n - 1] return { 2 * a[1] - b[1], 2 * a[2] - b[2], 2 * a[3] - b[3] } end
  return p[k]
end

-- Segment i (from point i to i + 1) at u (0..1): x, y, z.
local function path_eval(p, i, u, closed)
  local p0, p1, p2, p3 = path_point(p, i - 1, closed), path_point(p, i, closed), path_point(p, i + 1, closed), path_point(p, i + 2, closed)
  -- knots at the square roots of the distances (repeated points kept apart)
  local t1 = max(vec3_distance(p0, p1) ^ 0.5, 1e-4)
  local t2 = t1 + max(vec3_distance(p1, p2) ^ 0.5, 1e-4)
  local t3 = t2 + max(vec3_distance(p2, p3) ^ 0.5, 1e-4)
  local t = t1 + (t2 - t1) * u
  local out = {}
  for c = 1, 3 do
    local a1 = ((t1 - t) * p0[c] + t * p1[c]) / t1
    local a2 = ((t2 - t) * p1[c] + (t - t1) * p2[c]) / (t2 - t1)
    local a3 = ((t3 - t) * p2[c] + (t - t2) * p3[c]) / (t3 - t2)
    local b1 = ((t2 - t) * a1 + t * a2) / t2
    local b2 = ((t3 - t) * a2 + (t - t1) * a3) / (t3 - t1)
    out[c] = ((t2 - t) * b1 + (t - t1) * b2) / (t2 - t1)
  end
  return out
end

-- The segment and its parameter a fraction t of the path's length along:
-- its samples' lengths summed, the one the length falls in, interpolated.
local function path_find(p, t, opts, name)
  if opts then check_fields(opts, name, PATH_KEYS) else opts = EMPTY end
  local n, closed = #p, opts.closed
  assert(n >= 2, name .. ": give at least two points")
  if closed then t = fract(t) else t = clamp01(t) end
  if opts.easing then t = ease(opts.easing, t, 1) end
  local segs = closed and n or n - 1
  local lens, total, prev = { [0] = 0 }, 0, p[1]
  for k = 1, segs * PATH_STEPS do
    local i = (k - 1) // PATH_STEPS + 1
    local q = path_eval(p, i, (k - (i - 1) * PATH_STEPS) / PATH_STEPS, closed)
    total = total + vec3_distance(prev, q)
    lens[k], prev = total, q
  end
  local want, lo, hi = t * total, 0, segs * PATH_STEPS
  while hi - lo > 1 do
    local mid = (lo + hi) // 2
    if lens[mid] <= want then lo = mid else hi = mid end
  end
  local span = lens[hi] - lens[lo]
  local g = lo + (span > 0 and (want - lens[lo]) / span or 0)
  local i = math.min(floor(g / PATH_STEPS) + 1, segs)
  return i, g / PATH_STEPS - (i - 1), closed
end

function path_at(points, t, opts)
  local i, u, closed = path_find(points, t, opts, "path_at")
  return path_eval(points, i, u, closed)
end

-- The unit direction of travel at t (along the curve, not its speed).
function path_tangent(points, t, opts)
  local i, u, closed = path_find(points, t, opts, "path_tangent")
  local h = 1e-3
  local a, b
  if u + h <= 1 then a, b = path_eval(points, i, u, closed), path_eval(points, i, u + h, closed)
  else a, b = path_eval(points, i, u - h, closed), path_eval(points, i, u, closed) end
  return vec3_normalize(vec3_sub(b, a))
end

-- A decaying pulse on every whole unit of x: 1 at each integer, about 0 a
-- few 1/sharpness later; 0 for x < 0.
function pulse(x, sharpness)
  if x < 0 then return 0 end
  return exp(-(x - floor(x)) * (sharpness or 8))
end

-- A musical clock: bpm, offset (the seconds where beat 0 falls), beats per
-- bar (4). Times are video seconds, or a frame: its time on the video (the
-- beat grid is the video's, wherever the frame is).
function beat_clock(bpm, offset, per_bar)
  offset, per_bar = offset or 0, per_bar or 4
  local spb = 60 / bpm
  local c = { bpm = bpm, offset = offset, spb = spb, per_bar = per_bar }
  local function secs(t) return type(t) == "table" and t.global_seconds or t end
  function c.beat(t) return (secs(t) - offset) / spb end
  function c.bar(t) return (secs(t) - offset) / spb / per_bar end
  function c.time(beat) return offset + beat * spb end -- where a beat falls
  function c.seconds(beats) return beats * spb end -- how long beats last
  function c.frame(beat, fps) return floor((offset + beat * spb) * fps + 0.5) end
  function c.pulse(t, sharpness) return pulse(c.beat(t), sharpness) end
  return c
end

-- ---- spoken lines ---------------------------------------------------------------

-- say_cue(line, at, word, { name, nth }) -> the video time where `line` (from say(), its
-- track starting at video time `at`) says `word`: its text in any case (the nth time it is
-- said, 1 by default) or its index in line.words. Names that moment as cue `name` (default
-- the word in lower case) with hit = the line's clip, so inspect checks the voice starts
-- there (cue_no_hit); a word whose time is an estimate (a number, a symbol, a line that
-- could not be synthesized) gets the cue without the check.
local SAY_CUE_KEYS = { "name", "nth" }
local SAY_START_KEYS = { "nth" }

-- The word of `line` named by `word` (its text in any case, the nth time,
-- or its index), for say_cue and say_start (`fn` names the caller).
local function said_word(fn, line, word, nth)
  if type(word) == "number" then
    local w = line.words[word]
    if not w then error(string.format("%s: line %s has %d words, no word %d", fn, line.name, #line.words, word), 3) end
    return w
  end
  local want, seen = string.lower(word), 0
  for _, x in ipairs(line.words) do
    if string.lower(x.text) == want then
      seen = seen + 1
      if seen == nth then return x end
    end
  end
  error(string.format("%s: line %s says %q %d times, not %d", fn, line.name, word, seen, nth), 3)
end

function say_cue(line, at, word, opts)
  if opts then check_fields(opts, "say_cue", SAY_CUE_KEYS) else opts = EMPTY end
  local w = said_word("say_cue", line, word, opts.nth or 1)
  local name = opts.name or string.lower(w.text)
  if w.estimated or not line.ready then return cue(name, at + w.start) end
  return cue(name, at + w.start, { hit = line.name })
end

-- say_start(line, word, t, { nth }) -> where to start `line`'s track so it
-- says `word` (as say_cue finds it) at video time t: the inverse of
-- say_cue, for a voice that follows the music (`t = score.time("drop")`).
function say_start(line, word, t, opts)
  if opts then check_fields(opts, "say_start", SAY_START_KEYS) else opts = EMPTY end
  return t - said_word("say_start", line, word, opts.nth or 1).start
end

-- ---- transitions ---------------------------------------------------------------

local function noop() end

-- A repeatable random number 0..1 for n (and an optional seed): the same
-- inputs give the same value in every frame builder, unlike math.random.
function hash(n, seed)
  local x = sin(n * 127.1 + (seed or 0) * 269.5 + 311.7) * 43758.547
  return x - floor(x)
end

-- Where content b enters from: the unit vector pointing to that side.
local SIDES = { left = { -1, 0 }, right = { 1, 0 }, top = { 0, -1 }, bottom = { 0, 1 } }

local function side(o, default)
  local s = SIDES[o.from or default]
  if not s then error("transition: from must be left, right, top or bottom, not " .. tostring(o.from), 3) end
  return s
end

local KINDS = {}

-- Both fade: a out, b in.
function KINDS.fade(p, a, b, x, y, w, h, o)
  group({ opacity = 1 - p }, a)
  group({ opacity = p }, b)
end

-- b pushes a out, entering from `from` (default "right").
function KINDS.slide(p, a, b, x, y, w, h, o)
  local s = side(o, "right")
  local dx, dy = s[1] * w, s[2] * h
  group({ clip = { x = x, y = y, w = w, h = h } }, function()
    group({ transform = translate(-dx * p, -dy * p) }, a)
    group({ transform = translate(dx * (1 - p), dy * (1 - p)) }, b)
  end)
end

-- An edge crossing from `from` (default "left") reveals b; softness = the
-- edge's width in pixels (0: hard).
function KINDS.wipe(p, a, b, x, y, w, h, o)
  local s = side(o, "left")
  local soft = o.softness or 0
  local horizontal = s[2] == 0
  local len = horizontal and w or h
  -- the front, measured from the `from` side: b fully shown before c,
  -- fading out over [c, c + soft]
  local c = p * (len + soft) - soft
  if soft <= 0 then
    local ca, cb -- clip rectangles of a and b
    if horizontal then
      local bx = s[1] < 0 and x or x + w - c
      cb = { x = bx, y = y, w = c, h = h }
      ca = { x = s[1] < 0 and x + c or x, y = y, w = w - c, h = h }
    else
      local by = s[2] < 0 and y or y + h - c
      cb = { x = x, y = by, w = w, h = c }
      ca = { x = x, y = s[2] < 0 and y + c or y, w = w, h = h - c }
    end
    group({ clip = ca }, a)
    group({ clip = cb }, b)
    return
  end
  -- a soft edge: a linear gradient mask from the front to soft past it
  local function at(u) -- a point on the axis, u from the `from` side
    if horizontal then return s[1] < 0 and x + u or x + w - u, y end
    return x, s[2] < 0 and y + u or y + h - u
  end
  local x1, y1 = at(c)
  local x2, y2 = at(c + soft)
  if horizontal then y2 = y1 else x2 = x1 end
  local function mask(c1, c2)
    return function()
      rect { x = x, y = y, w = w, h = h, fill = linear_gradient { x1 = x1, y1 = y1, x2 = x2, y2 = y2,
        stops = { { 0, c1 }, { 1, c2 } } } }
    end
  end
  group({ mask = mask("#000000", "#ffffff") }, a)
  group({ mask = mask("#ffffff", "#000000") }, b)
end

-- A hand sweeping clockwise from 12 o'clock reveals b.
function KINDS.clock_wipe(p, a, b, x, y, w, h, o)
  local cx, cy = x + w / 2, y + h / 2
  local r = math.sqrt(w * w + h * h) / 2 + 2
  local ang = p * 2 * pi
  local ex, ey = cx + r * sin(ang), cy - r * cos(ang)
  local big = ang > pi and 1 or 0
  group({ clip_path = string.format("M%f %f L%f %f A%f %f 0 %d 1 %f %f Z", cx, cy, ex, ey, r, r, 1 - big, cx, cy - r) }, a)
  group({ clip_path = string.format("M%f %f L%f %f A%f %f 0 %d 1 %f %f Z", cx, cy, cx, cy - r, r, r, big, ex, ey) }, b)
end

-- a grows past the viewer and fades, b grows into place (scale = how far, 1.4).
function KINDS.zoom(p, a, b, x, y, w, h, o)
  local k = o.scale or 1.4
  local origin = { x + w / 2, y + h / 2 }
  group({ clip = { x = x, y = y, w = w, h = h } }, function()
    group({ opacity = 1 - p, transform = { scale = 1 + (k - 1) * p, origin = origin } }, a)
    group({ opacity = p, transform = { scale = 1 / k + (1 - 1 / k) * p, origin = origin } }, b)
  end)
end

-- Horizontal bands jump sideways and switch from a to b one by one
-- (bands = 12; amount = the largest shift as a fraction of the width, 0.12).
function KINDS.glitch(p, a, b, x, y, w, h, o)
  local n = o.bands or 12
  local shake = sin(pi * p) * (o.amount or 0.12) * w
  local seed = floor(p * 18) -- the bands jump about 18 times
  for i = 0, n - 1 do
    local y0, y1 = y + floor(i * h / n), y + floor((i + 1) * h / n)
    local dx = (hash(i * 13 + seed * 7) - 0.5) * 2 * shake
    if hash(i * 5 + seed * 3 + 1) < 0.5 then dx = dx * 0.15 end
    -- each band switches at its own moment between 0.2 and 0.8
    local content = p > 0.2 + 0.6 * hash(i * 7.31 + 2) and b or a
    group({ transform = translate(dx, 0), clip = { x = x, y = y0, w = w, h = y1 - y0 } }, content)
  end
end


-- Draws the switch from content a() to b() (functions adding nodes; either
-- may be nil) at progress p (clamped to 0..1): p = 0 draws only a, p = 1
-- only b. opts: x, y, w, h (the area; default the whole video) and the
-- kind's options.
local TRANSITION_KEYS = { "x", "y", "w", "h", "from", "softness", "scale", "bands", "amount", "duration", "easing" }
function transition(kind, p, a, b, opts)
  if opts then check_fields(opts, "transition", TRANSITION_KEYS) else opts = EMPTY end
  a, b = a or noop, b or noop
  if not (p > 0) then return a() end
  if p >= 1 then return b() end
  local k = KINDS[kind]
  if not k then error("transition: unknown kind " .. tostring(kind) .. " (fade, slide, wipe, clock_wipe, zoom, glitch)", 2) end
  k(p, a, b, opts.x or 0, opts.y or 0, opts.w or W, opts.h or H, opts)
end

-- scene{ ..., transition = { "wipe", duration = 0.6, easing = ease_in_out,
-- from = "right", ... } }: the scene enters over the overlap with the
-- previous scene (overlap.previous, defaulting to the duration, 0.5) and
-- that scene leaves by the same transition; timing by `easing` (linear).
local native_scene = scene
local last -- the previous scene's slot

local function window(slot, fps) -- frames both scenes are on screen
  return floor(slot.overlap * fps + EPS) + (slot.prev and floor(slot.prev.next * fps + EPS) or 0)
end

-- scene{ clip = "a.mp4" } or clip = { "a.mp4", from = 12, to = 15.5, speed = 1, name,
--   picture = { x, y, w, h, fit, align, opacity, fade_in, fade_out } or false,
--   sound = { gain_db, fade_in, fade_out, lead, extend, speed, offset, effects } or false }:
-- the scene shows the clip's [from, to) at `speed` (negative: from `to` back to `from`),
-- overlaps included (a transition crosses inside the cut), under its render. Its sound
-- reads the same stretch at the same speed (pitch moves with it), crossfading where the
-- scene overlaps its neighbours; `lead` starts it earlier, `extend` keeps it after the
-- picture, `speed` / `offset` give it a clock of its own.
local CLIP_KEYS = { "src", "from", "to", "speed", "name", "picture", "sound" }
local PICTURE_KEYS = { "x", "y", "w", "h", "fit", "align", "opacity", "fade_in", "fade_out" }
local SOUND_KEYS = { "gain_db", "fade_in", "fade_out", "lead", "extend", "speed", "offset", "effects" }

local function clip_scene(t, overlap)
  local c = t.clip
  t.clip = nil
  if type(c) == "string" then c = { c } end
  check_fields(c, "clip", CLIP_KEYS)
  local src = c[1] or c.src
  local function fail(fmt, ...) error(string.format("scene: clip %s " .. fmt, src, ...), 4) end
  if type(src) ~= "string" then error("scene: clip needs a video file, { \"clip.mp4\", from = ..., to = ... }", 3) end
  local info = video_info(src)
  if not info then error("scene: clip " .. src .. " is not a video in the media", 3) end
  local speed = c.speed or 1
  if speed == 0 then fail("speed 0 never moves (a still: picture = ..., or freeze())") end
  local from = c.from or 0
  local lap = (overlap.previous or 0) + (overlap.next or 0)
  local to = c.to
  if t.duration ~= nil then
    if to then fail("takes `to` or a scene duration, not both") end
    if type(t.duration) ~= "number" then fail("duration is seconds") end
    to = from + (t.duration + lap) * math.abs(speed)
  end
  to = to or info.duration
  if from < 0 or to <= from then fail("from %.3f to %.3f is empty", from, to) end
  if to > info.duration + 1e-3 then
    fail("is %.3f s; the cut %.3f..%.3f runs past its end", info.duration, from, to)
  end
  local span = (to - from) / math.abs(speed) -- seconds on the video
  if span <= lap then fail("from %.3f to %.3f is shorter than its overlaps (%.3f s)", from, to, lap) end
  t.duration = span - lap
  if t[1] == nil and t.name == nil then t.name = c.name end
  local first = speed > 0 and from or to -- where in the file the scene starts

  local snd = c.sound
  if snd ~= false and info.audio then
    snd = snd or EMPTY
    check_fields(snd, "clip sound", SOUND_KEYS)
    local sspeed = snd.speed or speed
    local lead, extend = snd.lead or 0, snd.extend or 0
    local offset = (snd.offset or first) - lead * sspeed
    if offset < -1e-3 or offset > info.duration + 1e-3 then
      fail("sound starts at %.3f s of the file, outside it (lead %.3f)", offset, lead)
    end
    local audio = { { src, start = -lead, stop = span + extend, offset = math.max(offset, 0), speed = sspeed,
      gain_db = snd.gain_db, fade_in = snd.fade_in, fade_out = snd.fade_out, effects = snd.effects,
      crossfade = lead == 0 and extend == 0 } }
    for _, a in ipairs(t.audio or EMPTY) do audio[#audio + 1] = a end
    t.audio = audio
  elseif snd ~= nil and snd ~= false then
    check_fields(snd, "clip sound", SOUND_KEYS)
  end

  local render = t.render
  local pic = c.picture
  if pic == false then
    t.render = render
    return
  end
  pic = pic or EMPTY
  check_fields(pic, "clip picture", PICTURE_KEYS)
  local fade_in, fade_out, opacity = pic.fade_in or 0, pic.fade_out or 0, pic.opacity or 1
  local frame = { src = src, x = pic.x or 0, y = pic.y or 0, w = pic.w or W, h = pic.h or H, fit = pic.fit,
    align = pic.align, clip_start = first, speed = speed }
  t.render = function(f)
    local k = opacity
    if fade_in > 0 then k = k * clamp01(f.seconds / fade_in) end
    if fade_out > 0 then k = k * clamp01((span - f.seconds) / fade_out) end
    frame.opacity = k
    video_frame(f, frame)
    if render then return render(f) end
  end
end

function scene(t)
  if type(t) ~= "table" then return native_scene(t) end
  local overlap = t.overlap or {}
  local tr = t.transition
  if tr and overlap.previous == nil then
    overlap.previous = tr.duration or 0.5
    t.overlap = overlap
  end
  if t.clip ~= nil then clip_scene(t, overlap) end
  local slot = { render = t.render, next = overlap.next or 0 }
  if tr then
    t.transition = nil
    slot.enter, slot.overlap, slot.prev = tr, overlap.previous, last
    if last then last.leave = slot end
  end
  local render = slot.render
  if render then
    t.render = function(f)
      local e, l = slot.enter, slot.leave
      if e then
        local wf = window(slot, f.fps)
        if f.index < wf then
          return transition(e[1], ease(e.easing, f.index / f.fps, wf / f.fps), nil, function() render(f) end, e)
        end
      end
      if l then
        local wf = window(l, f.fps)
        local k = f.global_index - (f.scene.end_frame - wf)
        if k >= 0 then
          return transition(l.enter[1], ease(l.enter.easing, k / f.fps, wf / f.fps), function() render(f) end, nil,
            l.enter)
        end
      end
      return render(f)
    end
  end
  last = slot
  return native_scene(t)
end

-- ---- captions ------------------------------------------------------------------

-- Word layouts of caption pages, by page and style: { lines = { { y, { i, x, w }, ... } }, h }
-- (x from the box's left, y from the block's top, both unscaled).
local caption_layouts = {}

local function caption_layout(words, o, size)
  local texts = {}
  for i = 1, #words do texts[i] = o.uppercase and words[i].text:upper() or words[i].text end
  local style = table.concat({ o.font or "", size, o.weight or 400, o.letter_spacing or 0, o.w, o.align or "center",
    o.line_height or 1.2 }, "|")
  local key = style .. "|" .. table.concat(texts, " ")
  local cached = caption_layouts[key]
  if cached then return cached, texts end
  local q = { font = o.font, size = size, weight = o.weight, letter_spacing = o.letter_spacing }
  local function width(a, b)
    q[1] = table.concat(texts, " ", a, b)
    return text_width(q)
  end
  -- Greedy wrap on whole-line widths: a word that alone overflows keeps its line.
  local lines, first, lh = {}, 1, size * (o.line_height or 1.2)
  for i = 1, #texts + 1 do
    if i > #texts or (i > first and width(first, i) > o.w) then
      local row, right = { y = (#lines + 0.5) * lh }, width(first, i - 1)
      local dx = o.align == "left" and 0 or o.align == "right" and o.w - right or (o.w - right) / 2
      for j = first, i - 1 do
        local ww = width(j, j)
        -- x: the line up to this word, minus the word (kerning across words included)
        row[#row + 1] = { i = j, x = dx + width(first, j) - ww, w = ww }
      end
      lines[#lines + 1] = row
      first = i
    end
  end
  cached = { lines = lines, h = #lines * lh }
  caption_layouts[key] = cached
  return cached, texts
end

local caption_spring, caption_slide

-- captions(f, { src, x, y, w, ... }) or captions{ ... } (the render call's clock): the caption
-- page showing now, wrapped within w, its active word highlighted. See the README.
local CAPTIONS_KEYS = { "src", "x", "y", "w", "align", "valign", "baseline", "font", "size", "weight",
  "letter_spacing", "italic", "line_height", "uppercase", "fill", "active_fill", "spoken_fill", "upcoming_fill",
  "stroke", "stroke_width", "highlight", "highlight_fill", "box_padding", "box_radius", "active_scale", "spring",
  "slide_spring", "max_words", "max_duration", "combine_ms", "hold", "start" }
function captions(f, o)
  if o == nil then f, o = nil, f end
  check_fields(o, "captions", CAPTIONS_KEYS)
  local words = caption_words(f, o.src, o)
  if not words then return end
  caption_spring = caption_spring or spring { stiffness = 380, damping = 22 } -- the pop overshoots a little
  caption_slide = caption_slide or spring { stiffness = 420, damping = 38 }   -- the box barely does
  local sp, size, x0 = o.spring or caption_spring, o.size or 64, o.x or 0
  local layout, texts = caption_layout(words, setmetatable({ w = o.w or W - 2 * x0 }, { __index = o }), size)
  local top = o.y or 0
  if o.valign == "middle" then top = top - layout.h / 2 elseif o.valign == "bottom" then top = top - layout.h end
  local t, mode = words.time, o.highlight or "fill"
  local fill, hl = o.fill or "#ffffff", o.highlight_fill or "#facc15"
  local active_fill = o.active_fill or (mode == "fill" and hl or fill)
  local spoken, upcoming = o.spoken_fill or fill, o.upcoming_fill or fill
  local grow = (o.active_scale or 1.12) - 1
  -- Each word's pop (0..1): a spring in when it starts, out when the next one does.
  local active, pops = nil, {}
  for i, w in ipairs(words) do
    local nxt = words[i + 1]
    pops[i] = ease(sp, t - w.start, 1) - (nxt and ease(sp, t - nxt.start, 1) or 0)
    if w.active then active = i end
  end
  -- Placed boxes: a growing word pushes its line's neighbours apart (the line keeps its alignment).
  local rects = {}
  for _, row in ipairs(layout.lines) do
    local extra = 0
    for _, p in ipairs(row) do extra = extra + grow * pops[p.i] * p.w end
    local x = x0 - (o.align == "left" and 0 or o.align == "right" and extra or extra / 2)
    for _, p in ipairs(row) do
      local s = 1 + grow * pops[p.i]
      rects[p.i] = { x = x + p.x, y = top + row.y, w = p.w * s, s = s }
      x = x + p.w * (s - 1)
    end
  end
  -- The word's text at its pop scale.
  local function draw_word(i, paint)
    local r = rects[i]
    local node = { texts[i], x = r.x + (r.w - r.w / r.s) / 2, y = r.y, baseline = o.baseline or "middle",
      font = o.font, size = size, weight = o.weight, letter_spacing = o.letter_spacing, italic = o.italic }
    local function draw()
      if o.stroke then -- an outline under the fill
        node.fill, node.stroke, node.stroke_width, node.line_join = "none", o.stroke, o.stroke_width or size * 0.12, "round"
        text(node)
        node.stroke = nil
      end
      node.fill = paint
      text(node)
    end
    if abs(r.s - 1) > 1e-3 then
      group({ transform = { scale = r.s, origin = { r.x + r.w / 2, r.y } } }, draw)
    else
      draw()
    end
  end
  -- The box / underline slides in from the previous word when it is on the same line.
  local hx, hw, k
  if active then
    local r, prev = rects[active], rects[active - 1]
    hx, hw, k = r.x, r.w, 1
    if prev and prev.y == r.y then
      k = ease(o.slide_spring or caption_slide, t - words[active].start, 1)
      hx, hw = prev.x + (r.x - prev.x) * k, prev.w + (r.w - prev.w) * k
    end
  end
  local box
  if active and mode == "box" then
    local px, h = o.box_padding or size * 0.2, size * 1.1 * rects[active].s
    box = { x = hx - px, y = rects[active].y - h / 2, w = hw + 2 * px, h = h }
    rect { x = box.x, y = box.y, w = box.w, h = box.h, rx = o.box_radius or size * 0.22, fill = hl }
  elseif active and mode == "underline" then
    local th = max(size * 0.09, 3)
    rect { x = hx, y = rects[active].y + size * 0.55 * rects[active].s, w = hw, h = th, rx = th / 2, fill = hl }
  end
  for i, w in ipairs(words) do
    local paint = w.progress > 0 and spoken or upcoming
    if not box and i == active then -- (a box's words take active_fill below, clipped to it)
      paint = animate(k, { { 0, 1, upcoming, active_fill } })
    elseif not box and active and i == active - 1 then
      paint = animate(k, { { 0, 1, active_fill, spoken } })
    end
    draw_word(i, paint)
  end
  if box then
    group({ clip = box }, function()
      if active > 1 then draw_word(active - 1, active_fill) end
      draw_word(active, active_fill)
    end)
  end
end

-- ---- text ---------------------------------------------------------------------

-- text_size{ "TEXT", font, weight, letter_spacing, max_width, size }: the
-- largest font size (at most `size`) at which the text fits `max_width` on one
-- line: titles that fill a width without leaving the canvas.
local TEXT_SIZE_KEYS = { "font", "weight", "letter_spacing", "max_width", "size", "italic", "text" }
function text_size(t)
  check_fields(t, "text_size", TEXT_SIZE_KEYS)
  local q = { t[1] or t.text, font = t.font, weight = t.weight, letter_spacing = t.letter_spacing,
    italic = t.italic, size = t.size or 1000 }
  local size = q.size
  for _ = 1, 3 do -- widths scale with the size, letter spacing does not: settle in a few steps
    q.size = size
    local w = text_width(q)
    if w <= t.max_width then break end
    size = size * t.max_width / w * 0.999
  end
  return math.min(size, t.size or size)
end

-- text_chars{ "TEXT", font, size, weight, letter_spacing } -> { { text, x, w }, ... }:
-- every character with its x from the start of the text (kerning included)
-- and its width, for animating letters one by one; draw each with text{} at
-- x0 + c.x (left aligned).
local TEXT_CHARS_KEYS = { "font", "size", "weight", "letter_spacing", "italic", "text" }
function text_chars(t)
  check_fields(t, "text_chars", TEXT_CHARS_KEYS)
  local str = t[1] or t.text
  local q = { "", font = t.font, size = t.size, weight = t.weight, letter_spacing = t.letter_spacing, italic = t.italic }
  local out = {}
  for p, c in utf8.codes(str) do
    local ch = utf8.char(c)
    q[1] = str:sub(1, p + #ch - 1)
    local after = text_width(q) -- the text up to and with this character
    q[1] = ch
    local w = text_width(q)
    out[#out + 1] = { text = ch, x = after - w, w = w }
  end
  return out
end

-- ---- strictness ----------------------------------------------------------------

-- `require` returns the module only: Lua 5.4 adds the file's path as a second
-- value, which slips into table constructors ({ require("a"), require("b") }).
local native_require = require
function require(name) return (native_require(name)) end

-- Reading a global that was never set is an error naming the closest one
-- (`eas_out` reads as nil otherwise and the animation silently runs linear).
-- Setting globals stays free; rawget(_G, name) reads one that may be unset.
local function edits(a, b) -- optimal string alignment distance (a swap is one edit)
  local prev2, prev, cur = {}, {}, {}
  for j = 0, #b do prev[j] = j end
  for i = 1, #a do
    cur[0] = i
    local ca = a:byte(i)
    for j = 1, #b do
      local cb = b:byte(j)
      local d = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca == cb and 0 or 1))
      if i > 1 and j > 1 and ca == b:byte(j - 1) and a:byte(i - 1) == cb then d = math.min(d, prev2[j - 2] + 1) end
      cur[j] = d
    end
    prev2, prev, cur = prev, cur, prev2
  end
  return prev[#b]
end

setmetatable(_G, { __index = function(_, name)
  if type(name) ~= "string" then return nil end
  local best, best_d = nil, math.max(1, #name // 3) + 1
  for k in next, _G do
    if type(k) == "string" then
      local d = edits(name, k)
      if d < best_d then best, best_d = k, d end
    end
  end
  error(("undefined global '%s'%s"):format(name, best and (" (did you mean '%s'?)"):format(best) or ""), 2)
end })
