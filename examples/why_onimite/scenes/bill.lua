-- What the same render costs the machine: CPU seconds of tiktok and peak
-- memory of beta, counters ticking on the beat (fframes' takes four ticks,
-- onimite' one), then the ratio.

local beat = require("beat")
local ui = require("ui")
local T = require("timeline")
local facts = require("facts")
local snap, soft = beat.snap, beat.soft

local CPU, MEM = facts.CPU, facts.MEMORY

local function panel(lb, x, appear_at, ticks, ratio_at, p)
  local appear = snap(lb - appear_at)
  local fv = ui.ticked(lb, ticks)
  local ov = ui.ticked(lb, { ticks[1] })
  group({ opacity = progress(lb, appear_at, appear_at + 0.1), transform = translate(0, (1 - appear) * 80) }, function()
    rect { x = x, y = 290, w = 820, h = 640, rx = 28, fill = ui.PANEL, stroke = ui.LINE, stroke_width = 2 }
    text { p.label, x = x + 48, y = 356, font = ui.MONO, size = 26, fill = ui.DIM }
    text { "fframes", x = x + 48, y = 430, font = ui.MONO, size = 28, fill = ui.F }
    text { p.fframes(fv), x = x + 40, y = 600, font = ui.DISPLAY, size = 190, fill = ui.F }
    text { "onimite", x = x + 48, y = 680, font = ui.MONO, size = 28, fill = ui.O }
    text { p.onimite(ov), x = x + 40, y = 850, font = ui.DISPLAY, size = 190, fill = ui.O }
    -- bars to scale: onimite' is a sliver
    if fv > 0 then rect { x = x + 540, y = 520, w = 240 * fv, h = 44, rx = 8, fill = ui.F } end
    rect { x = x + 540, y = 770, w = math.max(240 * ov * p.share, 3), h = 44, rx = 2, fill = ui.O }
  end)
  if lb >= ratio_at then
    local s = soft(lb - ratio_at)
    group({ transform = { rotate = -4, scale = s, origin = { x + 600, 880 } } }, function()
      rect { x = x + 370, y = 845, w = 460, h = 80, rx = 14, fill = ui.O }
      text { p.ratio, x = x + 600, y = 905, align = "center", font = ui.DISPLAY, size = 64, fill = ui.BG }
    end)
  end
end

local function render(f, lb)
  ui.header(lb, "THE BILL", "what the same render costs your machine")
  panel(lb, 120, 0.5, T.CPU_TICKS, T.CPU_RATIO, {
    label = "CPU TIME · " .. CPU.example,
    fframes = function(v) return string.format("%d s", math.floor(CPU.fframes * v + 0.5)) end,
    onimite = function(v) return string.format("%.1f s", CPU.onimite * v) end,
    share = CPU.onimite / CPU.fframes,
    ratio = string.format("%d× LESS CPU", math.floor(CPU.fframes / CPU.onimite + 0.5)),
  })
  panel(lb, 980, 7, T.MEMORY_TICKS, T.MEMORY_RATIO, {
    label = "PEAK MEMORY · " .. MEM.example,
    fframes = function(v) return string.format("%d GB", math.floor(MEM.fframes * v + 0.5)) end,
    onimite = function(v) return string.format("%d MB", math.floor(MEM.onimite * v + 0.5)) end,
    share = MEM.onimite / (MEM.fframes * 1000),
    ratio = string.format("%d× LESS MEMORY", math.floor(MEM.fframes * 1000 / MEM.onimite + 0.5)),
  })
  group({ opacity = progress(lb, 1, 2) }, function()
    text { "CPU = user + sys, memory = peak RSS · BENCHMARK.md full run, median of 3",
      x = 120, y = 1010, font = ui.MONO, size = 20, fill = ui.DIM }
  end)
end

return { name = "Bill", start = T.BILL, stop = T.SHIP, render = render }
