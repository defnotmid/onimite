local look = require("look")
local fx = require("fx")
local C = require("cues")
local sfx = require("sfx")
local facts = require("facts")
local snap = look.snap

-- ---- the bill ----------------------------------------------------------------

local function card(x, lb, cue, head, sub, big_from, big_to, unit_from, unit_to, ratio, fmt_from, fmt_to)
  local s = snap(lb - cue)
  if s <= 0.001 then return end
  group({ opacity = clamp01(s * 3), transform = { translate = { 0, (1 - s) * 60 } } }, function()
    rect { x = x, y = 190, w = 820, h = 760, rx = 36, fill = "#0e0720", opacity = 0.82, stroke = look.PINK, stroke_width = 3 }
    text { head, x = x + 50, y = 270, font = look.DISPLAY, size = 78, fill = look.INK }
    text { sub, x = x + 52, y = 315, font = look.MONO, size = 22, fill = look.DIM }
    local c1 = ease(easing.exponential_out, progress(lb, cue + 0.5, cue + 1.5))
    text { fmt_from(big_from * c1), x = x + 50, y = 520, font = look.DISPLAY, size = 190, fill = look.F }
    local strike = ease(easing.exponential_out, progress(lb, cue + 1.5, cue + 2))
    if strike > 0.01 then rect { x = x + 40, y = 455, w = 520 * strike, h = 10, rx = 5, fill = look.PINK } end
    local c2 = snap(lb - (cue + 2))
    if c2 > 0.001 then
      group({ opacity = clamp01(c2 * 3), transform = { scale = 0.7 + 0.3 * c2, origin = { x + 50, 700 } } }, function()
        text { fmt_to, x = x + 50, y = 720, font = look.DISPLAY, size = 230, fill = look.O }
      end)
    end
    local c3 = snap(lb - (cue + 3))
    if c3 > 0.001 then
      group({ opacity = clamp01(c3 * 3), transform = { scale = 0.6 + 0.4 * c3, origin = { x + 770, 880 } } }, function()
        text { ratio, x = x + 770, y = 900, align = "right", font = look.DISPLAY, size = 150, fill = look.LEMON }
      end)
    end
  end)
end

local function bill(f, lb, gb)
  fx.pop(f, 2, "#12062e", "#2a0c5a", "#8a5cff", look.kick(gb) * 0.6)
  look.title(lb, 0, "THE BILL", 100, 140, 96)
  local cpu_x = facts.CPU.fframes / facts.CPU.onimite
  local mem_x = facts.MEMORY.fframes * 1000 / facts.MEMORY.onimite
  card(100, lb, 1, "CPU TIME", "tiktok · user + sys seconds", facts.CPU.fframes, facts.CPU.onimite, "s", "s",
    string.format("%.0f× less", cpu_x), function(v) return string.format("%.0f s", v) end, string.format("%.1f s", facts.CPU.onimite))
  card(1000, lb, 4, "PEAK MEMORY", "beta · max resident set", facts.MEMORY.fframes, facts.MEMORY.onimite, "GB", "MB",
    string.format("%.0f× less", mem_x), function(v) return string.format("%.0f GB", v) end, string.format("%d MB", facts.MEMORY.onimite))
end

-- Its sounds (sfx.lua), in beats into the scene: on the beat grid (inspect's
-- off_beat). Each card: in on a beat, counting up as a 16th roll, a whoosh
-- into the strike, the result on the next beat, the ratio's boom a beat later.
local SOUNDS = {}
for _, cue in ipairs { 1, 4 } do
  for _, s in ipairs {
    sfx.at(C.BILL, cue, sfx.blip(880), 0.16),
    sfx.at(C.BILL, cue + 1.5, sfx.whoosh(C.seconds(C.BILL + cue + 1.5, 0.5)), 0.15),
    sfx.at(C.BILL, cue + 2, sfx.done(), 0.16),
    sfx.at(C.BILL, cue + 3, sfx.impact(), 0.4),
    sfx.at(C.BILL, cue + 3, sfx.crash(), 0.5),
  } do SOUNDS[#SOUNDS + 1] = s end
  for j = 0, 7 do SOUNDS[#SOUNDS + 1] = sfx.at(C.BILL, cue + 0.5 + j * 0.125, sfx.blip(600 + j * 70), 0.08) end
end

scene { "Bill", cue = "BILL", start = C.time(C.BILL), audio = SOUNDS, render = function(f)
  local gb = C.beat(f)
  bill(f, gb - C.BILL, gb)
end }
