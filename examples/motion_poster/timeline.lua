-- Every cue the picture uses, read from the soundtrack (track.lua) in video
-- seconds: its sections, and the notes it really plays (the kicks, the
-- riser, the impact).

local score = require("track")
local T = { score = score, FPS = 60, BEAT = score.seconds("4n") }

-- Intro: the type grows out of nothing from the second beat to the groove.
T.TYPE_IN, T.TYPE_SET = score.time("intro@2n"), score.time("groove")
-- The kicks: the type's outline breathes and the shader ripples on each.
T.KICKS = score.hits { part = "drums", note = "kick" }
-- Break: the type thins over its first two beats; the riser swirls the
-- poster into the finale, which lands on the impact.
T.BREAK, T.THIN = score.time("break"), score.time("break@2n")
local riser = score.events { part = "riser" }[1]
T.RISER = riser.time
T.FINALE = cue("impact", score.hits { part = "impact" }[1])

T.BARS = 0
for _, s in ipairs(score.sections) do T.BARS = T.BARS + s.bars end

-- The seconds since the last kick at or before t (nil before the first).
function T.since_kick(t)
  local last
  for _, k in ipairs(T.KICKS) do
    if k > t then break end
    last = k
  end
  return last and t - last
end

return T
