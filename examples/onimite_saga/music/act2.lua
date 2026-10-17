-- Act II: the K-pop verse (Am F C G, a chord a bar): four on the floor, an
-- offbeat bass and stabs pumping under the kick, a clap fill at the end of
-- every scene, a crash on each scene's downbeat, the arp from the race on.
-- Then the tape slows (the tempo falls under the kicks), a half-time hush on
-- a quiet piano, and the countdown into the chorus.

local P = require("music.parts")
local held, roll, join, at = P.held, P.roll, P.join, P.beats

local VERSE = "one..slow"

return {
  drums = {
    { VERSE, steps = { kick = "x...x...x...x...", clap = { "....x.......x...", "....x.......xoxX" } }, velocity = 0.95 },
    { VERSE, steps = { hat = "x...x...x...x...", open_hat = "..x...x...x...x." }, velocity = 0.6 },
    { "download..slow", steps = { crash = { "x...............", "" } }, velocity = 0.75 },
    -- the tape slows: the kicks follow the tempo down
    { "slow", events = roll("kick", 0, 4, 1, 0.9, 0.55, "8n") },
    -- the countdown: a tom each number, a crash and a roll on the family
    { "rise", events = join(
      { { time = at(0), note = "tom_low", velocity = 0.8 }, { time = at(1), note = "tom_mid", velocity = 0.85 },
        { time = at(2), note = "tom_high", velocity = 0.9 }, { time = at(3), note = "crash", velocity = 0.7 } },
      roll("clap", 3.25, 3, 0.25, 0.55, 0.85)) },
  },
  bass = { { VERSE, degrees = ". 1 8 1 . 1 8 1 . 1 8 1 . 1 8 1", subdivision = "16n", duration = "0:0:0.85" } },
  stabs = {
    { VERSE, chords = { voicing = "close", rhythm = "x.....x.....x..." }, duration = "8n" },
    { "slow", events = held("A3 C4 E4 A4", 0, "2n", 0.9) },
  },
  arp = { { "race..slow", degrees = "1 3 5 8 5 3 5 8", subdivision = "16n", velocity = 0.7 } },
  fall = { { "slow", events = { { time = 0, note = "A5", duration = "1m", velocity = 1 } } } },
  -- the hush (a bar of two beats a chord): the piano's broken chords over
  -- the pad, the roots below, a high C as the last line lands
  piano = {
    { "hush", degrees = "1 3 5 3", subdivision = "8n", velocity = 0.45 },
    { "hush", degrees = "1 . . .", subdivision = "8n", octave = 2, velocity = 0.4 },
    { "hush", events = { { time = at(6), note = "C6", duration = "2n", velocity = 0.5 } } },
  },
  pad = { { "hush", chords = { voicing = "open" }, octave = 3, velocity = 0.8 } },
  swell = { { "rise", events = held("A2 A3 C4 E4", 0, "1m", 1) } },
  boom = { { "rise", events = { { time = at(3), duration = "2n", velocity = 0.6 } } } },
}
