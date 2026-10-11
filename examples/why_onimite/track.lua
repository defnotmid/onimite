-- The soundtrack, synthesized when the script loads: 140 BPM in A minor
-- (Am F C G, a chord a bar), 29 bars arranged like the scenes. Its hits
-- (impacts, glitch stutters, blips, risers) sit on the beats timeline.lua
-- gives the picture. The instruments are the examples' shared ones
-- (../common/synth.lua); build() returns { left, right } samples and
-- video.lua registers it with audio_add (run once per render).

local beat = require("beat")
local T = require("timeline")
local synth = dofile("../common/synth.lua")

local M = {}

local BEAT = beat.BEAT

-- A chord per bar (MIDI notes) and its bass root.
local CHORDS = { { 57, 60, 64, 69 }, { 53, 57, 60, 65 }, { 55, 60, 64, 67 }, { 55, 59, 62, 67 } }
local ROOTS = { 33, 29, 36, 31 }

-- What plays in each bar: k kick, c clap, h hats, o open hats on the
-- off-beats, b bass, s stabs, a arp, p pad.
local BARS = {
  [0] = "hp", "khbp", "khbp", "khbp",          -- title: intro, the slam on bar 1
  "kchobs", "kchobs", "kchobs", "kchobs",      -- race: the drop
  "kchob", "kchob", "kchob", "kchob",          -- bill: groove
  "kchoba", "kchoba", "kchoba", "kchoba",      -- shipping: groove and arp
  "kchob", "kchob", "kchob", "kchob",          -- agents: groove
  "hpa", "hpa", "hpa", "hpa",                  -- tricks: breakdown
  "kchobsa", "kchobsa", "kchobsa", "kchobsa",  -- outro: the last drop
}

local s -- the synth buffer build() fills
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
  if has("p") then
    -- the breakdown's pad opens bar by bar
    local cutoff = bar >= 16 and 500 + (bar - 16) * 600 or 700
    s.chord(at(b0), BEAT * 4, notes, has("k") and 0.025 or 0.12, cutoff, 0.3, 0)
  end
end

function M.build()
  s = synth.new(T.TOTAL * BEAT, { seed = 140 })

  -- kicks first: bass, chords and plucks duck under them; the title's bar 3
  -- drops the kick for its last two beats under the riser
  local kicks = {}
  for bar = 0, #BARS do
    if BARS[bar]:find("k", 1, true) then
      for q = 0, 3 do
        if not (bar == 3 and q >= 2) then
          kick_on[bar * 4 + q] = true
          kicks[#kicks + 1] = at(bar * 4 + q)
        end
      end
    end
  end
  s.kicks(kicks, 0.8)
  for bar = 0, #BARS do play_bar(bar) end

  -- the tail: one long Am chord over a last kick and crash
  s.kick(at(T.OUTRO + 16), 0.9)
  crash(T.OUTRO + 16)
  s.chord(at(T.OUTRO + 16), 3, { 45, 57, 60, 64, 69 }, 0.05, 2200, 0.003, 1.4)

  -- hits on the picture's beats
  for _, b in ipairs(T.TITLE_GLITCHES) do s.glitch(at(T.TITLE + b), 0.12, BEAT) end
  s.riser(at(T.TITLE + 2), 2 * BEAT, 0.3)
  s.impact(at(T.TITLE + T.TITLE_SLAM), 1.0)
  s.riser(at(T.RACE - 4), 4 * BEAT, 0.35)
  crash(T.RACE)
  for _, b in ipairs(T.RACE_DONE) do s.done(at(T.RACE + b), 0.16, BEAT / 4) end
  crash(T.RACE + T.RACE_GO + T.RACE_BEATS)
  crash(T.BILL)
  for k, b in ipairs(T.CPU_TICKS) do s.blip(at(T.BILL + b), 660 * 2 ^ ((k - 1) * 2 / 12), 0.2) end
  for k, b in ipairs(T.MEMORY_TICKS) do s.blip(at(T.BILL + b), 660 * 2 ^ ((k - 1) * 2 / 12), 0.2) end
  s.done(at(T.BILL + T.CPU_RATIO), 0.16, BEAT / 4)
  s.done(at(T.BILL + T.MEMORY_RATIO), 0.16, BEAT / 4)
  crash(T.SHIP)
  -- Shipping: a sound per landing in the bins (scenes/ship.lua simulates them).
  for _, h in ipairs(require("scenes.ship").hits) do
    local t, g = at(T.SHIP) + h.t, clamp01(h.speed / 2500)
    if h.kind == "grain" then s.tick(t, 0.05 + 0.08 * g, 2200 + 1200 * hash(t))
    elseif h.kind == "build" then s.impact(t, 0.6)
    elseif h.kind == "onimite" then s.blip(t, 1320, 0.14)
    else s.thump(t, 36, 0.5) end
  end
  crash(T.SHIP + T.SHIP_TOTAL)
  s.done(at(T.SHIP + T.RELOAD), 0.16, BEAT / 4)
  crash(T.AGENTS)
  s.blip(at(T.AGENTS + T.AGENT_FOUND), 330, 0.16)           -- the finding
  s.blip(at(T.AGENTS + T.AGENT_FIX + 1), 880, 0.14)         -- the new number
  s.done(at(T.AGENTS + T.AGENT_CLEAN), 0.16, BEAT / 4)      -- clean
  for _, b in ipairs(T.TRICK_CUTS) do s.glitch(at(T.TRICKS + b), 0.1, BEAT) end
  s.riser(at(T.OUTRO - 4), 4 * BEAT, 0.35)
  s.impact(at(T.OUTRO), 1.0)
  for _, b in ipairs(T.OUTRO_LINES) do crash(T.OUTRO + b) end
  crash(T.OUTRO + T.WORDMARK)

  -- a gentle low-pass tames the naive saws' and noise's top end
  -- (inter-sample peaks), then the peak goes to -1 dBFS
  return s.finish(11000)
end

return M
