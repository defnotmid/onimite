-- Act I: a drone in the void, bells on the opening lines, the weight of
-- the setups as thumps, a script typing itself faster and faster into the drop.
-- Its hits sit on cues.lua's beats; music/parts.lua has what the acts share.

local C = require("cues")
local P = require("music.parts")

local B, bdur = C.time, C.seconds
local sin, floor, min = math.sin, math.floor, math.min

return function()
  local s = P.section(C.BEFORE, C.ONE)
  -- the void: a drone on A, then on F minor for the weight
  P.pad(s, C.BEFORE, 8, { 33, 40, 45, 48 }, 0.12, 160, 520, 5)
  P.pad(s, C.WEIGHT, 8, { 29, 36, 41, 44 }, 0.12, 180, 380, 1.5)
  -- the browser: a bell for each line (Pip's theme begins: A, C, E)
  s.bell(B(C.BEFORE + 0.4), 69, 0.1, 1.2, -0.2)
  s.bell(B(C.BEFORE + 3.2), 72, 0.1, 1.2, 0.2)
  s.riser(B(C.BEFORE + 4.4), bdur(C.BEFORE + 4.4, 1.2), 0.1, 0)
  s.bell(B(C.BEFORE + 5.6), 76, 0.12, 1, 0)
  s.bell(B(C.BEFORE + 6.4), 57, 0.08, 1.5, 0)
  -- the weight
  s.bell(B(C.WEIGHT + 0.3), 60, 0.1, 1.2, -0.2)
  s.bell(B(C.WEIGHT + 2.0), 56, 0.12, 1.2, 0.2)
  -- the spark: a pulse starts under the drone, and everything speeds up
  P.pad(s, C.SPARK, 15.5, { 45, 52, 57, 60, 64 }, 0.05, 300, 3500, 3)
  P.pad(s, C.SPARK, 15.5, { 33, 45 }, 0.09, 140, 260, 1)
  for b = C.SPARK + 2, C.SPARK + 14 do
    s.kick(B(b), 0.3 + 0.35 * (b - C.SPARK - 2) / 12)
  end
  for b = C.SPARK + 6, C.SPARK + 15 do
    local g = 0.12 + 0.2 * (b - C.SPARK - 6) / 9
    s.hat(B(b + 0.5), 0.045, 90, g)
    if b >= C.SPARK + 10 then
      s.hat(B(b + 0.25), 0.045, 90, g * 0.7)
      s.hat(B(b + 0.75), 0.045, 90, g * 0.7)
    end
  end
  for b = C.SPARK + 10, C.SPARK + 14 do s.clap(B(b + 1), 0.18 + 0.03 * (b - C.SPARK - 10)) end
  for r = 0, 5 do s.clap(B(C.SPARK + 14 + r / 4), 0.2 + 0.07 * r) end
  s.riser(B(C.SPARK + 8), bdur(C.SPARK + 8, 7.5), 0.35)

  return P.finish(s)
end
