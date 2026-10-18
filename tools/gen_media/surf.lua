-- A wide clip with its own sound for examples/cuts (surf.mp4): a beach in
-- the afternoon, 1280x720, 24 fps, 8 seconds. Waves roll in, break into
-- foam and wash up the sand, each heard as it breaks; gulls glide over.
-- The sound is surf and wind, synthesized at load.
--
--     onimite render tools/gen_media/surf.lua -o surf.mp4

local S = require("synth")

local W, H, LEN = 1280, 720, 8
local PERIOD = 2.0 -- a wave every two seconds
local TAU, sin, cos, max = 2 * math.pi, math.sin, math.cos, math.max

-- ---- the sound: a break per wave over wind -----------------------------------

local function sound()
  local b = S.buffer(LEN, 5)
  S.wind(b, 0, LEN, 0.14)
  for k = 0, LEN / PERIOD do
    S.whoosh(b, k * PERIOD - 0.3, 1.8, 0.7)
    S.whoosh(b, k * PERIOD + 0.4, 1.2, 0.35)
  end
  return S.wav(b, 0.7)
end
audio_add("surf_sound.wav", shared("surf_sound", sound))

-- ---- the picture -------------------------------------------------------------

-- The edge of a band of water at height y: a slow swell of sines.
local function edge(y, amp, t, phase)
  local pts = {}
  for i = 0, 48 do
    local x = i / 48 * W
    pts[#pts + 1] = { x, y + amp * (sin(x / 140 + t * 1.3 + phase) + 0.5 * sin(x / 61 - t * 0.9 + phase * 2)) }
  end
  return pts
end

-- Water from the shoreline (y = top) down to the edge `pts`.
local function band(pts, top, fill, opacity)
  local p = { { 0, top } }
  for _, q in ipairs(pts) do p[#p + 1] = q end
  p[#p + 1] = { W, top }
  polygon { points = p, fill = fill, opacity = opacity }
end

local function gull(x, y, t, k)
  local flap = 8 * sin(t * 5 + k)
  path { d = string.format("M%.1f %.1f Q%.1f %.1f %.1f %.1f Q%.1f %.1f %.1f %.1f", x - 22, y - flap, x - 9, y - 9, x, y,
    x + 9, y - 9, x + 22, y - flap), fill = "none", stroke = "#f8fafc", stroke_width = 3, line_cap = "round" }
end

video { width = W, height = H, fps = 24, duration = LEN,
  audio = { { "surf_sound.wav", start = 0 } },
  render = function(f)
    local t = f.seconds
    rect { x = 0, y = 0, w = W, h = H, fill = linear_gradient { x1 = 0, y1 = 0, x2 = 0, y2 = 300,
      stops = { { 0, "#5aa9e6" }, { 1, "#bfe3f5" } } } }
    circle { cx = 1040, cy = 110, r = 52, fill = "#fff7d6" }
    -- the sea to the horizon, then the sand
    rect { x = 0, y = 280, w = W, h = 160, fill = linear_gradient { x1 = 0, y1 = 280, x2 = 0, y2 = 440,
      stops = { { 0, "#1f6f99" }, { 1, "#2f9bb8" } } } }
    rect { x = 0, y = 440, w = W, h = H - 440, fill = "#e8cf9e" }
    -- each wave: rises out at sea, breaks into foam, washes up and draws back
    for k = -1, 1 do
      local u = ((t / PERIOD) + k * 0.34) % 1
      local reach = 446 + 190 * math.sin(math.pi * math.min(u * 1.2, 1)) -- how far up the sand
      local water = edge(reach, 4 + 8 * (1 - u), t, k)
      band(water, 436, "#7cc7d6", 0.6 * (1 - u))
      local foam = edge(reach - 3, 4 + 8 * (1 - u), t, k)
      polyline { points = foam, stroke = "#ffffff", stroke_width = 5 + 8 * (1 - u), opacity = 0.85 * (1 - u) }
    end
    -- the wet sand darkening behind the washes
    rect { x = 0, y = 440, w = W, h = 60, fill = "#b89a6a", opacity = 0.18 + 0.1 * sin(TAU * t / PERIOD) }
    for k = 1, 3 do
      local x = (t * (60 + 20 * k) + k * 400) % (W + 100) - 50
      gull(x, 140 + 30 * k + 10 * cos(t + k), t, k)
    end
  end }
