-- Act IV: the tape stops (kicks and hats on a tempo falling from 168 to 36,
-- a chord whose pitch falls with it), strings while Pip burns away, a beat
-- of silence and the logo's boom, then the matrix: a boot, a dread pulse, a
-- creeping arp fading in, Pip's theme on bells, and a heartbeat.

local P = require("music.parts")
local held, roll, join, at = P.held, P.roll, P.join, P.beats

-- The creep: sixteenths fading in over three beats (rain@3.5 .. rain@17).
local CREEP = { "Bb4", "C5", "Bb4", "E5", "C5", "Bb4", "A4", "A4" }
local creep = {}
for k = 0, 53 do
  creep[#creep + 1] = { time = at(3.5 + k / 4), note = CREEP[k % 8 + 1], duration = "16n",
    velocity = 0.9 * math.min(1, k / 12) }
end

return {
  drums = {
    { "tape_stop", events = join(roll("kick", 0, 4, 1, 1, 0.6, "8n"), roll("hat", 0.5, 4, 1, 0.5, 0.5),
      { { time = 0, note = "crash", velocity = 0.75 } }) },
  },
  boom = { { "tape_stop", events = { { time = 0, duration = "2n", velocity = 0.5 } } } },
  tape = { { "tape_stop", events = held("A2 A3 C4 E4 A4", 0, "1m") } },
  fall = {
    { "tape_stop", events = { { time = 0, note = "D6", duration = "1m", velocity = 0.8 } } },
    { "rain", events = { { time = 0, note = "F#7", duration = "2n", velocity = 0.4 } } },
  },
  -- Pip burns away
  strings = { { "fade", events = held("A2 A3 E4", 0, "2m"), velocity = 0.8 } },
  -- the slam: a beat of nothing, then a drone under the logo
  slam = { { "slam..rain@1m", events = held("A1 A2 Bb2", "4n", at(7)) } },
  -- the matrix
  drone = { { "rain", events = held("A1 E2 A2 Bb2", 0, "5m"), velocity = 0.8 } },
  bass = { { "rain@4n..rain@4:3", notes = "A1 A1 Bb1 Bb1 A1 A1 A1 A1", subdivision = "8n", duration = "16n.", velocity = 1 } },
  arp = { { "rain", events = creep } },
  bells = { { "rain", events = { { time = at(17.5), note = "A4", duration = "2n", velocity = 0.7 },
    { time = at(18.2), note = "C5", duration = "2n", velocity = 0.7 }, { time = at(18.9), note = "E5", duration = "2n", velocity = 0.7 } } } },
  -- the last thing heard
  heart = { { "rain", events = { { time = at(19.3), note = "Bb1", duration = "4n", velocity = 0.6 },
    { time = at(19.6), note = "C2", duration = "4n", velocity = 0.45 } } } },
}
