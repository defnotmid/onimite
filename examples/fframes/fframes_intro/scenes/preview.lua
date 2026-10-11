-- After the benchmark: the native preview window playing this video in real
-- time on the GPU (a capture of `cargo run -- preview`). On the second half
-- the window fills the frame and NO BROWSER AT ALL ANYWHERE runs over it.

local beat = require("beat")
local ui = require("ui")
local prog, expo_out, expo_in, snap, lerp = beat.prog, beat.expo_out, beat.expo_in, beat.snap, beat.lerp
local ORANGE, BONE, GREY, MONO, DISPLAY = ui.ORANGE, ui.BONE, ui.GREY, ui.MONO, ui.DISPLAY
local Slam, callout = ui.Slam, ui.callout

-- Beat inside the scene where the window goes full frame and the words start.
local TAKEOVER = 16

-- A takeover row: words with the beat each one lands on, baseline, color and
-- drift direction.
local ROWS = {
  { { { "NO", 16 }, { "BROWSER", 17 } }, 380, BONE, -1 },
  { { { "AT", 18 }, { "ALL", 19 } }, 690, ORANGE, 1 },
  { { { "ANYWHERE", 20 } }, 1000, BONE, -1 },
}

-- The captured window (1600x896), placed on the right.
local WIN = { 590, 262, 1180, 660.8 }

local KEYS = {
  { "SPACE", "PLAY / PAUSE" },
  { "H  L", "SEEK A SECOND" },
  { "J  K", "STEP A FRAME" },
}

-- The window's drop shadow: feGaussianBlur 24 in x -10% y -10% 120% x 130%.
local SHADOW = { { "blur", std = 24 }, region = { x = -0.1, y = -0.1, w = 1.2, h = 1.3 } }

-- NO BROWSER / AT ALL / ANYWHERE: rows larger than the frame that slam in
-- word by word and drift in opposite directions over the dimmed window.
local function takeover(lb)
  local l = lb - TAKEOVER
  if l < 0 then return end
  rect { x = 0, y = 0, w = 1920, h = 1080, fill = "#050505", opacity = prog(l, 0, 0.5) * 0.6 }
  for _, row in ipairs(ROWS) do
    local words, y, color, dir = row[1], row[2], row[3], row[4]
    local first = words[1][2] - TAKEOVER
    local shown = {}
    for _, w in ipairs(words) do if lb >= w[2] then shown[#shown + 1] = w[1] end end
    if #shown > 0 then
      local drift = dir * math.max(l - first, 0) * 34
      local x = 60 + drift + (dir > 0 and -140 or 0)
      Slam(x, y, table.concat(shown, " "), DISPLAY, 330, color):draw(l - first, 0, 220)
    end
  end
end

local function render(f, lb)
  -- the window grows from its place on the right to the full frame
  local full = expo_out(prog(lb, TAKEOVER, TAKEOVER + 0.7))
  local x, y, w, h = lerp(WIN[1], 0, full), lerp(WIN[2], 0, full), lerp(WIN[3], 1920, full), lerp(WIN[4], 1075.2, full)
  local radius = 14 * (1 - full)
  local enter = snap(lb - 0.5)
  local s = 0.9 + 0.1 * enter
  local t = string.format("translate(%s %s) scale(%s) translate(%s %s)",
    x + w / 2, y + h / 2 + (1 - enter) * 120, s, -(x + w / 2), -(y + h / 2))
  local cmd = prog(lb, 2, 2.4)
  -- the side panel and title leave as the window takes over
  local side = 1 - prog(lb, TAKEOVER - 0.2, TAKEOVER + 0.1)
  local exit = expo_in(prog(lb, 31.5, 32))

  group({ opacity = 1 - exit }, function()
    shader(f, { src = "shaders/grid.sksl", x = 0, y = 0, w = 1920, h = 1080, uniforms = {
      uSpeed = 1.5, uHorizon = 0.7, uBright = 0.3, uInk = "#6f6a63", uHot = ORANGE } })
    group({ opacity = side }, function()
      Slam(150, 205, "WATCH IT", DISPLAY, 110, BONE):draw(lb, 0, 150)
      Slam(820, 205, "LIVE.", DISPLAY, 110, ORANGE):draw(lb - 1, 0, 150)
    end)
    group({ transform = t, opacity = prog(lb, 0.5, 0.6) }, function()
      group({ filter = SHADOW, opacity = 0.55 * (1 - full) }, function()
        rect { x = x, y = y + 18, w = w, h = h, rx = radius, fill = "#000000" }
      end)
      group({ clip_path = ui.rounded_rect(x, y, w, h, radius) }, function()
        video_frame(f, { src = "preview_capture.mp4", x = x, y = y, w = w, h = h, start_from = 0, looping = true })
      end)
      rect { x = x, y = y, w = w, h = h, rx = radius, fill = "none", stroke = "#3d3a35", stroke_width = 1.5,
        opacity = 1 - full }
    end)
    group({ opacity = cmd * side }, function()
      text { "NATIVE PREVIEW WINDOW", x = 150, y = 330, font = MONO, weight = 500, size = 20, letter_spacing = 3, fill = GREY }
      text { "$", x = 150, y = 380, font = MONO, weight = 600, size = 26, fill = ORANGE }
      text { "cargo run -- preview", x = 180, y = 380, font = MONO, weight = 500, size = 26, fill = BONE }
      text { "GPU · WITH SOUND", x = 150, y = 440, font = MONO, weight = 500, size = 20, letter_spacing = 2, fill = BONE }
      text { "NO BROWSER, NO BUNDLER", x = 150, y = 472, font = MONO, weight = 500, size = 20, letter_spacing = 2, fill = BONE }
    end)
    group({ opacity = side }, function()
      for i, key in ipairs(KEYS) do
        local at = 3 + (i - 1) * 0.5
        local k = snap(lb - at)
        local ky = 560 + (i - 1) * 78
        group({ opacity = prog(lb, at, at + 0.1), transform = translate((1 - k) * -60, 0) }, function()
          rect { x = 150, y = ky - 38, w = 120, h = 54, rx = 8, fill = "#161514", stroke = BONE, stroke_opacity = 0.5,
            stroke_width = 1.5 }
          text { key[1], x = 210, y = ky - 3, align = "middle", font = MONO, weight = 600, size = 20, fill = BONE }
          text { key[2], x = 290, y = ky - 3, font = MONO, weight = 500, size = 18, letter_spacing = 2, fill = GREY }
        end)
      end
      callout(WIN[1] + 720, WIN[2] + 12, WIN[1] + 720, 170, "REAL-TIME, FRAME BY FRAME", ORANGE, prog(lb, 6, 6.8))
      callout(WIN[1] + 354, WIN[2] + 630, 560, 975, "PLAY · SEEK · LOOP · SCRUB", BONE, prog(lb, 8, 8.8))
    end)
    takeover(lb)
  end)
end

return { name = "PreviewScene", start = 128, stop = 160, render = render }
