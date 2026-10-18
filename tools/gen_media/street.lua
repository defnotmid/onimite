-- A phone-shaped clip with its own sound for examples/cuts (street.mp4): a
-- rainy street at night seen from a window, 720x1280 (9:16), 60 fps, 6
-- seconds. Buildings with lit windows, a streetlight, rain, and cars
-- whose headlights sweep through, each heard as it passes. The sound is
-- rain, a low city hum and a whoosh per car, synthesized at load.
--
--     onimite render tools/gen_media/street.lua -o street.mp4

local S = require("synth")

local W, H, LEN = 720, 1280, 6
local TAU, sin, floor = 2 * math.pi, math.sin, math.floor

-- Each car: when it crosses the middle, its direction and colour.
local CARS = { { 0.9, 1, "#ffe9b0" }, { 2.4, -1, "#fff4dc" }, { 3.5, 1, "#ffd9a0" }, { 5.1, -1, "#fff4dc" } }
local CROSS = 1.6 -- seconds a car takes to cross the frame

-- ---- the sound: rain, a hum and the cars ---------------------------------------

local function sound()
  local b = S.buffer(LEN, 11)
  S.wind(b, 0, LEN, 0.10)
  for k = 0, LEN * 40 - 1 do -- drops on the sill
    S.hat(b, k / 40 + (k * 7919 % 17) / 800, 0.03, 90, 0.025, (k * 31 % 7) / 7 - 0.5)
  end
  S.chord(b, 0, LEN, { 31, 38 }, 0.05, 160, 0.5, 0)
  for _, c in ipairs(CARS) do
    S.whoosh(b, c[1] - CROSS / 2, CROSS, 0.5)
  end
  return S.wav(b, 0.7)
end
audio_add("street_sound.wav", shared("street_sound", sound))

-- ---- the picture -------------------------------------------------------------

-- A tower of windows: a deterministic pattern of lit ones, a few flickering.
local function tower(x, top, w, color, seed, t)
  rect { x = x, y = top, w = w, h = H - top, fill = color }
  local cols = floor(w / 34)
  for r = 0, floor((H - 520 - top) / 46) do
    for c = 0, cols - 1 do
      local h = hash(r * 31 + c, seed)
      if h > 0.45 then
        local on = h > 0.97 and (sin(t * 9 + r) > 0 and 1 or 0.4) or 1
        rect { x = x + 10 + c * 34, y = top + 20 + r * 46, w = 18, h = 26,
          fill = h > 0.8 and "#ffcf7a" or "#f7a85a", opacity = (0.55 + 0.45 * hash(r, c + seed)) * on }
      end
    end
  end
end

local function car(t, cross, dir, color)
  local u = (t - cross) / CROSS -- -0.5 .. 0.5 while it crosses
  if u < -0.8 or u > 0.8 then return end
  local x = W / 2 + dir * u * (W + 400)
  local y = dir > 0 and 1010 or 950
  -- the beam on the wet road ahead of it
  group({ blend = "screen" }, function()
    ellipse { cx = x + dir * 220, cy = y + 40, rx = 260, ry = 26, fill = radial_gradient { cx = x + dir * 220, cy = y + 40,
      r = 260, stops = { { 0, color .. "88" }, { 1, color .. "00" } } } }
  end)
  rect { x = x - 110, y = y - 40, w = 220, h = 48, rx = 14, fill = "#11131c" }
  rect { x = x - 70, y = y - 74, w = 140, h = 40, rx = 12, fill = "#161a26" }
  circle { cx = x + dir * 104, cy = y - 18, r = 9, fill = color }
  circle { cx = x - dir * 106, cy = y - 18, r = 7, fill = "#ff4b4b" }
end

video { width = W, height = H, fps = 60, duration = LEN,
  audio = { { "street_sound.wav", start = 0 } },
  render = function(f)
    local t = f.seconds
    rect { x = 0, y = 0, w = W, h = H, fill = linear_gradient { x1 = 0, y1 = 0, x2 = 0, y2 = H,
      stops = { { 0, "#0b1026" }, { 0.5, "#1d1b3a" }, { 1, "#2a1f33" } } } }
    tower(-20, 180, 300, "#141629", 3, t)
    tower(300, 340, 220, "#191a30", 7, t)
    tower(500, 120, 260, "#121427", 13, t)
    -- the street: wet asphalt reflecting the windows
    rect { x = 0, y = 900, w = W, h = H - 900, fill = linear_gradient { x1 = 0, y1 = 900, x2 = 0, y2 = H,
      stops = { { 0, "#1c1a2a" }, { 1, "#0c0c14" } } } }
    for k = 0, 8 do
      rect { x = 40 + k * 80, y = 980 + 4 * sin(t * 2 + k), w = 6, h = 160, fill = "#f7a85a", opacity = 0.12 }
    end
    -- the streetlight and its pool of light
    rect { x = 588, y = 520, w = 10, h = 400, fill = "#0a0a10" }
    circle { cx = 560, cy = 525, r = 16, fill = "#ffe2a8" }
    circle { cx = 560, cy = 900, r = 220, fill = radial_gradient { cx = 560, cy = 900, r = 220,
      stops = { { 0, "#ffd08a44" }, { 1, "#ffd08a00" } } } }
    for _, c in ipairs(CARS) do car(t, c[1], c[2], c[3]) end
    -- rain: streaks falling at a slant, a fixed set wrapping down the frame
    for k = 0, 140 do
      local x0, sp = hash(k, 1) * (W + 200), 1300 + 500 * hash(k, 2)
      local y = (hash(k, 3) * H + t * sp) % (H + 80) - 40
      local x = (x0 - y * 0.18) % (W + 40) - 20
      line { x1 = x, y1 = y, x2 = x - 6, y2 = y + 30, stroke = "#c8d4ff", stroke_width = 1.6, opacity = 0.25 + 0.3 * hash(k, 4) }
    end
  end }
