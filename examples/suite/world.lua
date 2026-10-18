-- The group the shader warps (its `uniform shader uWorld` child), drawn by
-- ovg in 1920x1080 units: lines of this very script typing themselves,
-- planets with focal gradients, a spectrum ring round an o3d gyroscope, the
-- piece's name cut by a moving mask, a VP9 alpha clip for the kaleidoscope
-- to multiply, and in the break the suite's structure.

local beat = require("beat")
local ui = require("ui")
local T = require("timeline")
local snap, soft = beat.snap, beat.soft

local M = {}

local sin, cos, pi = math.sin, math.cos, math.pi

-- Lines of video.lua, typed one a beat from beat 1.
local CODE = {
  'local score = song { "score", style = "styles/synthwave.json" }',
  'shader(f, { src = "world.sksl", w = 1920, h = 1080,',
  '  uniforms = { uWorld = function() world.draw(f, b, bands) end,',
  '    uPano = "canyon.webp", uWarp = warp, uPulse = kick } })',
  'svg(f, { src = "rocket.svg", overrides = {',
  '  flame = { transform = scale(1, flicker, 200, 262) } } })',
  'video_frame(f, { src = "transparent.mov", looping = true })',
  'video_frame(f, { src = "avatar_vp9_alpha.webm", looping = true })',
  'audio_spectrum(f, { src = "score", sample_size = 512 })',
  'view3d { x = 720, y = 300, w = 480, h = 480, meshes = gyro }',
}
local CODE_SIZE, CODE_LEAD = 30, 46

