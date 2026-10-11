-- Where things happen, in beats from the start of the video (4 beats a
-- bar). The scenes animate from these numbers and track.lua puts its hits
-- on them, so picture and sound share one list.

local facts = require("facts")

local T = {}

-- Sections: 4 bars each, the outro has a bar of tail.
T.TITLE, T.RACE, T.BILL, T.SHIP, T.AGENTS, T.TRICKS, T.OUTRO, T.TOTAL = 0, 16, 32, 48, 64, 80, 96, 116

-- Title: glitches on beats 0 and 2, the slam on the downbeat of bar 2.
T.TITLE_GLITCHES = { 0, 2 }
T.TITLE_SLAM = 4

-- Race (beats inside the section): bars start at RACE_GO and fframes' bars
-- all take RACE_BEATS; each onimite bar takes its share of that, on the
-- nearest half beat (labels show the exact seconds).
T.RACE_GO, T.RACE_BEATS = 4, 8
T.RACE_DONE = {}
for i, r in ipairs(facts.RACE) do
  T.RACE_DONE[i] = T.RACE_GO + math.floor(r[3] / r[2] * T.RACE_BEATS * 2 + 0.5) / 2
end

-- Bill: counters tick on beats; fframes' takes four ticks, onimite' one.
T.CPU_TICKS = { 1, 2, 3, 4 }
T.MEMORY_TICKS = { 8, 9, 10, 11 }
T.CPU_RATIO, T.MEMORY_RATIO = 5, 12

-- Shipping: fframes' install lands from beat 1 (scenes/ship.lua times its
-- parts), onimite's on beat 6, the hot reload on beat 9.
T.SHIP_TOTAL, T.RELOAD = 6, 9

-- Agents: the command typed from beat 1, the finding on 3, the fix on 6
-- (the new number on 7), the re-run from 9, clean on 11.
T.AGENT_RUN, T.AGENT_FOUND, T.AGENT_FIX, T.AGENT_RERUN, T.AGENT_CLEAN = 1, 3, 6, 9, 11

-- Tricks: a cut per bar, each with a glitch.
T.TRICK_CUTS = { 4, 8, 12 }

-- Outro: three lines, then the wordmark.
T.OUTRO_LINES = { 0, 2, 4 }
T.WORDMARK = 8

return T
