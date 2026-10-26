-- The music: an odawg song, organic electronica at 120 BPM in E Dorian, its
-- sections named after the scenes. The parts the picture answers to are placed
-- in the sections and pitched from the data: a marimba note per month (higher
-- and harder for a bigger harvest), a chime on the best month and on the
-- total, a string swell while the line draws, a glockenspiel note per crop,
-- the count's ticks up the scale, a deep boom under the name. timeline.lua
-- reads them back as the picture's cues.
--
-- Why: a year of a garden told in numbers wants something organic and
-- precise at once, so organic electronica after Bonobo's "Cirrus": recorded
-- mallets in interlocking loops as the hook (a marimba ostinato against a
-- dotted glockenspiel line, a harp joining for the donut), a half-time broken
-- beat on a real kit (the kick and snare on three, swung sixteenth hats with
-- ghosts) with a tuned 909 kick under it for weight, a deep bass held through
-- the bar (a fingered electric bass over a synth sub), a pad of wide synth
-- saws (its filter opening as the line draws) with quiet violas in it. E Dorian (its
-- major IV, A9, is the colour), extended chords, no off-beat stabs. Recorded
-- and synthesized sounds are stacked as `layers`; the orchestral ones are VS
-- Chamber Orchestra 2's own SFZ files through `sources`, pinned in
-- media/pins/vsco.pins.

-- The skill's library (skills/onimite-video/library: rows to copy into your
-- media folder), from this example's media folder.
local LIB = "../../../skills/onimite-video/library/"

-- E minor pentatonic, two octaves: a month's value picks its marimba note.
local PENTA = { "E4", "G4", "A4", "B4", "D5", "E5", "G5", "A5", "B5", "D6" }
local SCALE = { "E5", "F#5", "G5", "A5", "B5", "C#6", "D6", "E6", "F#6", "G6", "A6", "B6" }

-- A position in a section: beats and sixteenths from its start.
local function at(beat, sixteenth) return string.format("0:%d:%d", beat, sixteenth or 0) end

