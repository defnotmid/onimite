-- The soundtrack: an odawg song, 120 BPM synthwave in D minor (Dm Bb F C, a
-- chord a bar), its sections the piece's parts: ignition and liftoff, the
-- drop, the kaleidoscope, the break, the lockup, a tail. The style plays
-- 909s (the library's machines/909.json), the octave saw bass ducking under
-- the kick, wide pads and the dotted-eighth arp; the transitions make the
-- risers and the impacts on the drop and the lockup. Its own parts carry
-- what the picture lands on (timeline.lua reads them back): a blip when the
-- rocket shows, one per portal, per box of the structure and per name; a
-- stutter before the break; a crash on the kaleidoscope, the break, the
-- line and the last hit.

-- The skill's library (skills/onimite-video/library: rows and styles to
-- copy into your media folder), from this example's media folder.
local LIB = "../../../skills/onimite-video/library/"
local INSTRUMENTS = { LIB .. "instruments/classic.json", LIB .. "instruments/sfx.json" }

local MACHINE = { LIB .. "machines/909.json" }

return song { "score", instruments = INSTRUMENTS, key = "D minor", bpm = 120, seed = 120,
  sections = {
    { "ignition", duration = "2m", style = LIB .. "styles/synthwave.json", energy = 0.15, chords = "Dm Bb" },
    { "liftoff", duration = "2m", energy = 0.5, chords = "F C", transition = "none" },
    { "drop", duration = "4m", energy = 0.85, chords = "Dm Bb F C" },
    { "kaleido", duration = "4m", energy = 1 },
    { "break", duration = "2m", energy = 0.2, chords = "Dm Bb" },
    { "lockup", duration = "3m", energy = 1, chords = "F C Dm" },
    { "tail", duration = "1m", style = LIB .. "styles/ambient.json", energy = 0.3, chords = "Dm", transition = "cut" },
  },
  parts = {
    -- the transitions, written out: a riser over the two bars into a drop, an impact and a crash on its downbeat
    rise = { instrument = "riser", gain_db = -4, play = { { "liftoff", events = { { time = 0, duration = "2m", note = "C4", velocity = 0.35 } } }, { "break", events = { { time = 0, duration = "2m", note = "C4", velocity = 0.35 } } } } },
    fx = { instrument = "impact", gain_db = -4, play = { { "drop", events = { { time = 0, duration = 2.5, note = "C2", velocity = 0.8 } } }, { "lockup", events = { { time = 0, duration = 2.5, note = "C2", velocity = 0.8 } } } } },
    fx_crash = { instrument = "crash", gain_db = -4, play = { { "drop", events = { { time = 0, duration = 1.6, note = "C4", velocity = 0.7 } } }, { "lockup", events = { { time = 0, duration = 1.6, note = "C4", velocity = 0.7 } } } } },
    drums = { instrument = MACHINE, gain_db = 2, play = { { "tail", steps = { kick = "X..............." } } } },
    pad = { gain_db = -12 },
    bass = { gain_db = -3 },
    -- the arp runs from the first bar and through the break, as in the drop
    arp = { play = { { "ignition..liftoff", arpeggio = { pattern = "up", interval = "16n", octaves = 2 }, velocity = 0.7 },
                     { "break", arpeggio = { pattern = "up", interval = "16n", octaves = 2 }, velocity = 0.7 } } },
    -- the kaleidoscope's lead: the chord tones, a bar each
    lead = { instrument = { "MonoSynth", oscillator = { type = "fatsawtooth", count = 3, spread = 18 },
        envelope = { attack = 0.01, decay = 0.3, sustain = 0.6, release = 0.4 },
        filter_envelope = { base_frequency = 600, octaves = 2.5 } },
      gain_db = -6, sidechain = { "drums/kick", depth = 0.3 },
      effects = { { "FeedbackDelay", delay_time = "8n.", feedback = 0.3, wet = 0.25 } }, sends = { hall = -10 },
      play = { { "kaleido", degrees = "5 - - 3 - - 1 - | 3 - - 5 - - 8 - | 5 - - 3 - - 1 - | 3 - - 1 - 2 - -",
        subdivision = "8n", octave = 5 } } },
    -- blips the picture lands on: the rocket, the portals, the boxes, the names
    blips = { instrument = "blip", gain_db = -3, octave = 5,
      play = { { "ignition", degrees = ". . . . 5 . . .", subdivision = "4n" },
               { "drop", degrees = ". . . . 1 . . . 3 . . . . . . .", subdivision = "4n", octave = 6 },
               { "break", degrees = ". 1 3 5 8 10 12 .", subdivision = "4n" },
               { "lockup", degrees = "1 3 5 8 10 12 . . . . . . . . . . . . . . . . . .", subdivision = "8n", octave = 6 } } },
    glitch = { instrument = "glitch", gain_db = -10,
      play = { { "liftoff", steps = { "", "............x..." }, note = "1", duration = "4n" },
               { "kaleido", steps = { "", "", "", "............x..." }, note = "1", duration = "4n" } } },
    crash = { instrument = MACHINE, gain_db = -2,
      play = { { "kaleido", steps = { crash = { "X...............", "", "", "" } } },
               { "break", steps = { crash = { "X...............", "" } } },
               { "lockup", steps = { crash = { "", "X...............", "" } } },
               { "tail", steps = { crash = "X..............." } } } },
  },
}
