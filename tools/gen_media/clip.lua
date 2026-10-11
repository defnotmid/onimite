-- A short clip with its own sound for media_demo (clip.mp4): a hot-air
-- balloon over rolling hills at sunrise, 640x480, 30 fps, 4 seconds, a
-- seamless loop (the birds and hills move by whole periods). The
-- sound is a bell melody over a pad and wind, synthesized at load.
--
--     onimite render tools/gen_media/clip.lua -o clip.mp4

local S = require("synth")

local W, H, LOOP = 640, 480, 4
local TAU, sin, cos = 2 * math.pi, math.sin, math.cos

-- ---- the sound: eight bells on the beats (120 BPM) over a pad and wind ------

local MELODY = { 72, 76, 79, 81, 79, 76, 74, 76 } -- C major pentatonic
local function sound()
  local b = S.buffer(LOOP, 7)
  S.chord(b, 0, LOOP, { 48, 55, 60, 64 }, 0.05, 900, 0.4, 0)
  S.wind(b, 0, LOOP, 0.12)
  for k, n in ipairs(MELODY) do
    S.bell(b, (k - 1) * 0.5, n, 0.16, k % 2 == 0 and 0.25 or -0.25, 3.5)
  end
  return S.wav(b, 0.7)
end
audio_add("clip_sound.wav", shared("clip_sound", sound))

-- ---- the picture ----------------------------------------------------------

-- A hill's outline: a sum of sines whose periods divide the width, scrolled
-- by `shift` (whole widths per loop, so the loop is seamless).
local function hill(base, amp, waves, shift, fill)
  local pts = { { 0, H } }
  for i = 0, 64 do
    local x = i / 64 * W
    local y = base
    for _, w in ipairs(waves) do y = y + amp * w[2] * sin(TAU * (x + shift) / W * w[1] + w[3]) end
    pts[#pts + 1] = { x, y }
  end
  pts[#pts + 1] = { W, H }
  polygon { points = pts, fill = fill }
end

local function cloud(x, y, s, a)
  group({ opacity = a }, function()
    for _, c in ipairs { { 0, 0, 34 }, { 34, -12, 42 }, { 74, 0, 30 }, { 36, 10, 36 } } do
      circle { cx = x + c[1] * s, cy = y + c[2] * s, r = c[3] * s, fill = "#fff4ec" }
    end
  end)
end

local function bird(x, y, t, k)
  local flap = sin(TAU * (t * 3 + k * 0.3)) * 6
  path { d = string.format("M%.1f %.1f Q%.1f %.1f %.1f %.1f Q%.1f %.1f %.1f %.1f", x - 10, y - flap, x - 4, y - 4,
    x, y, x + 4, y - 4, x + 10, y - flap), fill = "none", stroke = "#4a2b4f", stroke_width = 2.4, line_cap = "round" }
end

video { width = W, height = H, fps = 30, duration = LOOP,
  audio = { { "clip_sound.wav", start = 0 } },
  render = function(f)
    local t = f.seconds
    local u = t / LOOP -- 0..1 over the loop
    -- sky and the sun's glow
    rect { x = 0, y = 0, w = W, h = H, fill = linear_gradient { x1 = 0, y1 = 0, x2 = 0, y2 = H,
      stops = { { 0, "#3d4a8c" }, { 0.45, "#e9809b" }, { 0.75, "#ffc48a" }, { 1, "#ffe1a8" } } } }
    circle { cx = 420, cy = 300, r = 300, fill = radial_gradient { cx = 420, cy = 300, r = 300,
      stops = { { 0, "#fff6d8" }, { 0.25, "#ffe0a0aa" }, { 1, "#ffc48a00" } } } }
    circle { cx = 420, cy = 300, r = 46, fill = "#fff8e6" }
    -- clouds drift to and fro
    for k, c in ipairs { { 80, 90, 0.9 }, { 330, 150, 0.6 }, { 520, 70, 0.75 } } do
      cloud(c[1] + 16 * sin(TAU * u + k), c[2], c[3], 0.8 - k * 0.1)
    end
    -- the hills, far to near, scrolling at their own speeds: a hill moving
    -- W / n per loop only has waves whose counts are multiples of n
    hill(330, 18, { { 4, 1, 0 }, { 8, 0.35, 1 } }, u * W / 4, "#c9708f")
    hill(370, 22, { { 2, 1, 2 }, { 6, 0.3, 0 } }, u * W / 2, "#9c4f7d")
    hill(420, 24, { { 1, 1, 4 }, { 3, 0.5, 1 } }, u * W, "#6b3566")
    -- the balloon bobs and leans with the breeze
    local bx, by = 230 + 10 * sin(TAU * u), 190 + 14 * sin(TAU * u * 2)
    group({ transform = { rotate = 3 * sin(TAU * u), origin = { bx, by + 90 } } }, function()
      path { d = string.format("M%.1f %.1f L%.1f %.1f M%.1f %.1f L%.1f %.1f", bx - 30, by + 42, bx - 13, by + 92,
        bx + 30, by + 42, bx + 13, by + 92), stroke = "#4a2b4f", stroke_width = 2 }
      rect { x = bx - 15, y = by + 90, w = 30, h = 22, rx = 4, fill = "#8a4b2f" }
      -- the envelope: a teardrop in stripes, lit from the sun's side
      local env = string.format("M%.1f %.1f C%.1f %.1f %.1f %.1f %.1f %.1f C%.1f %.1f %.1f %.1f %.1f %.1f Z",
        bx, by + 50, bx - 96, by - 20, bx - 64, by - 112, bx, by - 112, bx + 64, by - 112, bx + 96, by - 20, bx, by + 50)
      group({ clip_path = env }, function()
        for s = -3, 3 do
          rect { x = bx + s * 24 - 12, y = by - 120, w = 24, h = 180, fill = s % 2 == 0 and "#f25c54" or "#ffd166" }
        end
        rect { x = bx - 90, y = by - 120, w = 180, h = 180, fill = linear_gradient { x1 = bx - 80, y1 = 0, x2 = bx + 80,
          y2 = 0, stops = { { 0, "#2a103a66" }, { 0.6, "#2a103a00" }, { 1, "#fff6d833" } } } }
      end)
    end)
    -- birds cross once a loop (they wrap off-screen)
    for k = 1, 3 do
      local x = (u * (W + 80) + k * 26) % (W + 80) - 40
      bird(x, 120 + k * 14 + 6 * sin(TAU * u + k), t, k)
    end
  end }
