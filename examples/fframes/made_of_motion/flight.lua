-- flight.rs: reference-derived letter flights for the wordmark ending.
local capture = require("ink_capture")

local M = {}

-- Seven letter poses ({ position = {x, y}, angle, scale }) for each of the
-- Fframes scene's 76 frames (1-based).
function M.new()
  local LETTERS = capture.LETTERS
  -- Three frames to assemble, four to pull the camera back. This is a
  -- cut-speed move, not a UI-like 700 ms ease-in/out.
  local gather = { { 2.541667, 2.666667, 0, 1, ease_in } }
  local target = { -229, -181, -124, -47.5, 66, 167.5, 226 }
  local function path(index, i)
    -- Replay the measured high-energy flight in independent phases. The
    -- three extra brand letters use reflected versions of those
    -- trajectories, rather than orbiting seven fixed anchor points.
    local phase = (index * (0.80 + i * 0.025) + i * 3.1) % 52
    if phase > 26 then phase = 52 - phase end
    local sample = 3 + phase
    local a = math.floor(sample)
    local b = math.min(a + 1, #LETTERS - 1)
    local f = sample - a
    local aa = LETTERS[a + 1][i % 4 + 1]
    local bb = LETTERS[b + 1][i % 4 + 1]
    local x = aa[1] + (bb[1] - aa[1]) * f
    local y = aa[2] + (bb[2] - aa[2]) * f
    if i >= 4 then
      x = 1440 - x
      y = 1080 - y
    end
    -- Softly fit the few off-canvas source excursions into this edit.
    return 60 + math.min(math.max(x, 0), 1440) * (1320 / 1440),
      85 + math.min(math.max(y, 0), 1080) * (910 / 1080)
  end
  local letters = {}
  local angles = { 0, 0, 0, 0, 0, 0, 0 }
  for index = 0, 75 do
    local g = animate(index / 24, gather)
    local poses = {}
    for n = 1, 7 do
      local i = n - 1
      local x, y = path(index, i)
      local px, py = path(index - 0.5, i)
      local speed = math.sqrt((x - px) ^ 2 + (y - py) ^ 2) * 2
      local direction = i % 2 == 0 and 1 or -1
      angles[n] = angles[n] + direction * (speed * 0.34 + 3.1)
      local margin = 52 + 270 * 4 * g * (1 - g)
      poses[n] = {
        position = {
          math.min(math.max(x * (1 - g) + (720 + target[n] * 2.8) * g, margin), 1440 - margin),
          y * (1 - g) + (540 + 39 * 2.8) * g,
        },
        angle = angles[n] * (1 - g),
        scale = (1.05 + math.min(speed / 170, 0.65)) * (1 - g) + (194 / 54 * 2.8) * g,
      }
    end
    letters[index + 1] = poses
  end
  return letters
end

return M
