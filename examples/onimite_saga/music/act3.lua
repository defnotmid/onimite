-- Act III: the chorus at 144 is Jersey club: the kick bouncing on its
-- broken triplets (one, the a of one, the and of two, three ...), the clap
-- on two and four, sixteenth hats, the 808 riding the kicks, the stabs in
-- the gaps, the arp all the way, Pip's hook (the lead with the violins on
-- it) over the family's cards and the check, a crash on every card. The
-- chords are the royal road (Amaj7 B7 G#m7 C#m9). The last chorus
-- accelerates to 168 and builds into the stop: a hat roll, a clap roll.

local P = require("music.parts")
local roll, join, at, HOOK = P.roll, P.join, P.beats, P.HOOK

local CHORUS = "montage..tape_stop"
local BOUNCE = { "x..x..x.x..x..x.", "x..x..x.x..x.x.x" }

return {
  drums = {
    { CHORUS, humanize = 0.002, steps = { kick = BOUNCE, clap = { "....x.......x...", "....x.......xoxX" } }, velocity = 0.95 },
    { CHORUS, humanize = 0.002, steps = { hat = "xoxoxoxoxoxoxoxo", open_hat = "..x.......x....." }, velocity = 0.6 },
    { "ovg..last", steps = { crash = { "x...............", "" } }, velocity = 0.45 },
    { "last", steps = { crash = { "x...............", "", "", "" } }, velocity = 0.45 },
    { "last", events = join(roll("hat", 14, 8, 0.125, 0.5, 1), roll("clap", 14, 16, 0.125, 0.4, 1)) },
  },
  -- the 808 on the bounce: the root, the octave, the fifth
  bass = { { CHORUS, degrees = "1 . . 1 . . 8 . 1 . . 5 . . 1 . | 1 . . 1 . . 8 . 1 . . 5 . 7 . 8", subdivision = "16n", velocity = 0.9 } },
  stabs = { { "montage..last", chords = { voicing = "close", rhythm = "....x.......x..." }, duration = "8n" } },
  arp3 = { { "montage..last", degrees = "1 3 5 8 5 3 5 8", subdivision = "16n", velocity = 0.55, humanize = 0.002 } },
  lead = {
    { "odecs", notes = HOOK.HOME, subdivision = "8n" },
    { "oksl", notes = HOOK.UP, subdivision = "8n" },
    { "check", notes = HOOK.UP, subdivision = "8n" },
    { "last", notes = HOOK.UP .. " " .. HOOK.TURN, subdivision = "8n" },
  },
}
