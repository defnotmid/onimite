-- The soundtrack: an odawg song, dub techno at 118 BPM in C minor, 10 bars in
-- four sections named after the scenes. timeline.lua reads the picture's cues
-- from it.
--
-- Why: the poster is slow metal and drifting noise that breathes on a pulse,
-- so the music is dub techno after Basic Channel's "Phylyps Trak": one minor
-- chord stab smeared through a long filtered delay, a soft deep kick, a sub
-- that ducks under it, shuffled hats, hiss, and almost nothing else. The
-- harmony stays on Cm9 (the genre moves by filter and echo, not chords) and
-- lifts once, to Abmaj9, for the break. The stab's filter opens across the
-- groove; the break throws its echoes up while a hiss swell rises into the
-- finale, which lands on one tuned 808 boom (the impact) with the kick back.
-- No crash, no riser sweep, no arpeggio.

-- The skill's library (skills/onimite-video/library: rows to copy into your
-- media folder), from this example's media folder.
local LIB = "../../../skills/onimite-video/library/"

local KIT = { LIB .. "machines/909.json", tone = 0.3, tune = -2, decay = 0.8 }

return song { "score", key = "C minor", bpm = 118, seed = 23,
  instruments = { LIB .. "instruments/synths.json", {
    -- the chord stab: three detuned saws and a square, a 24 dB low-pass
    -- snapped open and shut on every hit (harder hits open it further)
    stab = {
      nodes = {
        saws = { "Osc", wave = "fatsawtooth", count = 3, spread = 12 },
        sq = { "Osc", wave = "square", gain_db = -9 },
        both = { "Mix", "saws", "sq" },
        fenv = { "Env", attack = 0.002, decay = 0.16, sustain = 0, release = 0.08 },
        lp = { "Filter", "both", type = "lowpass", rolloff = -24, q = 1.4,
               frequency = { { 420, by = "fenv", octaves = 2.4 }, { by = "velocity", octaves = 1 } } },
        env = { "Env", attack = 0.003, decay = 0.22, sustain = 0, release = 0.1 },
        out = { "Mix", "lp", amp = "env", gain_db = -14 },
      },
      out = "out",
      options = { cutoff = "lp/frequency" },
    },
    -- tape hiss swelling up through a band-pass that climbs with it
    hiss = {
      nodes = {
        noise = { "Noise", color = "pink" },
        rise = { "Ramp", time = 1 },
        bp = { "Filter", "noise", type = "bandpass", q = 1.2, frequency = { 500, by = "rise", octaves = 3 } },
        out = { "Mix", "bp", amp = "rise", gain_db = -24 },
      },
      out = "out",
    },
  } },
  sections = {
    { "intro", duration = "2m", chords = "Cm9" },
    { "groove", duration = "4m", chords = "Cm9" },
    { "break", duration = "2m", chords = "Abmaj9" },
    { "finale", duration = "2m", chords = "Cm9" },
  },
  -- the echo the stabs live in: a dotted-eighth delay bouncing between the
  -- sides, its lows and highs cut so each repeat gets darker and thinner
  returns = {
    dub = { { "PingPongDelay", delay_time = "8n.", feedback = 0.6, wet = 1 },
            { "Filter", type = "highpass", frequency = 280 },
            { "Filter", type = "lowpass", frequency = 2600 } },
    hall = { { "Reverb", decay = 3.5, pre_delay = 0.02 }, { "Filter", type = "highpass", frequency = 300 } },
  },
  parts = {
    -- the kick on every beat (the ripples follow it), shuffled closed hats
    -- with accents and ghosts, an open hat on some off-beats, a rim now and then
    drums = { instrument = KIT, gain_db = 2, sends = { hall = -24 }, play = {
      { "groove", velocity = 0.8, humanize = 0.004, steps = {
        kick = "x...x...x...x...",
        hat = { "..x.oxo...x.oxo.", "o.x.oxo.o.x.ox.o", "..x.oxo...x.oxo.", "o.x.oxo.o.X.oxoo" },
        open_hat = { "", "", "", "..........x....." },
        rim = { "", "......x.........", "", "......x......x.." } } },
      { "finale", velocity = 0.85, humanize = 0.004, steps = {
        kick = "x...x...x...x...",
        hat = { "o.x.oxo.o.x.oxo.", "o.x.oxo.o.X.oxoo" },
        open_hat = { "......x.......x.", "..........x....." },
        rim = { "......x.........", "......x......x.." } } },
    } },
    -- the sub: the root on a dotted push, ducking under every kick
    sub = { instrument = { "Synth", oscillator = { type = "sine" }, envelope = { attack = 0.005, decay = 0.2, sustain = 0.8, release = 0.08 } },
      gain_db = 0, sidechain = { "drums/kick", depth = 0.7 },
      play = { { "groove", notes = "C2 - - . . . C2 - . . C2 . . . G1 .", subdivision = "16n", velocity = 0.8, humanize = 0.003 },
               { "finale", notes = "C2 - - . . . C2 - . . C2 . . . Bb1 .", subdivision = "16n", velocity = 0.85, humanize = 0.003 } } },
    -- the stab: the off-beat chord, mostly echo; sparse in the intro, a
    -- different push each bar of the groove, held long in the break
    stab = { instrument = { "stab" }, gain_db = 10, sends = { dub = -4 }, play = {
      { "intro", chords = { voicing = "close", rhythm = "..........x....." }, octave = 4, velocity = 0.45, duration = "16n" },
      { "groove..groove@2m", chords = { voicing = "close", rhythm = "..x.....x.....x." }, octave = 4, velocity = 0.7, duration = "16n", humanize = 0.004 },
      { "groove@2m..", chords = { voicing = "close", rhythm = "......x...x..x.." }, octave = 4, velocity = 0.75, duration = "16n", humanize = 0.004 },
      { "break", chords = { voicing = "close", rhythm = "x..............." }, octave = 4, velocity = 0.6, duration = "8n" },
      { "finale", chords = { voicing = "close", rhythm = "..x.....x...x..x" }, octave = 4, velocity = 0.8, duration = "16n", humanize = 0.004 },
    } },
    -- the bed: the chord held a bar at a time, low and dark (the picture's
    -- colour split reads its notes)
    pad = { instrument = { "pad", cutoff = 700, attack = 0.4 }, gain_db = 0, sends = { hall = -14 }, play = {
      { "intro..finale", chords = { voicing = "spread", rhythm = "x..............." }, octave = 3, duration = "1m", velocity = 0.5 },
    } },
    -- the break's last bar: hiss rising into the finale (its level: inspect's
    -- buried_part, 12 LU under the mix where it's loudest)
    riser = { instrument = { "hiss" }, gain_db = 18, sends = { dub = -12 },
      play = { { "break@1m", events = { { time = 0, duration = "1m", note = "C4", velocity = 0.8 } } } } },
    -- the finale's downbeat: one 808 boom on the root
    impact = { instrument = { LIB .. "instruments/808_bass.json", decay = 2.5 }, gain_db = 0, sends = { hall = -16 },
      play = { { "finale", events = { { time = 0, note = "C1", duration = "2n", velocity = 0.9 } } } } },
  },
  -- the stab's filter opens over the groove and closes for the break; the
  -- break throws its echoes up, and they fall back as the kick returns
  automation = {
    ["parts/stab/cutoff"] = { { "groove", 380 }, { "break", 1400 }, { "break@1n", 700, "step" }, { "finale", 1100 } },
    ["parts/stab/sends/dub"] = { { "break", -4 }, { "break@1m", 0 }, { "finale", -6, "step" } },
  },
}
