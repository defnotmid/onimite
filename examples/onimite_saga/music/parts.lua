-- What the four acts' score shares: the progression and the hook, the
-- groove, pads, crashes, and how a section becomes a clip. (Sound effects
-- belong to the scenes: sfx.lua.) Each act
-- (music/act1.lua ...) is its own clip, played from where its act starts, so
-- `onimite audio analyze video.lua --track act2` hears one act, and the
-- instruments (../common/synth.lua) take video seconds throughout.

local C = require("cues")
local synth = dofile("../common/synth.lua")

local M = {}

local B = C.time
-- Seconds the `d` beats from beat `b` last.
local function bdur(b, d) return C.seconds(b, d) end
local floor = math.floor

-- The level every act's clip is scaled by: one level for all, so the acts
-- keep their balance (`audio analyze` for the result; master_gain_db and the
-- limiter in video.lua finish the mix).
M.LEVEL = 0.5
-- Notes ring past the end of their act: each clip runs this much longer.
local TAIL = 3

-- A chord per bar (MIDI notes), its bass root, and a hook per bar as
-- { beat in the bar, note, beats long }. Bars are in sync with the global
-- beat: every section starts on a multiple of four.
local CHORDS = { { 57, 60, 64, 69 }, { 53, 57, 60, 65 }, { 55, 60, 64, 67 }, { 55, 59, 62, 67 } }
local ROOTS = { 33, 29, 36, 31 }
local HOOKS = {
  { { 0, 76, 0.5 }, { 0.5, 79, 0.5 }, { 1, 81, 1 }, { 2, 79, 0.5 }, { 2.5, 76, 0.5 }, { 3, 74, 1 } },
  { { 0, 77, 0.5 }, { 0.5, 81, 0.5 }, { 1, 84, 1 }, { 2, 81, 0.5 }, { 2.5, 77, 0.5 }, { 3, 76, 1 } },
  { { 0, 79, 0.5 }, { 0.5, 84, 0.5 }, { 1, 88, 1 }, { 2, 84, 0.5 }, { 2.5, 79, 0.5 }, { 3, 76, 1 } },
  { { 0, 74, 0.5 }, { 0.5, 79, 0.5 }, { 1, 83, 1 }, { 2, 79, 0.5 }, { 2.5, 74, 0.5 }, { 3, 71, 1 } },
}
local ARP = { 1, 2, 3, 4, 3, 2, 3, 4 }

-- Beats [from, to) of the groove. Flags: k kick, c clap on 2 and 4, h hats on
-- eighths, H hats on sixteenths, o open hats on the off-beats, b bass,
-- s stabs, a arp, l lead, p pad, f a clap roll in the last beat of every
-- eight.
function M.groove(s, from, to, flags)
  local function has(c) return flags:find(c, 1, true) ~= nil end
  for b = from, to - 1 do
    local bar = floor(b / 4)
    local i = bar % 4 + 1
    local notes, root = CHORDS[i], ROOTS[i]
    local q = b % 4
    local t = B(b)
    if has("k") then s.kick(t, 0.9) end -- (ducking: M.kick_times)
    if has("c") and (q == 1 or q == 3) then s.clap(t, 0.45) end
    if has("f") and b % 8 == 7 then
      for r = 0, 3 do s.clap(B(b + r / 4), 0.18 + 0.1 * r) end
    end
    for x = 0, 3 do
      local ts = B(b + x / 4)
      local len = B(b + x / 4 + 0.25) - ts
      if has("H") then
        if x == 2 and has("o") then s.hat(ts, 0.22, 14, 0.3)
        else s.hat(ts, 0.045, 90, x % 2 == 0 and 0.3 or 0.16) end
      elseif has("h") and x % 2 == 0 then
        if x == 2 and has("o") then s.hat(ts, 0.22, 14, 0.3) else s.hat(ts, 0.045, 90, 0.33) end
      end
      if has("b") and x ~= 0 then
        s.bass(ts, len * 0.85, root + (x == 2 and 12 or 0), 0.22)
      end
      local e = q * 4 + x -- sixteenth in the bar
      if has("a") then
        s.pluck(ts, notes[ARP[e % 8 + 1]] + 12, has("k") and 0.05 or 0.09, e % 2 == 0 and -0.4 or 0.4)
      end
      if has("s") and x % 2 == 0 and (e == 0 or e == 6 or e == 12) then
        s.chord(ts, len * 1.8, { notes[1] + 12, notes[2] + 12, notes[3] + 12, notes[4] + 12 }, 0.04, 2600, 0.003, 7)
      end
    end
    if q == 0 then
      if has("p") then s.chord(t, bdur(b, 4), notes, 0.03, 600, 0.3, 0, 1, 2400) end
      if has("l") then
        for _, n in ipairs(HOOKS[i]) do
          s.lead(B(b + n[1]), bdur(b + n[1], n[3] * 0.92), n[2], 0.06)
        end
      end
    end
  end
end

-- A pad, ducked not at all, on beats [b0, b0 + beats): the cutoff opens
-- from c0 to c1.
function M.pad(s, b0, beats, notes, gain, c0, c1, attack)
  s.chord(B(b0), bdur(b0, beats), notes, gain, c0, attack, 0, 0, c1)
end

-- A crash on beat `b`.
function M.crash(s, b, gain) s.hat(B(b), 1.6, 2.5, gain or 0.9) end

-- The kicks of a list of grooves { from, to, flags }: what the bass, chords
-- and leads duck under.
function M.kick_times(grooves)
  local out = {}
  for _, g in ipairs(grooves) do
    if g[3]:find("k", 1, true) then
      for b = g[1], g[2] - 1 do out[#out + 1] = B(b) end
    end
  end
  table.sort(out)
  return out
end

-- The synth for beats [from, to) of the film (plus the tail).
function M.section(from, to)
  return synth.new(B(to) - B(from) + TAIL, { seed = 204 + from, origin = B(from) })
end

-- The whole mix goes through a low-pass whose cutoff follows these keys
-- (seconds, Hz): shut for the tape slowing and the hush, and for the tape
-- stop, open elsewhere.
local function cutoff_keys()
  return {
    { B(C.SLOW), 11000 }, { B(C.SLOW + 4), 450 }, { B(C.HUSH), 450 }, { B(C.HUSH + 3), 3500 },
    { B(C.RISE), 3500 }, { B(C.RISE + 3.5), 11000 },
    { B(C.STOP), 11000 }, { B(C.STOP + 3), 250 }, { B(C.FADE), 11000 },
  }
end

local function cutoff_at(keys, t)
  if t <= keys[1][1] then return keys[1][2] end
  for i = 2, #keys do
    local a, b = keys[i - 1], keys[i]
    if t <= b[1] then
      local u = (t - a[1]) / (b[1] - a[1])
      return a[2] * (b[2] / a[2]) ^ u
    end
  end
  return keys[#keys][2]
end

local KEYS -- computed once
-- The finished clip: the mix's low-pass automation, the shared level.
function M.finish(s)
  KEYS = KEYS or cutoff_keys()
  s.finish(function(t) return cutoff_at(KEYS, t) end, false)
  s.mix:gain(M.LEVEL)
  return s.mix
end

return M
