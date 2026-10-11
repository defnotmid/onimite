-- Act III: the chorus (drums, side-chained bass, stabs, arp, the hook),
-- a cue on every card, glitches on the last chorus's words.
-- Its hits sit on cues.lua's beats; music/parts.lua has what the acts share.

local C = require("cues")
local P = require("music.parts")

local B, bdur = C.time, C.seconds
local sin, floor, min = math.sin, math.floor, math.min

return function()
  local s = P.section(C.CHORUS, C.STOP)
  local grooves = {
    { C.CHORUS, C.ODECS, "kcHobsaf" },
    { C.ODECS, C.NOT, "kcHobsalf" },
    { C.NOT, C.CHECK, "kcHobsaf" },
    { C.CHECK, C.STOP, "kcHobsalf" },
  }
  s.kicks(P.kick_times(grooves), 0.8)
  for _, g in ipairs(grooves) do P.groove(s, g[1], g[2], g[3]) end

  for _, b in ipairs { C.OVG, C.ODECS, C.OKSL, C.NOT, C.CHECK, C.LAST } do P.crash(s, b, 0.7) end
  P.crash(s, C.CHORUS)
  s.impact(B(C.CHORUS), 0.85)
  -- the last chorus builds into the stop
  s.riser(B(C.LAST + 8), bdur(C.LAST + 8, 7.8), 0.4)
  for r = 0, 7 do s.hat(B(C.LAST + 14 + r / 8), 0.045, 90, 0.2 + 0.04 * r) end
  for r = 0, 15 do s.clap(B(C.LAST + 14 + r / 8), 0.2 + 0.02 * r) end

  return P.finish(s)
end
