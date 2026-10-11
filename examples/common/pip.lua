-- Pip, the mascot (pip.svg, made by tools/mascot/pip.py): a tiny pixel-art
-- firecracker that bounces on the beat, blinks, and keeps its fuse sparking.
-- Not part of onimite; load it the way the examples do:
--
--   local pip = dofile("../common/pip.lua")
--   pip.draw(f, { x = 760, y = 300, size = 400, beat = clock.beat(f) })
--
-- Options: x, y, size (the 32x32 sprite drawn size x size, crisp at any
-- size), beat (bounce: a squash on every whole beat), mood ("happy",
-- "surprised", "sleepy", "boom"), opacity, seed (when it blinks), blink (true
-- or false: blinking now or not, for loops that must repeat exactly).

local P = {}

-- pip.svg sits next to this file, wherever the script that loads it is.
local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
local file = assert(io.open(here .. "pip.svg"), "pip.lua: pip.svg is missing next to it")
P.MARKUP = file:read("a")
file:close()

-- The time `t` (seconds) or frame `t` (its clock) as seconds.
local function seconds(t) return type(t) == "table" and t.seconds or t end

function P.draw(t, o)
  local s = seconds(t)
  local size = o.size or 256
  local x, y = o.x or 0, o.y or 0
  local mood = o.mood or "happy"
  -- a blink every few seconds (never while surprised or asleep)
  local seed = o.seed or 0
  local period = 2.6 + hash(seed) * 1.4
  local blink = mood == "sleepy" or (mood ~= "surprised" and (s + hash(seed + 1) * period) % period < 0.12)
  if o.blink ~= nil then blink = o.blink end
  -- the fuse flickers between two sparks; a burst on "boom"; out while asleep
  local flick = math.floor(s * 12) % 2 == 0
  local overrides = {
    eyes_open = { visible = not blink and mood ~= "surprised" },
    eyes_closed = { visible = blink },
    eyes_o = { visible = mood == "surprised" and not blink },
    mouth_smile = { visible = mood ~= "surprised" },
    mouth_o = { visible = mood == "surprised" },
    spark_a = { visible = mood ~= "sleepy" and mood ~= "boom" and flick },
    spark_b = { visible = mood ~= "sleepy" and mood ~= "boom" and not flick },
    spark_boom = { visible = mood == "boom" },
  }
  -- squash and stretch on the beat, about its feet
  local k = o.beat and pulse(o.beat, 7) or 0
  local hop = o.beat and math.abs(math.sin(o.beat * math.pi)) * size * 0.04 or 0
  group({ opacity = o.opacity, transform = scale(1 + 0.08 * k, 1 - 0.08 * k, x + size / 2, y + size * 0.86) }, function()
    svg { markup = P.MARKUP, x = x, y = y - hop, w = size, h = size, overrides = overrides }
  end)
end

return P
