-- The soundtrack: an odawg song at 96 BPM in Ab major (a bar is 2.5 s), its
-- sections named after the scenes, which take their lengths from it. Its
-- parts are the picture's too: a piano note as the pen starts each letter and
-- a harp pluck for each mark, the strings swelling into the burst and the
-- timpani and a cymbal on it, a chord as the title block is drawn. video.lua
-- reads its cues from these notes.
--
-- Why: a sheet being drawn, then lifting off and spinning, wants something
-- that builds by itself, so a piece after Nils Frahm's "Says": one synth
-- arpeggio (a voice of our own: two detuned saws and a square through a
-- resonant low-pass) cycling six sixteenths against the bar, its filter
-- opening over the whole piece to its peak at the burst and closing as the
-- shapes fall back; a soft grand for the pen, a harp for the marks, quiet
-- cellos and violas swelling under the lift, timpani, a sine sub and a real
-- cymbal on the burst. Ab major, the harmony moving by a fourth (Abmaj9
-- Dbmaj9) and lifting to Fm11 Eb6 for the rise, no risers or whooshes.

local LIB = "../../../skills/onimite-video/library/"

-- The pen: letter i starts on eighth i + 1 of the sheet, its mark an
-- eighth later (two notes on one eighth: a letter and the last mark).
local function eighth(k) return string.format("0:%d:%d", k // 2, (k % 2) * 2) end
local LETTER_NOTES = { "Ab5", "C6", "Db6", "Eb6", "F6", "Ab6", "C7" }
local MARK_NOTES = { "Ab3", "Eb4", "C4", "F4", "Db4", "Ab4", "Eb4" }
local letters, marks = {}, {}
for i = 1, 7 do
  letters[i] = { time = eighth(i + 1), note = LETTER_NOTES[i], duration = "2n", velocity = 0.6 }
  marks[i] = { time = eighth(i + 2), note = MARK_NOTES[i], duration = "8n", velocity = 0.65 }
end

local VSCO = { url = "https://raw.githubusercontent.com/sgossner/VSCO-2-CE/6dd651d55dde97fd4028699be9d4481f26917891/",
  page = "https://github.com/sgossner/VSCO-2-CE/tree/SFZ", licence = "CC0-1.0",
  credit = "VS Chamber Orchestra 2: Community Edition by Versilian Studios LLC, CC0 1.0", pins = "pins/vsco.pins" }

return song { "score", key = "Ab major", bpm = 96, seed = 1018, gain_db = -6,
  sources = { vsco = VSCO },
  instruments = { LIB .. "instruments/synths.json", {
    -- the arpeggio: two detuned saws and a square an octave down through a
    -- resonant 24 dB low-pass, plucked by its own envelope
    says = {
      nodes = {
        saws = { "Osc", wave = "fatsawtooth", count = 2, spread = 9 },
        sq = { "Osc", wave = "square", ratio = 0.5, gain_db = -8 },
        both = { "Mix", "saws", "sq" },
        pluck = { "Decay", time = 0.18 },
        lp = { "Filter", "both", type = "lowpass", rolloff = -24, q = 2.2,
               frequency = { { 500, by = "pluck", octaves = 1.2 }, { by = "velocity", octaves = 0.6 } } },
        env = { "Env", attack = 0.004, decay = 0.25, sustain = 0.35, release = 0.18 },
        out = { "Mix", "lp", amp = "env", gain_db = -14 },
      },
      out = "out",
      options = { cutoff = "lp/frequency" },
    },
  } },
  sections = {
    { "plot", duration = "2m", chords = "Abmaj9 Dbmaj9" },
    { "morph", duration = "2m", chords = "Abmaj9 Dbmaj9" },
    { "lift", duration = "3m", chords = "Fm11 Eb6 Dbmaj9" },
    { "fill", duration = "5m", chords = "Abmaj9 Dbmaj9 Fm11 Abmaj9" },
  },
  returns = { hall = { { "Reverb", decay = 3.2, pre_delay = 0.03 }, { "Filter", type = "highpass", frequency = 250 } },
              echo = { { "PingPongDelay", delay_time = "8n.", feedback = 0.4, wet = 1 }, { "Filter", type = "lowpass", frequency = 3000 } } },
  parts = {
    -- the arpeggio: six sixteenths against the bar, the chord's tones
    arp = { instrument = { "says" }, gain_db = 5, sends = { hall = -14, echo = -16 }, play = {
      { "plot..fill", degrees = "1 5 3 8 5 3", subdivision = "16n", octave = 4, velocity = 0.6, humanize = 0.002 },
    } },
    -- the piano: chords from the morph, a rising line under the lift
    piano = { instrument = { "Sampler", set = "osiris/soft_piano", release = 1.2 }, gain_db = -12, sends = { hall = -10 }, play = {
      { "morph", chords = { voicing = "open", rhythm = "x..............." }, octave = 3, duration = "1m", velocity = 0.45 },
      { "lift", degrees = "1 - 3 - 5 - 8 -", subdivision = "4n", octave = 3, velocity = 0.55, humanize = 0.008 },
      { "fill", chords = { voicing = "open", rhythm = { "x...............", "........x......." } }, octave = 3, duration = "2n", velocity = 0.45 },
    } },
    -- the strings under the lift, swelling into the burst
    cellos = { instrument = { "vsco/CelloEnsSusVib-Quiet.sfz", ampeg_attack = 1.2, ampeg_release = 1.2 }, gain_db = 5, sends = { hall = -8 }, play = {
      { "lift..lift@2m", degrees = "1", subdivision = "1m", octave = 2, velocity = 0.6 },
      { "fill", degrees = "1", subdivision = "1m", octave = 2, velocity = 0.45 },
    } },
    violas = { instrument = { "vsco/ViolaEnsSusVib-Quiet.sfz", ampeg_attack = 1.2, ampeg_release = 1.2 }, gain_db = -11, sends = { hall = -8 }, play = {
      { "lift..lift@2m", chords = { voicing = "close", rhythm = "x..............." }, octave = 3, duration = "1m", velocity = 0.6 },
    } },
    sub = { instrument = { "Synth", oscillator = { type = "sine" }, envelope = { attack = 0.3, decay = 0.2, sustain = 0.9, release = 0.8 } }, gain_db = -16,
      play = { { "lift..fill", degrees = "1", subdivision = "1m", octave = 2, velocity = 0.7 } } },
    -- the picture's: the pen, the marks, the burst, the title
    pen = { instrument = { "Sampler", set = "osiris/soft_piano", release = 1.5 }, gain_db = -3, sends = { hall = -6, echo = -14 }, play = { { "plot", events = letters } } },
    ink = { instrument = { "vsco/Harp.sfz", ampeg_release = 0.8 }, gain_db = 7, pan = 0.2, sends = { hall = -8 }, play = { { "plot", events = marks } } },
    impact = { instrument = { "vsco/Timpani.sfz" }, gain_db = 8, sends = { hall = -6 }, play = { { "lift@2m", events = { { time = 0, note = "Ab2", velocity = 0.95 } } } } },
    roll = { instrument = { "vsco/TimpaniRolls.sfz" }, gain_db = 8, sends = { hall = -8 }, play = { { "lift@1m", events = { { time = 0, duration = "1m", note = "Eb3", velocity = 0.55 } } } } },
    crash = { instrument = { "Sampler", set = "virtuosity/drums" }, gain_db = -3, sends = { hall = -8 }, play = { { "lift@2m", steps = { crash = "X..............." } } } },
    title = { instrument = { "Sampler", set = "osiris/soft_piano", release = 2 }, gain_db = -11, sends = { hall = -3 }, play = { { "fill@3m", events = {
      { time = 0, note = "Ab4", duration = "1m" }, { time = 0, note = "C5", duration = "1m" },
      { time = 0, note = "Eb5", duration = "1m" }, { time = "8n", note = "G5", duration = "1m", velocity = 0.6 } } } } },
    glint = { instrument = { "vsco/Glockenspiel.sfz", ampeg_release = 1 }, gain_db = 19, sends = { hall = -4 }, play = { { "fill@3m", events = {
      { time = "8n", note = "G6", duration = "2n", velocity = 0.5 }, { time = "4n", note = "C7", duration = "2n", velocity = 0.45 } } } } },
  },
  -- the arpeggio's filter opens over the piece, peaks at the burst, closes as
  -- the shapes fall back
  automation = {
    ["parts/arp/cutoff"] = { { "plot", 380 }, { "lift@2m", 3600 }, { "fill", 1400 }, { "fill@4m", 420 } },
  },
}
