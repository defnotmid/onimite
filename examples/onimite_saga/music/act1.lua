-- Act I: strings and a drone in the void, bells on the opening lines (Pip's
-- theme begins: A, C, E), F minor for the weight, then the build: a 909
-- pulse under an opening pad, everything speeding up into the drop. The
-- riser into it and the drop's impact are the song's transition (score.lua).

local P = require("music.parts")
local held, roll, join, at = P.held, P.roll, P.join, P.beats

return {
  drone = {
    { "before", events = held("A1 E2 A2 C3", 0, "2m") },
    { "weight", events = held("F1 C2 F2 Ab2", 0, "2m") },
    { "spark", events = held("A1 A2", 0, "0:15.5"), velocity = 0.75 },
  },
  strings = {
    { "before", events = held("A2 E3 A3 C4", 0, "2m"), velocity = 0.55 },
    { "weight", events = held("F2 C3 F3 Ab3", 0, "2m"), velocity = 0.7 },
  },
  -- a bell as each line of the browser and the weight appears
  bells = {
    { "before", events = {
      { time = at(0.4), note = "A4", duration = "2n" }, { time = at(3.2), note = "C5", duration = "2n" },
      { time = at(5.6), note = "E5", duration = "2n" }, { time = at(6.4), note = "A3", duration = "2n", velocity = 0.6 } } },
    { "weight", events = { { time = at(0.3), note = "C4", duration = "2n" }, { time = at(2), note = "Ab3", duration = "2n", velocity = 1 } } },
  },
  sweep = { { "before", events = { { time = at(4.4), duration = at(1.2), velocity = 0.1 } } } },
  -- the spark: a pad opening under the code, the pulse coming in and
  -- growing, hats, claps on every beat, a roll into the drop
  swell = { { "spark", events = held("A2 E3 A3 C4 E4", 0, "0:15.5") } },
  drums = {
    { "spark", events = join(
      roll("kick", 2, 13, 1, 0.35, 0.75, "8n"),
      roll("hat", 6.5, 10, 1, 0.4, 1),
      roll("hat", 10.25, 12, 0.5, 0.3, 0.7),
      roll("clap", 11, 4, 1, 0.4, 0.65),
      roll("clap", 14, 6, 0.25, 0.45, 1)) },
  },
}
