local look = require("look")
local fx = require("fx")
local score = require("music.score")
local sfx = require("sfx")
local facts = require("facts")
local snap, soft = look.snap, look.soft

-- ---- the montage -------------------------------------------------------------------

local BOARD = { x = 960, y = 120, w = 860, h = 840 }

local function word(lb, cb, s, fill)
  group({ shadow = look.SHADOW }, function()
    look.pop_word(s, 90, 470, 270, cb, fill or look.INK, look.DISPLAY, { each = 0.1 })
  end)
end

local function caption(cb, s)
  local p = snap(cb - 0.3)
  group({ opacity = clamp01(p * 3), transform = translate(0, (1 - p) * 30) }, function()
    text { s, x = 98, y = 560, font = look.MONO, size = 30, fill = look.INK }
  end)
end

local CARDS = {}
CARDS[1] = { "LOTTIE", "After Effects, played natively", 0, look.PINK, look.VIOLET, look.LEMON, function(f, cb, gb)
  lottie { src = "spiral.json", x = BOARD.x, y = BOARD.y + 40, w = 760, h = 760, fit = "contain", time = cb * 0.4 + 0.6,
    overrides = { ["White Solid 1"] = { visible = false }, ["Shape Layer 1"] = { stroke = look.LEMON } } }
end }
CARDS[2] = { "SVG", "elements animated by id", 3, look.CYAN, "#0b3a8a", look.LEMON, function(f, cb, gb)
  local flap = math.cos(gb * math.pi * 2) * 32
  svg(f, { src = "bird.svg", x = BOARD.x - 40, y = BOARD.y + 90, w = 920, h = 690, overrides = {
    wing = { transform = rotate(-flap, 215, 150) }, wing_back = { transform = rotate(flap * 0.6, 200, 150) },
    sun = { fill = math.floor(gb) % 2 == 0 and look.O or look.LEMON } } })
end }
-- A small 3D still life (view3d{}, three.js terms) on a turntable: lit,
-- shadowed, one sphere with its own GLSL; the camera swings round it.
local BANDS_VERT = [[
varying vec3 vNormal;
varying vec2 vUv;
void main() {
  vNormal = normalize(normalMatrix * normal);
  vUv = uv;
  gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
}
]]
local BANDS_FRAG = [[
varying vec3 vNormal;
varying vec2 vUv;
uniform float uBeat;
uniform vec3 uA;
uniform vec3 uB;
void main() {
  float band = step(0.5, fract(vUv.y * 6.0 - uBeat));
  float l = 0.35 + 0.65 * max(dot(normalize(vNormal), normalize(vec3(0.4, 0.9, 0.6))), 0.0);
  gl_FragColor = vec4(mix(uA, uB, band) * l, 1.0);
}
]]

