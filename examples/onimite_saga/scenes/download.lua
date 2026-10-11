local look = require("look")
local fx = require("fx")
local C = require("cues")
local sfx = require("sfx")
local facts = require("facts")
local snap = look.snap

-- ---- the download ----------------------------------------------------------------

-- A square per setup (facts.SETUP), its area what the setup puts on disk
-- before the first frame, in bands for its parts; ours beside them.
local K = 10.2 -- px per sqrt(MB)
local BOTTOM = 900

local SQUARES, BANDS = {}, {}
do
  local x, t = 100, 0.5
  for _, setup in ipairs(facts.SETUP) do
    local side = K * math.sqrt(setup.mb)
    local q = { setup = setup, x = x, y = BOTTOM - side, s = side, t0 = t }
    local y = BOTTOM
    for _, part in ipairs(setup.parts) do
      local h = side * part[2] / setup.mb
      y = y - h
      BANDS[#BANDS + 1] = { name = part[1], mb = part[2], x = x, y = y, w = side, h = h, t0 = t, dark = #BANDS % 2 == 1 }
      t = t + 0.5
    end
    q.t1 = t
    SQUARES[#SQUARES + 1] = q
    x = x + side + 40
    t = t + 0.5
  end
end

local ONE_SIDE = K * math.sqrt(facts.ONIMITE_MB)

local function download(f, lb, gb)
  fx.pop(f, 1, "#150a33", "#2a1060", "#4a1c9a", look.kick(gb))
  look.title(lb, 0, "THE DOWNLOAD", 100, 150, 100)
  group({ opacity = progress(lb, 0.4, 1) }, function()
    text { "on disk before the first frame, drawn to scale", x = 104, y = 200, font = look.MONO, size = 24, fill = look.DIM }
  end)
  for _, b in ipairs(BANDS) do
    local p = snap(lb - b.t0)
    if p > 0.001 then
      group({ transform = { scale = { 1, p }, origin = { b.x, b.y + b.h } }, opacity = clamp01(p * 3) }, function()
        rect { x = b.x, y = b.y, w = b.w, h = b.h - 3, rx = 4, fill = look.F, opacity = b.dark and 0.75 or 1 }
        if b.h > 48 then
          text { b.name, x = b.x + 14, y = b.y + b.h / 2 - 4, font = look.MONO, size = 18, fill = "#2a0e06" }
          text { facts.size(b.mb), x = b.x + 14, y = b.y + b.h / 2 + 18, font = look.MONO, size = 18, fill = "#2a0e06" }
        end
      end)
    end
  end
  for _, q in ipairs(SQUARES) do
    group({ opacity = progress(lb, q.t1, q.t1 + 0.5) }, function()
      text { string.format("%s · %d %s · %s", q.setup.name, q.setup.deps, q.setup.kind, facts.size(q.setup.mb)),
        x = q.x, y = q.y - 20, font = look.MONO, size = 22, fill = look.F }
    end)
  end

  -- ours
  local cx, cy = 1450, 560
  local s = snap(lb - 4.5)
  if s > 0.001 then
    local ring = progress(lb, 4.5, 5.5)
    circle { cx = cx, cy = cy, r = 40 + 600 * ease(easing.exponential_out, ring), fill = "none", stroke = look.O, stroke_width = 6,
      stroke_opacity = (1 - ring) * 0.9 }
    group({ transform = { scale = s, origin = { cx, cy } },
      filter = { { "blur", std = 10, input = "SourceAlpha", result = "b" }, { "flood", color = look.O, opacity = 0.9, result = "c" },
        { "composite", op = "in", input = "c", input2 = "b", result = "g" }, { "merge", "g", "SourceGraphic" },
        region = { x = -1, y = -1, w = 3, h = 3 } } }, function()
      rect { x = cx - ONE_SIDE / 2, y = cy - ONE_SIDE / 2, w = ONE_SIDE, h = ONE_SIDE, rx = 3, fill = look.O }
    end)
  end
  group({ opacity = progress(lb, 5.5, 6) }, function()
    text { string.format("%.1f MB", facts.ONIMITE_MB), x = cx, y = 760, align = "center", font = look.DISPLAY, size = 190,
      fill = look.O }
    text { "onimite · 0 dependencies", x = cx, y = 810, align = "center", font = look.MONO, size = 26, fill = look.INK }
  end)
  if lb >= 6.5 then
    local p = snap(lb - 6.5)
    group({ opacity = clamp01(p * 3), transform = { scale = 0.8 + 0.2 * p, origin = { cx, 960 } } }, function()
      text { "DOWNLOAD. RUN.", x = cx, y = 960, align = "center", font = look.DISPLAY, size = 110, fill = look.LEMON }
    end)
  end
end

-- Its sounds (sfx.lua), in beats into the scene.
local SOUNDS = {}
for k, b in ipairs(BANDS) do -- a blip per part, up the scale
  SOUNDS[#SOUNDS + 1] = sfx.at(C.DOWNLOAD, b.t0, sfx.blip(440 * 2 ^ ((k - 1) * 2 / 12)), 0.12)
end
for _, s in ipairs {
  sfx.at(C.DOWNLOAD, 3.5, sfx.whoosh(C.seconds(C.DOWNLOAD + 3.5, 1), 0.1), 0.2), -- then ours
  sfx.at(C.DOWNLOAD, 4.5, sfx.impact(), 0.5),
  sfx.at(C.DOWNLOAD, 5.5, sfx.done(), 0.14),
  sfx.at(C.DOWNLOAD, 6.5, sfx.done(), 0.18),
  sfx.at(C.DOWNLOAD, 6.5, sfx.crash(), 0.5),
} do SOUNDS[#SOUNDS + 1] = s end

scene { "Download", cue = "DOWNLOAD", start = C.time(C.DOWNLOAD), audio = SOUNDS, render = function(f)
  local gb = C.beat(f)
  download(f, gb - C.DOWNLOAD, gb)
end }
