-- The music bed, synthesized when the script loads: 120 BPM in C major
-- (C Am F G, a chord a bar), 15 bars arranged like the sections, with the
-- examples' shared instruments (../common/synth.lua). Its blips and crashes
-- sit on the beats timeline.lua gives the picture: a blip for every bar of
-- the chart (pitched by the month's value), every donut segment and the
-- outro's count. build(months, segments) returns { left, right } samples;
-- video.lua registers them with audio_add (run once per render).

local T = require("timeline")
local synth = dofile("../common/synth.lua")

local M = {}

local s -- the synth buffer build() fills
local midi = synth.midi

local RATE = synth.RATE
local BEAT = T.BEAT
local sin, exp, floor, abs, min, random = math.sin, math.exp, math.floor, math.abs, math.min, math.random
local TAU = 2 * math.pi

-- A chord per bar (MIDI notes) and its bass root: C Am F G.
local CHORDS = { { 60, 64, 67, 72 }, { 57, 60, 64, 69 }, { 53, 57, 60, 65 }, { 55, 59, 62, 67 } }
local ROOTS = { 36, 33, 29, 31 }

-- What plays in each bar: k kick, c clap, h hats, o open hats on the
-- off-beats, b bass, s stabs, a arp, p pad.
local BARS = {
  [0] = "hpa", "khbp",                    -- title
  "kchob", "kchob", "kchob", "kchob",     -- bars
  "kchobs", "kchobs", "kchobs",           -- line
  "kchoba", "kchoba", "kchoba",           -- donut
  "kchobsa", "kchobs", "",                -- outro, then the tail chord
}

local kick_on = {} -- beat index -> true where a kick plays


-- ---- the arrangement -----------------------------------------------------

local function at(b) return b * BEAT end
local function crash(b) s.hat(at(b), 1.6, 2.5, 0.7) end

-- C major pentatonic, two octaves: a month's value picks its blip's pitch.
local PENTA = { 72, 74, 76, 79, 81, 84, 86, 88, 91, 93 }

local function play_bar(bar)
  local p = BARS[bar]
  local has = function(c) return p:find(c, 1, true) ~= nil end
  local i = bar % 4 + 1
  local notes, root, b0 = CHORDS[i], ROOTS[i], bar * 4
  for q = 0, 3 do
    if kick_on[b0 + q] then s.kick(at(b0 + q), 0.8) end
    if has("c") and q % 2 == 1 then s.clap(at(b0 + q), 0.35) end
  end
  for e = 0, 7 do -- eighths
    local t = at(b0 + e / 2)
    if has("o") and e % 2 == 1 then s.hat(t, 0.22, 14, 0.25)
    elseif has("h") then s.hat(t, 0.045, 90, 0.3) end
    if has("s") and (e == 0 or e == 3 or e == 6) then
      s.chord(t, BEAT * 0.45, { notes[1] + 12, notes[2] + 12, notes[3] + 12, notes[4] + 12 }, 0.035, 2600, 0.003, 7)
    end
  end
  for x = 0, 15 do -- sixteenths
    local t = at(b0 + x / 4)
    if has("b") and x % 2 == 1 then s.bass(t, BEAT / 4 * 0.9, root + (x % 4 == 3 and 12 or 0), 0.22) end
    if has("a") and x % 2 == 0 then
      local pick = ({ 1, 2, 3, 4, 3, 2, 3, 4 })[x / 2 % 8 + 1]
      s.pluck(t, notes[pick] + 12, has("k") and 0.05 or 0.08, x % 4 == 0 and -0.4 or 0.4)
    end
  end
  if has("p") then s.chord(at(b0), BEAT * 4, notes, has("k") and 0.02 or 0.1, 900, 0.3, 0) end
end

function M.build(months, segments)
  s = synth.new(T.TOTAL * BEAT, { seed = T.BPM })

  for b = T.KICK_FROM, T.KICK_TO - 1 do kick_on[b] = true end
  -- bass, chords and plucks duck under every kick
  local kicks = {}
  for b = 0, T.TOTAL do if kick_on[b] then kicks[#kicks + 1] = at(b) end end
  s.kicks(kicks, 0.8)
  for bar = 0, #BARS do play_bar(bar) end

  -- section downbeats
  for k = 2, #T.SECTIONS do crash(T.SECTIONS[k][1]) end
  -- title: a soft impact under the name
  s.impact(at(T.NAME), 0.5)
  -- bars: a blip per month, pitched by its value; the best month rings
  local hi = 0
  for _, v in ipairs(months) do hi = math.max(hi, v) end
  for m, v in ipairs(months) do
    local note = PENTA[1 + floor(v / hi * (#PENTA - 1) + 0.5)]
    s.blip(at(T.BARS_GO + (m - 1) * T.BARS_STEP), midi(note), 0.14)
  end
  s.done(at(T.PEAK), 0.16, BEAT / 4)
  -- line: a riser while it draws, a hit as it lands on the total
  s.riser(at(T.LINE_GO), at(T.LINE_END - T.LINE_GO), 0.22)
  s.done(at(T.LINE_END), 0.16, BEAT / 4)
  -- donut: a blip per segment, stepping up the scale
  for k = 1, segments do s.blip(at(T.DONUT_GO + (k - 1) * T.DONUT_STEP), midi(PENTA[2 + k]), 0.14) end
  -- outro: the count ticks on sixteenths, the total lands with a crash
  for x = 0, (T.COUNT_END - T.COUNT_GO) * 4 - 1 do
    s.blip(at(T.COUNT_GO + x / 4), 600 + x * 40, 0.06)
  end
  s.done(at(T.COUNT_END), 0.18, BEAT / 4)
  crash(T.COUNT_END)
  -- the tail: one long C chord and a last kick
  s.kick(at(T.TOTAL - 4), 0.8)
  s.chord(at(T.TOTAL - 4), 4.5, { 48, 60, 64, 67, 72 }, 0.05, 2200, 0.003, 0.9)

  -- a gentle low-pass tames the naive saws' and noise's top end
  -- (inter-sample peaks), then the peak goes to -1 dBFS
  return s.finish(11000)
end

return M
