-- A tempo map: music whose tempo changes (holds and linear ramps), with
-- beats and seconds converting both ways in closed form, so picture and sound
-- read musical time from one place. For a steady tempo the standard
-- library's beat_clock is enough. Not part of onimite; copy it beside your
-- video.lua or load it as the examples do:
--
--   local tempo = dofile("../common/tempo.lua")
--   local map = tempo.map {
--     { "intro", 16, 60 },          -- name, beats, bpm
--     { "build", 16, 60, 128 },     -- a ramp from 60 to 128 BPM
--     { "drop", 32, 128 },
--   }
--   map.time(map.at.drop)           -- seconds where the drop starts
--   map.beat(f)                     -- the beat at a frame (its video time) or at seconds
--
-- Over a ramp the tempo moves linearly in beats: seconds = 60 n / (b1 - b0) * ln(bpm / b0).

local M = {}

local exp, log, floor = math.exp, math.log, math.floor

function M.map(segments)
  local map = { segments = {}, at = {} }
  local b, t = 0, 0
  for _, s in ipairs(segments) do
    local n, b0, b1 = s[2], s[3], s[4] or s[3]
    local dur = b1 == b0 and 60 * n / b0 or 60 * n / (b1 - b0) * log(b1 / b0)
    map.segments[#map.segments + 1] = { name = s[1], beat = b, sec = t, beats = n, bpm0 = b0, bpm1 = b1 }
    map.at[s[1]] = b -- the beat the segment starts on
    b, t = b + n, t + dur
  end
  map.total_beats, map.total_seconds = b, t
  local segs = map.segments

  local function by_beat(x)
    for i = #segs, 1, -1 do if x >= segs[i].beat then return segs[i] end end
    return segs[1]
  end
  local function by_sec(x)
    for i = #segs, 1, -1 do if x >= segs[i].sec then return segs[i] end end
    return segs[1]
  end

  -- Seconds at a beat (beats past the end keep the last tempo).
  function map.time(x)
    local g = by_beat(x)
    local d = x - g.beat
    if g.bpm1 == g.bpm0 then return g.sec + d * 60 / g.bpm0 end
    local bpm = g.bpm0 + (g.bpm1 - g.bpm0) * d / g.beats
    return g.sec + 60 * g.beats / (g.bpm1 - g.bpm0) * log(bpm / g.bpm0)
  end

  -- The (fractional) beat at video seconds, or at a frame (its video time).
  function map.beat(s)
    if type(s) == "table" then s = s.global_seconds end
    local g = by_sec(s)
    local d = s - g.sec
    if g.bpm1 == g.bpm0 then return g.beat + d * g.bpm0 / 60 end
    local bpm = g.bpm0 * exp(d * (g.bpm1 - g.bpm0) / (60 * g.beats))
    return g.beat + g.beats * (bpm - g.bpm0) / (g.bpm1 - g.bpm0)
  end

  -- The tempo at a beat, and how long `d` beats from beat `b` last.
  function map.bpm(x)
    local g = by_beat(x)
    if g.bpm1 == g.bpm0 then return g.bpm0 end
    return g.bpm0 + (g.bpm1 - g.bpm0) * math.min(x - g.beat, g.beats) / g.beats
  end
  function map.seconds(b, d) return map.time(b + d) - map.time(b) end
  function map.frame(x, fps) return floor(map.time(x) * fps + 0.5) end
  -- 1 on each beat, decaying (like beat_clock's).
  function map.pulse(t, sharpness) return pulse(map.beat(t), sharpness) end
  return map
end

return M
