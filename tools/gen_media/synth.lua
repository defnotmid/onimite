-- A small synthesizer for the example media: instruments that add into a
-- stereo buffer, and a 16-bit 48 kHz WAV packer. Plain Lua (math and
-- string only), after examples/why_onimite/track.lua; the scripts beside it
-- (sounds.lua, clip.lua) require it and register the result with
-- audio_add().

local M = {}

local RATE = 48000
M.RATE = RATE
local sin, exp, floor, abs, min, max, random = math.sin, math.exp, math.floor, math.abs, math.min, math.max, math.random
local TAU = 2 * math.pi

function M.midi(n) return 440 * 2 ^ ((n - 69) / 12) end
local midi = M.midi
-- One-pole low-pass coefficient for a cutoff in Hz.
local function lp(hz) return 1 - exp(-TAU * min(hz, RATE * 0.45) / RATE) end
local function noise() return random() * 2 - 1 end

-- A silent stereo buffer of `seconds`; `seed` makes the noise repeatable.
function M.buffer(seconds, seed)
  math.randomseed(seed or 1)
  local n = floor(seconds * RATE)
  local L, R = {}, {}
  for i = 1, n do L[i], R[i] = 0, 0 end
  return { L = L, R = R, n = n, duck = function() return 1 end }
end

-- The samples a sound starting at t0 for dur seconds covers.
local function span(b, t0, dur)
  return max(1, floor(t0 * RATE) + 1), min(b.n, floor((t0 + dur) * RATE))
end

local function add(b, i, v, pan)
  b.L[i] = b.L[i] + v * (1 - pan)
  b.R[i] = b.R[i] + v * (1 + pan)
end

-- ---- drums -----------------------------------------------------------------

-- A sine with a fast pitch drop and an exponential decay, plus a click.
function M.kick(b, t0, gain)
  local a, e = span(b, t0, 0.4)
  local ph = 0
  for i = a, e do
    local t = (i - a) / RATE
    ph = ph + TAU * (48 + 130 * exp(-t * 30)) / RATE
    add(b, i, (sin(ph) * exp(-t * 7) + noise() * exp(-t * 600) * 0.25) * gain, 0)
  end
end

-- Twice high-passed noise: short decays are closed hats, long ones open.
function M.hat(b, t0, dur, decay, gain, pan)
  local a, e = span(b, t0, dur)
  local p1, p2 = 0, 0
  for i = a, e do
    local t = (i - a) / RATE
    local x = noise()
    local h1 = x - p1
    local h2 = h1 - p2
    p1, p2 = x, h1
    add(b, i, h2 * 0.25 * exp(-t * decay) * gain, pan or 0.12)
  end
end

-- Three quick high-passed noise bursts and a tail, over a short tone body.
function M.clap(b, t0, gain)
  local a, e = span(b, t0, 0.3)
  local prev, ph = 0, 0
  for i = a, e do
    local t = (i - a) / RATE
    local x = noise()
    local hp = x - prev
    prev = x
    local bursts = t < 0.033 and exp(-(t % 0.011) * 300) or 0
    ph = ph + TAU * 185 / RATE
    add(b, i, (hp * (bursts * 0.7 + exp(-t * 16) * 0.5) * 0.6 + sin(ph) * exp(-t * 30) * 0.5) * gain, -0.05)
  end
end

-- ---- tones -----------------------------------------------------------------

-- Detuned saw pairs, one side tuned up and the other down, low-passed:
-- slow attacks make pads, short decays stabs. Ducked by b.duck(t).
function M.chord(b, t0, dur, notes, gain, cutoff, attack, decay)
  local a, e = span(b, t0, dur)
  local k = lp(cutoff)
  for _, n in ipairs(notes) do
    local f1, f2 = midi(n) * 1.006 / RATE, midi(n) / 1.006 / RATE
    local p1, p2, yl, yr = random(), random(), 0, 0
    for i = a, e do
      local t = (i - a) / RATE
      p1 = p1 + f1
      if p1 >= 1 then p1 = p1 - 1 end
      p2 = p2 + f2
      if p2 >= 1 then p2 = p2 - 1 end
      yl = yl + k * (2 * p1 - 1 + p2 - 0.5 - yl)
      yr = yr + k * (2 * p2 - 1 + p1 - 0.5 - yr)
      local env = min(1, t / attack, (e - i) / 2400) * exp(-t * decay) * gain * b.duck(t0 + t)
      b.L[i] = b.L[i] + yl * env
      b.R[i] = b.R[i] + yr * env
    end
  end
end

-- A low-passed square pluck.
function M.pluck(b, t0, note, gain, pan, cutoff)
  local a, e = span(b, t0, 0.22)
  local f = midi(note) / RATE
  local ph, y, k = 0, 0, lp(cutoff or 2500)
  for i = a, e do
    local t = (i - a) / RATE
    ph = ph + f
    if ph >= 1 then ph = ph - 1 end
    y = y + k * ((ph < 0.5 and 1 or -1) - y)
    add(b, i, y * exp(-t * 16) * min(1, (e - i) / 240) * gain * b.duck(t0 + t), pan)
  end
