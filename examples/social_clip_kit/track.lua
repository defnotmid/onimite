-- The soundtrack: an odawg song, amapiano at 113 BPM in F minor, a section per
-- part of the promo and a bar of tail. Its own parts carry what the picture
-- lands on (timeline.lua reads them back): a clap under each headline line, a
-- glockenspiel note per format frame and a double one for this video's own, a
-- crash on every feature cut, and a glockenspiel note for the command. The
-- same song serves all three formats.
--
-- Why: a promo for short social video wants the sound of the platforms, so
-- amapiano after Focalistic and Vigro Deep's "Ke Star": the log drum (a tuned,
-- hollow, plucked bass, the genre's signature) carrying the groove, swung
-- sixteenth shakers with accents, rim shots off the beat, jazzy piano stabs
-- on an upright and a soft electric piano bed, minor ninths moving to major
-- ninths for the drop. The hook is the shakers, the stabs and the headline
-- claps; the kick and the log drum drop in with the formats. No riser, no
-- impact sweep; the cuts get a real crash and nothing else does.

-- The skill's library (skills/onimite-video/library: rows to copy into your
-- media folder), from this example's media folder.
local LIB = "../../../skills/onimite-video/library/"

local KIT = { LIB .. "machines/909.json", tone = 0.4, decay = 0.85 }

