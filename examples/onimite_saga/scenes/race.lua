local look = require("look")
local fx = require("fx")
local score = require("music.score")
local sfx = require("sfx")
local facts = require("facts")
local snap = look.snap

-- ---- the race ----------------------------------------------------------------

-- A row per video (facts.RACE, fastest win first). Each row is its own race
-- in its own time: fframes' bar fills the row's width over [GO, STOP], and
-- onimite' bar grows just as fast, so it stops at its share of fframes' time
-- and the speed-up lands in the right-hand column.
local X0, W, COL = 400, 1000, 1640
local GO, STOP = 1, 6
-- Where onimite's bar for row r finishes: its share of fframes' time, on the
-- nearest half beat (the labels show the exact seconds).
local function finish(r) return GO + math.floor((STOP - GO) * r[3] / r[2] * 2 + 0.5) / 2 end

local function race(f, lb, gb)
  fx.pop(f, 3, "#1d0838", "#35105f", "#ff2d95", look.kick(gb) * 0.5)
  look.title(lb, 0, "SAME VIDEO. SAME MACHINE.", 100, 140, 96)
  group({ opacity = progress(lb, 0.3, 0.9) }, function()
    text { "seconds to render · shorter is faster", x = 104, y = 196, font = look.MONO, size = 24, fill = look.DIM }
    local LX = 760
    rect { x = LX, y = 176, w = 22, h = 22, rx = 4, fill = look.F }
    text { "fframes", x = LX + 32, y = 196, font = look.MONO, size = 24, fill = look.INK }
    rect { x = LX + 180, y = 176, w = 22, h = 22, rx = 4, fill = look.O }
    text { "onimite", x = LX + 212, y = 196, font = look.MONO, size = 24, fill = look.INK }
    text { "faster", x = COL, y = 196, font = look.MONO, size = 24, fill = look.DIM }
  end)
  local q = progress(lb, GO, STOP)
  for i, r in ipairs(facts.RACE) do
    local y = 250 + (i - 1) * 124
    local share = (finish(r) - GO) / (STOP - GO)
    local p = snap(lb - (0.3 + i * 0.12))
    -- each row slides in across the left edge: the clip says the cut is meant
    group({ clip = { x = 0, y = 0, w = look.W, h = look.H } }, function()
      group({ opacity = clamp01(p * 3), transform = translate((1 - p) * -120, 0) }, function()
        text { r[1], x = 100, y = y + 58, font = look.MONO, size = 30, fill = look.INK }
        local wf, wo = math.max(W * q, 2), math.max(W * math.min(q, share), 2)
        rect { x = X0, y = y, w = wf, h = 42, rx = 6, fill = look.F }
        rect { x = X0, y = y + 50, w = wo, h = 42, rx = 6, fill = look.O }
        if q > 0 then
          text { string.format("%.1f s", r[2] * q), x = X0 + wf + 14, y = y + 31, font = look.MONO, size = 22, fill = look.F }
          text { string.format("%.2f s", r[3] * math.min(q, share) / share), x = X0 + wo + 14, y = y + 81, font = look.MONO,
            size = 22, fill = look.O }
        end
      end)
    end)
    if q >= share then
      local pp = snap((q - share) * (STOP - GO))
      group({ opacity = clamp01(pp * 3), transform = { scale = 0.6 + 0.4 * pp, origin = { COL, y + 80 } } }, function()
        text { string.format("%.1f×", r[4]), x = COL, y = y + 80, font = look.DISPLAY, size = 84, fill = look.LEMON }
      end)
    end
  end
  group({ opacity = 0.9 }, function()
    text { string.format("wall seconds, %s · %s · %s · BENCHMARK.md", facts.runs, facts.machine, facts.versions), x = 100, y = 1040,
      font = look.MONO, size = 20, fill = look.DIM }
  end)
end

-- Its sounds (sfx.lua), in beats into the scene.
local SOUNDS = {}
for _, r in ipairs(facts.RACE) do -- a DONE as each onimite bar finishes
  SOUNDS[#SOUNDS + 1] = sfx.at("race", finish(r), sfx.done(), 0.14)
end

local AT = score.time("race")
scene { "Race", cue = "race", start = AT, audio = SOUNDS, render = function(f)
  local gb = score.beat(f)
  race(f, gb - score.beat(AT), gb)
end }