end

-- A two-operator FM bell: a sine whose phase a 3.5x sine bends, the
-- bending dying faster than the tone.
function M.bell(b, t0, note, gain, pan, decay)
  local dur = 6 / (decay or 3)
  local a, e = span(b, t0, dur)
  local f = midi(note)
  for i = a, e do
    local t = (i - a) / RATE
    local mod = sin(TAU * f * 3.5 * t) * 2.2 * exp(-t * 6)
    local v = sin(TAU * f * t + mod) * exp(-t * (decay or 3)) * min(1, t * 400, (e - i) / 480)
    add(b, i, v * gain, pan or 0)
  end
end

-- A sine sub with a soft attack, ducked.
function M.sub(b, t0, dur, note, gain)
  local a, e = span(b, t0, dur)
  local f = midi(note) / RATE
  local ph = 0
  for i = a, e do
    local t = (i - a) / RATE
    ph = ph + f
    local env = min(1, t * 60, (e - i) / 960)
    local x = sin(TAU * ph)
    add(b, i, (x + 0.15 * x * x * x) * env * gain * b.duck(t0 + t), 0)
  end
end

-- ---- effects ---------------------------------------------------------------

-- A pop: a sine falling an octave and a half in a few milliseconds, with a
-- breathy click on top.
function M.pop(b, t0, gain, pan)
  local a, e = span(b, t0, 0.12)
  local ph, y = 0, 0
  for i = a, e do
    local t = (i - a) / RATE
    ph = ph + TAU * (380 + 900 * exp(-t * 55)) / RATE
    y = y + lp(4000) * (noise() - y)
    local env = min(1, t * 2000) * exp(-t * 38)
    add(b, i, (sin(ph) + y * 0.25 * exp(-t * 120)) * env * gain, pan or 0)
  end
end

-- A whoosh: noise through a band-pass (two one-poles) whose centre rises
-- and falls, swelling and fading, panned across.
function M.whoosh(b, t0, dur, gain)
  local a, e = span(b, t0, dur)
  local y1, y2 = 0, 0
  for i = a, e do
    local u = (i - a) / (e - a)
    local hz = 300 + 3200 * sin(math.pi * u ^ 0.8)
    local k1, k2 = lp(hz * 1.6), lp(hz * 0.6)
    local x = noise()
    y1 = y1 + k1 * (x - y1)
    y2 = y2 + k2 * (y1 - y2)
    local env = sin(math.pi * u) ^ 2 * (1 - u * 0.3)
    add(b, i, (y1 - y2) * 1.8 * env * gain, -0.6 + 1.2 * u)
  end
end

-- Wind: slowly wandering low-passed noise, a different gust each side.
function M.wind(b, t0, dur, gain)
  local a, e = span(b, t0, dur)
  local yl, yr = 0, 0
  for i = a, e do
    local t = (i - a) / RATE
    local g = 0.55 + 0.45 * sin(TAU * t / dur) ^ 2
    yl = yl + lp(500 + 300 * sin(TAU * t * 0.5)) * (noise() - yl)
    yr = yr + lp(500 + 300 * sin(TAU * t * 0.5 + 2)) * (noise() - yr)
    local fade = min(1, t * 4, (e - i) / RATE * 4)
    b.L[i] = b.L[i] + yl * g * fade * gain
    b.R[i] = b.R[i] + yr * g * fade * gain
  end
end

-- ---- output ----------------------------------------------------------------

-- A gentle low-pass, then normalize the peak to `peak` (0.89 = -1 dBFS) and
-- pack as a 16-bit stereo 48 kHz WAV string.
function M.wav(b, peak)
  local L, R, n = b.L, b.R, b.n
  local k, yl, yr = lp(15000), 0, 0
  for i = 1, n do
    yl = yl + k * (L[i] - yl)
    yr = yr + k * (R[i] - yr)
    L[i], R[i] = yl, yr
  end
  local top = 1e-9
  for i = 1, n do top = max(top, abs(L[i]), abs(R[i])) end
  local s = (peak or 0.89) / top * 32767
  local FRAMES = 4096
  local full = "<" .. string.rep("i2", 2 * FRAMES)
  local chunks, buf = {}, {}
  for first = 1, n, FRAMES do
    local m = min(FRAMES, n - first + 1)
    for j = 0, m - 1 do
      buf[2 * j + 1] = floor(L[first + j] * s + 0.5)
      buf[2 * j + 2] = floor(R[first + j] * s + 0.5)
    end
    local fmt = m == FRAMES and full or "<" .. string.rep("i2", 2 * m)
    chunks[#chunks + 1] = string.pack(fmt, table.unpack(buf, 1, 2 * m))
  end
  local data = table.concat(chunks)
  return string.pack("<c4I4c4c4I4I2I2I4I4I2I2c4I4", "RIFF", 36 + #data, "WAVE", "fmt ", 16, 1, 2,
    RATE, RATE * 4, 4, 16, "data", #data) .. data
end

return M
