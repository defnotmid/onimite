-- Act I: the string sections and a drone in the void, bells on the opening
-- lines (Pip's theme begins: C#, E, G#), A minor for the weight (a minor
-- sixth, borrowed: the darkest chord near home), then the build: a 909 pulse
-- under a pad whose filter opens with the tempo, everything speeding up
-- into the drop. The build is the rolls and the opening filter, no riser;
-- the drop's boom and crash are in score.lua.

local P = require("music.parts")
local held, roll, join, at = P.held, P.roll, P.join, P.beats

return {
  drone = {
    { "before", events = held("C#2 G#2 C#3 E3", 0, "2m") },
    { "weight", events = held("A1 E2 A2 C3", 0, "2m") },
    { "spark", events = held("C#2 C#3", 0, "0:15.5"), velocity = 0.75 },
  },
  strings = {
    { "before", events = held("C#3 G#3 D#4 E4", 0, "2m"), velocity = 0.55 },
    { "weight", events = held("A2 E3 A3 C4", 0, "2m"), velocity = 0.7 },
  },
  -- a bell as each line of the browser and the weight appears
  bells = {
    { "before", events = {
      { time = at(0.4), note = "C#5", duration = "2n" }, { time = at(3.2), note = "E5", duration = "2n" },
      { time = at(5.6), note = "G#5", duration = "2n" }, { time = at(6.4), note = "C#4", duration = "2n", velocity = 0.6 } } },
    { "weight", events = { { time = at(0.3), note = "E4", duration = "2n" }, { time = at(2), note = "C4", duration = "2n", velocity = 1 } } },
  },
  -- the spark: a pad opening under the code, the pulse coming in and
  -- growing, hats, claps on every beat, a roll into the drop
  swell = { { "spark", events = held("C#3 G#3 C#4 E4 G#4", 0, "0:15.5") } },
  drums = {
    { "spark", events = join(
      roll("kick", 2, 13, 1, 0.35, 0.75, "8n"),
      roll("hat", 6.5, 10, 1, 0.4, 1),
      roll("hat", 10.25, 12, 0.5, 0.3, 0.7),
      roll("clap", 11, 4, 1, 0.4, 0.65),
      roll("clap", 14, 6, 0.25, 0.45, 1)) },
  },
}
