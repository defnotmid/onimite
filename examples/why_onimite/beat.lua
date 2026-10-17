-- The easing the scenes share, on the song's beat (track.lua): springs
-- released on a beat, `beats` after it, as long as the song says those
-- beats last.

local score = require("track")

local M = {}

M.FPS = 60

-- A snappy spring and a softer one with a visible overshoot.
local SNAP, SOFT = spring { stiffness = 320, damping = 22 }, spring { stiffness = 170, damping = 13 }
function M.snap(beats) return beats <= 0 and 0 or ease(SNAP, score.seconds(beats)) end
function M.soft(beats) return beats <= 0 and 0 or ease(SOFT, score.seconds(beats)) end

return M
