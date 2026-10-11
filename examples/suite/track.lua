-- The soundtrack, synthesized when the script loads with the examples'
-- shared instruments (../common/synth.lua): 120 BPM in D minor (Dm Bb F C, a
-- chord a bar), 18 bars. Its hits sit on the beats timeline.lua gives the
-- picture. build() returns { left, right } samples; video.lua registers them
-- with audio_add (run once per render).

local beat = require("beat")
local T = require("timeline")
local synth = dofile("../common/synth.lua")

local M = {}

local s -- the synth buffer build() fills

local RATE = synth.RATE
local BEAT = beat.BEAT
local sin, exp, floor, abs, min, random = math.sin, math.exp, math.floor, math.abs, math.min, math.random
local TAU = 2 * math.pi

-- A chord per bar (MIDI notes) and its bass root.
local CHORDS = { { 57, 62, 65, 69 }, { 58, 62, 65, 70 }, { 57, 60, 65, 69 }, { 55, 60, 64, 67 } }
local ROOTS = { 38, 34, 41, 36 }

-- What plays in each bar: k kick, c clap, h hats, o open hats on the
-- off-beats, b bass, s stabs, a arp, p pad.
local BARS = {
  [0] = "pa", [1] = "hpa", [2] = "khbpa", [3] = "khbpa",         -- ignition
  [4] = "kchobs", [5] = "kchobsa", [6] = "kchobs", [7] = "kchobsa", -- the drop
  [8] = "kchobsa", [9] = "kchobsa", [10] = "kchobsa", [11] = "kchobs", -- kaleidoscope
  [12] = "hpa", [13] = "hpab",                                   -- the break
  [14] = "kchobsa", [15] = "kchobsa", [16] = "kchobsa",           -- the lockup
}

local kick_on = {} -- beat index -> true where a kick plays

-- ---- the arrangement -----------------------------------------------------

local function at(b) return b * BEAT end
local function crash(b) s.hat(at(b), 1.6, 2.5, 0.9) end

local function play_bar(bar)
  local p = BARS[bar]
  local has = function(c) return p:find(c, 1, true) ~= nil end
  local i = bar % 4 + 1
  local notes, root, b0 = CHORDS[i], ROOTS[i], bar * 4
  for q = 0, 3 do
    if kick_on[b0 + q] then s.kick(at(b0 + q), 0.9) end
    if has("c") and q % 2 == 1 then s.clap(at(b0 + q), 0.45) end
  end
  for e = 0, 7 do -- eighths
    local t = at(b0 + e / 2)
    if has("o") and e % 2 == 1 then s.hat(t, 0.22, 14, 0.3)
    elseif has("h") then s.hat(t, 0.045, 90, has("k") and 0.35 or 0.3) end
    if has("s") and (e == 0 or e == 3 or e == 6) then
      s.chord(t, BEAT * 0.45, { notes[1] + 12, notes[2] + 12, notes[3] + 12, notes[4] + 12 }, 0.04, 2600, 0.003, 7)
    end
  end
  for x = 0, 15 do -- sixteenths
    local t = at(b0 + x / 4)
    if has("b") and x % 4 ~= 0 then s.bass(t, BEAT / 4 * 0.85, root + (x % 4 == 2 and 12 or 0), 0.22) end
    if has("a") then
      local pick = ({ 1, 2, 3, 4, 3, 2, 3, 4 })[x % 8 + 1]
      s.pluck(t, notes[pick] + 12, has("k") and 0.05 or 0.09, x % 2 == 0 and -0.4 or 0.4)
    end
  end
  if has("p") then s.chord(at(b0), BEAT * 4, notes, has("k") and 0.025 or 0.1, 900, 0.3, 0) end
end

function M.build()
  s = synth.new(T.TOTAL * BEAT, { seed = 120 })

  -- kicks first: the sidechain needs them; the bar before the drop drops
  -- the kick for its last two beats under the riser
  local bars = T.TOTAL // 4
  for bar = 0, bars - 1 do
    if BARS[bar] and BARS[bar]:find("k", 1, true) then
      for q = 0, 3 do
        if not (bar == T.DROP // 4 - 1 and q >= 2) then kick_on[bar * 4 + q] = true end
      end
    end
  end
  -- bass, chords and plucks duck under every kick
  local kicks = {}
  for b = 0, T.TOTAL do if kick_on[b] then kicks[#kicks + 1] = at(b) end end
  s.kicks(kicks, 0.8)
  for bar = 0, bars - 1 do
    if BARS[bar] then play_bar(bar) end
  end

  -- ignition: a blip when the rocket shows, a riser into the drop
  s.blip(at(T.ROCKET_IN), 660, 0.2)
  s.glitch(at(T.RISER + 3), 0.08, BEAT)
  s.riser(at(T.RISER), 4 * BEAT, 0.35)

  -- the drop, a blip per portal, a stutter before the break
  s.impact(at(T.DROP), 0.9)
  crash(T.DROP)
  for k, b in ipairs(T.PORTALS) do s.blip(at(b), 880 * 2 ^ ((k - 1) * 4 / 12), 0.2) end
  crash(T.KALEIDO)
  s.glitch(at(T.GLITCH), 0.1, BEAT)

  -- the break: a blip per box of the structure, a riser into the lockup
  crash(T.BREAK)
  for k, b in ipairs(T.BOXES) do s.blip(at(b), 660 * 2 ^ ((k - 1) * 3 / 12), 0.18) end
  s.riser(at(T.RISER2), 4 * BEAT, 0.35)

  -- the lockup: the impact, a blip per name, the last hit and a held Dm chord
  s.impact(at(T.LOCKUP), 1.0)
  crash(T.LOCKUP)
  for k, b in ipairs(T.NAMES) do s.blip(at(b), 880 * 2 ^ ((k - 1) * 3 / 12), 0.16) end
  crash(T.LINE)
  s.kick(at(T.END), 0.9)
  crash(T.END)
  s.chord(at(T.END), 2, { 38, 50, 57, 62, 65 }, 0.05, 2200, 0.003, 1.2)

  -- a gentle low-pass tames the naive saws' and noise's top end
  -- (inter-sample peaks), then the peak goes to -1 dBFS
  return s.finish(11000)
end

return M
