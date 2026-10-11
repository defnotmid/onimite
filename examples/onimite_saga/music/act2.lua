-- Act II: the K-pop verse (Am F C G) with a hit on every scene's beat, the
-- tape slowing, a half-time hush with bells, the countdown into the chorus.
-- Its hits sit on cues.lua's beats; music/parts.lua has what the acts share.

local C = require("cues")
local P = require("music.parts")

local B, bdur = C.time, C.seconds
local sin, floor, min = math.sin, math.floor, math.min

return function()
  local s = P.section(C.ONE, C.CHORUS)
  local grooves = {
    { C.ONE, C.RACE, "kchobsf" },
    { C.RACE, C.SLOW, "kchobsaf" },
  }
  s.kicks(P.kick_times(grooves), 0.8)
  for _, g in ipairs(grooves) do P.groove(s, g[1], g[2], g[3]) end

  -- every section opens with a crash
  for _, b in ipairs { C.DOWNLOAD, C.RACE, C.BILL, C.RELOAD } do P.crash(s, b, 0.7) end
  P.crash(s, C.ONE)
  s.impact(B(C.ONE), 0.95)

  -- the tape slows: the kicks follow the tempo down, a stab and a long fall
  for b = C.SLOW, C.SLOW + 3 do s.kick(B(b), 0.8 - 0.1 * (b - C.SLOW)) end
  s.chord(B(C.SLOW), bdur(C.SLOW, 2), { 57, 60, 64, 69 }, 0.08, 2500, 0.003, 3, 0)
  s.fall(B(C.SLOW), bdur(C.SLOW, 4), 0.25, 900, 60)
  -- the hush: pad and bells at half time, two beats a chord
  local HUSH = {
    { { 45, 57, 60, 64 }, { 69, 72, 76, 72 } }, { { 41, 57, 60, 65 }, { 65, 69, 72, 69 } },
    { { 38, 57, 62, 65 }, { 62, 65, 69, 65 } }, { { 36, 55, 60, 64 }, { 64, 67, 72, 67 } },
  }
  for c, h in ipairs(HUSH) do
    local b = C.HUSH + (c - 1) * 2
    s.chord(B(b), bdur(b, 2.1), h[1], 0.1, 900, 0.6, 0, 0, 1100)
    for j = 0, 3 do s.bell(B(b + j * 0.5), h[2][j + 1], 0.06, 2.5, j % 2 == 0 and -0.3 or 0.3) end
  end
  s.bell(B(C.HUSH + 6), 84, 0.1, 1.5, 0)
  -- the countdown: a tom each number, a riser, a roll, and the family
  P.pad(s, C.RISE, 4, { 45, 57, 60, 64 }, 0.1, 800, 6000, 0.5)
  for n = 0, 2 do s.tom(B(C.RISE + n), 90 + n * 25, 0.55) end
  s.riser(B(C.RISE), bdur(C.RISE, 4), 0.35)
  P.crash(s, C.RISE + 3, 0.6)
  s.impact(B(C.RISE + 3), 0.45)
  for r = 1, 3 do s.clap(B(C.RISE + 3 + r / 4), 0.25 + 0.08 * r) end

  return P.finish(s)
end
