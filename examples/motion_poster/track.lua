-- The soundtrack: an odawg song, ambient techno at 120 BPM in A minor
-- (Am9 Fmaj7 C G, a chord a bar), 10 bars in four sections named after the
-- scenes. The ambient style gives the pad, and from the groove the strings
-- and the bells, through its long hall; the parts below add the techno: a
-- 909 machine (machines/909.json) whose kick plays in the groove and the finale, a sine
-- sub on the off-beats ducking under it, plucks a dotted eighth apart
-- echoing from side to side, a riser over the break's last bar and the
-- impact on the finale. timeline.lua reads the picture's cues from it.

-- The skill's library (skills/onimite-video/library: rows and styles to
-- copy into your media folder), from this example's media folder.
local LIB = "../../../skills/onimite-video/library/"
local INSTRUMENTS = { LIB .. "instruments/synths.json", LIB .. "instruments/classic.json", LIB .. "instruments/sfx.json" }

local MACHINE = { LIB .. "machines/909.json", tone = 0.4 }
local FOUR = "x...x...x...x..."

return song { "score", instruments = INSTRUMENTS, key = "A minor", bpm = 120, seed = 120,
  sections = {
    { "intro", duration = "2m", style = LIB .. "styles/ambient.json", energy = 0.2, chords = "Am9 Fmaj7" },
    { "groove", duration = "4m", energy = 0.35, chords = "C G Am9 Fmaj7" },
    { "break", duration = "2m", energy = 0.25, chords = "C G" },
    { "finale", duration = "2m", energy = 0.38, chords = "Am9 Fmaj7" },
  },
  parts = {
    pad = { gain_db = -13 },
    drums = { instrument = MACHINE, gain_db = 5, sends = { hall = -20 }, play = {
      { "groove", steps = { kick = FOUR, open_hat = "..x...x...x...x." } },
      { "groove@2m..", steps = { hat = ".x.x.x.x.x.x.x.x" }, velocity = 0.5 },
      { "finale", steps = { kick = FOUR, clap = "....x.......x...", open_hat = "..x...x...x...x.", hat = ".x.x.x.x.x.x.x.x" } },
    } },
    crash = { instrument = MACHINE, gain_db = -6, sends = { hall = -10 },
      play = { { "groove", events = { { time = 0, note = "crash" } } }, { "finale", events = { { time = 0, note = "crash" } } } } },
    sub = { instrument = { "Synth", oscillator = { type = "sine" }, envelope = { attack = 0.01, decay = 0.1, sustain = 0.9, release = 0.05 } },
      gain_db = 0, sidechain = "drums/kick",
      play = { { "groove", degrees = ". 1 . 1 . 1 . 1", subdivision = "8n", octave = 2, duration = "16n." },
               { "finale", degrees = ". 1 . 1 . 1 . 1", subdivision = "8n", octave = 2, duration = "16n." } } },
    arp = { instrument = "pluck", gain_db = 6, sends = { hall = -10 },
      effects = { { "PingPongDelay", delay_time = "8n.", feedback = 0.45, wet = 0.45 } },
      play = { { "intro..finale", arpeggio = { pattern = "up", interval = "8n.", octaves = 1 }, octave = 4, velocity = 0.8 } } },
    riser = { instrument = "riser", gain_db = 2, play = { { "break@1m", events = { { time = 0, duration = "1m" } } } } },
    impact = { instrument = "impact", gain_db = -4, play = { { "finale", events = { { time = 0, note = "A1" } } } } },
  },
}
