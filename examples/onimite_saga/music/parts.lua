-- What the four acts' score shares: the sources and the film's own rows,
-- the instruments (a part each, with its role, effects, sends and
-- side-chain), the hook, and the builders the acts write their play entries
-- with. The acts (music/act1.lua ...) say what each part
-- plays where; music/score.lua puts the sections and the acts together.
-- A part's gain_db sets it in the mix, a note's velocity (0..1) its dynamics.

-- The skill's library (skills/onimite-video/library: rows and styles to
-- copy into your media folder), from this example's media folder.
local LIB = "../../../skills/onimite-video/library/"
local INSTRUMENTS = { LIB .. "instruments/synths.json", LIB .. "instruments/classic.json", LIB .. "instruments/sfx.json" }

local M = {}

-- ---- the instruments ---------------------------------------------------------

-- The TR-909's circuits: the build, the K-pop acts and the tape stop.
local MACHINE = { LIB .. "machines/909.json", tone = 0.55 }
-- What ducks under the kick: the stabs, the arp, the hook.
local DUCK = { "drums/kick", depth_db = -6.9, release = 0.18 }

-- VS Chamber Orchestra 2's own SFZ files, fetched on first use and pinned
-- (media/pins/vsco.pins).
M.SOURCES = {
  vsco = { url = "https://raw.githubusercontent.com/sgossner/VSCO-2-CE/6dd651d55dde97fd4028699be9d4481f26917891/",
    page = "https://github.com/sgossner/VSCO-2-CE/tree/SFZ", licence = "CC0-1.0",
    credit = "VS Chamber Orchestra 2: Community Edition by Versilian Studios LLC, CC0 1.0", pins = "pins/vsco.pins" },
}

-- Rows of the film's own, beside the library's.
M.ROWS = {
  -- the string sections together: violins, violas and cellos
  sections = { layers = {
    { instrument = { "vsco/ViolinEnsSusVib.sfz", ampeg_attack = 1.2, ampeg_release = 2.5 } },
    { instrument = { "vsco/ViolaEnsSusVib-Quiet.sfz", ampeg_attack = 1.2, ampeg_release = 2.5 } },
    { instrument = { "vsco/CelloEnsSusVib.sfz", ampeg_attack = 1.2, ampeg_release = 2.5 }, gain_db = 4 } } },
  -- Pip's hook: the library's lead with the violin section doubling it
  theme = { layers = {
    { instrument = { "lead" } },
    { instrument = { "vsco/ViolinEnsSusVib.sfz", ampeg_attack = 0.05, ampeg_release = 0.4 }, gain_db = 8 } } },
  -- Pip's bells: the library's FM bell with the glockenspiel in it
  chime = { layers = {
    { instrument = { "bell" } },
    { instrument = { "vsco/Glockenspiel.sfz", ampeg_release = 1.5 }, gain_db = 16 } } },
}

