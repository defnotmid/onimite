-- The soundtrack: an odawg song, hybrid orchestral electronica at 112 BPM in
-- F# minor, its sections the piece's parts: ignition and liftoff, the drop,
-- the kaleidoscope, the break, the lockup, a tail. Its own parts carry what the
-- picture lands on (timeline.lua reads them back): a ping when the rocket
-- shows, one per portal, per box of the structure and per name; a stutter
-- before the break; a cymbal on the kaleidoscope, the break, the line and the
-- last hit; the impacts on the drop and the lockup.
--
-- Why: seven libraries working as one machine, a rocket, a shader world folding
-- into a kaleidoscope: hybrid orchestral electronica after Daft Punk's Tron:
-- Legacy score ("End of Line"). Spiccato strings drive sixteenth ostinatos
-- under a pulsing ladder-filter bass, horns and trombones carry the chords,
-- a synth lead sings the kaleidoscope's theme doubled by the violin section,
-- timpani and a tuned 909 give the hits their weight, and the tail opens onto
-- F# major. The harmony avoids the four-chord loop: i–VI–iv–V7 through the
-- harmonic minor's dominant, the kaleidoscope wandering through Bm9 E Amaj7
-- while it accelerates from 112 to 140 BPM, the break braking back to 112.
-- The orchestra is VS Chamber Orchestra 2's own SFZ files through `sources`,
-- pinned in media/pins/vsco.pins; the synths are rows of the song's own.

-- The skill's library (skills/onimite-video/library: rows to copy into your
-- media folder), from this example's media folder.
local LIB = "../../../skills/onimite-video/library/"

local KIT = { LIB .. "machines/909.json", tone = 0.35, tune = -2 }

local VSCO = { url = "https://raw.githubusercontent.com/sgossner/VSCO-2-CE/6dd651d55dde97fd4028699be9d4481f26917891/",
  page = "https://github.com/sgossner/VSCO-2-CE/tree/SFZ", licence = "CC0-1.0",
  credit = "VS Chamber Orchestra 2: Community Edition by Versilian Studios LLC, CC0 1.0", pins = "pins/vsco.pins" }

