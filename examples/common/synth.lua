-- The instruments the examples' soundtracks share: plain Lua that computes
-- one sound at a time and adds it to a native audio_buffer (48 kHz stereo),
-- for a video without supplied music. Not part of onimite; copy it next to
-- your own video.lua, or load it the way the examples do:
--
--   local synth = dofile("../common/synth.lua")   -- dofile resolves beside the script
--   local function build()
--     local s = synth.new(30, { seed = 120 })     -- 30 s of silence
--     s.kick(0.5, 0.9)
--     s.chord(1.0, 2, { 57, 60, 64 }, 0.1, 1800, 0.01, 2)
--     return s.finish()                           -- the buffer, peak at -1 dBFS
--   end
--   audio_add("track", build)                     -- built when the sound is needed
--
-- Times are seconds; opts.origin is where the buffer starts on the video, so
-- one section of a long video is its own clip played from there while its
-- instruments still take video times.
-- Sidechain: set s.duck(t) to a gain (bass, chords, plucks and leads multiply
-- by it), e.g. s.kicks({ kick times }, 0.8) dips them under every kick.
-- Your own instruments: `local n, x = s.note(dur)` gives the sample count
-- and a scratch list to fill (x[1..n]), `s.put(t0, x, n, pan)` adds it
-- (`s.put_stereo(t0, l, r, n)` for two lists); s.RATE, s.midi(note),
-- s.lp(hz) and s.noise() help.

local M = {}

local RATE = 48000
local sin, exp, floor, abs, min, max, random = math.sin, math.exp, math.floor, math.abs, math.min, math.max, math.random
local TAU = 2 * math.pi

local function midi(n) return 440 * 2 ^ ((n - 69) / 12) end
-- One-pole low-pass coefficient for a cutoff in Hz.
local function lp(hz) return 1 - exp(-TAU * hz / RATE) end
local function noise() return random() * 2 - 1 end
M.RATE, M.midi, M.lp, M.noise = RATE, midi, lp, noise