-- Syntax colours: strings, then everything else.
local function code_line(s, x, y, n)
  s = s:sub(1, n)
  local spans, i = {}, 1
  while i <= #s do
    local q = s:find('"', i, true)
    if not q then spans[#spans + 1] = { s:sub(i), fill = ui.TEXT } break end
    if q > i then spans[#spans + 1] = { s:sub(i, q - 1), fill = ui.TEXT } end
    local e = s:find('"', q + 1, true) or #s
    spans[#spans + 1] = { s:sub(q, e), fill = ui.ODECS }
    i = e + 1
  end
  text { "", x = x, y = y, font = ui.MONO, size = CODE_SIZE, spans = spans }
end

local GLOW = { filter = {
  { "blur", std = 6, result = "b" },
  { "merge", "b", "SourceGraphic" },
} }

local function code(b)
  local show = progress(b, 0.5, 2) * (1 - progress(b, T.KALEIDO - 1, T.KALEIDO))
  if show <= 0 then return end
  -- the block drifts up once the beat drops
  local y0 = 250 - math.max(b - T.DROP, 0) * 4
  group({ opacity = show * lerp(1, 0.4, progress(b, T.DROP, T.DROP + 1)) }, function()
    group(GLOW, function()
      for i, line in ipairs(CODE) do
        local n = math.floor(#line * progress(b, i * 1.2, i * 1.2 + 1))
        if n > 0 then code_line(line, 150, y0 + (i - 1) * CODE_LEAD, n) end
      end
    end)
  end)
end

-- Two planets lit off-centre (focal radial gradients).
local function planets(b)
  local a = progress(b, 2, 8) * lerp(1, 0.3, progress(b, T.LOCKUP, T.LOCKUP + 1))
  if a <= 0 then return end
  local bob = sin(b * pi / 8)
  group({ opacity = a }, function()
    circle { cx = 1440 + bob * 30, cy = 330, r = 190, fill = radial_gradient {
      cx = 0.5, cy = 0.5, r = 0.5, fx = 0.32, fy = 0.28, units = "bbox",
      stops = { { 0, "#ffd8ec" }, { 0.35, ui.OKSL }, { 1, "#2a0618" } } } }
    circle { cx = 470 - bob * 20, cy = 820, r = 120, fill = radial_gradient {
      cx = 0.5, cy = 0.5, r = 0.5, fx = 0.7, fy = 0.3, units = "bbox",
      stops = { { 0, "#e6fbff" }, { 0.4, ui.OVG }, { 1, "#04161c" } } } }
    -- a ring around the big one
    group({ transform = { rotate = -18, origin = { 1440 + bob * 30, 330 } } }, function()
      ellipse { cx = 1440 + bob * 30, cy = 330, rx = 300, ry = 46, fill = "none", stroke = ui.TEXT,
        stroke_width = 3, stroke_opacity = 0.5 }
    end)
  end)
end

local RING_N = 48
local RING_ANG = {}
for i = 1, RING_N do RING_ANG[i] = (i - 0.5) / RING_N * 2 * pi end
local ACCENTS = { ui.ONIMITE, ui.OVG, ui.OKSL, ui.ODECS }

local function ring(b, bands)
  local a = progress(b, T.DROP - 0.5, T.DROP)
  if a <= 0 or b >= T.LOCKUP then return end
  local r0 = 250 + 20 * pulse(b, 6)
  group({ opacity = a * (1 - progress(b, T.BREAK - 0.5, T.BREAK)), blend = "screen" }, function()
    for i = 1, RING_N do
      local v = bands[(i - 1) % #bands + 1]
      local len = 20 + 220 * v * v
      local t = RING_ANG[i] + b * 0.05
      local c, s = cos(t), sin(t)
      line { x1 = 960 + c * r0, y1 = 540 + s * r0, x2 = 960 + c * (r0 + len), y2 = 540 + s * (r0 + len),
        stroke = ACCENTS[(i - 1) % 4 + 1], stroke_width = 14, line_cap = "round" }
    end
  end)
end

-- The gyroscope in the ring (o3d): a ring per library round onimite's core,
-- each turning on its own axes, shading as it turns; the kick swells it.
-- One torus geometry for all four rings, sized by `scale`.
local GYRO = {
  { color = ui.OVG, size = 1.25, spin = { 0.9, 0.3, 0 } },
  { color = ui.OKSL, size = 1.03, spin = { -0.4, 0.8, 0.2 } },
  { color = ui.ODECS, size = 0.81, spin = { 0.3, -0.5, 0.9 } },
  { color = ui.O3D, size = 0.59, spin = { -0.8, 0.2, -0.5 } },
}
local GYRO_R = 240 -- the view's half size, in the ring's middle

local function gyro(b, bands)
  local a = snap(b - T.DROP) * (1 - progress(b, T.BREAK - 0.5, T.BREAK))
  if a <= 0.001 or b >= T.BREAK then return end
  local swell = 1 + 0.06 * pulse(b, 6) + 0.1 * (bands[2] or 0)
  local meshes = {
    { geometry = { type = "SphereGeometry", radius = 1, width_segments = 48, height_segments = 24 },
      scale = 0.3 * swell, material = { color = ui.ONIMITE, emissive = ui.ONIMITE, emissive_intensity = 0.6,
        roughness = 0.3 } },
  }
  for i, r in ipairs(GYRO) do
    meshes[#meshes + 1] = {
      geometry = { type = "TorusGeometry", radius = 1, tube = 0.06, radial_segments = 16, tubular_segments = 96 },
      scale = r.size * swell * a, rotation = { b * r.spin[1], b * r.spin[2], b * r.spin[3] },
      material = { color = r.color, emissive = r.color, emissive_intensity = 0.25, roughness = 0.35 } }
  end
  view3d { x = 960 - GYRO_R, y = 540 - GYRO_R, w = 2 * GYRO_R, h = 2 * GYRO_R,
    camera = { fov = 30, position = { 0, 0, 7 }, target = { 0, 0, 0 } },
    lights = {
      { type = "HemisphereLight", color = "#dfe8ff", ground_color = "#20121c", intensity = 1.2 },
      { type = "DirectionalLight", color = "#ffffff", intensity = 2.6, position = { 3, 4, 5 } },
    },
    meshes = meshes,
  }
end

-- "LUA SCRIPT IN · MP4 OUT", huge, seen through stripes that slide.
local function title(b)
  local a = progress(b, T.DROP, T.DROP + 1) * (1 - progress(b, T.KALEIDO - 1, T.KALEIDO))
  if a <= 0 then return end
  local shift = (b - T.DROP) * 30
  group({ opacity = a * 0.5, mask = function()
    for k = -2, 24 do
      rect { x = k * 90 + shift % 90, y = 0, w = 45, h = 1080, fill = "#ffffff" }
    end
  end }, function()
    text { "LUA SCRIPT IN · MP4 OUT", x = 960, y = 990, align = "center", font = ui.DISPLAY, size = 210,
      fill = linear_gradient { x1 = 0, y1 = 0, x2 = 1, y2 = 0, units = "bbox",
        stops = { { 0, ui.ONIMITE }, { 0.5, ui.OVG }, { 1, ui.OKSL } } } }
  end)
end

-- The VP9 clip in the wedge the kaleidoscope mirrors (about 15 degrees
-- right of centre), so the fold turns one dancer into twelve.
local function dancer(f, b)
  local a = progress(b, T.KALEIDO, T.KALEIDO + 0.5) * (1 - progress(b, T.BREAK - 0.5, T.BREAK))
  if a <= 0 then return end
  group({ opacity = a, filter = {
    { "blur", std = 10, input = "SourceAlpha", result = "s" },
    { "flood", color = ui.OKSL, opacity = 0.9, result = "c" },
    { "composite", op = "in", input = "c", input2 = "s", result = "g" },
    { "merge", "g", "SourceGraphic" },
  } }, function()
    video_frame(f, { src = "avatar_vp9_alpha.webm", x = 1079, y = 512, w = 400, h = 225, looping = true })
  end)
  -- dashes on the fold lines
  circle { cx = 960, cy = 540, r = 470, fill = "none", stroke = ui.ODECS, stroke_width = 4,
    stroke_dasharray = { 18, 30 }, stroke_dashoffset = -b * 24, opacity = a * 0.8 }
end

-- The suite: onimite over its four libraries, three of them on SDL_GPU.
-- Every label is from the libraries' READMEs. o3d's box lands with the
-- SDL row.
local BOXES = {
  { name = "ovg", line = "2D vector canvas", x = 220, color = ui.OVG, at = T.BOXES[1] },
  { name = "oksl", line = "SkSL → SPIR-V · MSL · CPU", x = 600, color = ui.OKSL, at = T.BOXES[2] },
  { name = "o3d", line = "3D in three.js terms", x = 980, color = ui.O3D, at = T.O3D_BOX },
  { name = "odecs", line = "codecs, no FFmpeg", x = 1360, color = ui.ODECS, at = T.BOXES[3] },
}
local BOX_W, BOX_H = 340, 150

function M.structure(b, x0, y0, s)
  local a = progress(b, T.BREAK, T.BREAK + 0.25)
  if a <= 0 then return end
  group({ opacity = a, transform = { translate = { x0, y0 }, scale = s } }, function()
    -- onimite on top
    local p = snap(b - T.BREAK)
    group({ transform = { scale = p, origin = { 960, 140 } } }, function()
      rect { x = 660, y = 60, w = 600, h = 160, rx = 22, fill = ui.PANEL, stroke = ui.ONIMITE, stroke_width = 4 }
      text { "onimite", x = 960, y = 138, align = "center", font = ui.DISPLAY, size = 92, fill = ui.ONIMITE }
      text { "Lua scripts → video, one binary", x = 960, y = 192, align = "center", font = ui.MONO, size = 26,
        fill = ui.TEXT }
    end)
    for _, bx in ipairs(BOXES) do
      local at = bx.at
      local w = progress(b, at - 0.75, at)
      if w > 0 then
        local cx = bx.x + BOX_W / 2
        line { x1 = 960, y1 = 220, x2 = cx, y2 = 330, stroke = bx.color, stroke_width = 4, path_length = 1,
          stroke_dasharray = { 1, 1 }, stroke_dashoffset = 1 - w }
      end
      local pop = snap(b - at)
      if pop > 0.001 then
        group({ transform = { scale = pop, origin = { bx.x + BOX_W / 2, 330 + BOX_H / 2 } } }, function()
          rect { x = bx.x, y = 330, w = BOX_W, h = BOX_H, rx = 18, fill = ui.PANEL, stroke = bx.color, stroke_width = 3 }
          text { bx.name, x = bx.x + BOX_W / 2, y = 405, align = "center", font = ui.DISPLAY, size = 72, fill = bx.color }
          text { bx.line, x = bx.x + BOX_W / 2, y = 450, align = "center", font = ui.MONO, size = 20, fill = ui.TEXT }
        end)
      end
    end
    -- SDL_GPU under ovg, oksl and o3d; odecs on Vulkan Video or its own codecs
    local sdl = snap(b - T.BOXES[4])
    if sdl > 0.001 then
      group({ opacity = clamp01(sdl), transform = translate(0, (1 - sdl) * 40) }, function()
        rect { x = 220, y = 520, w = 1100, h = 70, rx = 14, fill = ui.LINE }
        text { "SDL_GPU · Vulkan / Metal / D3D12", x = 770, y = 565, align = "center", font = ui.MONO, size = 26,
          fill = ui.TEXT }
        rect { x = 1360, y = 520, w = 340, h = 70, rx = 14, fill = ui.LINE }
        text { "Vulkan Video or native", x = 1530, y = 565, align = "center", font = ui.MONO, size = 22,
          fill = ui.TEXT }
      end)
    end
  end)
end

function M.draw(f, b, bands)
  planets(b)
  title(b)
  code(b)
  ring(b, bands)
  gyro(b, bands)
  dancer(f, b)
  if b >= T.BREAK and b < T.LOCKUP then
    M.structure(b, 0, 200, 1)
  elseif b >= T.LOCKUP then
    -- smaller, under the wordmark
    local m = soft(b - T.LOCKUP)
    M.structure(b, lerp(0, 240, m), lerp(200, 500, m), lerp(1, 0.75, m))
  end
end

return M
