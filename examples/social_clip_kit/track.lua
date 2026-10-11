-- The soundtrack, synthesized when the script loads: 120 BPM pop in C
-- (C G Am F, a chord a bar), 8 bars with the examples' shared instruments
-- (../common/synth.lua) and a detuned bass of its own. Its hits sit on
-- timeline.lua's cues: a clap under each headline line, a riser into the
-- drop, a blip per format frame, a crash on every feature cut, the impact
-- under the wordmark. build() returns { left, right } samples; video.lua
-- registers them with audio_add (run once per render). The same samples
-- serve all three formats.

local T = require("timeline")
local synth = dofile("../common/synth.lua")

local M = {}

local s -- the synth buffer build() fills
local midi, lp, noise = synth.midi, synth.lp, synth.noise

local RATE = synth.RATE
local BEAT = T.BEAT
local sin, exp, floor, abs, min, random = math.sin, math.exp, math.floor, math.abs, math.min, math.random
local TAU = 2 * math.pi

-- A chord per bar (MIDI notes) and its bass root: C G Am F.
local CHORDS = { { 60, 64, 67, 72 }, { 55, 59, 62, 67 }, { 57, 60, 64, 69 }, { 53, 57, 60, 65 } }
local ROOTS = { 36, 31, 33, 29 }

-- What plays in each bar: k kick, c clap, h hats, o open hats on the
-- off-beats, b bass, s stabs, a arp, p pad.
local BARS = {
  [0] = "pa", "pah",              -- hook (the riser on bar 1)
  "kchob", "kchob",               -- formats
  "kchoba", "kchoba",             -- features
  "kchobsa", "kp",                -- outro, then the tail chord
}

local kick_on = {} -- beat index -> true where a kick plays

-- A detuned saw bass, low-passed, ducked.
local function bass(t0, dur, note, gain)
  local n, x = s.note(dur)
  local f1, f2 = midi(note) / RATE, midi(note) * 1.004 / RATE
  local p1, p2, y, k1 = 0, 0.5, 0, lp(420)
  for k = 1, n do
    local t = (k - 1) / RATE
    p1 = p1 + f1
    if p1 >= 1 then p1 = p1 - 1 end
    p2 = p2 + f2
    if p2 >= 1 then p2 = p2 - 1 end
    y = y + k1 * (p1 + p2 - 1 - y)
    x[k] = y * min(1, t * 200, (n - k) / 480) * s.duck(t0 + t) * gain
  end
  s.put(t0, x, n, 0)
end

-- ---- the arrangement -----------------------------------------------------

local function at(b) return b * BEAT end
local function crash(b, gain) s.hat(at(b), 1.4, 2.8, gain or 0.6) end

local function play_bar(bar)
  local p = BARS[bar]
  local has = function(c) return p:find(c, 1, true) ~= nil end
  local i = bar % 4 + 1
  local notes, root, b0 = CHORDS[i], ROOTS[i], bar * 4
  for q = 0, 3 do
    if kick_on[b0 + q] then s.kick(at(b0 + q), 0.8) end
    if has("c") and q % 2 == 1 then s.clap(at(b0 + q), 0.3) end
  end
  for e = 0, 7 do -- eighths
    local t = at(b0 + e / 2)
    if has("o") and e % 2 == 1 then s.hat(t, 0.22, 14, 0.25)
    elseif has("h") then s.hat(t, 0.045, 90, 0.3) end
    if has("s") and (e == 0 or e == 3 or e == 6) then
      s.chord(t, BEAT * 0.45, { notes[1] + 12, notes[2] + 12, notes[3] + 12, notes[4] + 12 }, 0.03, 2600, 0.003, 7)
    end
  end
  for x = 0, 15 do -- sixteenths
    local t = at(b0 + x / 4)
    if has("b") and x % 2 == 1 then bass(t, BEAT / 4 * 0.9, root + (x % 4 == 3 and 12 or 0), 0.2) end
    if has("a") and x % 2 == 0 then
      local pick = ({ 1, 2, 3, 4, 3, 2, 3, 4 })[x / 2 % 8 + 1]
      s.pluck(t, notes[pick] + 12, has("k") and 0.05 or 0.08, x % 4 == 0 and -0.4 or 0.4)
    end
  end
  if has("p") then s.chord(at(b0), BEAT * 4, notes, has("k") and 0.025 or 0.09, 900, 0.3, 0) end
end

function M.build()
  s = synth.new(T.TOTAL * BEAT, { seed = T.BPM })

  for b = 0, T.TOTAL - 1 do kick_on[b] = T.kicking(b) or nil end
  -- bass, chords and plucks duck under every kick
  local kicks = {}
  for b = 0, T.TOTAL do if kick_on[b] then kicks[#kicks + 1] = at(b) end end
  s.kicks(kicks, 0.8)
  for bar = 0, #BARS do play_bar(bar) end

  -- hook: a clap and a low thump under each headline line, a riser to the drop
  for _, b in ipairs { T.LINE1, T.LINE2 } do
    s.clap(at(b), 0.45)
    s.kick(at(b), 0.5)
  end
  s.riser(at(T.RISER), at(T.SECTIONS[2][1] - T.RISER), 0.25)
  crash(T.SECTIONS[2][1])
  -- formats: a blip per frame, rising; a double blip when this one lights up
  for k = 0, 2 do s.blip(at(T.FRAMES_GO + k), midi(76 + k * 3), 0.14) end
  s.blip(at(T.HERE), midi(84), 0.16)
  s.blip(at(T.HERE + 0.25), midi(88), 0.16)
  -- features: a crash on every cut
  for k = 0, 3 do crash(T.FEATURES_GO + k * T.FEATURE_LEN, k == 0 and 0.6 or 0.35) end
  -- outro: the impact under the wordmark, a blip for the command
  s.impact(at(T.MARK), 0.6)
  crash(T.MARK)
  s.blip(at(T.PILL), midi(84), 0.14)
  -- the tail: one long C chord
  s.chord(at(T.TOTAL - 2), 2 * BEAT + 0.6, { 48, 60, 64, 67, 72 }, 0.05, 2200, 0.003, 1.2)

  -- a gentle low-pass tames the naive saws' and noise's top end
  -- (inter-sample peaks), then the peak goes to -1 dBFS
  return s.finish(11000)
end

return M
