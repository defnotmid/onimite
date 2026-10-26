-- Motion poster: a 20 second generative piece (1080x1350, 60 fps) on a
-- 120 BPM ambient techno track (an odawg song, track.lua). Everything is
-- drawn from noise:
--
--   * the field: feTurbulence, stretched to grey (feColorMatrix) and
--     posterized into an OKLab palette (feComponentTransfer, discrete), its
--     number of levels stepping with the bars;
--   * the disc: turbulence as a height map under feDiffuseLighting and
--     feSpecularLighting, lit by a point light that wanders by noise();
--   * the type: feMorphology erodes it out of nothing, then dilates an
--     outline that breathes with the kick;
--   * the rings and orbs: noise()-driven contours and content-sized blur
--     layers;
--   * an SkSL shader whose `uniform shader` child is all of the above,
--     rippling on every kick and splitting colour on every bar;
--   * the paper card: fine turbulence under a distant light.
--
--     onimite render examples/motion_poster/video.lua -o motion_poster.mp4

local T = require("timeline")
local score = T.score

local W, H = 1080, 1350
local CX, CY = 540, 470 -- the disc

-- ---- palette (OKLab) ----------------------------------------------------------

local STOPS = { "#0d0a24", "#33196b", "#b42f7d", "#ff7046", "#ffd79a" }
local INK, CREAM, ACCENT = STOPS[1], "#f6ead8", "#ff7046"

