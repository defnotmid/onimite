-- The score: an odawg song in C# minor whose sections are the film's
-- scenes, each with its length in bars and its tempo. The tempo ramps (the build
-- into the drop, the tape slowing, the countdown, the last chorus, the tape
-- stop) are the sections' `bpm = { from, to }`. Every scene starts on its
-- section (`score.time("race")`), and everything placed in a scene is
-- measured on this tempo map, so changing a section moves the scenes, the
-- music and the sounds after it together.
--
-- The parts are music/parts.lua's instruments, playing what each act
-- (music/act1.lua ...) gives them. The drops are written out below: an 808
-- boom and a recorded crash on each downbeat; what leads into them is the
-- music (the build's rolls and opening filter, the countdown), no riser.
--
-- Why: the film goes from a void to K-pop to a twist, so the score follows
-- K-pop's own switch-ups: string sections and a drone for the void; a verse
-- of four on the floor under a dembow rim and a tresillo 808 (the Latin
-- lilt K-pop borrows) on C#m9 F#m9 Amaj7 G#7; a half-time hush; then the
-- chorus as Jersey club (the bouncing kick of NewJeans-era K-pop) on the
-- royal road, Amaj7 B7 G#m7 C#m9, the progression K-pop and J-pop lean on,
-- with Pip's hook on a lead the violins double; the tape stopping, and the
-- matrix's half-step dread. Inspiration from the genre, no song copied.

-- The skill's library (skills/onimite-video/library: rows and styles to
-- copy into your media folder), from this example's media folder.
local LIB = "../../../skills/onimite-video/library/"
local P = require("music.parts")
local INSTRUMENTS = { P.ROWS, LIB .. "instruments/synths.json", LIB .. "instruments/classic.json", LIB .. "instruments/sfx.json" }

local parts = {}
for name, p in pairs(P.PARTS) do
  local part = { play = {} }
  for k, v in pairs(p) do part[k] = v end
  parts[name] = part
end
for _, act in ipairs { "act1", "act2", "act3", "act4" } do
  for name, entries in pairs(require("music." .. act)) do
    local part = assert(parts[name], ("music/%s.lua: no part %q in music/parts.lua"):format(act, name))
    for _, e in ipairs(entries) do part.play[#part.play + 1] = e end
  end
end

-- the two drops (one, montage): an 808 boom (the picture flashes on it) and
-- a recorded crash on each downbeat
parts.fx = { role = "fx", instrument = { LIB .. "instruments/808_bass.json", decay = 0.9 }, gain_db = 1, play = {
  { "one", events = { { time = 0, duration = "2n", note = "C#2", velocity = 0.9 } } },
  { "montage", events = { { time = 0, duration = "2n", note = "C#2", velocity = 0.9 } } } } }
parts.fx_crash = { role = "fx", instrument = { "Sampler", set = "virtuosity/drums" }, gain_db = 2.7, sends = { hall = -12 }, play = {
  { "one", steps = { crash = "X..............." } },
  { "montage", steps = { crash = "X..............." } } } }

return song { "score", instruments = INSTRUMENTS, key = "C# minor", seed = 204, gain_db = -18, sources = P.SOURCES,
  sections = {
    -- act I: the void, slow and dramatic
    { "before", duration = "2m", bpm = 60, energy = 0.2, chords = "C#madd9" },
    { "weight", duration = "2m", energy = 0.25, chords = "Am" },
    { "spark", duration = "4m", bpm = { 60, 128 }, energy = 0.5, chords = "C#m" },
    -- act II: K-pop
    { "one", duration = "2m", bpm = 128, energy = 1, chords = "C#m9 F#m9" },
    { "download", duration = "2m", energy = 0.9, chords = "Amaj7 G#7" },
    { "race", duration = "2m", chords = "C#m9 F#m9" },
    { "bill", duration = "2m", chords = "Amaj7 G#7" },
    { "reload", duration = "2m", chords = "C#m9 F#m9" },
    { "slow", duration = "1m", bpm = { 128, 64 }, energy = 0.4, chords = "C#m" },   -- the tape slows
    { "hush", duration = "4m", time_signature = 2, bpm = 64, energy = 0.2, chords = "F#m9 Amaj7 Emaj7 G#sus4" }, -- half time
    { "rise", duration = "1m", time_signature = 4, bpm = { 64, 144 }, energy = 0.4, chords = "G#7" }, -- and back up
    -- act III: all it does (the montage), then what it is built on (the family)
    { "montage", duration = "4m", bpm = 144, energy = 1, chords = "Amaj7 B7 G#m7 C#m9" },
    { "ovg", duration = "2m", energy = 0.9, chords = "Amaj7 B7" },
    { "oicut", duration = "2m", chords = "G#m7 C#m9" },
    { "oksl", duration = "2m", chords = "Amaj7 B7" },
    { "not_needed", duration = "2m", chords = "G#m7 C#m9" },
    { "check", duration = "2m", chords = "Amaj7 B7" },
    { "last", duration = "4m", bpm = { 144, 168 }, energy = 1, chords = "Amaj7 B7 G#m7 G#7" }, -- keeps accelerating
    -- act IV: the twist
    { "tape_stop", duration = "1m", bpm = { 168, 36 }, energy = 0.3, chords = "C#m" },
    { "fade", duration = "2m", bpm = 54, energy = 0.1 },                          -- Pip fades
    { "slam", duration = "1m", bpm = 140, energy = 0.3, transition = "none" },    -- the logo
    { "rain", duration = "5m", bpm = 90 },                                        -- the matrix
  },
  parts = parts,
  returns = P.RETURNS,
  -- the logo lands a beat into its section, after a beat of nothing
  markers = { { "logo_hit", at = "slam@4n" } },
  automation = {
    -- the build's pad opens with the tempo, into the drop (the countdown's
    -- swell plays open)
    ["parts/swell/cutoff"] = { { "spark", 450 }, { "spark@3m", 2200 }, { "one", 7000 } },
    -- the 808 up where the tempo falls under it and the kit rolls, and the
    -- kit up for the countdown and the stop (inspect's role_balance: 9-10 LU
    -- under the mix there, 3-5 in the verse)
    ["parts/bass/gain_db"] = { { "before", 0 }, { "slow", 6.5, "step" }, { "hush", 0, "step" },
      { "tape_stop", 6.5, "step" }, { "fade", 0, "step" } },
    ["parts/drums/gain_db"] = { { "before", 0 }, { "rise", 3, "step" }, { "montage", 0, "step" },
      { "tape_stop", 2, "step" }, { "fade", 0, "step" } },
    -- the stabs' last chord held as the tape slows
    ["parts/stabs/gain_db"] = { { "one", 0 }, { "slow", 2, "step" }, { "hush", 0, "step" } },
  },
}
