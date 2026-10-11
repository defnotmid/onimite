-- Act IV: the tape stops, Pip's embers, the slam, the matrix and a heartbeat.
-- Its hits sit on cues.lua's beats; music/parts.lua has what the acts share.

local C = require("cues")
local P = require("music.parts")

local B, bdur = C.time, C.seconds
local sin, floor, min = math.sin, math.floor, math.min

return function()
  local s = P.section(C.STOP, C.END)
  -- the tape stops: kicks and hats at a tempo that falls away, a chord that
  -- falls with it
  P.crash(s, C.STOP, 0.7)
  s.impact(B(C.STOP), 0.5)
  for b = C.STOP, C.STOP + 3 do
    s.kick(B(b), 0.9 - 0.12 * (b - C.STOP))
    s.hat(B(b + 0.5), 0.045, 90, 0.2)
  end
  s.tape_chord(B(C.STOP), bdur(C.STOP, 4), { 45, 57, 60, 64, 69 }, 0.1)
  s.fall(B(C.STOP), bdur(C.STOP, 4), 0.2, 1200, 40)
  -- Pip burns away: a thin pad
  s.chord(B(C.FADE), bdur(C.FADE, 8), { 45, 57, 64 }, 0.14, 700, 2, 0.25, 0, 500)
  -- the slam: a beat of silence, then a drone under the logo
  P.pad(s, C.LOGO_HIT, 7, { 33, 45, 46 }, 0.18, 300, 120, 0.05)
  -- the matrix: a boot, a dread pulse, a creeping arp, Pip's theme
  s.fall(B(C.RAIN), bdur(C.RAIN, 2), 0.1, 3000, 200)
  P.pad(s, C.RAIN, 20, { 33, 40, 45, 46 }, 0.12, 200, 1500, 4)
  local DREAD = { 33, 33, 34, 33 }
  for b = C.RAIN + 1, C.RAIN + 19 do
    for h = 0, 1 do
      s.bass(B(b + h / 2), bdur(b + h / 2, 0.45), DREAD[b % 4 + 1], 0.3)
    end
  end
  local CREEP = { 57, 58, 60, 58, 64, 60, 58, 57 }
  local n = 0
  for b = C.RAIN + 3.5, C.RAIN + 17, 0.25 do
    n = n + 1
    s.pluck(B(b), CREEP[n % 8 + 1] + 12, 0.06 * min(1, (b - C.RAIN - 3.5) / 3), n % 2 == 0 and -0.5 or 0.5)
  end
  s.bell(B(C.RAIN + 17.5), 69, 0.08, 1.3, -0.2)
  s.bell(B(C.RAIN + 18.2), 72, 0.08, 1.3, 0.2)
  s.bell(B(C.RAIN + 18.9), 76, 0.08, 1.3, 0)
  -- the last thing heard: a heartbeat
  s.thump(B(C.RAIN + 19.3), 34, 0.6)
  s.thump(B(C.RAIN + 19.6), 36, 0.45)

  return P.finish(s)
end