return song { "score", key = "F minor", bpm = 113, seed = 7, swing = 0.14, swing_subdivision = "16n",
  instruments = { LIB .. "instruments/synths.json", {
    -- the log drum: a sine falling into its note from most of an octave up, a
    -- hollow triangle an octave above, a little drive, a fast pluck
    logdrum = {
      nodes = {
        fall = { "Decay", time = 0.035 },
        body = { "Osc", wave = "sine", frequency = { by = "fall", octaves = 0.85 } },
        hollow = { "Osc", wave = "triangle", ratio = 2, gain_db = -13, frequency = { by = "fall", octaves = 0.85 } },
        both = { "Mix", "body", "hollow" },
        drive = { "Drive", "both", amount = 1.5, oversample = 1 },
        lp = { "Filter", "drive", type = "lowpass", frequency = 1100, q = 0.8 },
        env = { "Env", attack = 0.002, decay = 0.42, sustain = 0, release = 0.12 },
        out = { "Mix", "lp", amp = "env", gain_db = -8 },
      },
      out = "out",
      options = { decay = "env/decay" },
    },
  } },
  sources = {
    vsco = { url = "https://raw.githubusercontent.com/sgossner/VSCO-2-CE/6dd651d55dde97fd4028699be9d4481f26917891/",
      page = "https://github.com/sgossner/VSCO-2-CE/tree/SFZ", licence = "CC0-1.0",
      credit = "VS Chamber Orchestra 2: Community Edition by Versilian Studios LLC, CC0 1.0", pins = "pins/vsco.pins" },
  },
  sections = {
    { "hook", duration = "2m", chords = "Fm9 Bbm9" },
    { "formats", duration = "2m", chords = "Dbmaj9 Ebmaj9" },
    { "features", duration = "2m", chords = "Bbm9 Ebmaj9 Abmaj9 Dbmaj9" },
    { "outro", duration = "1m", chords = "C7" },
    { "tail", duration = "1m", chords = "Fm9" },
  },
  returns = { hall = { { "Reverb", decay = 1.8, pre_delay = 0.015 }, { "Filter", type = "highpass", frequency = 300 } } },
  parts = {
    -- the kit: shakers and rim from the start, the kick from the drop; the
    -- shakers swing, accented on the beat's last sixteenth
    drums = { instrument = KIT, gain_db = 0, sends = { hall = -22 }, play = {
      { "hook", velocity = 0.95, humanize = 0.005, steps = {
        shaker = "x.ox.oxXx.ox.oxX", rim = { "......x.......x.", "......x....x..x." } } },
      { "formats..features", velocity = 0.8, humanize = 0.005, steps = {
        kick = "x...x...x...x...", shaker = "xoox.oxXxoox.oxX",
        rim = { "......x.......x.", "......x....x..x.", "......x.......x.", "...x..x....x..x." },
        conga_high = { "", "..........x..x..", "", ".............xx." } } },
      { "outro", velocity = 0.85, humanize = 0.005, steps = { kick = "x...x...x...x...", shaker = "xoox.oxXxoox.oxX", rim = "......x....x..x." } },
      { "tail", steps = { kick = "X..............." } },
    } },
    -- the log drum: the roots, pushed and pulled across the bar
    logdrum = { instrument = { "logdrum" }, gain_db = 9, play = {
      { "formats", notes = "Db2 . . Db1 . . Ab1 . . . Db2 . Eb2 . . Bb1 | Eb2 . . Eb1 . . Bb1 . . . Eb2 . Db2 . C2 .", subdivision = "16n", velocity = 0.85, humanize = 0.003 },
      { "features", notes = "Bb1 . . Bb1 . . F2 . Eb2 . . Eb1 . . Bb1 . | Ab1 . . Ab1 . . Eb2 . Db2 . . Db1 . Ab1 . .", subdivision = "16n", velocity = 0.85, humanize = 0.003 },
      { "outro", notes = "C2 . . C1 . . G1 . . . C2 . Bb1 . G1 .", subdivision = "16n", velocity = 0.9, humanize = 0.003 },
    } },
    -- the upright: jazzy stabs, sparse in the hook, pushing off the beat after
    piano = { instrument = { "Sampler", set = "vcsl/upright_piano", release = 0.4 }, gain_db = -7, sends = { hall = -12 }, play = {
      { "hook", chords = { voicing = "close", rhythm = "x.....x...x....." }, octave = 4, duration = "8n", velocity = 0.6, humanize = 0.008 },
      { "formats", chords = { voicing = "close", rhythm = "..x...x...x..x.." }, octave = 4, duration = "16n", velocity = 0.65, humanize = 0.008 },
      { "features", chords = { voicing = "close", rhythm = "x..x..x...x...x." }, octave = 4, duration = "16n", velocity = 0.7, humanize = 0.008 },
      { "outro", chords = { voicing = "open", rhythm = "x..............." }, octave = 4, duration = "2n", velocity = 0.75 },
      { "tail", chords = { voicing = "open", rhythm = "x..............." }, octave = 4, duration = "1m", velocity = 0.6 },
    } },
    -- the bed: an electric piano holding each chord, under everything
    keys = { instrument = { "keys", brightness = 0.6 }, gain_db = 0, sends = { hall = -14 }, play = {
      { "hook..outro", chords = { voicing = "spread", rhythm = "x......." }, octave = 3, duration = "2n", velocity = 0.45 },
    } },
    -- a clap and a low kick under each headline line
    hits = { instrument = KIT, gain_db = 0, sends = { hall = -18 },
      play = { { "hook", steps = { clap = { "........X.......", "X..............." },
                                   kick = { "........x.......", "x..............." } }, velocity = 0.85 } } },
    -- a glockenspiel note per format frame rising, a double one when this
    -- one lights up; the command's note in the outro
    blips = { instrument = { "vsco/Glockenspiel.sfz", ampeg_release = 0.8 }, gain_db = 19, sends = { hall = -10 }, octave = 5,
      play = { { "formats", degrees = ". . . . 1 . . . 3 . . . 5 . . . | 8 10 . . . . . . . . . . . . . .", subdivision = "16n", velocity = 0.7 },
               { "outro", degrees = ". . . . . . . . 8 . . . . . . .", subdivision = "16n", velocity = 0.7 } } },
    -- a real crash on the drop, on every feature cut and on the outro
    crash = { instrument = { "Sampler", set = "virtuosity/drums" }, gain_db = 0, sends = { hall = -16 },
      play = { { "formats", steps = { crash = { "X...............", "" } } },
               { "features", steps = { crash = "X.......X......." } },
               { "outro", steps = { crash = "X..............." } } } },
  },
}
