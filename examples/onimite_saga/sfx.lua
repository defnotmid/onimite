-- The film's sound effects: short clips built once (when the sound is
-- needed), each placed by the scene it belongs to, on the "sfx" bus
-- (video.lua sets its level). The music (music/) is only the score.
--
--   local sfx = require("sfx")
--   scene { "Race", ..., audio = {
--     sfx.at(C.RACE, 2.5, sfx.done(), 0.14),     -- a DONE 2.5 beats into the scene
--   } }
--
-- Every sound is its own track, on the event that makes it (a key press, a
-- pop): `audio at` names it, and it moves with its scene. Clips are named by
-- what they are (`blip_660`, `tick_2200`), so each is built once however
-- often it plays.

local C = require("cues")
local synth = dofile("../common/synth.lua")

local S = {}

local made = {}

-- Registers clip `name` (seconds long, `play(s)` writes it from 0) once and
-- returns the name.
function S.clip(name, seconds, play)
  if not made[name] then
    made[name] = true
    audio_add(name, function()
      local s = synth.new(seconds, { seed = #name })
      play(s)
      return s.finish(14000, false)
    end)
  end
  return name
end

local function ms(x) return math.floor(x * 1000 + 0.5) end

function S.blip(hz) return S.clip(("blip_%d"):format(math.floor(hz + 0.5)), 0.12, function(s) s.blip(0, hz, 1) end) end
function S.done() return S.clip("done", 0.25, function(s) s.done(0, 1, 0.12) end) end
function S.tick(hz) return S.clip(("tick_%d"):format(math.floor(hz)), 0.04, function(s) s.tick(0, 1, hz) end) end
function S.tom(hz) return S.clip(("tom_%d"):format(math.floor(hz)), 0.55, function(s) s.tom(0, hz, 1) end) end
function S.thump(note) return S.clip(("thump_%.1f"):format(note), 0.75, function(s) s.thump(0, note, 1) end) end
function S.impact() return S.clip("impact", 2.6, function(s) s.impact(0, 1) end) end
function S.crash() return S.clip("crash", 1.7, function(s) s.hat(0, 1.6, 2.5, 1) end) end
function S.hat(dur, decay) return S.clip(("hat_%d_%d"):format(ms(dur), decay), dur + 0.05, function(s) s.hat(0, dur, decay, 1) end) end
-- A whoosh: noise swelling over `seconds` into a cut.
function S.whoosh(seconds, tone)
  return S.clip(("whoosh_%d_%d"):format(ms(seconds), ms(tone or 0)), seconds + 0.05, function(s) s.riser(0, seconds, 1, tone or 0) end)
end
-- A stutter of eight grains over `seconds`.
function S.glitch(seconds) return S.clip(("glitch_%d"):format(ms(seconds)), seconds + 0.05, function(s) s.glitch(0, 1, seconds) end) end

function S.beep(hz) return S.clip(("beep_%d"):format(math.floor(hz)), 0.04, function(s) s.beep(0, hz, 1) end) end
function S.crackle() return S.clip("crackle", 0.02, function(s) s.crackle(0, 1, 0) end) end

-- A track for clip `name`, `lb` beats into the scene that starts on beat
-- `scene_at`, at `gain` (linear; 1 = as built), on the sfx bus.
function S.at(scene_at, lb, name, gain, pan)
  return { name, start = C.time(scene_at + lb) - C.time(scene_at), gain_db = 20 * math.log(gain or 1, 10), pan = pan,
    bus = "sfx" }
end

-- Keys for `text` typed over beats [from, to] of the scene that starts on
-- beat `scene_at`, the way the scene reveals it (`floor(#text * progress)`
-- characters): a track per visible character, as it appears, none for
-- spaces. `key(k)` gives character k's clip (default: a key click, its pitch
-- and level varied by `seed`).
function S.typing(scene_at, from, to, text, gain, seed, key)
  local out, n = {}, #text
  for k = 1, n do
    if text:sub(k, k) ~= " " then
      local clip = key and key(k) or S.tick(1400 + math.floor(hash(k * 3 + seed) * 32) * 50)
      out[#out + 1] = S.at(scene_at, from + k / n * (to - from), clip, gain * (0.7 + 0.6 * hash(k + seed)))
    end
  end
  return out
end

-- Adds tracks to a scene's list: single tracks, or lists of them (typing).
function S.add(list, ...)
  for _, t in ipairs { ... } do
    if type(t[1]) == "string" then
      list[#list + 1] = t
    else
      for _, x in ipairs(t) do list[#list + 1] = x end
    end
  end
  return list
end

return S