CARDS[3] = { "3D", "three.js terms: lights, shadows, GLSL", 4, look.NIGHT, look.VIOLET, look.CYAN, function(f, cb, gb)
  local orbit = -0.5 + 0.45 * cb
  local hop = 0.35 * look.kick(gb)
  view3d { x = BOARD.x - 40, y = BOARD.y, w = 940, h = 840,
    camera = { fov = 38, position = { 7.2 * math.sin(orbit), 3.4, 7.2 * math.cos(orbit) }, target = { 0, 0.5, 0 } },
    lights = {
      { type = "HemisphereLight", color = "#f1e9ff", ground_color = look.NIGHT, intensity = 1.1 },
      { type = "DirectionalLight", intensity = 2.8, position = { 3, 7, 4 }, cast_shadow = true,
        shadow = { map_size = 1024, height = 7, bias = -0.0005, normal_bias = 0.02 } },
    },
    meshes = {
      { geometry = { type = "CylinderGeometry", radius_top = 2.6, radius_bottom = 2.6, height = 0.2, radial_segments = 96 },
        position = { 0, -0.1, 0 }, material = { color = look.INK, roughness = 0.8 }, receive_shadow = true },
      { geometry = { type = "BoxGeometry" }, position = { -1.4, 0.6 + hop, 0.3 }, scale = 1.2, rotation = { 0, gb * 0.8, 0 },
        material = { color = look.PINK, roughness = 0.35 }, cast_shadow = true, receive_shadow = true },
      { geometry = { type = "TorusGeometry", radius = 0.55, tube = 0.2, radial_segments = 24, tubular_segments = 64 },
        position = { 1.3, 0.9, 0.5 }, rotation = { gb * 0.9, gb * 0.5, 0 },
        material = { color = look.CYAN, roughness = 0.3 }, cast_shadow = true, receive_shadow = true },
      { geometry = { type = "SphereGeometry", radius = 0.75, width_segments = 48, height_segments = 24 },
        position = { 0, 0.75 + 0.5 * hop, -1.2 }, rotation = { 0, gb * 0.6, 0 },
        material = { type = "ShaderMaterial", vertex_shader = BANDS_VERT, fragment_shader = BANDS_FRAG,
          uniforms = { uBeat = gb, uA = look.VIOLET, uB = look.LEMON } },
        cast_shadow = true },
      { geometry = { type = "CylinderGeometry", radius_top = 0, radius_bottom = 0.45, height = 1.1, radial_segments = 48 },
        position = { 0.2, 0.55, 1.5 }, material = { color = look.LEMON, roughness = 0.5 }, cast_shadow = true },
    },
  }
end }
CARDS[4] = { "CAPTIONS", "word-timed, TikTok style", 1, look.VIOLET, look.PINK, look.CYAN, function(f, cb, gb)
  local words = { "NO", "AUDIO", "FILES", "IN", "THIS", "FILM" }
  local active = math.floor(cb * 3) % #words + 1
  for i, w in ipairs(words) do
    local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
    local x, y = BOARD.x + 40 + col * 420, BOARD.y + 160 + row * 230
    local on = i == active
    group({ transform = { scale = on and 1.08 or 1, origin = { x + 190, y } } }, function()
      if on then rect { x = x - 14, y = y - 150, w = 400, h = 190, rx = 28, fill = look.LEMON } end
      text { w, x = x + 190, y = y, align = "center", font = look.DISPLAY, size = 190, fill = on and look.NIGHT or look.INK }
    end)
  end
end }
-- Four filters in a 2 x 2 grid, the top row on the title's baseline: a word
-- each (sized to its tile), its filter named under it.
local TILE_W = 380
local FILTERS = {
  { "WOBBLE", "turbulence + displacement", function(gb)
    return { { "turbulence", type = "turbulence", base_frequency = { 0.012, 0.03 }, octaves = 2, seed = 9, result = "n" },
      { "displacement_map", input = "SourceGraphic", input2 = "n", scale = 30 + 40 * look.kick(gb), x_channel = "R", y_channel = "B" } }
  end },
  { "BLUR", "gaussian blur", function(gb)
    return { { "blur", std = 1 + 9 * (0.5 + 0.5 * math.sin(gb * math.pi / 2)) } }
  end },
  { "GLOW", "blur + flood + merge", function(gb)
    return { { "blur", std = 10 + 8 * look.kick(gb), input = "SourceAlpha", result = "b" },
      { "flood", color = look.CYAN, opacity = 0.95, result = "c" },
      { "composite", op = "in", input = "c", input2 = "b", result = "g" }, { "merge", "g", "g", "SourceGraphic" } }
  end },
  { "OUTLINE", "morphology", function(gb)
    return { { "morphology", operator = "dilate", radius = 5 + 3 * look.kick(gb), input = "SourceAlpha", result = "d" },
      { "flood", color = look.PINK, result = "c" }, { "composite", op = "in", input = "c", input2 = "d", result = "o" },
      { "merge", "o", "SourceGraphic" } }
  end },
}
for _, fl in ipairs(FILTERS) do
  fl.size = text_size { fl[1], font = look.DISPLAY, max_width = TILE_W - 40, size = 170 }
end

