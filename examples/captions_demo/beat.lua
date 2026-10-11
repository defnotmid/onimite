-- A voice-less 120 BPM beat made when the script loads with the examples'
-- shared instruments (../common/synth.lua): kick, clap, hats and a
-- low-passed saw bass over Am F C G (a chord a bar). build(seconds) returns
-- { left, right } samples for audio_add.

local synth = dofile("../common/synth.lua")

local M = {}

M.BPM = 120
local BEAT = 60 / M.BPM
local ROOTS = { 33, 29, 36, 31 }

function M.build(seconds)
  local s = synth.new(seconds, { seed = 120 })
  local beats = math.floor(seconds / BEAT)
  local kicks = {}
  for b = 0, beats - 1 do kicks[#kicks + 1] = b * BEAT end
  s.kicks(kicks, 0.8) -- the bass dips under every kick
  for b = 0, beats - 1 do
    local t = b * BEAT
    s.kick(t, 0.9)
    if b % 2 == 1 then s.clap(t, 0.4) end
    s.hat(t + BEAT / 2, 0.22, 14, 0.3)
    s.hat(t, 0.045, 90, 0.3)
    local root = ROOTS[math.floor(b / 4) % 4 + 1]
    for x = 1, 3 do s.bass(t + x * BEAT / 4, BEAT / 4 * 0.85, root + (x == 2 and 12 or 0), 0.2) end
  end
  return s.finish()
end

return M