return function(months, crops)
  local hi = 0
  for _, v in ipairs(months) do hi = math.max(hi, v) end
  local blips, segments, ticks = {}, {}, {}
  for m, v in ipairs(months) do      -- a beat into "bars", a month a sixteenth
    blips[m] = { time = at(1, m - 1), note = PENTA[1 + math.floor(v / hi * (#PENTA - 1) + 0.5)], duration = "8n",
      velocity = 0.5 + 0.4 * v / hi }
  end
  for k = 1, crops do                -- a beat into "donut", a crop a beat
    segments[k] = { time = at(k), note = PENTA[4 + k], duration = "8n", velocity = 0.75 }
  end
  for x = 1, 12 do                   -- a beat into "outro", twelve sixteenths up the scale
    ticks[x] = { time = at(1, x - 1), note = SCALE[x], duration = "16n", velocity = 0.45 + 0.03 * x }
  end

  local VSCO = { url = "https://raw.githubusercontent.com/sgossner/VSCO-2-CE/6dd651d55dde97fd4028699be9d4481f26917891/",
    page = "https://github.com/sgossner/VSCO-2-CE/tree/SFZ", licence = "CC0-1.0",
    credit = "VS Chamber Orchestra 2: Community Edition by Versilian Studios LLC, CC0 1.0", pins = "pins/vsco.pins" }

  return song { "score", key = "E dorian", bpm = 120, seed = 12, gain_db = -13, swing = 0.12, swing_subdivision = "16n",
    sources = { vsco = VSCO },
    instruments = { LIB .. "instruments/synths.json", {
      -- the bass: a fingered electric bass over a sine sub
      deep = { layers = { { instrument = { "Sampler", set = "karoryfer/growlybass", release = 0.2 } },
                          { instrument = { "Synth", oscillator = { type = "sine" }, envelope = { attack = 0.005, decay = 0.3, sustain = 0.8, release = 0.15 } }, gain_db = -4 } } },
      -- the chime: the harp with an FM bell inside it
      chime = { layers = { { instrument = { "vsco/Harp.sfz", ampeg_release = 1.5 } }, { instrument = { "bell", decay = 1.2 }, gain_db = -9 } } },
    } },
    sections = {
      { "title", duration = "2m", chords = "Em9" },
      { "bars", duration = "4m", chords = "Em9 A9" },
      { "line", duration = "3m", chords = "Cmaj7 D6 Em9" },
      { "donut", duration = "3m", chords = "Em9 A9 Gmaj7" },
      { "outro", duration = "2m", chords = "Cmaj7 Bm7" },
      { "tail", duration = "1m", chords = "Em9" },
    },
    returns = { space = { { "Reverb", decay = 2.4, pre_delay = 0.02 }, { "Filter", type = "highpass", frequency = 300 } },
                echo = { { "PingPongDelay", delay_time = "8n.", feedback = 0.35, wet = 1 }, { "Filter", type = "lowpass", frequency = 3500 } } },
    parts = {
      -- the hook: a marimba ostinato, two bars, developing
      marimba = { instrument = { "vsco/Marimba.sfz" }, gain_db = 14, sends = { space = -14, echo = -18 }, play = {
        { "title..outro", notes = "E5 . B4 . D5 . E5 B4 . G5 . . F#5 . D5 . | E5 . B4 . D5 . A5 . G5 . F#5 . D5 . B4 .", subdivision = "16n",
          velocity = 0.55, humanize = 0.005, vary = { {}, { fill = true }, {}, { transpose = 1 } } },
      } },
      -- against it, a dotted glockenspiel line, high and sparse
      glock = { instrument = { "vsco/Glockenspiel.sfz", ampeg_release = 0.6 }, gain_db = 24, sends = { space = -10, echo = -12 }, play = {
        { "bars..outro", notes = "B6 . . . . . E6 . . . . . G6 . . . | . . A6 . . . . . F#6 . . . . . . .", subdivision = "16n", velocity = 0.45, humanize = 0.005 },
      } },
      -- the harp joins for the donut: the chord, up and down
      harp = { instrument = { "vsco/Harp.sfz", ampeg_release = 0.8 }, gain_db = 7, sends = { space = -12 }, play = {
        { "donut", arpeggio = { pattern = "upDown", interval = "16n", octaves = 2 }, octave = 4, velocity = 0.5, humanize = 0.004 },
      } },
      -- the beat: half time on a real kit, a tuned 909 kick under it
      drums = { instrument = { "Sampler", set = "virtuosity/drums" }, gain_db = -5, sends = { space = -18 }, play = {
        { "bars", velocity = 0.8, humanize = 0.004, steps = {
          kick = { "x.....x.x.......", "x.....x...x....." }, snare = "........X.......",
          hat = { "x.oxx.oxx.oxx.ox", "x.oxx.oxx.oxX.ox" } } },
        { "line", velocity = 0.7, humanize = 0.004, steps = { kick = "x.......x.......", hat = "x.o.x.o.x.o.x.o." } },
        { "donut..outro", velocity = 0.85, humanize = 0.004, steps = {
          kick = { "x.....x.x.......", "x.....x...x..x.." }, snare = { "........X.......", "........X.....o." },
          hat = { "x.oxx.oxx.oxx.ox", "x.oxx.oxx.oxX.ox" }, open_hat = { "", "..............x." } } },
        { "tail", events = { { time = 0, note = "kick" } } },
      } },
      thump = { instrument = { LIB .. "machines/909.json", tone = 0.3, tune = -3, decay = 1.2 }, gain_db = -6, play = {
        { "bars", steps = { kick = { "x.....x.x.......", "x.....x...x....." } }, velocity = 0.7 },
        { "line", steps = { kick = "x.......x......." }, velocity = 0.6 },
        { "donut..outro", steps = { kick = { "x.....x.x.......", "x.....x...x..x.." } }, velocity = 0.75 },
      } },
      -- the bass: long notes, a push into the bar's second half
      bass = { instrument = { "deep" }, gain_db = -10, sidechain = { "thump/kick", depth = 0.35 }, play = {
        { "bars..outro", degrees = "1 - - - - - 1 - 5 - - - - - 7 -", subdivision = "16n", octave = 2, velocity = 0.8, humanize = 0.003 },
        { "tail", degrees = "1", subdivision = "1m", octave = 2, velocity = 0.7 },
      } },
      -- the pad: wide synth saws opening as the line draws, quiet violas in it
      pad = { instrument = { "pad", cutoff = 900, attack = 0.8 }, gain_db = -4, sends = { space = -8 }, play = {
        { "title..tail", chords = { voicing = "spread", rhythm = "x..............." }, octave = 3, duration = "1m", velocity = 0.5 },
      } },
      violas = { instrument = { "vsco/ViolaEnsSusVib-Quiet.sfz", ampeg_attack = 0.6, ampeg_release = 1 }, gain_db = -6, sends = { space = -8 }, play = {
        { "title..tail", chords = { voicing = "close", rhythm = "x..............." }, octave = 3, duration = "1m", velocity = 0.5 },
      } },
      -- what the picture answers to
      impact = { instrument = { LIB .. "instruments/808_bass.json", decay = 2 }, gain_db = -3, sends = { space = -12 },
        play = { { "title", events = { { time = "2n", note = "E1", duration = "2n", velocity = 0.9 } } } } },
      months = { instrument = { "vsco/Marimba.sfz" }, gain_db = 7, sends = { space = -10, echo = -14 }, play = { { "bars", events = blips } } },
      segments = { instrument = { "vsco/Glockenspiel.sfz" }, gain_db = 17, sends = { space = -10, echo = -12 }, play = { { "donut", events = segments } } },
      ticks = { instrument = { "vsco/Glockenspiel.sfz" }, gain_db = 14, sends = { space = -12 }, play = { { "outro", events = ticks } } },
      chimes = { instrument = { "chime" }, gain_db = 7, sends = { space = -8 }, play = {
        { "bars", events = { { time = "2:2:0", note = "B5", duration = "2n" } } },   -- the best month
        { "line", events = { { time = "1:3:0", note = "E6", duration = "2n" } } },   -- the line lands on the total
        { "outro", events = { { time = "1m", note = "E5", duration = "1m" } } },     -- the count lands
      } },
      -- while the line draws: the violin section swelling from nothing
      riser = { instrument = { "vsco/ViolinEnsSusVib.sfz", ampeg_attack = 1.2, ampeg_release = 0.6 }, gain_db = 3, sends = { space = -10 },
        play = { { "line", events = { { time = "4n", duration = "1:2:0", note = "B5", velocity = 0.6 },
                                      { time = "4n", duration = "1:2:0", note = "E5", velocity = 0.6 } } } } },
    },
    automation = {
      ["parts/pad/cutoff"] = { { "title", 700 }, { "line", 900 }, { "donut", 2400 }, { "tail", 900 } },
    },
  }
end