return song { "score", key = "F# minor", bpm = 112, seed = 33,
  sources = { vsco = VSCO },
  instruments = { LIB .. "instruments/synths.json", {
    -- the pulse: a saw and a square through a resonant ladder, plucked by a
    -- short envelope, the machine's heartbeat in eighths
    pulse = {
      nodes = {
        saw = { "Osc", wave = "sawtooth" },
        sq = { "Osc", wave = "square", ratio = 0.5, gain_db = -6 },
        both = { "Mix", "saw", "sq" },
        pluck = { "Decay", time = 0.11 },
        lp = { "Ladder", "both", q = 2.4, frequency = { { 160, by = "pluck", octaves = 3.2 }, { by = "velocity", octaves = 1 } } },
        env = { "Env", attack = 0.002, decay = 0.2, sustain = 0.5, release = 0.06 },
        out = { "Mix", "lp", amp = "env", gain_db = -12 },
      },
      out = "out", mono = true,
      options = { cutoff = "lp/frequency" },
    },
    -- a ping: a glockenspiel strike with a sine an octave down inside it
    ping = { layers = { { instrument = { "vsco/Glockenspiel.sfz", ampeg_release = 0.6 } },
                        { instrument = { "Synth", oscillator = { type = "sine" }, envelope = { attack = 0.002, decay = 0.5, sustain = 0, release = 0.3 } }, gain_db = -14 } } },
    -- the theme: the lead synth with the violins doubling it
    theme = { layers = { { instrument = "lead" }, { instrument = { "vsco/ViolinEnsSusVib.sfz", ampeg_attack = 0.05, ampeg_release = 0.4 }, gain_db = 2 } } },
    -- an impact: the timpani with an 808 boom under it
    hit = { layers = { { instrument = { "vsco/Timpani.sfz" } }, { instrument = { LIB .. "instruments/808_bass.json", decay = 2 }, gain_db = -6 } } },
  } },
  sections = {
    { "ignition", duration = "2m", chords = "F#m" },
    { "liftoff", duration = "2m", chords = "Dmaj7 E" },
    { "drop", duration = "4m", chords = "F#m Dmaj7 Bm7 C#7" },
    { "kaleido", duration = "4m", bpm = { 112, 140 }, chords = "Bm9 E Amaj7 C#7" },   -- accelerating into the fold
    { "break", duration = "2m", bpm = 112, chords = "Dmaj7 E" },                      -- and braking back
    { "lockup", duration = "3m", chords = "F#m Dmaj7 C#7" },
    { "tail", duration = "1m", chords = "F#" },
  },
  returns = { hall = { { "Reverb", decay = 3, pre_delay = 0.025 }, { "Filter", type = "highpass", frequency = 250 } } },
  parts = {
    -- the strings' engine: spiccato sixteenths, cellos then violas, from liftoff
    spic = { instrument = { "vsco/ViolaEnsSpic.sfz" }, gain_db = 0, sends = { hall = -12 }, play = {
      { "liftoff", arpeggio = { pattern = "up", interval = "16n", octaves = 1 }, octave = 3, velocity = 0.55, humanize = 0.004 },
      { "drop..kaleido", arpeggio = { pattern = "upDown", interval = "16n", octaves = 2 }, octave = 3, velocity = 0.7, humanize = 0.004 },
      { "lockup", arpeggio = { pattern = "upDown", interval = "16n", octaves = 2 }, octave = 3, velocity = 0.8, humanize = 0.004 },
    } },
    celli = { instrument = { "vsco/CelloEnsSpic.sfz" }, gain_db = 6, sends = { hall = -14 }, play = {
      { "ignition..liftoff", degrees = "1 1 1 1 1 1 1 1", subdivision = "8n", octave = 2, velocity = 0.5, humanize = 0.004 },
      { "drop..kaleido", degrees = "1 1 1 1 1 1 5 1", subdivision = "8n", octave = 2, velocity = 0.7, humanize = 0.004 },
      { "lockup", degrees = "1 1 1 1 1 1 5 1", subdivision = "8n", octave = 2, velocity = 0.8, humanize = 0.004 },
    } },
    -- the synth heartbeat, its filter opening over the liftoff
    pulse = { instrument = { "pulse" }, gain_db = 12, sidechain = { "drums/kick", depth = 0.4 }, play = {
      { "ignition..kaleido", degrees = "1 1 8 1 1 1 8 1", subdivision = "8n", octave = 2, velocity = 0.8, humanize = 0.002 },
      { "lockup", degrees = "1 1 8 1 1 1 8 1", subdivision = "8n", octave = 2, velocity = 0.9, humanize = 0.002 },
    } },
    -- horns and trombones on the chords from the drop
    horns = { instrument = { "vsco/FHornSus.sfz", ampeg_attack = 0.08, ampeg_release = 0.5 }, gain_db = 0, sends = { hall = -10 }, play = {
      { "drop", chords = { voicing = "close", rhythm = "x.......x.......", }, octave = 3, duration = "2n", velocity = 0.65 },
      { "lockup", chords = { voicing = "close", rhythm = "x.......x.......", }, octave = 3, duration = "2n", velocity = 0.8 },
      { "tail", chords = { voicing = "open", rhythm = "x..............." }, octave = 3, duration = "1m", velocity = 0.7 },
    } },
    bones = { instrument = { "vsco/TromboneSus.sfz", ampeg_attack = 0.06, ampeg_release = 0.4 }, gain_db = 17, sends = { hall = -12 }, play = {
      { "drop", degrees = "1 - - - 1 - - -", subdivision = "4n", octave = 2, velocity = 0.6 },
      { "lockup", degrees = "1 - - - 1 - - -", subdivision = "4n", octave = 2, velocity = 0.75 },
    } },
    -- the bed: wide synth saws, low, under it all
    pad = { instrument = { "pad", cutoff = 800, attack = 1 }, gain_db = 0, sends = { hall = -8 }, play = {
      { "ignition..tail", chords = { voicing = "spread", rhythm = "x..............." }, octave = 3, duration = "1m", velocity = 0.45 },
    } },
    -- the kaleidoscope's theme, the synth lead doubled by violins
    lead = { instrument = { "theme" }, gain_db = 3, sends = { hall = -10 },
      effects = { { "FeedbackDelay", delay_time = 0.4018, feedback = 0.28, wet = 0.2 } }, play = { -- a dotted eighth at 112, in seconds: the kaleidoscope speeds up under it
        { "kaleido", notes = "C#6 - - B5 A5 - F#5 - | E5 - - F#5 G#5 - B5 - | C#6 - - E6 C#6 - B5 - | A5 - - G#5 F5 - - -",
          subdivision = "8n", velocity = 0.75, humanize = 0.006 },
      } },
    -- the drums: from the drop, half the kit in the break, one last kick
    drums = { instrument = KIT, gain_db = -3, sends = { hall = -20 }, play = {
      { "liftoff@1m", velocity = 0.7, steps = { kick = "x...x...x...x.x.", clap = "....x.......x..." } },
      { "drop", velocity = 0.85, humanize = 0.003, steps = { kick = "x.......x.x.....", clap = "....X.......X...",
        hat = "x.xox.xox.xox.xo", open_hat = { "", "", "", "..............x." } } },
      -- the kaleidoscope drives harder as it speeds up: the kick doubles, the last bar rolls in
      { "kaleido", velocity = 0.9, humanize = 0.003, steps = {
        kick = { "x.......x.x.....", "x...x...x.x.x...", "x.x.x.x.x.x.x.x.", "x.x.x.x.xxxxxxxx" },
        clap = { "....X.......X...", "....X.......X...", "....X.......X.X.", "....X...X.X.XXXX" },
        hat = "xxxoxxxoxxxoxxxo" } },
      { "lockup", velocity = 0.9, humanize = 0.003, steps = { kick = "x.......x.x.....", clap = "....X.......X...", hat = "x.xox.xox.xox.xo" } },
      { "tail", steps = { kick = "X..............." } },
    } },
    -- the impacts on the drop and the lockup (the picture flashes on C2)
    fx = { instrument = { "hit" }, gain_db = 3, sends = { hall = -8 }, play = {
      { "drop", events = { { time = 0, duration = 2.5, note = "C2", velocity = 0.9 } } },
      { "lockup", events = { { time = 0, duration = 2.5, note = "C2", velocity = 0.95 } } },
    } },
    -- the timpani rolling up into the drop and the lockup
    roll = { instrument = { "vsco/TimpaniRolls.sfz" }, gain_db = 14, sends = { hall = -10 }, play = {
      { "liftoff@1m", events = { { time = 0, duration = "1m", note = "F#2", velocity = 0.6 } } },
      { "break@1m", events = { { time = 0, duration = "1m", note = "C#3", velocity = 0.6 } } },
    } },
    -- pings the picture lands on: the rocket, the portals, the boxes, the names
    blips = { instrument = { "ping" }, gain_db = 12, sends = { hall = -10 }, octave = 5,
      play = { { "ignition", degrees = ". . . . 5 . . .", subdivision = "4n" },
               { "drop", degrees = ". . . . 1 . . . 3 . . . . . . .", subdivision = "4n", octave = 6 },
               { "break", degrees = ". 1 3 5 8 10 12 .", subdivision = "4n" },
               { "lockup", degrees = "1 3 5 8 10 12 . . . . . . . . . . . . . . . . . .", subdivision = "8n", octave = 6 } } },
    -- the stutter before the break: the violins ratcheting down
    glitch = { instrument = { "vsco/ViolinEnsSpic.sfz" }, gain_db = 0, sends = { hall = -14 },
      play = { { "kaleido@3m", notes = ". . . . . . . . . . . . . . . . . . . . . . . . C#6 B5 A5 G#5 F#5 E5 D5 C#5", subdivision = "32n", velocity = 0.8 } } },
    -- a cymbal on the kaleidoscope, the break, the line and the last hit
    crash = { instrument = { "Sampler", set = "virtuosity/drums" }, gain_db = -3, sends = { hall = -16 },
      play = { { "kaleido", steps = { crash = { "X...............", "", "", "" } } },
               { "break", steps = { crash = { "X...............", "" } } },
               { "lockup", steps = { crash = { "", "X...............", "" } } },
               { "tail", steps = { crash = "X..............." } } } },
    -- the harp: the break's and the tail's chords, rising
    harp = { instrument = { "vsco/Harp.sfz", ampeg_release = 1.2 }, gain_db = 14, sends = { hall = -10 }, play = {
      { "break", arpeggio = { pattern = "up", interval = "16n", octaves = 2 }, octave = 4, velocity = 0.55 },
      { "tail", arpeggio = { pattern = "up", interval = "32n", octaves = 3 }, octave = 3, velocity = 0.6 },
    } },
  },
  automation = {
    ["parts/pulse/cutoff"] = { { "ignition", 140 }, { "drop", 420 }, { "break", 160 }, { "lockup", 460 } },
  },
}
