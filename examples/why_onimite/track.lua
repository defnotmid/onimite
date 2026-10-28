-- The soundtrack: an odawg song, UK garage at 132 BPM in G minor, its
-- sections named after the scenes (the title has two: the intro bar and the
-- slam). Its parts carry what the picture answers to: the glitch stutters,
-- the bill's counter blips, a boom and a real crash on each drop and each
-- scene's downbeat, the kicks the picture pumps on. The scenes start on
-- these sections and read the hits back (video.lua, timeline.lua).
--
-- Why: a fast, confident pitch wants something that moves without
-- shouting, so UK garage after MJ Cole's "Sincere": a swung 2-step on the
-- 909 (the kick on one and the and of three, the snare and clap on two and
-- four, ghosted sixteenth hats), a sine sub that slides between its notes,
-- an electric piano stabbing jazz ninths, the hook on an upright piano with
-- a synth pluck inside it. Shipping turns to speed garage: four to the floor
-- under a warping bass of our own (detuned saws through a ladder filter an
-- eighth-note LFO sweeps). The tricks are the breakdown: strings and the
-- stutters, the beat coming back in its last bar. G minor through a
-- Neapolitan Abmaj9 to D7; no risers, no whooshes.

local library = require("library")
local LIB, INSTRUMENTS = library.LIB, library.INSTRUMENTS

local KIT = { LIB .. "machines/909.json", tone = 0.55, decay = 0.8 }

