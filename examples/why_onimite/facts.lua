-- Every number on screen comes from bench/facts.json through
-- bench/facts.lua (its fields are this module's too): `tools/bench.sh
-- facts` measures the race on each release (BENCHMARK.md has the tables
-- and the method) and `tools/bench.sh setup` the installs. This file only
-- picks the race's lanes for the film.

local M = dofile("../../bench/facts.lua")

-- "4.5×", "0.79×": a speed-up as the film prints it.
local function times(x) return string.format(x < 1 and "%.2f×" or "%.1f×", x) end

-- The race's eight lanes: the biggest wins, then fframes' wins (two at
-- most, its biggest first). Each: name, fframes' wall seconds, onimite's,
-- the speed-up.
local LANES = 8
local losses = math.min(#M.losses, 2)
M.RACE = {}
for i = 1, math.min(LANES - losses, #M.race - #M.losses) do
  local r = M.race[i]
  M.RACE[#M.RACE + 1] = { r.name, r.fframes, r.onimite, times(r.speedup) }
end
for i = 1, losses do
  local r = M.losses[i]
  M.RACE[#M.RACE + 1] = { r.name, r.fframes, r.onimite, times(r.speedup) }
end

return M
