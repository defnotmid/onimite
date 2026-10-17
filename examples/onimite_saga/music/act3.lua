-- Act III: the chorus at 144: the verse's groove on sixteenth hats, the arp
-- all the way, Pip's hook over the family's second and third cards and the
-- check, a crash on every card. The last chorus accelerates to 168 and
-- builds into the stop: a riser, a hat roll, a clap roll.

local P = require("music.parts")
local roll, join, at, HOOK = P.roll, P.join, P.beats, P.HOOK

local CHORUS = "montage..tape_stop"

return {
  drums = {
    { CHORUS, steps = { kick = "x...x...x...x...", clap = { "....x.......x...", "....x.......xoxX" } }, velocity = 0.95 },
    { CHORUS, steps = { hat = "xo.oxo.oxo.oxo.o", open_hat = "..x...x...x...x." }, velocity = 0.6 },
    { "ovg..last", steps = { crash = { "x...............", "" } }, velocity = 0.75 },
    { "last", steps = { crash = { "x...............", "", "", "" } }, velocity = 0.75 },
    { "last", events = join(roll("hat", 14, 8, 0.125, 0.5, 1), roll("clap", 14, 16, 0.125, 0.4, 1)) },
  },
  bass = { { CHORUS, degrees = ". 1 8 1 . 1 8 1 . 1 8 1 . 1 8 1", subdivision = "16n", duration = "0:0:0.85" } },
  stabs = { { CHORUS, chords = { voicing = "close", rhythm = "x.....x.....x..." }, duration = "8n" } },
  arp = { { CHORUS, degrees = "1 3 5 8 5 3 5 8", subdivision = "16n", velocity = 0.55 } },
  lead = {
    { "odecs", notes = HOOK.AF, subdivision = "8n" },
    { "oksl", notes = HOOK.CG, subdivision = "8n" },
    { "check", notes = HOOK.CG, subdivision = "8n" },
    { "last", notes = HOOK.AF .. " " .. HOOK.CG, subdivision = "8n" },
  },
  sweep = { { "last", events = { { time = "2m", duration = at(7.8), velocity = 0.4 } } } },
}