-- the 2-step, two bars: the kick on one and the and of three (pushed in
-- the second bar), snare and clap on two and four, sixteenth hats with
-- ghosts between (the song's swing pushes them late), an open hat on the
-- and of one and three
local TWO_STEP = {
  kick = { "x.........x.....", "x.....x...x....." },
  snare = { "....x.......x...", "....x.......x..o" },
  clap = "....x.......x...",
  hat = "xoxoxoxoxoxoxoxo",
  open_hat = { "..x.......x.....", "..x.......x...x." },
}

local VSCO = { url = "https://raw.githubusercontent.com/sgossner/VSCO-2-CE/6dd651d55dde97fd4028699be9d4481f26917891/",
  page = "https://github.com/sgossner/VSCO-2-CE/tree/SFZ", licence = "CC0-1.0",
  credit = "VS Chamber Orchestra 2: Community Edition by Versilian Studios LLC, CC0 1.0", pins = "pins/vsco.pins" }

local instruments = { {
  -- the sub: a sine with a triangle an octave up (heard on small speakers),
  -- a little drive; one voice that slides into a note marked ~
  sub = {
    mono = true, portamento = 0.07,
    nodes = {
      sine = { "Osc", wave = "sine" },
      edge = { "Osc", wave = "triangle", ratio = 2, gain_db = -14 },
      both = { "Mix", "sine", "edge" },
      drive = { "Drive", "both", amount = 1.2, oversample = 1 },
      env = { "Env", attack = 0.004, decay = 0.3, sustain = 0.85, release = 0.08 },
      out = { "Mix", "drive", amp = "env", gain_db = -6 },
    },
    out = "out",
  },
  -- the warp: two detuned saws and a sine through a ladder low-pass that an
  -- eighth-note LFO sweeps, driven; speed garage's bass
  warp = {
    mono = true, portamento = 0.04,
    nodes = {
      saws = { "Osc", wave = "fatsawtooth", count = 2, spread = 18 },
      body = { "Osc", wave = "sine", gain_db = -4 },
      wob = { "Lfo", rate = "8n" },
      lp = { "Ladder", "saws", q = 1.8, frequency = { base = 420, by = "wob", octaves = 1.8 } },
      both = { "Mix", "lp", "body" },
      drive = { "Drive", "both", amount = 1.6, oversample = 1 },
      env = { "Env", attack = 0.005, decay = 0.2, sustain = 0.9, release = 0.1 },
      out = { "Mix", "drive", amp = "env", gain_db = -10 },
    },
    out = "out",
    options = { cutoff = "lp/frequency" },
  },
  -- the hook: an upright piano with the library's pluck inside it
  hook = { layers = { { instrument = { "Sampler", set = "vcsl/upright_piano", release = 0.5 } },
                      { instrument = { "pluck" }, gain_db = -10 } } },
  -- the strings: the violin and viola sections together
  strings = { layers = { { instrument = { "vsco/ViolinEnsSusVib.sfz", ampeg_attack = 0.5, ampeg_release = 1 } },
                         { instrument = { "vsco/ViolaEnsSusVib-Quiet.sfz", ampeg_attack = 0.5, ampeg_release = 1 } } } },
} }
for _, f in ipairs(INSTRUMENTS) do instruments[#instruments + 1] = f end

return song { "score", instruments = instruments, key = "G minor", bpm = 132, seed = 132, gain_db = -14,
  swing = 0.28, swing_subdivision = "16n", sources = { vsco = VSCO },
  sections = {
    { "title", duration = "1m", chords = "Gm9" },
    { "slam", duration = "3m", chords = "Cm9 Abmaj9 D7" },
    { "race", duration = "4m", chords = "Gm9 Cm9 Abmaj9 D7" },
    { "bill", duration = "4m", chords = "Ebmaj9 Dm7 Cm9 D7" },
    { "ship", duration = "4m", chords = "Gm9 . Cm9 D7" },
    { "agents", duration = "4m", chords = "Gm9 Cm9 Abmaj9 D7" },
    { "tricks", duration = "4m", chords = "Ebmaj9 Dm7 Cm9 D7" },
    { "outro", duration = "4m", chords = "Gm9 Cm9 Abmaj9 D7" },
    { "tail", duration = "1m", chords = "Gm9" },
  },
  returns = { room = { { "Reverb", decay = 0.9, pre_delay = 0.005 }, { "Filter", type = "highpass", frequency = 250 } },
              hall = { { "Reverb", decay = 2.4, pre_delay = 0.02 }, { "Filter", type = "highpass", frequency = 300 } },
              echo = { { "PingPongDelay", delay_time = "8n.", feedback = 0.3, wet = 1 }, { "Filter", type = "lowpass", frequency = 3500 } } },
  parts = {
    -- the 909: the 2-step from the slam, four to the floor for shipping, out
    -- for the tricks until their last bar, the last kick on the tail
    drums = { role = "drums", instrument = KIT, gain_db = 0, sends = { room = -18 }, play = {
      { "slam..bill", steps = TWO_STEP, humanize = 0.004 },
      { "ship", humanize = 0.003, steps = { kick = "x...x...x...x...", clap = "....x.......x...",
        hat = "xoxoxoxoxoxoxoxo", open_hat = "..x...x...x...x." } },
      { "agents", steps = TWO_STEP, humanize = 0.004 },
      { "tricks@2m..tricks@3m", velocity = 0.7, steps = { hat = "xoxoxoxoxoxoxoxo" } },
      { "tricks@3m..", humanize = 0.004, steps = { kick = "x.........x.....", hat = "xoxoxoxoxoxoxoxo",
        snare = "....x.......x.xX" } },
      { "outro", steps = TWO_STEP, humanize = 0.004 },
      { "tail", steps = { kick = "X..............." } },
    } },
    -- the sub: the roots, pushed across the bar, sliding up into the fifth
    -- and back
    bass = { role = "bass", instrument = "sub", gain_db = 2.5, sidechain = { "drums/kick", depth_db = -3.1 }, play = {
      { "slam..bill", degrees = "1 - - . . . 1~ 5 - . 1 . . 7 . .", subdivision = "16n", octave = 1, velocity = 0.85 },
      { "agents", degrees = "1 - - . . . 1~ 5 - . 1 . . 7 . .", subdivision = "16n", octave = 1, velocity = 0.85 },
      { "tricks@3m..", degrees = "1 - - - - - - - 5 - - - 7 - - -", subdivision = "16n", octave = 1, velocity = 0.8 },
      { "outro", degrees = "1 - - . . . 1~ 5 - . 1 . . 7 . .", subdivision = "16n", octave = 1, velocity = 0.9 },
      { "tail", degrees = "1", subdivision = "1m", octave = 1, velocity = 0.6 },
    } },
    -- speed garage's bass for shipping
    warp = { role = "bass", instrument = "warp", gain_db = 0, sidechain = { "drums/kick", depth_db = -4.4 }, play = {
      { "ship", degrees = "1 - - 1 - - 1 - 8~ 1 - - 5 - 7 -", subdivision = "16n", octave = 1, velocity = 0.85 },
    } },
    -- the electric piano: jazz ninths stabbed off the beat, a chord to
    -- open the title
    keys = { role = "comp", instrument = { "keys", brightness = 1.3 }, gain_db = -2.5, sends = { room = -12 },
      effects = { { "Chorus", frequency = 0.6, delay_time = 0.012, depth = 0.5, wet = 0.35 } }, play = {
      { "title", chords = { voicing = "spread", rhythm = "x.......x......." }, octave = 3, duration = "4n", velocity = 0.7 },
      { "slam..bill", chords = { voicing = "close", rhythm = { "..x..x....x..x..", "..x..x.......x.." } }, octave = 4, duration = "8n", velocity = 0.65, humanize = 0.006 },
      { "agents", chords = { voicing = "close", rhythm = { "..x..x....x..x..", "..x..x.......x.." } }, octave = 4, duration = "8n", velocity = 0.65, humanize = 0.006 },
      { "outro", chords = { voicing = "close", rhythm = { "..x..x....x..x..", "..x..x.......x.." } }, octave = 4, duration = "8n", velocity = 0.7, humanize = 0.006 },
    } },
    -- the organ: speed garage's stabs under shipping
    organ = { role = "comp", instrument = "organ", gain_db = 0, sends = { room = -12 },
      effects = { { "Chorus", frequency = 1.2, delay_time = 0.006, depth = 0.6, wet = 0.4 } }, play = {
      { "ship", chords = { voicing = "close", rhythm = { "..x..x....x..x..", "..x..x.......x.." } }, octave = 4, duration = "16n", velocity = 0.8, humanize = 0.004 },
    } },
    -- the hook: four bars on the upright and the pluck, through a dotted
    -- echo, for the agents and the last drop
    hook = { role = "melody", instrument = "hook", gain_db = -3, sidechain = { "drums/kick", depth_db = -1.9 }, sends = { echo = -16, room = -14 }, play = {
      { "agents", subdivision = "16n", humanize = 0.004,
        notes = "D5 . . F5! . . A5 . . G5 . F5 . D5 . . | Eb5 . . G5! . . Bb5 . . G5 . F5 . Eb5 . . | C5 . . Eb5! . . G5 . . Eb5 . C5 . Bb4 . . | A4 . . C5! . . D5 . . F#5 . . A5 - G5 ." },
      { "outro", subdivision = "16n", humanize = 0.004, velocity = 0.9,
        notes = "D5 . . F5! . . A5 . . G5 . F5 . D5 . . | Eb5 . . G5! . . Bb5 . . G5 . F5 . Eb5 . . | C5 . . Eb5! . . G5 . . Eb5 . C5 . Bb4 . . | A4 . . C5! . . D5 . . F#5 . . A5 - G5 ." },
    } },
    -- the strings: the tricks' bed, and a lift under the last drop
    strings = { role = "pad", instrument = "strings", gain_db = -5, sends = { hall = -8 }, play = {
      { "tricks", chords = { voicing = "open", rhythm = "x..............." }, octave = 3, duration = "1m", velocity = 0.55 },
      { "outro", chords = { voicing = "open", rhythm = "x..............." }, octave = 3, duration = "1m", velocity = 0.55 },
    } },
    -- the picture's: a boom and a crash on the slam and the last drop (the
    -- picture flashes on the boom), a crash on each scene's downbeat from
    -- the race on and on the last kick
    fx = { role = "fx", instrument = { LIB .. "instruments/808_bass.json", decay = 2 }, gain_db = 3, sends = { hall = -14 }, play = {
      { "slam", events = { { time = 0, duration = "2n", note = "G1", velocity = 0.9 } } },
      { "outro", events = { { time = 0, duration = "2n", note = "G1", velocity = 0.9 } } },
    } },
    crash = { role = "fx", instrument = { "Sampler", set = "virtuosity/drums" }, gain_db = 5, sends = { hall = -14 }, play = {
      { "slam", steps = { crash = "X..............." } },
      { "race..agents", steps = { crash = { "X...............", "", "", "" } } },
      { "outro", steps = { crash = "X..............." } },
      { "tail", steps = { crash = "X..............." } },
    } },
    -- the title's two stutters, then one on each of the tricks' cuts
    glitch = { role = "fx", instrument = "glitch", gain_db = 0,
      play = { { "title", steps = "x.......x.......", note = "1", duration = "4n" },
               { "tricks", steps = { "................", "x...............", "x...............", "x..............." },
                 note = "1", duration = "4n" } } },
    -- the bill's counters: a glockenspiel note a beat up the chord, four for
    -- each panel
    ticks = { role = "fx", instrument = { "vsco/Glockenspiel.sfz", ampeg_release = 0.6 }, gain_db = 16.5, octave = 5, sends = { room = -10 },
      play = { { "bill", degrees = ". 1 3 5 | 8 . . . | 1 3 5 8 | . . . .", subdivision = "4n", velocity = 0.75 } } },
  },
  automation = {
    -- the kit up under the last drop's hook and strings, and the last kick
    -- on its own (inspect's role_balance: 9.5 LU under the mix in the outro,
    -- 13.5 on the tail)
    ["parts/drums/gain_db"] = { { "title", 0 }, { "outro", 2, "step" }, { "tail", 5, "step" } },
  },
}
