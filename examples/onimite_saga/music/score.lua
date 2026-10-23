-- The score: an odawg song in A minor whose sections are the film's scenes,
-- each with its length in bars and its tempo. The tempo ramps (the build
-- into the drop, the tape slowing, the countdown, the last chorus, the tape
-- stop) are the sections' `bpm = { from, to }`. Every scene starts on its
-- section (`score.time("race")`), and everything placed in a scene is
-- measured on this tempo map, so changing a section moves the scenes, the
-- music and the sounds after it together.
--
-- The parts are music/parts.lua's instruments, playing what each act
-- (music/act1.lua ...) gives them. The drops are written out below: a
-- riser over the two bars before, an impact and a crash.

-- The skill's library (skills/onimite-video/library: rows and styles to
-- copy into your media folder), from this example's media folder.
local LIB = "../../../skills/onimite-video/library/"
local INSTRUMENTS = { LIB .. "instruments/synths.json", LIB .. "instruments/classic.json", LIB .. "instruments/sfx.json" }

local P = require("music.parts")

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

-- the two drops (one, montage): a riser into each, an impact and a crash on its downbeat
parts.rise = { instrument = "riser", gain_db = -4, play = {
  { "spark", events = { { time = "2m", duration = "2m", note = "C4", velocity = 0.35 } } },
  { "rise", events = { { time = 0, duration = "1m", note = "C4", velocity = 0.35 } } } } }
parts.fx = { instrument = "impact", gain_db = -4, play = {
  { "one", events = { { time = 0, duration = 2.5, note = "C2", velocity = 0.8 } } },
  { "montage", events = { { time = 0, duration = 2.5, note = "C2", velocity = 0.8 } } } } }
parts.fx_crash = { instrument = "crash", gain_db = -4, play = {
  { "one", events = { { time = 0, duration = 1.6, note = "C4", velocity = 0.7 } } },
  { "montage", events = { { time = 0, duration = 1.6, note = "C4", velocity = 0.7 } } } } }

return song { "score", instruments = INSTRUMENTS, key = "A minor", seed = 204, gain_db = -10,
  sections = {
    -- act I: the void, slow and dramatic
    { "before", duration = "2m", bpm = 60, energy = 0.2, chords = "Am" },
    { "weight", duration = "2m", energy = 0.25, chords = "Fm" },
    { "spark", duration = "4m", bpm = { 60, 128 }, energy = 0.5, chords = "Am" },
    -- act II: K-pop
    { "one", duration = "2m", bpm = 128, energy = 1, chords = "Am F" },
    { "download", duration = "2m", energy = 0.9, chords = "C G" },
    { "race", duration = "2m", chords = "Am F" },
    { "bill", duration = "2m", chords = "C G" },
    { "reload", duration = "2m", chords = "Am F" },
    { "slow", duration = "1m", bpm = { 128, 64 }, energy = 0.4, chords = "Am" },   -- the tape slows
    { "hush", duration = "4m", time_signature = 2, bpm = 64, energy = 0.2, chords = "Am F Dm C" }, -- half time
    { "rise", duration = "1m", time_signature = 4, bpm = { 64, 144 }, energy = 0.4, chords = "Am" }, -- and back up
    -- act III: all it does (the montage), then what it is built on (the family)
    { "montage", duration = "4m", bpm = 144, energy = 1, chords = "C G Am F" },
    { "ovg", duration = "2m", energy = 0.9, chords = "C G" },
    { "odecs", duration = "2m", chords = "Am F" },
    { "oksl", duration = "2m", chords = "C G" },
    { "not_needed", duration = "2m", chords = "Am F" },
    { "check", duration = "2m", chords = "C G" },
    { "last", duration = "4m", bpm = { 144, 168 }, energy = 1, chords = "Am F C G" }, -- keeps accelerating
    -- act IV: the twist
    { "tape_stop", duration = "1m", bpm = { 168, 36 }, energy = 0.3, chords = "Am" },
    { "fade", duration = "2m", bpm = 54, energy = 0.1 },                          -- Pip fades
    { "slam", duration = "1m", bpm = 140, energy = 0.3, transition = "none" },    -- the logo
    { "rain", duration = "5m", bpm = 90 },                                        -- the matrix
  },
  parts = parts,
  returns = P.RETURNS,
  -- the logo lands a beat into its section, after a beat of nothing
  markers = { { "logo_hit", at = "slam@4n" } },
}
