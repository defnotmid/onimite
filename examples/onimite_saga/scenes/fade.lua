local look = require("look")
local fx = require("fx")
local C = require("cues")
local pip = dofile("../common/pip.lua")
local sfx = require("sfx")
local W = look.W

-- ---- Pip burns away -----------------------------------------------------------------

local function fade(f, lb, gb)
  fx.fog(f, "#1a1440", 0.25 * (1 - progress(lb, 5, 8)), 0)
  local p = smoothstep(0, 1, progress(lb, 1.3, 6.4))
  local breath = 1 + 0.012 * math.sin(lb * 1.2)
  -- Pip, where the tape stop left it, coming back out of the dark, asleep
  local b = look.PIP_STILL
  fx.dissolve(f, function()
    group({ opacity = progress(lb, 0, 0.6), transform = { scale = breath, origin = { W / 2, b.y + b.size / 2 } } }, function()
      pip.draw(f, { x = b.x, y = b.y, size = b.size, mood = "sleepy" })
    end)
  end, p, nil, lb * 0.6)
  -- one small question, typed
  local line = "pip?"
  local n = math.floor(#line * progress(lb, 5.6, 6.6) + 0.001)
  if n > 0 then
    text { line:sub(1, n), x = W / 2, y = 860, align = "center", font = look.MONO, size = 44, fill = look.DIM,
      opacity = 1 - progress(lb, 7.2, 7.9) }
  end
end

-- Its sounds (sfx.lua), in beats into the scene.
-- embers popping while Pip burns away, then the question typed
local SOUNDS = {}
local lb = 1.3
while lb < 7 do
  local p = math.sin(math.pi * (lb - 1.3) / 5.7)
  local k = math.floor(lb * 100)
  if hash(k) < 0.7 * p * p then
    SOUNDS[#SOUNDS + 1] = sfx.at(C.FADE, lb + hash(k + 1) * 0.04, sfx.crackle(), 0.2 + 0.3 * hash(k + 2), hash(k + 3) * 2 - 1)
  end
  lb = lb + 0.04
end
sfx.add(SOUNDS, sfx.typing(C.FADE, 5.6, 6.6, "pip?", 0.4, 900, function() return sfx.tick(2200) end))

scene { "Fade", cue = "FADE", start = C.time(C.FADE), audio = SOUNDS, render = function(f)
  local gb = C.beat(f)
  fade(f, gb - C.FADE, gb)
end }
