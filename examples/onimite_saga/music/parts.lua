-- What the four acts' score shares: the instruments (a part each, with its
-- effects, sends and side-chain), the hook, and the builders the acts write
-- their play entries with. The acts (music/act1.lua ...) say what each part
-- plays where; music/score.lua puts the sections and the acts together.
-- A part's gain_db sets it in the mix, a note's velocity (0..1) its dynamics.

-- The skill's library (skills/onimite-video/library: rows and styles to
-- copy into your media folder), from this example's media folder.
local LIB = "../../../skills/onimite-video/library/"
local INSTRUMENTS = { LIB .. "instruments/classic.json", LIB .. "instruments/sfx.json" }

local M = {}

-- ---- the instruments ---------------------------------------------------------

-- The TR-909's circuits: the build, the K-pop acts and the tape stop.
local MACHINE = { LIB .. "machines/909.json", tone = 0.55 }
-- What ducks under the kick: the pumping bass, the stabs, the arp, the hook.
local DUCK = { "drums/kick", depth = 0.55, release = 0.18 }

M.PARTS = {
  drums = { instrument = MACHINE, gain_db = -0.5, sends = { room = -20 } },
  -- the offbeat bass, and the matrix's dread pulse
  bass = { instrument = "bass", gain_db = -2.5, octave = 1, sidechain = DUCK },
  stabs = { instrument = "stab", gain_db = -11, octave = 4, sidechain = DUCK, sends = { hall = -14 } },
  arp = { instrument = "pluck", gain_db = -12.5, octave = 4, sidechain = DUCK,
    effects = { { "PingPongDelay", delay_time = "8n.", feedback = 0.3, wet = 0.22 } }, sends = { hall = -16 } },
  lead = { instrument = "lead", gain_db = -15.5, sidechain = DUCK,
    effects = { { "FeedbackDelay", delay_time = "8n.", feedback = 0.25, wet = 0.18 } }, sends = { hall = -10 } },
  -- the void: a dark pad, and string sections over it
  drone = { instrument = { "pad", cutoff = 160, cutoff2 = 520, envelope = { attack = 3 } }, gain_db = -15.5 },
  strings = { instrument = { "Sampler", set = "vsco2/strings", attack = 1.2, release = 2.5 }, gain_db = -19.4,
    sends = { hall = -8 } },
  -- the pad that opens: the build into the drop, the countdown
  swell = { instrument = { "pad", cutoff = 300, cutoff2 = 3500, envelope = { attack = 2 } }, gain_db = -20.5 },
  bells = { instrument = "bell", gain_db = -13.5, sends = { hall = -6 } },
  -- the hush: a quiet grand over a soft pad
  piano = { instrument = { "Sampler", set = "osiris/soft_piano", release = 1.2 }, gain_db = -8.4, sends = { hall = -10 } },
  pad = { instrument = { "pad", cutoff = 450, cutoff2 = 1100, envelope = { attack = 0.6 } }, gain_db = -22.5 },
  -- the tape: a chord whose pitch falls to nothing, a sine gliding down
  tape = { instrument = "tape_chord", gain_db = -15.5 },
  fall = { instrument = "fall", gain_db = -12 },
  -- the logo's drone: a boom closing over seven beats
  slam = { instrument = { "pad", cutoff = 300, cutoff2 = 120, envelope = { attack = 0.05 } }, gain_db = -10.5 },
  sweep = { instrument = "riser", gain_db = 4.5 },
  boom = { instrument = "impact", gain_db = -1.5 },
  heart = { instrument = "thump", gain_db = 0.5 },
}

M.RETURNS = {
  hall = { { "Reverb", decay = 3.2, pre_delay = 0.03 } },
  room = { { "Reverb", decay = 0.9, pre_delay = 0.01 } },
}

-- ---- the hook ----------------------------------------------------------------

-- Pip's hook, a bar per chord in eighths ("-" holds): over Am F, over C G.
M.HOOK = {
  AF = "E5 G5 A5 - G5 E5 D5 - F5 A5 C6 - A5 F5 E5 -",
  CG = "G5 C6 E6 - C6 G5 E5 - D5 G5 B5 - G5 D5 B4 -",
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
