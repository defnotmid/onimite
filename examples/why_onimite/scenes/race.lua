-- Eight renders side by side: each lane's bars are the progress of the same
-- video in fframes and in onimite, at their measured relative speeds.
-- fframes' bars all take two bars of music; onimite' finish on the nearest
-- eighth of their share, with a DONE. The speedup pops once both are
-- done, in the winner's colour: the last two lanes are fframes' wins.

local beat = require("beat")
local ui = require("ui")
local T = require("timeline")
local facts = require("facts")
local snap, soft = beat.snap, beat.soft

local TRACK_X, TRACK_W, LANE_Y, LANE_H = 520, 940, 272, 84
local GO, STOP = T.RACE_GO, T.RACE_STOP

local function bar(x, y, w, p, color)
  rect { x = x, y = y, w = w, h = 26, rx = 13, fill = ui.LINE }
  if p > 0 then rect { x = x, y = y, w = math.max(w * p, 26), h = 26, rx = 13, fill = color } end
end

local function lane(i, r, lb)
  local name, fsec, osec, ratio = r[1], r[2], r[3], r[4]
  local done = T.RACE_DONE[i]
  local both = math.max(done, STOP)
  local y = LANE_Y + (i - 1) * LANE_H
  local at = 0.4 * i
  local appear = snap(lb - at)
  local pf = progress(lb, GO, STOP)
  local po = progress(lb, GO, done)
  group({ opacity = progress(lb, at, at + 0.1), transform = translate((1 - appear) * 200, 0) }, function()
    text { name, x = 120, y = y + 52, font = ui.MONO, size = 32, fill = ui.TEXT }
    bar(TRACK_X, y + 10, TRACK_W, pf, ui.F)
    bar(TRACK_X, y + 46, TRACK_W, po, ui.O)
    text { string.format("%.1f s", fsec * pf), x = 1630, y = y + 32, align = "right", font = ui.MONO, size = 26,
      fill = ui.F }
    text { string.format("%.2f s", osec * po), x = 1630, y = y + 68, align = "right", font = ui.MONO, size = 26,
      fill = ui.O }
  end)
  if lb >= done then
    -- DONE pops at the end of the finished bar
    local s = soft(lb - done)
    group({ transform = { scale = s, origin = { TRACK_X + TRACK_W - 70, y + 59 } } }, function()
      rect { x = TRACK_X + TRACK_W - 150, y = y + 40, w = 160, h = 38, rx = 19, fill = ui.O }
      text { "DONE", x = TRACK_X + TRACK_W - 128, y = y + 71, font = ui.DISPLAY, size = 34, fill = ui.BG }
      ui.check(TRACK_X + TRACK_W - 50, y + 47, 24, ui.BG, 5)
    end)
  end
  if lb >= both then
    local s = soft(lb - both)
    group({ transform = { scale = s, origin = { 1760, y + 46 } } }, function()
      text { ratio, x = 1820, y = y + 72, align = "right", font = ui.DISPLAY, size = 72,
        fill = osec < fsec and ui.O or ui.F }
    end)
  end
end

local function render(f, lb)
  ui.header(lb, "RENDER RACE", "wall time · same video · same machine · BENCHMARK.md")
  group({ opacity = progress(lb, 1, 1.2) }, function()
    rect { x = 1290, y = 150, w = 22, h = 22, rx = 6, fill = ui.O }
    text { "onimite (GPU)", x = 1324, y = 169, font = ui.MONO, size = 22, fill = ui.TEXT }
    rect { x = 1290, y = 190, w = 22, h = 22, rx = 6, fill = ui.F }
    text { "fframes", x = 1324, y = 209, font = ui.MONO, size = 22, fill = ui.TEXT }
  end)
  for i, r in ipairs(facts.RACE) do lane(i, r, lb) end
  group({ opacity = progress(lb, 2, 3) }, function()
    text { "onimite is faster on 16 of 18 comparable examples.",
      x = 120, y = 990, font = ui.MONO, size = 20, fill = ui.DIM }
    text { "fframes still wins hello_world and, narrowly, podcast: there the hardware encoder is the bottleneck.",
      x = 120, y = 1020, font = ui.MONO, size = 20, fill = ui.DIM }
  end)
end

-- A DONE as each onimite bar lands, a crash when fframes' land.
local audio = { { sound { "crash", duration = "2n" }, start = T.at.RACE_STOP, gain_db = -8 } }
for _, t in ipairs(T.at.RACE_DONE) do audio[#audio + 1] = { sound { "done", duration = "16n" }, start = t, gain_db = -6 } end

return { name = "Race", section = "race", render = render, audio = audio }
