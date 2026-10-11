-- The clock and every cue, in beats from the start (120 BPM, 4 beats a bar,
-- a beat is half a second). The picture (video.lua) and the music
-- (track.lua) both read these numbers.

local T = {}

T.FPS, T.BPM = 60, 120
T.clock = beat_clock(T.BPM)
T.BEAT = T.clock.spb

-- Sections: start beat, scene name. A section runs to the next one's start.
T.SECTIONS = {
  { 0, "Title" },
  { 8, "Bars" },
  { 24, "Line" },
  { 36, "Donut" },
  { 48, "Outro" },
}
T.TOTAL = 60 -- 15 bars, 30 s

-- Title: the emoji pops, the name slams, the subtitle follows.
T.EMOJI, T.NAME, T.SUB = 1, 2, 3
-- Bars: twelve months rise a sixteenth apart, the best month lights up.
T.BARS_GO, T.BARS_STEP, T.PEAK = 9, 0.25, 18
-- Line: the running total draws itself on, then the total pops.
T.LINE_GO, T.LINE_END = 25, 31
-- Donut: a segment a beat, the legend rows with them.
T.DONUT_GO, T.DONUT_STEP = 37, 1
-- Outro: the total counts up over three beats.
T.COUNT_GO, T.COUNT_END = 49, 52

-- Bars where the kick plays (the picture pumps with it).
T.KICK_FROM, T.KICK_TO = 4, 56

return T
