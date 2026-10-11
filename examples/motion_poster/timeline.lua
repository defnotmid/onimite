-- The clock and every cue, in beats from the start (120 BPM, 4 beats a bar,
-- 10 bars = 20 s). The picture (video.lua) and the music (track.lua) both
-- read these numbers.

local T = {}

T.FPS, T.BPM = 60, 120
T.clock = beat_clock(T.BPM)
T.BEAT = T.clock.spb
T.TOTAL = 40

-- Sections (labels for timeline, strips and per-section loudness).
T.SECTIONS = { { 0, "Intro" }, { 8, "Groove" }, { 24, "Break" }, { 32, "Finale" } }

-- Intro: the field fades up, the type grows out of nothing (erode -> 0).
T.FIELD_IN, T.TYPE_IN, T.TYPE_SET = 0, 2, 8
-- Where the kick plays: the type's outline breathes and the shader ripples.
T.KICK = { { 8, 24 }, { 32, 40 } }
-- Break: the type thins, the light slows, a riser swirls into the finale.
T.BREAK, T.RISER, T.FINALE = 24, 28, 32

function T.kicking(b)
  for _, s in ipairs(T.KICK) do if b >= s[1] and b < s[2] then return true end end
  return false
end

return T
