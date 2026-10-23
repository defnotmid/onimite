-- The soundtrack: an odawg song, ambient in D minor at 96 BPM (a bar is
-- 2.5 s), its sections named after the scenes, which take their lengths
-- from it. The ambient style gives the pad, the bells and, as the energy
-- rises under the rings, the strings and the sub; the parts below are the
-- picture's: a bell as the pen starts each letter and a pluck for each
-- mark, a riser into the burst and an impact, crash and whoosh on it, and a
-- chord as the title block is drawn. video.lua reads its cues from these
-- notes.

local LIB = "../../../skills/onimite-video/library/"
local INSTRUMENTS = { LIB .. "instruments/synths.json", LIB .. "instruments/classic.json", LIB .. "instruments/sfx.json" }

-- The pen: letter i starts on eighth i + 1 of the sheet, its mark an
-- eighth later (two notes on one eighth: a letter and the last mark).
local function eighth(k) return string.format("0:%d:%d", k // 2, (k % 2) * 2) end
local LETTER_NOTES = { "D5", "F5", "G5", "A5", "C6", "D6", "F6" }
local MARK_NOTES = { "D4", "A4", "F4", "C5", "G4", "D5", "A4" }
local letters, marks = {}, {}
for i = 1, 7 do
  letters[i] = { time = eighth(i + 1), note = LETTER_NOTES[i], duration = "2n", velocity = 0.7 }
  marks[i] = { time = eighth(i + 2), note = MARK_NOTES[i], duration = "8n", velocity = 0.55 }
end

return song { "score", instruments = INSTRUMENTS, key = "D minor", bpm = 96, seed = 1018, gain_db = -6,
  sections = {
    { "plot", duration = "2m", style = LIB .. "styles/ambient.json", energy = 0.2, chords = "Dm9 Bbmaj7" },
    { "morph", duration = "2m", energy = 0.3, chords = "Gm9 A7" },
    { "lift", duration = "3m", energy = 0.5, chords = "Dm9 Bbmaj7 C" },
    { "fill", duration = "5m", energy = 0.32, chords = "Dm9 Bbmaj7 Fmaj7 Dm9" },
  },
  parts = {
    pad = { gain_db = -17 },
    pen = { instrument = "bell", gain_db = 1.9, sends = { hall = -6 }, play = { { "plot", events = letters } } },
    ink = { instrument = "pluck", gain_db = -2.2, pan = 0.2, sends = { hall = -8 }, play = { { "plot", events = marks } } },
    riser = { instrument = "riser", gain_db = -1, play = { { "lift@1m", events = { { time = 0, duration = "1m" } } } } },
    impact = { instrument = "impact", gain_db = 3, play = { { "lift@2m", events = { { time = 0, note = "D1" } } } } },
    whoosh = { instrument = "whoosh", gain_db = -1, play = { { "lift@2m", events = { { time = 0, duration = "2n" } } } } },
    crash = { instrument = "crash", gain_db = -7, sends = { hall = -8 }, play = { { "lift@2m", events = { { time = 0 } } } } },
    title = { instrument = "bell", gain_db = 2.9, sends = { hall = -3 }, play = { { "fill@3m", events = {
      { time = 0, note = "D5", duration = "1m" }, { time = 0, note = "F5", duration = "1m" },
      { time = 0, note = "A5", duration = "1m" }, { time = "8n", note = "E6", duration = "1m", velocity = 0.6 } } } } },
  },
}