-- A colour at t (0..1) along the stops, mixed in OKLab.
local function palette(t)
  local x = clamp01(t) * (#STOPS - 1)
  local i = math.min(math.floor(x), #STOPS - 2)
  return mix_color(STOPS[i + 1], STOPS[i + 2], x - i)
end

-- feComponentTransfer tables mapping grey to n palette steps, at load.
-- Filters work in linear RGB (as in SVG), so the tables hold linear values.
local function linear(v) return v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4 end
local LEVELS = {}
for n = 3, 8 do
  local r, g, b = {}, {}, {}
  for k = 1, n do
    local c = palette((k - 1) / (n - 1) * 0.8)
    r[k], g[k], b[k] = linear(c.r), linear(c.g), linear(c.b)
  end
  LEVELS[n] = { r = { type = "discrete", values = r }, g = { type = "discrete", values = g },
    b = { type = "discrete", values = b } }
end

-- ---- the field ----------------------------------------------------------------

-- Levels per bar: 4 in the intro, 5/6 alternating in the groove, 3 in the
-- break, 7/8 in the finale.
local LEVELS_IN = { intro = { 4, 4 }, groove = { 5, 6 }, ["break"] = { 3, 3 }, finale = { 7, 8 } }
local function levels(t)
  local s = score.section(t) or { name = "finale", bar = 1 }
  return LEVELS_IN[s.name][s.bar % 2 + 1]
end

-- The turbulence drifts: the group moves one way, the region the other, so
-- the window stays put while the noise slides under it.
local GREY = { 3, 0, 0, 0, -1, 3, 0, 0, 0, -1, 3, 0, 0, 0, -1, 0, 0, 0, 0, 1 }
local function field(t, b)
  local dx, dy = t * 26, t * 14
  group({ transform = translate(-dx, -dy), opacity = progress(b, -3, 3), filter = {
    { "turbulence", type = "fractalNoise", base_frequency = 0.0032, octaves = 3, seed = 11 },
    { "color_matrix", type = "matrix", values = GREY },
    { "component_transfer", r = LEVELS[levels(t)].r, g = LEVELS[levels(t)].g, b = LEVELS[levels(t)].b },
    region = { x = dx, y = dy, w = W, h = H, units = "userSpaceOnUse" },
  } }, function()
    rect { x = dx, y = dy, w = W, h = H, fill = INK }
  end)
end

-- ---- the poster's group (the shader's child) ------------------------------------

-- The light wanders by noise and dips towards the disc on every kick.
local function light(t, kick)
  return { "point", x = CX + 330 * noise(t * 0.22, 1), y = CY - 40 + 260 * noise(t * 0.22, 2), z = 170 - 50 * kick }
end

local function disc(t, kick)
  local L = light(t, kick)
  group({ filter = {
    { "turbulence", type = "turbulence", base_frequency = 0.011, octaves = 4, seed = 5, result = "bump" },
    { "diffuse_lighting", input = "bump", surface_scale = 4, constant = 1.15, color = "#ffffff", light = L, result = "diffuse" },
    { "specular_lighting", input = "bump", surface_scale = 4, constant = 1.1, exponent = 22, color = "#fff1d6",
      light = L, result = "spec" },
    { "composite", op = "arithmetic", k = { 1, 0, 0, 0 }, input = "diffuse", input2 = "SourceGraphic", result = "lit" },
    { "composite", op = "arithmetic", k = { 0, 1, 0.8, 0 }, input = "lit", input2 = "spec", result = "metal" },
    { "composite", op = "in", input = "metal", input2 = "SourceAlpha" },
    region = { x = CX - 290, y = CY - 290, w = 580, h = 580, units = "userSpaceOnUse" },
  } }, function()
    circle { cx = CX, cy = CY, r = 270, fill = radial_gradient { cx = CX - 80, cy = CY - 100, r = 380,
      stops = { { 0, palette(0.95) }, { 0.55, palette(0.7) }, { 1, palette(0.45) } } } }
  end)
end

-- Contour rings around the disc: radii pushed by 3D noise (angle on a
-- circle, time), each ring a step along the palette.
local RING_N = 96
local function rings(t, b)
  for k = 1, 5 do
    local pts = {}
    local base = 300 + k * 26
    for i = 0, RING_N - 1 do
      local a = i / RING_N * 2 * math.pi
      local r = base + 34 * noise(math.cos(a) * 1.3, math.sin(a) * 1.3 + k * 0.7, t * 0.35 + k * 0.2)
      pts[#pts + 1] = { CX + r * math.cos(a), CY + r * math.sin(a) }
    end
    polygon { points = pts, fill = "none", stroke = palette(0.35 + k * 0.12), stroke_width = 3,
      opacity = progress(b, k * 0.6, k * 0.6 + 2) * 0.85 }
  end
end

-- Orbs drifting through a noise flow, each a blurred glow under a core.
local function orbs(t, b, kick)
  local a = progress(b, 4, 8)
  if a <= 0 then return end
  for i = 1, 7 do
    local x = 540 + 470 * noise(t * 0.09, i * 3.1)
    local y = 640 + 560 * noise(t * 0.08, i * 7.7)
    local r = 8 + 6 * ((i * 37) % 5) / 4
    local c = palette(0.55 + 0.4 * ((i * 13) % 7) / 6)
    group({ blur = 14 + 10 * kick, opacity = a * 0.9 }, function() circle { cx = x, cy = y, r = r * 2.2, fill = c } end)
    circle { cx = x, cy = y, r = r * 0.6, fill = CREAM, opacity = a }
  end
end

-- "NOISE": eroded out of nothing in the intro, then a dilated outline
-- (dilate minus the letters) that breathes with the kick.
local function word(str, y, size, fill, erode, outline, outline_color)
  local f, src = {}, "SourceGraphic"
  if erode > 0.05 then
    f[#f + 1] = { "morphology", operator = "erode", radius = erode, input = src, result = "type" }
    src = "type"
  end
  if outline > 0.05 then
    f[#f + 1] = { "morphology", operator = "dilate", radius = outline, input = src, result = "fat" }
    f[#f + 1] = { "composite", op = "out", input = "fat", input2 = src, result = "ring" }
    f[#f + 1] = { "flood", color = outline_color, result = "ink" }
    f[#f + 1] = { "composite", op = "in", input = "ink", input2 = "ring", result = "outline" }
    f[#f + 1] = { "merge", "outline", src }
  end
  f.region = { x = 0, y = y - size * 0.82, w = W, h = size * 0.95, units = "userSpaceOnUse" }
  group({ filter = #f > 0 and f or nil }, function()
    text { str, x = W / 2, y = y, align = "center", font = "Bebas Neue", size = size, letter_spacing = 10, fill = fill }
  end)
end

local function poster(t, b, kick)
  rings(t, b)
  local d = ease(spring { stiffness = 60, damping = 14 }, t - score.time("intro@4n"))
  if d > 0 then
    group({ transform = { scale = 0.85 + 0.15 * d, origin = { CX, CY } }, opacity = clamp01(d * 1.5) }, function()
      disc(t, kick)
    end)
  end
  orbs(t, b, kick)
  -- the type: grows in (erode 14 -> 0) over the intro, thins in the break
  local grow = 14 * (1 - ease(ease_out, t - T.TYPE_IN, T.TYPE_SET - T.TYPE_IN))
  local thin = 5 * smoothstep(T.BREAK, T.THIN, t) * (1 - smoothstep(score.time("finale@-8n"), T.FINALE, t))
  if t >= T.TYPE_IN then
    word("NOISE", 735, 330, INK, grow + thin, 3 + 9 * kick, CREAM)
    word("FIELD", 1015, 330, linear_gradient { x1 = 0, y1 = 780, x2 = 0, y2 = 1015,
      stops = { { 0, CREAM }, { 1, palette(0.86) } } }, grow + thin * 1.4, 6, INK)
    group({ opacity = progress(t, score.time("groove@-2n"), T.TYPE_SET),
      shadow = { dx = 0, dy = 3, blur = 8, color = INK, opacity = 0.9 } }, function()
      text { "a study in noise and light", x = W / 2, y = 1082, align = "center", font = "Instrument Serif",
        italic = true, size = 58, fill = CREAM }
    end)
  end
end

-- ---- the shader ---------------------------------------------------------------

local WARP = [[
uniform float3 iResolution;
uniform shader uPoster;
uniform float uSinceKick;  // seconds since the last kick (large without one)
uniform float uSplit;      // colour split in pixels
uniform float uSwirl;      // radians at the centre
uniform float2 uCenter;
half4 main(float2 p) {
  float2 d = p - uCenter;
  float r = length(d);
  float2 n = d / max(r, 1.0);
  // a ring rushing out from the disc after each kick
  float front = uSinceKick * 1400.0;
  float ring = exp(-pow((r - front) / 70.0, 2.0)) * exp(-uSinceKick * 2.5);
  float2 q = p - n * ring * 26.0;
  // a swirl that grows with the riser
  float a = uSwirl * exp(-r / 420.0);
  float c = cos(a), s = sin(a);
  float2 e = q - uCenter;
  q = uCenter + float2(c * e.x - s * e.y, s * e.x + c * e.y);
  float2 o = n * uSplit;
  half4 R = uPoster.eval(q + o);
  half4 G = uPoster.eval(q);
  half4 B = uPoster.eval(q - o);
  return half4(R.r, G.g, B.b, max(max(R.a, G.a), B.a));
}]]

-- ---- paper card and header (outside the warp, always legible) ----------------------

local CARD = { x = 80, y = 1118, w = 920, h = 168 }
local function card(b)
  local a = progress(b, 6, 8)
  if a <= 0 then return end
  group({ opacity = a, filter = {
    { "turbulence", type = "fractalNoise", base_frequency = 0.05, octaves = 3, seed = 2, result = "grain" },
    { "diffuse_lighting", input = "grain", surface_scale = 1.6, constant = 1.05, color = "#ffffff",
      light = { "distant", azimuth = 235, elevation = 55 }, result = "relief" },
    { "composite", op = "arithmetic", k = { 1, 0, 0, 0 }, input = "relief", input2 = "SourceGraphic", result = "paper" },
    { "composite", op = "in", input = "paper", input2 = "SourceAlpha" },
    region = { x = CARD.x, y = CARD.y, w = CARD.w, h = CARD.h, units = "userSpaceOnUse" },
  } }, function()
    rect { x = CARD.x, y = CARD.y, w = CARD.w, h = CARD.h, rx = 6, fill = CREAM }
  end)
  group({ opacity = a }, function()
    text { "feTurbulence  feDiffuseLighting  feSpecularLighting", x = CARD.x + 36, y = CARD.y + 52,
      font = "JetBrains Mono", size = 28, fill = INK }
    text { "feMorphology  feComponentTransfer  SkSL", x = CARD.x + 36, y = CARD.y + 94,
      font = "JetBrains Mono", size = 28, fill = INK }
    text { string.format("%d BPM  ·  music composed by odawg  ·  onimite", score.sections[1].bpm), x = CARD.x + 36, y = CARD.y + 136,
      font = "JetBrains Mono", size = 28, fill = "#7a3b52" }
  end)
end

local function header(t, b, kick)
  local a = progress(b, 0.5, 2.5)
  text { "ONIMITE", x = 80, y = 92, font = "JetBrains Mono", size = 28, letter_spacing = 6, fill = CREAM, opacity = a }
  local bar = math.floor(score.bar(t)) + 1
  text { string.format("BAR %02d / %02d", math.min(bar, T.BARS), T.BARS), x = 1000, y = 92, align = "right",
    font = "JetBrains Mono", size = 28, fill = CREAM, opacity = a }
  rect { x = 80, y = 112, w = 920, h = 2, fill = CREAM, opacity = a * 0.5 }
  rect { x = 80, y = 111, w = math.max(920 * t / score.duration, 1), h = 4, fill = ACCENT, opacity = a }
end

-- ---- video ---------------------------------------------------------------------

video {
  width = W, height = H, fps = T.FPS, duration = score.duration, background = INK,
  audio = { { "score", fade_out = 1.5 } },
  -- the song lifted to about -14 LUFS under the limiter
  master_gain_db = 5,
  render = function(f)
    local t = f.global_seconds
    local b = score.beat(t)
    -- the kicks really played: a pulse on each, the ripple's age while they play
    local kick = score.pulse(f, { part = "drums", note = "kick", decay = 6 })
    local since_kick = T.since_kick(t)
    if not since_kick or since_kick > T.BEAT then since_kick = 10 end
    -- a colour split on every bar while they play (the pad changes chord each bar),
    -- growing with the riser, a big one on the impact
    local bar = score.pulse(f, { part = "pad", decay = 2.5 })
    local split = (since_kick < 10 and 10 * bar or 0) + 4 * smoothstep(T.RISER, T.FINALE, t)
      + 24 * score.pulse(f, { part = "impact", decay = 1.5 })
    local swirl = 1.3 * smoothstep(T.RISER, T.FINALE, t) * (1 - progress(t, T.FINALE, score.time("finale@4n")))

    rect { x = 0, y = 0, w = W, h = H, fill = INK }
    field(t, b)
    shader { sksl = WARP, x = 0, y = 0, w = W, h = H, uniforms = {
      uSinceKick = since_kick, uSplit = split, uSwirl = swirl, uCenter = { CX, CY },
      uPoster = function() poster(t, b, kick) end,
    } }
    card(b)
    header(t, b, kick)
    -- the finale's flash on the impact and the fade at the end
    local flash = score.pulse(f, { part = "impact", decay = 3 })
    if flash > 0.01 then rect { x = 0, y = 0, w = W, h = H, fill = CREAM, opacity = flash * 0.6 } end
    local out = progress(t, score.duration - 1, score.duration)
    if out > 0 then rect { x = 0, y = 0, w = W, h = H, fill = INK, opacity = out } end
  end,
}

-- The sections as scenes (no render): Groove@2s and per-section loudness work.
for _, s in ipairs { { "intro", "Intro" }, { "groove", "Groove" }, { "break", "Break" }, { "finale", "Finale" } } do
  scene { s[2], start = score.time(s[1]) }
end
