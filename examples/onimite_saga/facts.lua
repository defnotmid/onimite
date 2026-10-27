-- Every number on screen comes from bench/facts.json through
-- bench/facts.lua (its fields are this module's too): `tools/bench.sh
-- facts` measures the race on each release (BENCHMARK.md has the tables
-- and the method) and `tools/bench.sh setup` the installs. This file only
-- picks the race's rows for the film.
-- Remotion's install is measured, its speed is not; Motion Canvas, Revideo
-- and Manim are not measured at all: the film says what they need (a
-- browser, a runtime), not how fast they are.

local M = dofile("../../bench/facts.lua")

-- The six biggest wins: name, fframes' wall seconds, onimite's, speed-up.
M.RACE = {}
for i = 1, math.min(6, #M.race - #M.losses) do
  local r = M.race[i]
  M.RACE[i] = { r.name, r.fframes, r.onimite, r.speedup }
end
-- Short names for the reload chart's columns, by race row.
local SHORT = { made_of_motion = "made", fframes_intro = "intro", audio_announce = "audio", shader_mode = "shader",
  conference = "conf", motion_graphics = "motion", mg_install = "install", low_poly_art = "lowpoly",
  pixel_memory = "pixel", lottie_launch = "lottie", svg_in_3d = "svg3d", neon_triangle = "neon", signal_lab = "signal",
  teej_podcast = "teej" }
function M.short(name) return SHORT[name] or name end

-- If fframes wins none, its closest race (a race row).
M.CLOSEST = M.race[#M.race]

return M
