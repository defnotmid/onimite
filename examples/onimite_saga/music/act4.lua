-- Act IV: the tape stops (kicks and hats on a tempo falling from 168 to 36,
-- a chord whose pitch falls with it, an 808 boom), the string sections while
-- Pip burns away, a beat of silence and the logo's drone, then the matrix:
-- a dread pulse a half step apart (C# and D), a creeping arp fading in,
-- Pip's theme on the bells, and a heartbeat.

local P = require("music.parts")
local held, roll, join, at = P.held, P.roll, P.join, P.beats

-- The creep: sixteenths fading in over three beats (rain@3.5 .. rain@17).
local CREEP = { "D5", "E5", "D5", "G#5", "E5", "D5", "C#5", "C#5" }
local creep = {}
for k = 0, 53 do
  creep[#creep + 1] = { time = at(3.5 + k / 4), note = CREEP[k % 8 + 1], duration = "16n",
    velocity = 0.9 * math.min(1, k / 12) }
end

return {
  drums = {
    { "tape_stop", events = join(roll("kick", 0, 4, 1, 1, 0.6, "8n"), roll("hat", 0.5, 4, 1, 0.5, 0.5),
      { { time = 0, note = "crash", velocity = 0.45 } }) },
  },
  boom = { { "tape_stop", events = { { time = 0, note = "C#2", duration = "2n", velocity = 0.5 } } } },
  tape = { { "tape_stop", events = held("C#3 C#4 E4 G#4 C#5", 0, "1m") } },
  fall = {
    { "tape_stop", events = { { time = 0, note = "F#6", duration = "1m", velocity = 0.8 } } },
    { "rain", events = { { time = 0, note = "Bb7", duration = "2n", velocity = 0.4 } } },
  },
  -- Pip burns away
  strings = { { "fade", events = held("C#3 C#4 G#4", 0, "2m"), velocity = 0.8 } },
  -- the slam: a beat of nothing, then a drone under the logo
  slam = { { "slam..rain@1m", events = held("C#2 C#3 D3", "4n", at(7)) } },
  -- the matrix
  drone = { { "rain", events = held("C#2 G#2 C#3 D3", 0, "5m"), velocity = 0.8 } },
  pulse = { { "rain@4n..rain@4:3", notes = "C#2 C#2 D2 D2 C#2 C#2 C#2 C#2", subdivision = "8n", duration = "16n.", velocity = 1 } },
  creep = { { "rain", events = creep } },
  bells = { { "rain", events = { { time = at(17.5), note = "C#5", duration = "2n", velocity = 0.7 },
    { time = at(18.2), note = "E5", duration = "2n", velocity = 0.7 }, { time = at(18.9), note = "G#5", duration = "2n", velocity = 0.7 } } } },
  -- the last thing heard
  heart = { { "rain", events = { { time = at(19.3), note = "D2", duration = "4n", velocity = 0.6 },
    { time = at(19.6), note = "E2", duration = "4n", velocity = 0.45 } } } },
}
