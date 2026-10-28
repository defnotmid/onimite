-- The music of the video (fframes' src/soundtrack.rs): a 120 BPM track in A minor, composed
-- when the video renders. Its hits, plucks and keystrokes use the timing in beat.lua.
--
-- The original synthesizes every voice sample by sample in Rust; here the same score is a
-- song{} (odawg), each voice a row of nodes built from the original's own recipe (the same
-- oscillators, noise, filters and envelopes, the same times and levels), each note an event
-- at the original's time with its gain as the velocity and its pan in the note's accent
-- (`pan = -1 + 2 * accent` on the row's out). The pad and the bass pump under the kick as
-- the original's sidechain does (1 - 0.7 e^(-9 t) after each kick). It sounds close, not
-- identical: odawg's filters, noise and saws are its own.

local B = require("beat")

local M = {}

local TAU = 2 * math.pi
local function db(gain) return 20 * math.log(gain, 10) end
local bt = B.beat_time

-- MIDI note to a name ("A4")
local NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
local function name(midi)
  local m = math.floor(midi + 0.5)
  return NAMES[m % 12 + 1] .. tostring(m // 12 - 1)
end

-- the pan of a note as its accent: the rows place it by -1 + 2 * accent
local function accent(pan) return (pan + 1) / 2 end
local PAN = { base = -1, by = "accent", amount = 2 }

-- ------------------------------------------------------------------ Score

-- Chord of each bar (4 beats): root and the notes of the pad, as MIDI notes.
local AM = { 45, { 57, 60, 64, 69 } }
local F = { 41, { 57, 60, 65, 69 } }
local C = { 48, { 55, 60, 64, 67 } }
local G = { 43, { 55, 59, 62, 67 } }
local function chord(beat)
  local bar = math.floor(beat / 4)
  if bar == 1 or bar == 5 then return F end
  if bar == 2 then return C end
  if bar == 3 or bar == 6 then return G end
  -- bars 0, 4 and from the outro on
  return AM
end

-- A minor pentatonic from A4, for plucks that always fit.
local SCALE = { 0, 3, 5, 7, 10 }
local function pentatonic(step) return 69 + SCALE[step % 5 + 1] + 12 * (step // 5) end

-- Beats with a kick drum.
local KICKS = {}
for b = 0, 23 do KICKS[#KICKS + 1] = b end
for b = 28, 33 do KICKS[#KICKS + 1] = b end

-- the events of each part: { time (s), note, duration (s), velocity, accent }
local parts = {}
local function add(part, t, note, duration, velocity, pan)
  local list = parts[part] or {}
  parts[part] = list
  list[#list + 1] = { time = t, note = name(note), duration = duration, velocity = velocity,
    accent = accent(pan or 0) }
end

-- The drums are one kit: its pads at these keys (the kick hits that answer the picture, at
-- beat 1 and under "VECTOR.", are the kick on a pad of their own: the pad and the bass pump
-- under the groove's kicks only, as in the original).
local KICK, HIT, CLAP, HAT = 36, 37, 39, 42
-- drums: the groove kick 0.9, its claps 0.55, its hats 0.22 (offbeats) and 0.08 (sixteenths)
for _, b in ipairs(KICKS) do add("drums", bt(b), KICK, 0.5, 1) end
for b = 8, 33 do
  if b % 2 == 1 and (b < 24 or b >= 29) then add("drums", bt(b), CLAP, 0.3, 1, 0.1) end
end
for i = 0, math.floor(B.END * 4) - 1 do
  local b = i / 4
  local fract = b - math.floor(b)
  local offbeat = math.abs(fract - 0.5) < 0.01
  local sixteenth = b >= 16 and b < 24 and fract ~= 0
  if ((b >= 4 and b < 24) or (b >= 28 and b < 34)) and (offbeat or sixteenth) then
    add("drums", bt(b), HAT, 0.06, offbeat and 1 or 0.08 / 0.22, offbeat and 0.25 or -0.25)
  end
end
-- the build under the zoom: a snare roll that gets faster
do
  local b = B.ZOOM
  while b < B.OUTRO - 0.1 do
    local p = (b - B.ZOOM) / (B.OUTRO - B.ZOOM)
    add("drums", bt(b), CLAP, 0.3, (0.15 + 0.35 * p) / 0.55, 0.1)
    b = b + (p < 0.5 and 0.5 or (p < 0.75 and 0.25 or 0.125))
  end
end

-- bass on the offbeat eighths, the pad a chord a bar; both pump with the kick, and both are
-- silent for 50 ms right before the outro hit
for e = 0, math.floor(B.END * 2) - 1 do
  local b = e / 2
  if e % 2 == 1 and (b < B.ZOOM or (b >= B.OUTRO and b < B.END - 2)) then
    add("bass", bt(b), chord(b)[1], bt(0.5), 1)
  end
end
for bar = 0, math.floor((B.END - 2) / 4) do
  local from = bar * 4
  local to = math.min(from + 4, B.END - 2)
  if from == B.ZOOM then to = B.OUTRO - 0.05 end
  if to > from then
    for _, note in ipairs(chord(from)[2]) do add("pad", bt(from), note, bt(to - from), 1) end
  end
end

-- the hook: hit, word thumps, a rising note per letter
add("impact", bt(B.HOOK), 36, 2.5, 0.8)
-- "NOW PLAYS" gets one hit, because its two words are only 50 ms apart
add("drums", bt(B.WORD_NOW), HIT, 0.5, 0.5 / 0.9)
add("pluck", bt(B.WORD_NOW), 57, 0.8, 1)
for i, note in ipairs { 69, 72, 74, 76, 79, 81 } do
  add("pluck", bt(B.LETTERS + (i - 1) * B.LETTER_STEP), note, 0.8, 0.18 / 0.25, -0.5 + (i - 1) * 0.2)
end

-- transitions: noise sweeping up into the cuts
for _, cut in ipairs { B.GRID, B.CODE } do add("whoosh", bt(cut) - 0.6, 36, 0.6, 0.35 / 0.35) end
add("whoosh", bt(B.ZOOM), 36, bt(B.OUTRO - B.ZOOM), 0.3 / 0.35)
add("impact", bt(B.OUTRO), 36, 2.5, 1.0)
add("impact", bt(B.END - 2), 36, 2.5, 0.7)

-- a pluck for every tile of the grid, panned by its column
for i = 0, B.TILES - 1 do
  add("pluck", bt(B.TILE_POP + i * B.TILE_STEP), pentatonic(i + 2), 0.8, 0.16 / 0.25, ((i % 3) - 1) * 0.6)
end
-- soft arpeggio under the code
for i = 0, math.floor((B.ZOOM - B.CODE) * 2) - 1 do
  local b = B.CODE + i * 0.5
  add("pluck", bt(b), chord(b)[2][i % 4 + 1] + 12, 0.8, 0.05 / 0.25, i % 2 == 0 and -0.4 or 0.4)
end
-- keystrokes, every third one
for i, b in ipairs(B.key_beats()) do
  if (i - 1) % 3 == 0 then add("keys", bt(b), 36, 0.025, 1, (i - 1) % 4 == 0 and -0.2 or 0.2) end
end
-- "VECTOR."
add("drums", bt(B.ZOOM + 0.5), HIT, 0.5, 0.6 / 0.9)
-- the outro: the last chord rings out
for i, note in ipairs { 57, 60, 64, 69, 72 } do
  add("pluck", bt(B.END - 2) + (i - 1) * 0.02, note, 0.8, 0.12 / 0.25, -0.4 + (i - 1) * 0.2)
end

-- ------------------------------------------------------------------ Voices
-- The original's building blocks as rows. Its biquads are odawg Filters of the same type,
-- cutoff and q; its tanh is a Drive (tanh(x) / tanh(1), hence its -2.36 dB).

local TANH1 = db(math.tanh(1))

local INSTRUMENTS = {
  -- a sine falling from 155 Hz to 45 (e^(-32 t)) dying in e^(-7 t), a 4 ms click, then tanh
  kick = { length = 0.5, velocity = "amp", nodes = {
    fall = { "Decay", time = 1 / 32 },
    env = { "Decay", time = 1 / 7 },
    body = { "Osc", wave = "sine", frequency = { base = 45, amount = 110, by = "fall" }, amp = "env" },
    click = { "Ramp", from = 0.6, to = 0, time = 0.004 },
    sum = { "Mix", "body", "click" },
    out = { "Drive", "sum", amount = 1, gain_db = TANH1 },
  }, out = "out" },
  -- band-passed noise (1400 Hz, q 1.2): three quick bursts (e^(-180 t), 11 ms apart) and a tail
  clap = { length = 0.3, velocity = "amp", nodes = {
    noise = { "Noise" },
    band = { "Filter", "noise", type = "bandpass", frequency = 1400, q = 1.2 },
    bursts = { "Decay", time = 1 / 180, bursts = 3, spacing = 0.011 },
    tail = { "Decay", time = 1 / 18 },
    snap = { "Mix", "band", amp = "bursts", gain_db = db(0.5) },
    wash = { "Mix", "band", amp = "tail", gain_db = db(0.6) },
    out = { "Mix", "snap", "wash", pan = PAN },
  }, out = "out" },
  -- high-passed noise (8 kHz, q 0.8) in e^(-70 t)
  hat = { length = 0.06, velocity = "amp", nodes = {
    noise = { "Noise" },
    high = { "Filter", "noise", type = "highpass", frequency = 8000, q = 0.8 },
    env = { "Decay", time = 1 / 70 },
    out = { "Mix", "high", amp = "env", pan = PAN },
  }, out = "out" },
  -- a mechanical key: band-passed noise (3500 Hz, q 2) in e^(-250 t)
  key = { length = 0.025, velocity = "amp", nodes = {
    noise = { "Noise" },
    band = { "Filter", "noise", type = "bandpass", frequency = 3500, q = 2 },
    env = { "Decay", time = 1 / 250 },
    out = { "Mix", "band", amp = "env", pan = PAN },
  }, out = "out" },
  -- two detuned saws through a closing low-pass (400 + 5000 e^(-14 t), q 2), in e^(-5 t)
  pluck = { length = 0.8, velocity = "amp", nodes = {
    a = { "Osc", wave = "sawtooth" },
    b = { "Osc", wave = "sawtooth", ratio = 1.006 },
    sum = { "Mix", "a", "b" },
    fall = { "Decay", time = 1 / 14 },
    low = { "Filter", "sum", type = "lowpass", frequency = { base = 400, amount = 5000, by = "fall" }, q = 2 },
    env = { "Decay", time = 1 / 5 },
    out = { "Mix", "low", amp = "env", pan = PAN },
  }, out = "out" },
  -- a boom (38 + 70 e^(-9 t) Hz, e^(-2.2 t), x 1.2, tanh) and noise through a closing
  -- low-pass (300 + 5000 e^(-4 t), q 0.7) in 0.5 e^(-3 t)
  impact = { length = 2.5, velocity = "amp", nodes = {
    fall = { "Decay", time = 1 / 9 },
    env = { "Decay", time = 1 / 2.2 },
    sine = { "Osc", wave = "sine", frequency = { base = 38, amount = 70, by = "fall" }, amp = "env", gain_db = db(1.2) },
    boom = { "Drive", "sine", amount = 1, gain_db = TANH1 },
    noise = { "Noise" },
    sweep = { "Decay", time = 1 / 4 },
    low = { "Filter", "noise", type = "lowpass", frequency = { base = 300, amount = 5000, by = "sweep" }, q = 0.7 },
    hiss_env = { "Decay", time = 1 / 3 },
    hiss = { "Mix", "low", amp = "hiss_env", gain_db = db(0.5) },
    out = { "Mix", "boom", "hiss" },
  }, out = "out" },
  -- noise through a band-pass sweeping 300 Hz x 20^p (q 1.5), rising as p^2 over the note,
  -- panned by sin(3 t) x 0.6
  whoosh = { velocity = "amp", nodes = {
    noise = { "Noise" },
    sweep = { "Ramp", from = 0, to = 1 },
    band = { "Filter", "noise", type = "bandpass", frequency = { base = 300, by = "sweep", octaves = math.log(20, 2) }, q = 1.5 },
    rise = { "Ramp", from = 0, to = 1, curve = 2 },
    held = { "Env", attack = 0, decay = 0, sustain = 1, release = 0.003 },
    level = { "Mul", "rise", "held" },
    swing = { "Lfo", wave = "sine", rate = 3 / TAU },
    out = { "Mix", "band", amp = "level", pan = { base = 0, by = "swing", amount = 0.6 } },
  }, out = "out" },
  -- a saw and its octave (0.4) through a low-pass (500 Hz, q 1), e^(-10 t) over the eighth
  bass = { velocity = "amp", nodes = {
    a = { "Osc", wave = "sawtooth" },
    b = { "Osc", wave = "sawtooth", ratio = 2, gain_db = db(0.4) },
    sum = { "Mix", "a", "b" },
    low = { "Filter", "sum", type = "lowpass", frequency = 500, q = 1 },
    env = { "Decay", time = 0.1, release = 0.002 },
    out = { "Mix", "low", amp = "env" },
  }, out = "out" },
  -- a saw a side, detuned 0.997 left and 1.003 right, through a low-pass (q 0.9) whose cutoff
  -- the song moves
  pad = { velocity = "amp", nodes = {
    left = { "Osc", wave = "sawtooth", ratio = 0.997, pan = -1 },
    right = { "Osc", wave = "sawtooth", ratio = 1.003, pan = 1 },
    both = { "Mix", "left", "right" },
    low = { "Filter", "both", type = "lowpass", frequency = 1400, q = 0.9 },
    held = { "Env", attack = 0.002, decay = 0, sustain = 1, release = 0.003 },
    out = { "Mix", "low", amp = "held" },
  }, out = "out", options = { cutoff = "low/frequency" } },
}

-- the pad's level and cutoff: 0.05 and 1400 Hz in the hook, 0.07 and 2200 to the zoom,
-- under the zoom 0.05 + 0.08 s and 2200 + 5000 s^2 (s 0 -> 1), 0.08 and 2200 in the outro
local pad_gain = { { 0, db(0.05) }, { bt(B.GRID), db(0.07), "step" }, { bt(B.ZOOM), db(0.05), "step" } }
local pad_cutoff = { { 0, 1400 }, { bt(B.GRID), 2200, "step" } , { bt(B.ZOOM), 2200 } }
for k = 1, 16 do
  local s = k / 16
  local at = bt(B.ZOOM + s * (B.OUTRO - B.ZOOM))
  pad_gain[#pad_gain + 1] = { at, db(0.05 + 0.08 * s) }
  pad_cutoff[#pad_cutoff + 1] = { at, 2200 + 5000 * s * s }
end
pad_gain[#pad_gain + 1] = { bt(B.OUTRO), db(0.08), "step" }
pad_cutoff[#pad_cutoff + 1] = { bt(B.OUTRO), 2200, "step" }

-- The original's gains: each part's gain is its loudest note's, the notes' velocities the rest.
INSTRUMENTS.kit = { pads = {
  kick = { instrument = "kick", key = KICK, gain_db = db(0.9) },
  hit = { instrument = "kick", key = HIT, gain_db = db(0.9) },
  clap = { instrument = "clap", key = CLAP, gain_db = db(0.55) },
  hat = { instrument = "hat", key = HAT, gain_db = db(0.22) },
} }
local SIDECHAIN = { source = "drums/" .. name(KICK), depth_db = -10.5, release = 1 / 9 }
local function part(name, instrument, role, gain_db, extra)
  return merge({ instrument = instrument, role = role, gain_db = gain_db,
    play = { { "music", events = parts[name] } } }, extra)
end

-- The original normalizes its mix to a -1 dBFS peak. The parts as odawg plays them, at the
-- original's gains with inspect's role_balance raises, peak near +6 dBTP: lowered 7 dB.
M.score = song { "score", key = "A minor", bpm = 120, seed = 1, gain_db = -7,
  sections = { { "music", duration = string.format("%dm", math.floor(B.END / 4)) } },
  instruments = INSTRUMENTS,
  -- each part at the original's gain, plus the raise (or cut) inspect's role_balance named
  parts = {
    drums = part("drums", "kit", "drums", 0),
    bass = part("bass", "bass", "bass", db(0.32) + 5.7, { sidechain = SIDECHAIN }),
    -- its level is the gain_db lane's (added to the part's)
    pad = part("pad", "pad", "comp", -1.6, { sidechain = SIDECHAIN }),
    pluck = part("pluck", "pluck", "melody", db(0.25)),
    keys = part("keys", "key", "texture", db(0.25) + 1.2),
    whoosh = part("whoosh", "whoosh", "fx", db(0.35) + 1.3),
    impact = part("impact", "impact", "fx", 0),
  },
  automation = {
    ["parts/pad/gain_db"] = pad_gain,
    ["parts/pad/cutoff"] = pad_cutoff,
  },
}

-- The original normalizes its mix to a -1 dBFS peak, then lifts it 3.5 dB into a -1.3 dBTP
-- limiter (main.rs). This lifts the song to the same loudness.
M.MASTER_GAIN_DB = 3.5

return M
