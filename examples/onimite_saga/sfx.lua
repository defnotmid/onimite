-- The film's sound effects: odawg's presets as sound{} clips (each built
-- once, named by its content), each placed by the scene it belongs to on the
-- "sfx" bus. The music (music/) is only the score.
--
--   local sfx = require("sfx")
--   scene { "Race", ..., audio = {
--     sfx.at("race", 2.5, sfx.done(), 0.14),     -- a DONE 2.5 beats into the race
--   } }
--
-- A scene says where in beats from its start: the same numbers its
-- animation uses. The song measures them (score.seconds), so a sound stays
-- on its beat whatever the tempo there. Every sound is its own track, on the
-- event that makes it (a key press, a pop): `audio at` names it, and it
-- moves with its scene.

local score = require("music.score")

local S = {}

-- A preset playing `hz` (as a MIDI note) for `seconds`, at the score's level.
local function play(preset, hz, seconds)
  return sound { preset, note = hz and ("%.2f"):format(69 + 12 * math.log(hz / 440, 2)) or nil, duration = seconds,
    gain_db = 0 }
end

function S.blip(hz) return play("blip", hz) end
function S.done() return sound { "done", note = "E6", gain_db = 0 } end
function S.tick(hz) return play("tick", hz) end
function S.beep(hz) return play("beep", hz) end
function S.tom(hz) return play("tom", hz, 0.55) end
function S.thump(note) return sound { "thump", note = ("%.1f"):format(note), duration = 0.75, gain_db = 0 } end
function S.impact() return play("impact", nil, 2.6) end
function S.crash() return play("crash", nil, 1.7) end
function S.crackle() return play("crackle") end
function S.hat(seconds, decay) return play({ "hat", decay = decay }, nil, seconds) end
-- A whoosh: noise swelling over `seconds` into a cut (with a rising tone).
function S.whoosh(seconds, tone) return play({ "whoosh", tone = tone }, nil, seconds) end
-- A stutter of eight grains over `seconds`.
function S.glitch(seconds) return play("glitch", nil, seconds) end

-- Seconds that `beats` last from `lb` beats into section `section`.
function S.seconds(section, lb, beats)
  return score.seconds(beats, score.time(section) + score.seconds(lb, section))
end

-- A track for clip `name`, `lb` beats into the scene on section `section`,
-- at `gain` (linear; 1 = as built), on the sfx bus; `cue`: the cue its sound
-- lands on (inspect checks).
function S.at(section, lb, name, gain, pan, cue)
  return { name, start = score.seconds(lb, section), gain_db = 20 * math.log(gain or 1, 10), pan = pan, bus = "sfx",
    cue = cue }
end

-- Keys for `text` typed over beats [from, to] of the scene on `section`,
-- the way the scene reveals it (`floor(#text * progress)` characters): a
-- track per visible character, as it appears, none for spaces. `key(k)`
-- gives character k's clip (default: a key click, its pitch and level
-- varied by `seed`).
function S.typing(section, from, to, text, gain, seed, key)
  local out, n = {}, #text
  for k = 1, n do
    if text:sub(k, k) ~= " " then
      local clip = key and key(k) or S.tick(1400 + math.floor(hash(k * 3 + seed) * 32) * 50)
      out[#out + 1] = S.at(section, from + k / n * (to - from), clip, gain * (0.7 + 0.6 * hash(k + seed)))
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
