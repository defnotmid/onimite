local look = require("look")
local fx = require("fx")
local C = require("cues")
local sfx = require("sfx")
local facts = require("facts")
local snap = look.snap

-- ---- the weight ---------------------------------------------------------------

-- What Remotion and fframes need before the first frame (facts.SETUP), as a
-- chart: the size on disk, then the dependencies; a bar drops in on each
-- beat in ROWS, its value counting up as it grows.
local X, MAXW, BAR_H = 400, 1150, 64
local function setup(name)
  for _, s in ipairs(facts.SETUP) do if s.name == name then return s end end
end
local CHARTS = {
  { label = "on disk before the first frame", y = 470, max = 0, value = function(s) return s.mb end,
    text = function(s, v) return facts.size(v) end },
  { label = "dependencies, subdependencies included", y = 760, max = 0, value = function(s) return s.deps end,
    text = function(s, v) return string.format("%d %s", math.floor(v + 0.5), s.kind) end },
}
local ROWS = {}
for c, chart in ipairs(CHARTS) do
  for i, name in ipairs { "Remotion", "fframes" } do
    local s = setup(name)
    chart.max = math.max(chart.max, chart.value(s))
    ROWS[#ROWS + 1] = { chart = chart, setup = s, y = chart.y + 30 + (i - 1) * 90, t0 = 1 + (c - 1) * 2.2 + (i - 1) * 0.8 }
  end
end

local function weight(f, lb)
  local out = 1 - progress(lb, 7.3, 8)
  fx.fog(f, "#4a1c12", 0.55 * progress(lb, 0, 1.5) * out, 0)

  local function line(t, y, s, fill, cue)
    local p = progress(lb, cue, cue + 1.2)
    group({ opacity = p * out, transform = translate(0, (1 - ease(easing.exponential_out, p)) * 20) }, function()
      text { t, x = 160, y = y, font = look.SERIF, italic = true, size = s, fill = fill }
    end)
  end
  line("Lots of downloads.", 230, 96, look.INK, 0.3)
  line("Tons of dependencies.", 350, 96, look.F, 2.4)

  for _, chart in ipairs(CHARTS) do
    group({ opacity = progress(lb, 0.6, 1.2) * out }, function()
      text { chart.label, x = 160, y = chart.y, font = look.MONO, size = 26, fill = look.DIM }
    end)
  end
  for _, r in ipairs(ROWS) do
    local g = snap(lb - r.t0)
    if g > 0.001 then
      local v = r.chart.value(r.setup) * clamp01(g)
      local w = math.max(MAXW * v / r.chart.max, 4)
      group({ opacity = clamp01(g * 4) * out }, function()
        text { r.setup.name, x = 160, y = r.y + 43, font = look.MONO, size = 32, fill = look.INK }
        rect { x = X, y = r.y, w = w, h = BAR_H, rx = 6, fill = look.F }
        text { r.chart.text(r.setup, v), x = X + w + 24, y = r.y + 55, font = look.DISPLAY, size = 64, fill = look.F }
      end)
    end
  end
end

-- Its sounds (sfx.lua), in beats into the scene.
local SOUNDS = {}
for _, r in ipairs(ROWS) do -- a thump as each bar lands, lower and louder the longer it is
  local heavy = r.chart.value(r.setup) / r.chart.max
  SOUNDS[#SOUNDS + 1] = sfx.at(C.WEIGHT, r.t0, sfx.thump(34 - 8 * heavy), 0.4 + 0.3 * heavy)
end
local BIG = ROWS[2].t0 -- fframes' 3.4 GB
SOUNDS[#SOUNDS + 1] = sfx.at(C.WEIGHT, BIG - 0.8, sfx.whoosh(C.seconds(C.WEIGHT + BIG - 0.8, 0.8), 0.05), 0.22)
SOUNDS[#SOUNDS + 1] = sfx.at(C.WEIGHT, BIG, sfx.impact(), 0.7)

scene { "Weight", cue = "WEIGHT", start = C.time(C.WEIGHT), audio = SOUNDS, render = function(f)
  local gb = C.beat(f)
  weight(f, gb - C.WEIGHT, gb)
end }
