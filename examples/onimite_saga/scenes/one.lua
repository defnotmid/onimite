local look = require("look")
local fx = require("fx")
local score = require("music.score")
local sfx = require("sfx")
local facts = require("facts")
local snap = look.snap

-- ---- one binary ----------------------------------------------------------------

local function one(f, lb, gb)
  fx.pop(f, 0, look.PINK, look.VIOLET, look.LEMON, look.kick(gb))
  look.pip(f, 940, 170, 960, 540, gb)
  group({ shadow = look.SHADOW }, function()
    look.pop_word("ONE", 110, 440, 330, lb, look.INK, look.DISPLAY, { each = 0.1 })
    look.pop_word("BINARY.", 110, 740, 330, lb - 1, look.LEMON, look.DISPLAY, { each = 0.1 })
  end)
  local chips = { { string.format("%.1f MB", facts.disk_mb), look.INK }, { "0 dependencies", look.INK },
    { "no browser", look.INK }, { "no compiler", look.INK } }
  local x, y = 118, 800
  for i, c in ipairs(chips) do
    local w = look.chip(x, y, c[1], c[2], look.NIGHT, 30, snap(lb - (2 + i)))
    x = x + w + 18
    if i == 2 then x, y = 118, 890 end
  end
end

-- Its sounds (sfx.lua), in beats into the scene.
local SOUNDS = {}
for i = 1, 4 do -- a blip per chip, up the scale
  SOUNDS[#SOUNDS + 1] = sfx.at("one", 2 + i, sfx.blip(660 * 2 ^ ((i - 1) * 2 / 12)), 0.18)
end

local AT = score.time("one")
scene { "One", cue = "one", start = AT, audio = SOUNDS, render = function(f)
  local gb = score.beat(f)
  one(f, gb - score.beat(AT), gb)
end }