CARDS[5] = { "FILTERS", "every SVG primitive, on the GPU", 0, look.PINK, look.NIGHT, look.CYAN, function(f, cb, gb)
  for i, fl in ipairs(FILTERS) do
    local col, row = (i - 1) % 2, (i - 1) // 2
    local x, base = BOARD.x + col * (TILE_W + 60), 470 + row * 300
    local cx = x + TILE_W / 2
    local p = snap(cb - 0.15 * i)
    local filter = fl[3](gb)
    filter.region = { x = x - 30, y = base - 230, w = TILE_W + 60, h = 290, units = "userSpaceOnUse" }
    group({ opacity = clamp01(p * 3), filter = filter }, function()
      text { fl[1], x = cx, y = base, align = "center", font = look.DISPLAY, size = fl.size, fill = look.LEMON }
    end)
    text { fl[2], x = cx, y = base + 50, align = "center", font = look.MONO, size = 22, fill = look.INK, opacity = clamp01(p * 3) }
  end
end }
CARDS[6] = { "ALPHA", "ProRes and VP9 clips with transparency", 3, look.NIGHT, look.VIOLET, look.PINK, function(f, cb, gb)
  group({ filter = { { "blur", std = 26, input = "SourceAlpha", result = "b" }, { "flood", color = look.PINK, opacity = 0.9, result = "c" },
    { "composite", op = "in", input = "c", input2 = "b", result = "g" }, { "merge", "g", "SourceGraphic" },
    region = { x = -0.3, y = -0.3, w = 1.6, h = 1.6 } } }, function()
    look.pip_clip(f, BOARD.x - 80, BOARD.y + 90, 1020, 600, gb)
  end)
end }
CARDS[7] = { "BATCH", "one script, a video per row", 4, look.LEMON, look.ORANGE or look.F, look.PINK, function(f, cb, gb)
  for i = 0, 29 do
    local col, row = i % 5, math.floor(i / 5)
    local d = look.snap(cb * 4 - i * 0.2)
    if d > 0.001 then
      local x, y = BOARD.x + 20 + col * 170, BOARD.y + 40 + row * 130
      group({ opacity = clamp01(d * 3), transform = { scale = d, origin = { x + 70, y + 50 } } }, function()
        rect { x = x, y = y, w = 148, h = 100, rx = 14, fill = look.NIGHT, stroke = look.INK, stroke_width = 3 }
        text { string.format("#%03d", i + 1), x = x + 74, y = y + 62, align = "center", font = look.MONO, size = 30,
          fill = ({ look.PINK, look.CYAN, look.LEMON, look.O, look.VIOLET })[(i % 5) + 1] }
      end)
    end
  end
  text { "rows.csv  →  out/{name}.mp4", x = BOARD.x + 430, y = BOARD.y + 840, align = "center", font = look.MONO, size = 34,
    fill = look.NIGHT }
end }
CARDS[8] = { "SPECTRUM", "the soundtrack, drawn live", 2, look.NIGHT, look.PINK, look.CYAN, function(f, cb, gb)
  local bands = look.spectrum(f, 28)
  for i, v in ipairs(bands) do
    local h = v * 640 + 10
    rect { x = BOARD.x + (i - 1) * 31, y = BOARD.y + 780 - h, w = 24, h = h, rx = 8,
      fill = i % 2 == 0 and look.PINK or look.CYAN }
  end
end }
CARDS[7][5] = look.F

local function montage(f, lb, gb)
  local idx = math.min(math.floor(lb / 2) + 1, #CARDS)
  local c = CARDS[idx]
  local cb = lb - (idx - 1) * 2
  fx.pop(f, c[3], c[4], c[5], c[6], look.kick(gb))
  word(lb, cb, c[1], look.INK)
  caption(cb, c[2])
  local p = snap(cb)
  group({ opacity = clamp01(p * 4), transform = { scale = 0.9 + 0.1 * p, origin = { BOARD.x + 430, 540 } } }, function()
    c[7](f, cb, gb)
  end)
  -- what this is (Hush promised it), top left; the counter, bottom left
  look.chip(100, 110, string.format("all of this · %.1f MB on disk", facts.disk_mb), look.INK, look.NIGHT, 28,
    snap(lb))
  text { string.format("%02d / %02d", idx, #CARDS), x = 98, y = 1020, font = look.MONO, size = 26, fill = look.INK, opacity = 0.7 }
end

-- Its sounds (sfx.lua), in beats into the scene.
local SOUNDS = {}
for k = 1, 7 do -- a whoosh into every cut, a crash on it
  SOUNDS[#SOUNDS + 1] = sfx.at("montage", 2 * k - 0.5, sfx.whoosh(sfx.seconds("montage", 2 * k - 0.5, 0.5)), 0.12)
  SOUNDS[#SOUNDS + 1] = sfx.at("montage", 2 * k, sfx.hat(0.6, 1 / 6), 0.6)
end

local AT = score.time("montage")
scene { "Montage", cue = "montage", start = AT, audio = SOUNDS, render = function(f)
  local gb = score.beat(f)
  montage(f, gb - score.beat(AT), gb)
end }
