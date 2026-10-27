local look = require("look")
local fx = require("fx")
local score = require("music.score")
local sfx = require("sfx")
local facts = require("facts")
local snap = look.snap
local W, H = look.W, look.H

-- ---- the last chorus -----------------------------------------------------------------------

local LAST_WORDS = {
  { "ONE BINARY.", look.INK }, { "ALL YOUR CORES.", look.LEMON }, { "ANY LUA SCRIPT.", look.INK }, { "EVERY FRAME.", look.CYAN },
  { string.format("%.1f× FASTER", facts.RACE[1][4]), look.LEMON },
  { string.format("%.0f× LESS CPU", facts.cpu.ratio), look.INK },
  { string.format("%.0f× LESS RAM", facts.memory.ratio), look.CYAN },
  { string.format("%.1f MB", facts.disk_mb), look.LEMON },
  { "NO BROWSER.", look.INK }, { "NO COMPILER.", look.CYAN }, { "NO WAITING.", look.LEMON },
  { "ONE BINARY.", look.PINK },
}

local function last(f, lb, gb)
  fx.pop(f, 2 + (math.floor(lb / 4) % 2) * 2, "#1d0838", "#ff2d95", "#19e3ff", look.kick(gb))
  local idx, cb
  if lb < 8 then idx = math.floor(lb / 2) + 1; cb = lb - (idx - 1) * 2
  else idx = 5 + math.floor(lb - 8); cb = (lb - 8) % 1 end
  idx = math.min(idx, #LAST_WORDS)
  local w = LAST_WORDS[idx]
  local size = math.min(330, 1700 / look.width(w[1], look.DISPLAY, 330) * 330)
  local amount = math.max(0, 0.9 - cb * 3.5)
  local p = snap(cb)
  fx.glitch(f, function()
    group({ transform = { scale = 1.2 - 0.2 * p, origin = { W / 2, 620 } } }, function()
      text { w[1], x = W / 2, y = 620, align = "center", font = look.DISPLAY, size = size, fill = w[2],
        stroke = look.NIGHT, stroke_width = 8 }
    end)
  end, amount, idx * 3 + math.floor(cb * 6), { x = 0, y = 0, w = W, h = H }, 24)
  look.pip(f, 1380, 640, 520, 420, gb)
  if lb > 15.2 then
    rect { x = 0, y = 0, w = W, h = H, fill = "#ffffff", opacity = progress(lb, 15.2, 16) }
  end
end

-- Its sounds (sfx.lua), in beats into the scene.
local SOUNDS = {}
for _, lb in ipairs { 2, 4, 6, 8, 9, 10, 11, 12, 13, 14, 15 } do -- a glitch on every word
  SOUNDS[#SOUNDS + 1] = sfx.at("last", lb, sfx.glitch(sfx.seconds("last", lb, 0.5)), 0.07)
  SOUNDS[#SOUNDS + 1] = sfx.at("last", lb, sfx.hat(0.5, 1 / 8), 0.45)
end

local AT = score.time("last")
scene { "Last", cue = "last", start = AT, audio = SOUNDS, render = function(f)
  local gb = score.beat(f)
  last(f, gb - score.beat(AT), gb)
end }
