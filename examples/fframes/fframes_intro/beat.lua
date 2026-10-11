-- The musical clock (fframes-intro's beat.rs). The soundtrack is an edit of
-- a 132 BPM track whose cuts all land on phrase boundaries, so the whole
-- video sits on one beat grid: every scene starts on a downbeat and
-- animations are written in beats.

local M = {}

local floor, ceil, exp, sqrt, sin, cos = math.floor, math.ceil, math.exp, math.sqrt, math.sin, math.cos

M.FPS = 60
-- One beat of the soundtrack, in seconds (132.007 BPM, measured).
M.BEAT = 0.454522
-- First downbeat of the soundtrack (bar 1, beat 1).
M.DOWNBEAT0 = 2.14851
-- The music ends with a decay; the video stops with it.
M.TOTAL_SECONDS = 127.5

local BEAT, DOWNBEAT0, FPS = M.BEAT, M.DOWNBEAT0, M.FPS

function M.beat_time(beat) return DOWNBEAT0 + beat * BEAT end

-- Rust's f32::round: half away from zero.
M.round = round

-- The frame a beat starts on, rounded so scene boundaries never drift.
function M.beat_frame(beat) return round(M.beat_time(beat) * FPS) end

-- Seconds since the start of the video, whichever scene the frame belongs to.
function M.gsec(f) return f.global_index / FPS end

-- Position on the beat grid of the whole video (negative before bar 1).
function M.gbeat(f) return (M.gsec(f) - DOWNBEAT0) / BEAT end

-- Frames between two beats; nil stands for the start or end of the video.
function M.span_frames(start, stop)
  local a = start and M.beat_frame(start) or 0
  local b = stop and M.beat_frame(stop) or round(M.TOTAL_SECONDS * FPS)
  return b - a
end

-- ---- numbers as Rust has them ----------------------------------------------------------

-- f32::fract: x - trunc(x) (negative for negative x).
M.fract = fract
-- `x as usize`: truncation, saturating at 0.
function M.usize(x) if x ~= x or x <= 0 then return 0 end return floor(x) end

-- ---- easing, all on 0..1 ---------------------------------------------------------------

M.clamp01 = clamp01 -- the standard library's

-- Where `x` is between `a` and `b`, clamped to 0..1.
M.prog = progress

M.lerp = lerp

function M.expo_out(t)
  t = clamp01(t)
  if t >= 1 then return 1 end
  return 1 - 2 ^ (-10 * t)
end

function M.expo_in(t)
  t = clamp01(t)
  if t <= 0 then return 0 end
  return 2 ^ (10 * t - 10)
end

function M.cubic_in_out(t)
  t = clamp01(t)
  if t < 0.5 then return 4 * t * t * t end
  return 1 - (-2 * t + 2) ^ 3 / 2
end

function M.quart_out(t) return 1 - (1 - clamp01(t)) ^ 4 end

-- Damped spring from 0 to 1 (mass 1), `t` in seconds since release.
local function spring(t, stiffness, damping)
  if t <= 0 then return 0 end
  local w0 = sqrt(stiffness)
  local zeta = damping / (2 * w0)
  if zeta < 1 then
    local wd = w0 * sqrt(1 - zeta * zeta)
    return 1 - exp(-zeta * w0 * t) * (cos(wd * t) + zeta * w0 / wd * sin(wd * t))
  end
  return 1 - (1 + w0 * t) * exp(-w0 * t)
end
M.spring = spring

-- A snappy UI spring, `beats` since it was released.
function M.snap(beats) return spring(beats * BEAT, 320, 22) end
-- A softer spring with a visible overshoot.
function M.soft(beats) return spring(beats * BEAT, 170, 15) end

-- Decaying pulse that fires on every beat: 1 on the beat, ~0 half a beat later.
function M.pulse(beat, sharpness) return exp(-(beat - floor(beat)) * sharpness) end

-- Deterministic hash noise, 0..1: fract(sin(n * 127.1 + 311.7) * 43758.547).
function M.hash(n)
  local x = sin(n * 127.1 + 311.7) * 43758.547
  return x - floor(x)
end

return M