M.PARTS = {
  drums = { role = "drums", instrument = MACHINE, gain_db = -0.5, sends = { room = -20 } },
  -- the 808 under the K-pop acts, and the matrix's dread pulse on its own
  bass = { role = "bass", instrument = { LIB .. "instruments/808_bass.json", decay = 0.6 }, gain_db = -2, octave = 1 },
  pulse = { role = "bass", instrument = { LIB .. "instruments/808_bass.json", decay = 0.6 }, gain_db = -4.5 },
  stabs = { role = "comp", instrument = "stab", gain_db = -0.7, octave = 4, sidechain = DUCK, sends = { hall = -14 } },
  -- the arp, a part an act so its dotted-eighth echo is read at that act's
  -- tempo (the verse's 128; the chorus's 144 in seconds, as the lead's, the
  -- last chorus speeding up under it)
  arp = { role = "texture", instrument = "pluck", gain_db = -6.2, octave = 4, sidechain = DUCK,
    effects = { { "PingPongDelay", delay_time = "8n.", feedback = 0.3, wet = 0.22 } }, sends = { hall = -16 } },
  arp3 = { role = "texture", instrument = "pluck", gain_db = -6.2, octave = 4, sidechain = DUCK,
    effects = { { "PingPongDelay", delay_time = 0.3125, feedback = 0.3, wet = 0.22 } }, sends = { hall = -16 } },
  -- the matrix's creeping figure, on the same pluck
  creep = { role = "counter", instrument = "pluck", gain_db = -6.2,
    effects = { { "PingPongDelay", delay_time = "8n.", feedback = 0.3, wet = 0.22 } }, sends = { hall = -16 } },
  -- its echo a dotted eighth at the chorus's 144, in seconds: the last
  -- chorus speeds up to 168 under it and the echo stays where it was
  lead = { role = "melody", instrument = "theme", gain_db = 5.6, sidechain = DUCK,
    effects = { { "FeedbackDelay", delay_time = 0.3125, feedback = 0.25, wet = 0.18 } }, sends = { hall = -10 } },
  -- the void: a dark pad, and the string sections over it
  drone = { role = "pad", instrument = { "pad", cutoff = 520, attack = 3 }, gain_db = -2.9 },
  strings = { role = "pad", instrument = "sections", gain_db = -6, sends = { hall = -8 } },
  -- the pad that opens: the build into the drop (its cutoff rises with the
  -- tempo, score.lua), the countdown
  swell = { role = "pad", instrument = { "pad", cutoff = 3500, attack = 2 }, gain_db = -4.3 },
  bells = { role = "fx", instrument = "chime", gain_db = 4.7, sends = { hall = -6 } },
  -- the hush: a quiet grand over a soft pad
  piano = { role = "melody", instrument = { "Sampler", set = "osiris/soft_piano", release = 1.2 }, gain_db = -4.4, sends = { hall = -10 } },
  pad = { role = "pad", instrument = { "pad", cutoff = 1100, attack = 0.6 }, gain_db = -5.3 },
  -- the tape: a chord whose pitch falls to nothing, a sine gliding down
  tape = { role = "fx", instrument = "tape_chord", gain_db = -6.2 },
  fall = { role = "fx", instrument = "fall", gain_db = 3.9 },
  -- the logo's drone: a boom closing over seven beats
  slam = { role = "pad", instrument = { "pad", cutoff = 300, attack = 0.05 }, gain_db = -1.5 },
  -- an 808 boom: the countdown's last number, the tape stop
  boom = { role = "fx", instrument = { LIB .. "instruments/808_bass.json", decay = 2 }, gain_db = 12 },
  heart = { role = "fx", instrument = "thump", gain_db = 0.5 },
}

M.RETURNS = {
  hall = { { "Reverb", decay = 3.2, pre_delay = 0.03 } },
  room = { { "Reverb", decay = 0.9, pre_delay = 0.01 } },
}

-- ---- the hook ----------------------------------------------------------------

-- Pip's hook, a bar per chord in eighths ("-" holds), on the chorus's
-- royal road (Amaj7 B7 G#m7 C#m9): its first half over Amaj7 B7, its second
-- over G#m7 C#m9, and the last chorus's turn over G#m7 G#7 into the stop.
M.HOOK = {
  UP = "C#6 - B5 G#5 - E5 G#5 - B5 - A5 F#5 - D#5 F#5 -",
  HOME = "B5 - G#5 D#5 - F#5 G#5 - E5 - D#5 C#5 - - - -",
  TURN = "B5 - G#5 D#5 - F#5 G#5 - G#5 - F#5 D#5 - C5 D#5 -",
}

-- ---- builders ----------------------------------------------------------------

-- `b` beats into a play entry's range, as a time ("0:3.5": 3.5 quarters).
function M.beats(b) return ("0:%g"):format(b) end

-- Notes held together: `notes` ("A1 E2 A2") from `at` (a time) for `length`.
function M.held(notes, at, length, velocity)
  local out = {}
  for n in notes:gmatch("%S+") do out[#out + 1] = { time = at or 0, note = n, duration = length, velocity = velocity } end
  return out
end

-- `n` hits of `note` (a pad or a note) every `step` beats from beat `from`,
-- the velocity going from v0 to v1: rolls and crescendos.
function M.roll(note, from, n, step, v0, v1, length)
  local out = {}
  for i = 0, n - 1 do
    out[#out + 1] = { time = M.beats(from + i * step), note = note, duration = length or "32n",
      velocity = v0 + (v1 - v0) * (n > 1 and i / (n - 1) or 0) }
  end
  return out
end

-- Event lists joined into one.
function M.join(...)
  local out = {}
  for _, l in ipairs { ... } do for _, e in ipairs(l) do out[#out + 1] = e end end
  return out
end

return M
