-- Where things happen, read from the song (track.lua): its sections are
-- the scenes, its hits the counters' ticks and the tricks' cuts, the rest
-- positions in its grammar ("race@1m", "agents@2:3"). Each name gives
-- T.X, beats into its scene (what the scenes animate from), and T.at.X,
-- video seconds (where its sound goes).

local score = require("track")
local facts = require("facts")

local T = { at = {} }

-- beats into `section` of video seconds t
local function into(t, section) return score.beat(t) - score.beat(score.time(section)) end
local function put(name, section, times)
  if type(times) == "table" then
    T[name], T.at[name] = {}, times
    for i, t in ipairs(times) do T[name][i] = into(t, section) end
  else
    T[name], T.at[name] = into(times, section), times
  end
end
local function place(name, pos) put(name, pos:match("^[%w_]+"), score.time(pos)) end

-- Title: the slam on the downbeat of bar 2 (the "slam" section).
place("TITLE_SLAM", "slam")

-- Race: bars start on bar 2 and fframes' all take two bars; each onimite
-- bar takes its share of that, its DONE on the nearest eighth (labels show
-- the exact seconds).
place("RACE_GO", "race@1m")
place("RACE_STOP", "race@3m")
do
  local done = {}
  for i, r in ipairs(facts.RACE) do
    done[i] = score.snap(T.at.RACE_GO + r[3] / r[2] * (T.at.RACE_STOP - T.at.RACE_GO), "8n")
  end
  put("RACE_DONE", "race", done)
end

-- Bill: the counters tick on the song's blips, four each (fframes' takes
-- all four, onimite' the first); then the ratios.
do
  local ticks = score.hits { part = "ticks", range = "bill" }
  put("CPU_TICKS", "bill", { ticks[1], ticks[2], ticks[3], ticks[4] })
  put("MEMORY_TICKS", "bill", { ticks[5], ticks[6], ticks[7], ticks[8] })
end
place("CPU_RATIO", "bill@1:1")
place("MEMORY_RATIO", "bill@3m")

-- Shipping: fframes' install lands from beat 1 (scenes/ship.lua times its
-- parts), onimite's on beat 6, the hot reload on beat 9.
place("SHIP_TOTAL", "ship@1:2")
place("RELOAD", "ship@2:1")

-- Agents: the command typed from beat 1, the finding on 3, the fix on 6
-- and the new number on 7, the re-run from 9, clean on 11.
place("AGENT_RUN", "agents@4n")
place("AGENT_FOUND", "agents@0:3")
place("AGENT_FIX", "agents@1:2")
place("AGENT_NUMBER", "agents@1:3")
place("AGENT_RERUN", "agents@2:1")
place("AGENT_CLEAN", "agents@2:3")

-- Tricks: a cut on each of the song's glitch stutters.
put("TRICK_CUTS", "tricks", score.hits { part = "glitch", range = "tricks" })

-- Outro: three lines a half bar apart, then the wordmark; the tail.
put("OUTRO_LINES", "outro", { score.time("outro"), score.time("outro@2n"), score.time("outro@1m") })
place("WORDMARK", "outro@2m")
put("TAIL", "outro", score.time("tail"))

return T
