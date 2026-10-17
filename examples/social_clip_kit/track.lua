-- The soundtrack: an odawg song, 120 BPM Chicago house in C (C G Am F, a
-- chord a bar), a section per part of the promo and a bar of tail. The
-- style plays a swung 909 (DrumMachine), the rolling sixteenth bass, organ
-- stabs and, at the outro, piano chords on a sampled upright (vcsl); a
-- pluck arpeggio runs under the hook and the cuts. Its own parts carry what
-- the picture lands on (timeline.lua reads them back): a clap under each
-- headline line, a blip per format frame and a double one for this video's
-- own, a crash on every feature cut, the impact under the wordmark and a
-- blip for the command. The same song serves all three formats.

local MACHINE = { "DrumMachine", machine = "909", tone = 0.55 }

return song { "score", key = "C major", bpm = 120, seed = 120,
  sections = {
    { "hook", duration = "2m", style = "chicago_house", energy = 0.3, chords = "C G" },
    { "formats", duration = "2m", energy = 0.6, chords = "Am F" },
    { "features", duration = "2m", energy = 0.7, chords = "C G" },
    { "outro", duration = "1m", energy = 0.9, chords = "Am", transition = "none" },
    { "tail", duration = "1m", energy = 0.15, chords = "C", transition = "none" },
  },
  parts = {
    pad = { gain_db = -7 },
    drums = { instrument = MACHINE, gain_db = 2, play = { { "tail", steps = { kick = "X...x..........." } } } },
    piano = { instrument = { "Sampler", set = "vcsl/upright_piano" }, gain_db = -6.3,
      play = { { "tail@2n..", chords = { voicing = "open" }, duration = "2n", velocity = 0.7 } } },
    arp = { instrument = "pluck", gain_db = -5, sends = { hall = -14 },
      play = { { "hook..features", arpeggio = { pattern = "upDown", interval = "8n", octaves = 2 }, velocity = 0.75 } } },
    -- a clap and a low kick under each headline line
    hits = { instrument = MACHINE, gain_db = -2,
      play = { { "hook", steps = { clap = { "........X.......", "X..............." },
                                   kick = { "........x.......", "x..............." } }, velocity = 0.8 } } },
    -- a blip per format frame rising, a double one when this one lights
    -- up; the command's blip in the outro
    blips = { instrument = "blip", gain_db = -4, octave = 5,
      play = { { "formats", degrees = ". . . . 1 . . . 3 . . . 5 . . . | 8 10 . . . . . . . . . . . . . .", subdivision = "16n" },
               { "outro", degrees = ". . . . . . . . 8 . . . . . . .", subdivision = "16n" } } },
    -- a crash on each section's downbeat and on every feature cut
    crash = { instrument = MACHINE, gain_db = -3,
      play = { { "formats", steps = { crash = { "X...............", "" } } },
               { "features", steps = { crash = "X.......X......." } },
               { "outro", steps = { crash = "X..............." } } } },
    impact = { instrument = "impact", gain_db = -8, play = { { "outro", steps = "x...............", duration = "2n" } } },
  },
}
