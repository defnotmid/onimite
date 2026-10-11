-- A photo-like canyon panorama (4800x928), one frame, for the suite's
-- skyline (canyon.webp): a dawn sky with thin clouds, hazy mesas, a
-- hoodoo amphitheatre in striped, lit rock, and a dark ridge of pines in
-- front. The rock is filter work: turbulence as a height map under a low
-- light, multiplied into strata that a second turbulence displaces.
-- Ridges are noise() profiles made at load.
--
--     onimite frame tools/gen_media/canyon.lua 0 -o out/

local W, H = 4800, 928

-- A ridge profile: `n` points across, heights from octaves of noise around
-- `base`, flattened into mesas where `flat` > 0 (tops clamped).
local function ridge(base, amp, freq, seed, flat, n)
  local pts = { { 0, H } }
  for i = 0, n do
    local x = i / n * W
    local v = 0
    local a, fr = 1, freq
    for o = 1, 5 do
      v = v + a * noise(x * fr, seed + o * 17)
      a, fr = a * 0.5, fr * 2.1
    end
    if flat > 0 then v = math.min(v, flat) + (v > flat and 0.04 * noise(x * 0.02, seed) or 0) end
    pts[#pts + 1] = { x, base - amp * v }
  end
  pts[#pts + 1] = { W, H }
  return pts
end

-- Hoodoos: thin spires with rounded caps standing on a floor at `base`,
-- heights and widths from noise (seeded per row), as one path.
local function hoodoos(base, tall, seed)
  local parts, x, k = {}, 20, 0
  while x < W do
    k = k + 1
    local h = tall * (0.55 + 0.35 * noise(x * 0.004, seed) + 0.2 * noise(k * 0.9, seed + 5))
    local w = 24 + 22 * (0.5 + 0.5 * noise(k * 1.7, seed + 2))
    local waist = 0.26 + 0.14 * (0.5 + 0.5 * noise(k * 1.1, seed + 3))
    local top = base - h
    -- a spire: a wide foot, a waist, a cap a little wider than the waist
    parts[#parts + 1] = string.format(
      "M%.1f %.1f C%.1f %.1f %.1f %.1f %.1f %.1f C%.1f %.1f %.1f %.1f %.1f %.1f C%.1f %.1f %.1f %.1f %.1f %.1f Z",
      x - w * 0.9, base,
      x - w * 0.55, base - h * 0.4, x - w * waist, top + h * 0.35, x - w * 0.5, top + w * 0.5,
      x - w * 0.6, top - w * 0.2, x + w * 0.6, top - w * 0.2, x + w * 0.5, top + w * 0.5,
      x + w * waist, top + h * 0.35, x + w * 0.55, base - h * 0.4, x + w * 0.9, base)
    x = x + w * (0.6 + 0.5 * (0.5 + 0.5 * noise(k * 2.3, seed + 4)))
  end
  return path_data(table.concat(parts, " "))
end

local FAR = ridge(560, 120, 0.0011, 1, 0.35, 240)
local MID = ridge(650, 90, 0.0016, 2, 0.6, 320)
local BACK = hoodoos(720, 260, 13)
local FRONT = hoodoos(800, 300, 3)
local NEAR = ridge(890, 70, 0.0025, 4, 0, 480)

-- Pines along the near ridge.
local PINES = {}
for i = 1, #NEAR - 2, 3 do
  local p = NEAR[i + 1]
  local h = 40 + 50 * (0.5 + 0.5 * noise(i * 0.7, 11))
  if noise(i * 0.31, 12) > -0.2 then PINES[#PINES + 1] = { p[1], p[2] + 6, h } end
end

-- Strata: a repeating vertical gradient of rock colours.
local STRATA = { { 0, "#e9a06e" }, { 0.12, "#d97c4c" }, { 0.2, "#efc193" }, { 0.37, "#c9653d" },
  { 0.5, "#e49561" }, { 0.58, "#f4d2a8" }, { 0.66, "#dd8754" }, { 0.85, "#c25a36" }, { 1, "#e9a06e" } }

-- Rock: strata displaced by turbulence, multiplied by a lit height map,
-- over the whole region; `shape` (drawn white) masks it, so the
-- displacement never pulls the outside in at the edges.
local function rock(region, light, strata, shape)
  local r = region
  group({ mask = shape, filter = {
    { "turbulence", type = "fractalNoise", base_frequency = { 0.003, 0.022 }, octaves = 3, seed = 21, result = "warp" },
    { "displacement_map", input = "SourceGraphic", input2 = "warp", scale = 60, x_channel = "R", y_channel = "G",
      result = "strata" },
    { "turbulence", type = "turbulence", base_frequency = { 0.011, 0.018 }, octaves = 5, seed = 7, result = "bump" },
    { "diffuse_lighting", input = "bump", surface_scale = 6, constant = 1.2, color = "#fff1dc", light = light,
      result = "lit" },
    { "composite", op = "arithmetic", k = { 1.1, 0, 0, 0 }, input = "lit", input2 = "strata" },
    region = { x = r.x, y = r.y, w = r.w, h = r.h, units = "userSpaceOnUse" },
  } }, function()
    rect { x = r.x, y = r.y, w = r.w, h = r.h, fill = strata }
  end)
end

local function white(pts) return function() polygon { points = pts, fill = "#ffffff" } end end

video { width = W, height = H, fps = 30, duration = { frames = 1 }, render = function(f)
  -- sky, lighter towards the dawn on the right
  rect { x = 0, y = 0, w = W, h = H, fill = linear_gradient { x1 = 0, y1 = 0, x2 = 0, y2 = 700,
    stops = { { 0, "#27406f" }, { 0.55, "#7e95bd" }, { 0.85, "#f0c9a6" }, { 1, "#ffe0b5" } } } }
  circle { cx = 3600, cy = 560, r = 1400, fill = radial_gradient { cx = 3600, cy = 560, r = 1400,
    stops = { { 0, "#fff3d6cc" }, { 0.3, "#ffd9a855" }, { 1, "#ffd9a800" } } } }
  -- thin clouds: stretched fractal noise turned into white alpha, upper sky only
  group({ opacity = 0.55, filter = {
    { "turbulence", type = "fractalNoise", base_frequency = { 0.0009, 0.009 }, octaves = 4, seed = 33 },
    { "color_matrix", type = "matrix", values = { 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 2.6, 0, 0, 0, -1.25 } },
    { "composite", op = "in", input2 = "SourceGraphic" },
    region = { x = 0, y = 0, w = W, h = 520, units = "userSpaceOnUse" },
  } }, function()
    rect { x = 0, y = 0, w = W, h = 520, fill = linear_gradient { x1 = 0, y1 = 0, x2 = 0, y2 = 520,
      stops = { { 0, "#ffffff" }, { 0.7, "#ffffff" }, { 1, "#ffffff00" } } } }
  end)

  -- far mesas: faint relief, pale with distance
  rock({ x = 0, y = 380, w = W, h = 548 }, { "distant", azimuth = 340, elevation = 35 },
    linear_gradient { x1 = 0, y1 = 400, x2 = 0, y2 = 640, stops = { { 0, "#b9a3b8" }, { 1, "#dcbcb4" } } }, white(FAR))

  -- the amphitheatre: its wall and a back row of hoodoos, hazed, then the
  -- front row; all lit from the dawn side
  local light = { "distant", azimuth = 340, elevation = 28 }
  local strata = linear_gradient { x1 = 0, y1 = 540, x2 = 0, y2 = 760, spread = "repeat", stops = STRATA }
  rock({ x = 0, y = 400, w = W, h = 528 }, light, strata, function()
    polygon { points = MID, fill = "#ffffff" }
    path { d = BACK, fill = "#ffffff" }
  end)
  rect { x = 0, y = 420, w = W, h = 360, fill = linear_gradient { x1 = 0, y1 = 420, x2 = 0, y2 = 780,
    stops = { { 0, "#f3d2bd00" }, { 0.5, "#efc6b040" }, { 1, "#c98a7a70" } } } }
  rock({ x = 0, y = 400, w = W, h = 528 }, light, strata, function() path { d = FRONT, fill = "#ffffff" } end)
  -- shadow at the front row's feet
  rect { x = 0, y = 680, w = W, h = 248, fill = linear_gradient { x1 = 0, y1 = 680, x2 = 0, y2 = 900,
    stops = { { 0, "#5a2a3000" }, { 1, "#5a2a30dd" } } } }

  -- the near ridge and its pines, nearly black against the glow
  polygon { points = NEAR, fill = "#2a1a22" }
  for _, p in ipairs(PINES) do
    local x, y, h = p[1], p[2], p[3]
    polygon { points = { x, y - h, x - h * 0.22, y - h * 0.45, x - h * 0.12, y - h * 0.47, x - h * 0.3, y,
      x + h * 0.3, y, x + h * 0.12, y - h * 0.47, x + h * 0.22, y - h * 0.45 }, fill = "#22151c" }
  end
end }