-- A buffer of `seconds` of silence and the instruments that play into it.
-- opts.seed seeds math.random (so every render makes the same noise).
function M.new(seconds, opts)
  opts = opts or {}
  math.randomseed(opts.seed or 1)
  local mix = audio_buffer(seconds)
  local origin = opts.origin or 0
  local N = floor(seconds * RATE)
  local s = { RATE = RATE, mix = mix, origin = origin, midi = midi, lp = lp, noise = noise }

  -- One sound at a time: scratch lists reused for every note.
  local x, xr = {}, {}
  local function note(dur) return max(0, floor(dur * RATE)), x end
  local function put(t0, list, n, pan) mix:add(t0 - origin, list, pan or 0, n) end
  s.note, s.put = note, put
  function s.put_stereo(t0, l, r, n) mix:add_stereo(t0 - origin, l, r, n) end
  s.duck = function() return 1 end
  local function duck(t) return s.duck(t) end

  -- Sidechain: gains dip by `depth` under each kick time (video seconds), 70
  -- ms release. The gain is kept per 64-sample block, so instruments read a
  -- table entry per sample rather than searching the kicks.
  function s.kicks(times, depth)
    depth = depth or 0.8
    local BLOCK = 64
    local blocks = floor(N / BLOCK) + 2
    local g = {}
    for j = 1, blocks do g[j] = 1 end
    local release = floor(0.5 * RATE / BLOCK) -- 0.5 s: the dip is gone by then
    for _, kt in ipairs(times) do
      local j0 = floor((kt - origin) * RATE / BLOCK) + 1
      for j = max(j0, 1), min(blocks, j0 + release) do
        local d = 1 - depth * exp(-max((j - 1) * BLOCK / RATE + origin - kt, 0) / 0.07)
        if d < g[j] then g[j] = d end
      end
    end
    s.duck = function(t)
      local j = floor((t - origin) * RATE / BLOCK) + 1
      return g[j] or 1
    end
  end

  -- ---- instruments ---------------------------------------------------------

  -- A sine with a fast pitch drop and an exponential decay, plus a click.
  function s.kick(t0, gain)
    local n = note(0.4)
    local ph = 0
    for k = 1, n do
      local t = (k - 1) / RATE
      ph = ph + TAU * (48 + 130 * exp(-t * 30)) / RATE
      x[k] = (sin(ph) * exp(-t * 7) + noise() * exp(-t * 600) * 0.25) * gain
    end
    put(t0, x, n, 0)
  end

  -- Three quick high-passed noise bursts and a tail, over a short tone body.
  function s.clap(t0, gain)
    local n = note(0.3)
    local prev, ph = 0, 0
    for k = 1, n do
      local t = (k - 1) / RATE
      local v = noise()
      local hp = v - prev
      prev = v
      local bursts = t < 0.033 and exp(-(t % 0.011) * 300) or 0
      ph = ph + TAU * 185 / RATE
      x[k] = (hp * (bursts * 0.7 + exp(-t * 16) * 0.5) * 0.6 + sin(ph) * exp(-t * 30) * 0.5) * gain
    end
    put(t0, x, n, -0.05)
  end

  -- Twice high-passed noise; crashes are long open hats.
  function s.hat(t0, dur, decay, gain)
    local n = note(dur)
    local p1, p2 = 0, 0
    for k = 1, n do
      local t = (k - 1) / RATE
      local v = noise()
      local h1 = v - p1
      local h2 = h1 - p2
      p1, p2 = v, h1
      x[k] = h2 * 0.25 * exp(-t * decay) * gain
    end
    put(t0, x, n, 0.12)
  end

  -- A saw (and a sine an octave down) through a one-pole low-pass, ducked.
  function s.bass(t0, dur, note_, gain)
    local n = note(dur)
    local f = midi(note_) / RATE
    local ph, y, k1 = 0, 0, lp(420)
    for k = 1, n do
      local t = (k - 1) / RATE
      ph = ph + f
      if ph >= 1 then ph = ph - 1 end
      y = y + k1 * (2 * ph - 1 - y)
      local env = min(1, t * 400, (n - k) / 480)
      x[k] = (y + sin(TAU * ph) * 0.6) * env * gain * duck(t0 + t)
    end
    put(t0, x, n, 0)
  end

  -- Detuned saw pairs, one side tuned up and the other down, low-passed and
  -- ducked: short decays make stabs, slow attacks pads. `sc` is how much the
  -- sidechain dips it (1, 0 for pads); the cutoff moves from `cutoff` to
  -- `cutoff2` over the chord.
  function s.chord(t0, dur, notes, gain, cutoff, attack, decay, sc, cutoff2)
    local n = note(dur)
    if n == 0 then return end
    local k0, k1 = lp(cutoff), lp(cutoff2 or cutoff)
    sc = sc or 1
    for k = 1, n do x[k], xr[k] = 0, 0 end
    for _, nt in ipairs(notes) do
      local f1, f2 = midi(nt) * 1.006 / RATE, midi(nt) / 1.006 / RATE
      local p1, p2, yl, yr = random(), random(), 0, 0
      for k = 1, n do
        local t = (k - 1) / RATE
        local kc = k0 + (k1 - k0) * (k - 1) / n
        p1 = p1 + f1
        if p1 >= 1 then p1 = p1 - 1 end
        p2 = p2 + f2
        if p2 >= 1 then p2 = p2 - 1 end
        yl = yl + kc * (2 * p1 - 1 + p2 - 0.5 - yl)
        yr = yr + kc * (2 * p2 - 1 + p1 - 0.5 - yr)
        local g = sc > 0 and 1 - sc * (1 - duck(t0 + t)) or 1
        local env = min(1, t / attack, (n - k) / 2400) * exp(-t * decay) * gain * g
        x[k] = x[k] + yl * env
        xr[k] = xr[k] + yr * env
      end
    end
    mix:add_stereo(t0 - origin, x, xr, n)
  end

  -- A low-passed square pluck for arps.
  function s.pluck(t0, note_, gain, pan)
    local n = note(0.18)
    local f = midi(note_) / RATE
    local ph, y, k1 = 0, 0, lp(2500)
    for k = 1, n do
      local t = (k - 1) / RATE
      ph = ph + f
      if ph >= 1 then ph = ph - 1 end
      y = y + k1 * ((ph < 0.5 and 1 or -1) - y)
      x[k] = y * exp(-t * 16) * gain * duck(t0 + t)
    end
    put(t0, x, n, pan)
  end

  -- Noise through an opening low-pass and a rising sine (`tone`, 0.15),
  -- swelling into a drop.
  function s.riser(t0, dur, gain, tone)
    local n = note(dur)
    local y, ph = 0, 0
    tone = tone or 0.15
    for k = 1, n do
      local u = (k - 1) / n
      y = y + lp(300 + 9000 * u * u) * (noise() - y)
      ph = ph + TAU * (180 + 900 * u * u) / RATE
      x[k] = (y * 0.8 + sin(ph) * tone) * u * u * gain
    end
    put(t0, x, n, 0)
  end

  -- The big hit: a falling sub boom and a burst of dark noise, saturated.
  function s.impact(t0, gain)
    local n = note(2.5)
    local ph, y, k1 = 0, 0, lp(900)
    for k = 1, n do
      local t = (k - 1) / RATE
      ph = ph + TAU * (30 + 70 * exp(-t * 6)) / RATE
      y = y + k1 * (noise() - y)
      local v = (sin(ph) * exp(-t * 1.6) + y * 1.5 * exp(-t * 4)) * gain
      x[k] = v / (1 + abs(v)) * 1.6
    end
    put(t0, x, n, 0)
  end

  -- A tuned drum: a sine falling from 1.6x its pitch.
  function s.tom(t0, hz, gain)
    local n = note(0.5)
    local ph = 0
    for k = 1, n do
      local t = (k - 1) / RATE
      ph = ph + TAU * hz * (1 + 0.6 * exp(-t * 25)) / RATE
      x[k] = (sin(ph) * exp(-t * 9) + noise() * exp(-t * 400) * 0.2) * gain
    end
    put(t0, x, n, 0)
  end

  -- A heavy landing: a low sine dropping a little, a click on top.
  function s.thump(t0, note_, gain)
    local n = note(0.7)
    local f, ph = midi(note_), 0
    for k = 1, n do
      local t = (k - 1) / RATE
      ph = ph + TAU * f * (1 + 0.8 * exp(-t * 40)) / RATE
      x[k] = (sin(ph) * exp(-t * 6) + noise() * exp(-t * 500) * 0.3) * gain
    end
    put(t0, x, n, 0)
  end

  -- A hook voice: a detuned saw pair and a square an octave down, a little
  -- vibrato once the note settles, ducked half as much as the chords.
  function s.lead(t0, dur, note_, gain)
    local n = note(dur)
    local f = midi(note_)
    local p1, p2, p3, y = 0, random(), 0, 0
    local k1 = lp(3500)
    for k = 1, n do
      local t = (k - 1) / RATE
      local vib = 1 + 0.004 * sin(TAU * 5.5 * t) * min(1, t * 6)
      p1 = p1 + f * 1.004 * vib / RATE
      if p1 >= 1 then p1 = p1 - 1 end
      p2 = p2 + f / 1.004 * vib / RATE
      if p2 >= 1 then p2 = p2 - 1 end
      p3 = p3 + f * 0.5 / RATE
      if p3 >= 1 then p3 = p3 - 1 end
      y = y + k1 * (2 * p1 - 1 + 2 * p2 - 1 + (p3 < 0.5 and 0.6 or -0.6) - y)
      local env = min(1, t * 200, (n - k) / 400) * exp(-t * 1.2)
      x[k] = y * env * gain * (1 - 0.5 * (1 - duck(t0 + t)))
    end
    put(t0, x, n, 0)
  end

  -- A struck bell: the note, a stretched partial and a high one that dies fast.
  function s.bell(t0, note_, gain, decay, pan)
    local f = midi(note_)
    local n = note(min(4, 8 / decay))
    for k = 1, n do
      local t = (k - 1) / RATE
      local v = sin(TAU * f * t) + 0.35 * sin(TAU * f * 2.01 * t) * exp(-t * decay * 1.5)
        + 0.2 * sin(TAU * f * 3.5 * t) * exp(-t * decay * 3)
      x[k] = v * exp(-t * decay) * min(1, t * 500) * gain
    end
    put(t0, x, n, pan or 0)
  end

  -- A sine gliding from f0 to f1 Hz and fading: tape slowing, a boot.
  function s.fall(t0, dur, gain, f0, f1)
    local n = note(dur)
    local ph = 0
    for k = 1, n do
      local u = (k - 1) / n
      ph = ph + TAU * f0 * (f1 / f0) ^ u / RATE
      x[k] = (sin(ph) + 0.4 * sin(2 * ph)) * (1 - u) ^ 1.5 * min(1, (k - 1) / 200) * gain
    end
    put(t0, x, n, 0)
  end

  -- A chord on a stopping tape: every note's pitch falls to nothing.
  function s.tape_chord(t0, dur, notes, gain)
    local n = note(dur)
    local k1 = lp(2500)
    for k = 1, n do x[k] = 0 end
    for _, nt in ipairs(notes) do
      local f = midi(nt) / RATE
      local ph, y = random(), 0
      for k = 1, n do
        local u = (k - 1) / n
        ph = ph + f * (1 - u) ^ 2
        if ph >= 1 then ph = ph - 1 end
        y = y + k1 * (2 * ph - 1 - y)
        x[k] = x[k] + y * (1 - u) * min(1, (k - 1) / 100) * gain
      end
    end
    put(t0, x, n, 0)
  end

  -- A key: a high-passed click over a short tap at `hz`.
  function s.tick(t0, gain, hz)
    local n = note(0.025)
    local prev = 0
    for k = 1, n do
      local t = (k - 1) / RATE
      local v = noise()
      local h = v - prev
      prev = v
      x[k] = (h * exp(-t * 500) * 0.5 + sin(TAU * hz * t) * exp(-t * 300) * 0.5) * gain
    end
    put(t0, x, n, 0)
  end

  -- A terminal's beep: a short square.
  function s.beep(t0, hz, gain)
    local n = note(0.03)
    local ph, f = 0, hz / RATE
    for k = 1, n do
      local t = (k - 1) / RATE
      ph = ph + f
      if ph >= 1 then ph = ph - 1 end
      x[k] = (ph < 0.5 and 1 or -1) * exp(-t * 90) * min(1, t * 800) * gain
    end
    put(t0, x, n, 0)
  end

  -- A tiny ember popping.
  function s.crackle(t0, gain, pan)
    local n = note(0.012)
    local prev = 0
    for k = 1, n do
      local t = (k - 1) / RATE
      local v = noise()
      local h = v - prev
      prev = v
      x[k] = h * exp(-t * 900) * gain
    end
    put(t0, x, n, pan)
  end

  -- A beat (`len` seconds) of stutter: eight grains of square tone and
  -- noise at pitches from hash(g + t0, 0..1), bouncing left and right.
  function s.glitch(t0, gain, len)
    local grain = len / 8
    for g = 0, 7 do
      local n = note(grain * 0.7)
      local f = midi(72 + floor(hash(g + t0) * 24)) / RATE
      local ph = 0
      for k = 1, n do
        ph = ph + f
        if ph >= 1 then ph = ph - 1 end
        x[k] = ((ph < 0.5 and 0.5 or -0.5) + noise() * 0.3) * gain
      end
      put(t0 + g * grain, x, n, g % 2 == 0 and -0.6 or 0.6)
    end
  end

  -- A short sine blip with an octave on top.
  function s.blip(t0, hz, gain)
    local n = note(0.09)
    for k = 1, n do
      local t = (k - 1) / RATE
      x[k] = (sin(TAU * hz * t) + 0.3 * sin(TAU * 2 * hz * t)) * exp(-t * 45) * gain
    end
    put(t0, x, n, 0)
  end

  -- A DONE: two rising blips `gap` seconds apart.
  function s.done(t0, gain, gap)
    s.blip(t0, 1320, gain)
    s.blip(t0 + gap, 1980, gain)
  end

  -- A gentle low-pass over the mix (tames the naive saws' and noise's top
  -- end; a function of video seconds automates it), then the peak normalised
  -- to `peak` (0.89, about -1 dBFS; false keeps the level, for sections mixed
  -- together); returns the buffer for audio_add.
  function s.finish(cutoff, peak)
    if type(cutoff) == "function" then
      mix:lowpass(function(t) return cutoff(t + origin) end)
    else
      mix:lowpass(cutoff or 11000)
    end
    if peak ~= false then mix:normalize(peak or 0.89) end
    return mix
  end

  return s
end

return M
