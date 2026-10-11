-- The musical clock (the standard library's beat_clock) and the easing the
-- scenes share. The soundtrack (track.lua) is written on the same grid, so
-- every cut, pop and counter tick lands on a beat by construction. Beat 0 is
-- the first frame.

local M = {}

M.FPS = 60
M.BPM = 120
M.clock = beat_clock(M.BPM)
M.BEAT = M.clock.spb -- seconds per beat

-- ---- easing, all on 0..1 ----------------------------------------------------

-- A snappy spring and a softer one with a visible overshoot, `beats` since
-- they were released on a beat.
local SNAP, SOFT = spring { stiffness = 320, damping = 22 }, spring { stiffness = 170, damping = 13 }
function M.snap(beats) return ease(SNAP, beats * M.BEAT) end
function M.soft(beats) return ease(SOFT, beats * M.BEAT) end

return M
