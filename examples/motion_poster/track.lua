-- The soundtrack, synthesized when the script loads: ambient techno at
-- 120 BPM in A minor (Am9 Fmaj7 C G, a chord a bar), 10 bars, with the
-- examples' shared instruments (../common/synth.lua) plus a sine sub of its
-- own and echoing plucks. The kick plays where timeline.lua says the picture
-- pumps; the riser and the impact sit on the break and the finale. build()
-- returns { left, right } samples; video.lua registers them with audio_add
-- (run once per render).

local T = require("timeline")
local synth = dofile("../common/synth.lua")

local M = {}

local s -- the synth buffer build() fills
local midi, lp, noise = synth.midi, synth.lp, synth.noise

local RATE = synth.RATE
local BEAT = T.BEAT
local sin, exp, floor, abs, min, random = math.sin, math.exp, math.floor, math.abs, math.min, math.random
local TAU = 2 * math.pi

-- A chord per bar (MIDI notes) and its bass root: Am9 Fmaj7 C G.
local CHORDS = { { 57, 60, 64, 67, 71 }, { 53, 57, 60, 64, 69 }, { 48, 55, 60, 64, 67 }, { 55, 59, 62, 67, 71 } }
local ROOTS = { 33, 29, 36, 31 }

-- What plays in each bar: k kick, c clap, o open hats on the off-beats,
-- h closed hats, u sub, a arp, p pad.
local BARS = {
  [0] = "pa", "pah",                  -- intro: pad and echoing plucks
  "kouap", "kouap", "kouaph", "kouaph", -- groove
  "pa", "pa",                         -- break (the riser on bar 7)
  "kcouaph", "kcouaph",               -- finale
}

local kick_on = {} -- beat index -> true where a kick plays





-- A sine sub with a soft attack, ducked under the kick.
local function sub(t0, dur, note, gain)
  local n, x = s.note(dur)
  local f = midi(note) / RATE
  local ph = 0
  for k = 1, n do
    local t = (k - 1) / RATE
    ph = ph + f
    local v = sin(TAU * ph)
    x[k] = (v + 0.15 * v * v * v) * min(1, t * 60, (n - k) / 960) * gain * s.duck(t0 + t)
  end
  s.put(t0, x, n, 0)
end

-- ---- the arrangement -----------------------------------------------------

local function at(b) return b * BEAT end
local function crash(b) s.hat(at(b), 2.4, 1.8, 0.6) end

local function play_bar(bar)
  local p = BARS[bar]
  local has = function(c) return p:find(c, 1, true) ~= nil end
  local i = bar % 4 + 1
  local notes, root, b0 = CHORDS[i], ROOTS[i], bar * 4
  for q = 0, 3 do
    if kick_on[b0 + q] then s.kick(at(b0 + q), 0.75) end
    if has("c") and q % 2 == 1 then s.clap(at(b0 + q), 0.25) end
    if has("u") then sub(at(b0 + q + 0.5), BEAT * 0.45, root + 12, 0.32) end
  end
  for x = 0, 15 do -- sixteenths
    local t = at(b0 + x / 4)
    if has("o") and x % 4 == 2 then s.hat(t, 0.2, 16, 0.22) end
    if has("h") and x % 2 == 1 then s.hat(t, 0.03, 120, 0.12) end
    -- the arp: one note every dotted eighth, each with three echoes a
    -- dotted eighth apart, bouncing between the sides
    if has("a") and x % 3 == 0 then
      local note = notes[(x / 3) % #notes + 1] + 12
      for e = 0, 3 do
        local te = t + e * BEAT * 0.75
        if te < at(T.TOTAL) then s.pluck(te, note, (has("k") and 0.06 or 0.09) * 0.45 ^ e, (e % 2 == 0 and -0.35 or 0.35)) end
      end
    end
  end
  if has("p") then
    -- the pad opens over the piece
    s.chord(at(b0), BEAT * 4 + 0.05, notes, has("k") and 0.035 or 0.11, 500 + bar * 120, 0.4, 0)
  end
end

function M.build()
  s = synth.new(T.TOTAL * BEAT, { seed = T.BPM })

  for b = 0, T.TOTAL - 1 do kick_on[b] = T.kicking(b) or nil end
  -- bass, chords and plucks duck under every kick
  local kicks = {}
  for b = 0, T.TOTAL do if kick_on[b] then kicks[#kicks + 1] = at(b) end end
  s.kicks(kicks, 0.8)
  for bar = 0, #BARS do play_bar(bar) end

  crash(T.KICK[1][1])
  s.riser(at(T.RISER), at(T.FINALE - T.RISER), 0.3)
  s.impact(at(T.FINALE), 0.7)
  crash(T.FINALE)
  -- the last chord rings past the end (the video fades it out)
  s.chord(at(T.TOTAL - 4), 4 * BEAT, { 45, 57, 60, 64, 67, 71 }, 0.03, 1800, 0.01, 0.5)

  -- a gentle low-pass tames the naive saws' and noise's top end
  -- (inter-sample peaks), then the peak goes to -1 dBFS
  return s.finish(11000)
end

return M
