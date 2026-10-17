-- The soundtrack: an odawg song, 140 BPM in A minor (Am F C G, a chord a
-- bar), its sections named after the scenes (the title has two: the intro
-- bar and the slam). House on TR-909 circuit models (DrumMachine) for the
-- title, race and bill; a TB-303 line (acid_house's AcidSynth) takes over
-- for shipping and the agents; a breakdown under the tricks, the last drop,
-- an ambient tail. The transitions make the risers and the impacts; the
-- parts below add what the picture answers to: the glitch stutters, the
-- bill's counter blips, a crash on each scene's downbeat. The scenes start
-- on these sections and read the hits back (video.lua, timeline.lua).

local MACHINE = { "DrumMachine", machine = "909", tone = 0.55 }

return song { "score", key = "A minor", bpm = 140, seed = 140,
  sections = {
    { "title", duration = "1m", style = "house", energy = 0.3, chords = "Am" },
    { "slam", duration = "3m", energy = 0.55, chords = "F C G", transition = "impact" },
    { "race", duration = "4m", energy = 0.85, chords = "Am F C G", transition = "riser" },
    { "bill", duration = "4m", energy = 0.75 },
    { "ship", duration = "4m", style = "acid_house", energy = 0.6 },
    { "agents", duration = "4m", energy = 0.8 },
    { "tricks", duration = "4m", style = "house", energy = 0.35 },
    { "outro", duration = "4m", energy = 1 },
    { "tail", duration = "1m", style = "ambient", energy = 0.3, chords = "Am", transition = "cut" },
  },
  parts = {
    drums = { instrument = MACHINE, gain_db = 4, play = { { "tail", steps = { kick = "X..............." } } } },
    bass = { gain_db = 1 },
    pad = { gain_db = -16 },
    keys = { mute = { "bill" } },                                 -- the bill grooves without the stabs
    arp = { play = { { "tricks", arpeggio = { pattern = "upDown", interval = "16n", octaves = 2 }, velocity = 0.8 } } },
    -- the last drop's hook, up each chord, through a dotted-eighth echo
    lead = { instrument = "lead", gain_db = -9, sidechain = { "drums/kick", depth = 0.4 },
      effects = { { "FeedbackDelay", delay_time = "8n.", feedback = 0.3, wet = 0.22 } }, sends = { hall = -12 },
      play = { { "outro", notes = "A5 - C6 A5 E6 - C6 - | F5 - A5 F5 C6 - A5 - | G5 - C6 G5 E6 - C6 - | G5 - B5 D6 B5 - G5 -",
        subdivision = "8n" } } },
    -- a crash on each scene's downbeat from the race on, and on the last kick
    crash = { instrument = MACHINE, gain_db = -2,
      play = { { "race..agents", steps = { crash = { "X...............", "", "", "" } } },
               { "tail", steps = { crash = "X..............." } } } },
    -- the title's two stutters, then one on each of the tricks' cuts
    glitch = { instrument = "glitch", gain_db = -10,
      play = { { "title", steps = "x.......x.......", note = "1", duration = "4n" },
               { "tricks", steps = { "................", "x...............", "x...............", "x..............." },
                 note = "1", duration = "4n" } } },
    -- the bill's counters: a blip a beat up the chord, four for each panel
    ticks = { instrument = "blip", gain_db = 0, octave = 5,
      play = { { "bill", degrees = ". 1 3 5 | 8 . . . | 1 3 5 8 | . . . .", subdivision = "4n" } } },
  },
}
