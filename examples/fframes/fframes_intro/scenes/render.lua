-- The second drop: frames of this video fly out of the grid, next to the
-- time it took to render all of them.

local beat = require("beat")
local ui = require("ui")
local facts = require("facts")
local prog, expo_out, expo_in, snap, pulse, lerp, hash, fract, round =
  beat.prog, beat.expo_out, beat.expo_in, beat.snap, beat.pulse, beat.lerp, beat.hash, beat.fract, beat.round
local ORANGE, BONE, INK, MONO, DISPLAY = ui.ORANGE, ui.BONE, ui.INK, ui.MONO, ui.DISPLAY

local THUMBS = 10
local TITLE_W = text_width { "THIS VIDEO.", font = DISPLAY, size = 120, letter_spacing = -4 }

-- Each card's lane, side and place in the world (static).
local CARDS = {}
for k = 0, 13 do
  local side = k % 2 == 0 and -1 or 1
  CARDS[k + 1] = {
    k = k,
    src = string.format("fly_%d.jpg", k % THUMBS),
    xw = side * (620 + hash(k * 3.1) * 520),
    yw = -330 + hash(k * 7.7) * 300,
  }
end

local FADE = linear_gradient { x1 = 0, y1 = 0, x2 = 0, y2 = 1, units = "bbox",
  stops = { { 0, rgba(11, 11, 11, 0) }, { 1, rgba(11, 11, 11, 0.9) } } }

local REALTIME = facts.RENDER_SECONDS > 0 and beat.TOTAL_SECONDS / facts.RENDER_SECONDS or 0

local function render(f, lb)
  -- thumbnails on a stream towards the camera, far ones first
  local t = lb * beat.BEAT
  local cards = {}
  for _, c in ipairs(CARDS) do
    local phase = fract(t * 0.45 + c.k / 14)
    local z = lerp(7, 0.35, phase)
    local w = 520 / z
    cards[#cards + 1] = { z = z, k = c.k, src = c.src, x = 960 + c.xw / z, y = 540 + c.yw / z, w = w, h = w * 9 / 16,
      o = prog(phase, 0, 0.2) * (1 - prog(phase, 0.85, 1)) * prog(lb, 0, 0.3) }
  end
  table.sort(cards, function(a, b) if a.z ~= b.z then return a.z > b.z end return a.k < b.k end)

  local title_w = TITLE_W
  local count = round(facts.FRAMES * expo_out(prog(lb, 0, 3)))
  local secs = facts.RENDER_SECONDS * expo_out(prog(lb, 4, 6))
  local a = snap(lb)
  local b = snap(lb - 4)
  local c = prog(lb, 8, 8.3)
  local exit = expo_in(prog(lb, 15.7, 16))

  group({ opacity = 1 - exit }, function()
    shader(f, { src = "shaders/grid.sksl", x = 0, y = 0, w = 1920, h = 1080, uniforms = {
      uSpeed = 6, uHorizon = 0.5, uBright = 0.9 + pulse(lb, 6) * 0.4, uInk = "#6f6a63", uHot = ORANGE } })
    for _, cd in ipairs(cards) do
      group({ opacity = cd.o }, function()
        image { src = cd.src, x = cd.x - cd.w / 2, y = cd.y - cd.h / 2, w = cd.w, h = cd.h }
        rect { x = cd.x - cd.w / 2, y = cd.y - cd.h / 2, w = cd.w, h = cd.h, fill = "none", stroke = BONE,
          stroke_opacity = 0.35, stroke_width = 1 }
      end)
    end
    rect { x = 0, y = 600, w = 1920, h = 480, fill = FADE }
    group({ transform = translate((1 - snap(lb - 0.5)) * -200, 0), opacity = prog(lb, 0.5, 0.6) }, function()
      rect { x = 120, y = 120, w = title_w + 60, h = 150, fill = ORANGE }
      text { "THIS VIDEO.", x = 150, y = 232, font = DISPLAY, size = 120, letter_spacing = -4, fill = INK }
    end)
    group({ transform = translate(0, (1 - a) * 70), opacity = prog(lb, 0, 0.08) }, function()
      text { ui.thousands(count), x = 150, y = 820, font = DISPLAY, size = 190, letter_spacing = -8, fill = BONE }
      text { "FRAMES · 1920×1080 · 60 FPS", x = 160, y = 880, font = MONO, weight = 600, size = 30, letter_spacing = 6,
        fill = BONE }
    end)
    group({ transform = translate(0, (1 - b) * 70), opacity = prog(lb, 4, 4.08) }, function()
      text { string.format("%.1fs", secs), x = 1770, y = 820, align = "end", font = DISPLAY, size = 190, letter_spacing = -8,
        fill = ORANGE }
      text { "TO RENDER · SKIA ON METAL", x = 1770, y = 880, align = "end", font = MONO, weight = 600, size = 30,
        letter_spacing = 6, fill = BONE }
    end)
    group({ opacity = c }, function()
      rect { x = 1330, y = 170, w = 440, h = 64, fill = ORANGE }
      text { string.format("%.1f× REAL TIME", REALTIME), x = 1550, y = 214, align = "middle", font = MONO, weight = 700,
        size = 30, letter_spacing = 3, fill = INK }
    end)
  end)
end

return { name = "RenderScene", start = 208, stop = 224, render = render }
