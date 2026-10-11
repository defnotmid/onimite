-- hero.rs: cached hero poses share the ring trajectories; measured vector
-- ink supplies the gestures.
local objects = require("objects")
local capture = require("restoration_capture")
local label = require("ui").label

local M = {}

local function motion_exposures()
  local arrive = { { 0.0, 0.166667, 0, 1, cubic_bezier(0.12, 0.9, 0.22, 1) } }
  -- Keep the measured silhouettes, but interpolate between them instead of
  -- holding each exposure and jumping to the next. Start after the shared
  -- ring arrival (local frame 5); the return then restores the normal aspect.
  local normal = capture.CAMERA_POSE[6]
  local tall = capture.CAMERA_POSE[13]
  local flat = capture.CAMERA_POSE[18]
  local css = cubic_bezier(0.42, 0, 0.58, 1)
  local deformation = {}
  for axis = 1, 3 do
    deformation[axis] = {
      { 5 / 24, 10 / 24, normal[axis], tall[axis], css },
      { 10 / 24, 15 / 24, tall[axis], flat[axis], css },
    }
  end
  local list = {}
  for index = 0, 15 do
    local t = index / 24
    local entry = animate(t, arrive)
    local sx, sy, roll = animate(t, deformation[1]), animate(t, deformation[2]), animate(t, deformation[3])
    local wide = math.min(math.max((sx - 1) / 1.2, 0), 1)
    local object = objects.Object.new(5, {
      -296 + wide * 25 - (1 - entry) * 60,
      -8 + (1 - entry) * 74,
      1250,
    }, 470 * (0.83 + entry * 0.17), { 0.10, 0.035, roll }, 0):with_stretch { sx, sy }
    list[#list + 1] = { object = object, title_opacity = 1 }
  end
  return list
end

-- The three feature cards' exposures; moves the selected ring tracks of
-- `frames` (objects.choreography's) through their excursions.
function M.new(frames)
  local arrival = { { 0.0, 0.208333, 0, 1, cubic_bezier(0.12, 0.9, 0.22, 1) } }
  local push = {
    { 0.208333, 0.583333, 0, 0.25, linear },
    { 0.583333, 0.875, 0.25, 1, ease_in },
  }
  local yaw = {
    { 0.0, 0.166667, -0.85, -0.28, cubic_bezier(0.16, 1, 0.3, 1) },
    { 0.166667, 0.833333, -0.28, 0.40, ease_in_out },
  }
  local spin = { { 0.0, 0.875, -0.38, 2.95, linear } }
  local function build(feeling)
    local list = {}
    for index = 0, (feeling and 21 or 20) - 1 do
      local t = index / 24
      local entry = animate(t, arrival)
      local p = animate(t, push)
      local y = animate(t, yaw)
      local object = objects.Object.new(feeling and 4 or 0, {
        442 - 720 - (1 - entry) * 74,
        -9 + (1 - entry) * 68,
        1250 - p * 70,
      }, (feeling and 555 or 530) * (0.82 + entry * 0.18), {
        feeling and y * 0.6 or y,
        0.16 - p * 0.20,
        feeling and animate(t, spin) or (-0.15 + entry * 0.05 + p * 0.13),
      }, 0)
      list[#list + 1] = { object = object, title_opacity = 1 }
    end
    return list
  end
  local heroes = { code = build(false), feeling = build(true), motion = motion_exposures() }
  for i, card in ipairs { { heroes.code, false }, { heroes.motion, false }, { heroes.feeling, true } } do
    local exposures, keep_spinning = card[1], card[2]
    local schedule = objects.EXCURSIONS[i]
    local poses = {}
    for k, e in ipairs(exposures) do poses[k] = e.object:clone() end
    objects.ring_excursion(frames, poses, schedule, keep_spinning)
    local arrive = (schedule.arrival - schedule.start) / 24
    local exit = (schedule.return_start - schedule.start) / 24
    local caption = {
      { arrive - 2 / 24, arrive, 0, 1, ease_out },
      { exit, exit + 3 / 24, 1, 0, ease_in_out },
    }
    for k, e in ipairs(exposures) do
      e.object = poses[k]
      e.title_opacity = animate((k - 1) / 24, caption)
    end
  end
  return heroes
end

local function type_block(f, card)
  local copy, cursor
  if card == "code" then copy, cursor = "code.", 1120
  elseif card == "motion" then copy, cursor = "motion.", 1256
  else copy, cursor = "feeling.", 1246 end
  group({ transform = animate(f, {
    { 0.0, 0.166667, translate(48, 18), translate(0, 0), cubic_bezier(0.12, 1, 0.25, 1) },
  }) }, function()
    label(copy, 800, 559, 112, "#f4efe4", false)
    rect { x = cursor, y = 477, h = 86, fill = "#ed3d27",
      w = animate(f, { { 0.0, 0.125, 76, 6, ease_out } }) }
  end)
  group({
    transform = animate(f, { { 0.041667, 0.25, translate(0, 24), translate(0, 0), cubic_bezier(0.16, 1, 0.3, 1) } }),
    opacity = animate(f, { { 0.041667, 0.166667, 0, 1, ease_out } }),
  }, function()
    if card == "feeling" then
      text { "every frame matters.", x = 807, y = 617, font = "Instrument Serif", italic = true, size = 35, fill = "#d4cabb" }
      path { d = "M811 653 C905 641 970 662 1045 647", fill = "none", stroke = "#ed3d27", stroke_width = 2 }
    elseif card == "code" then
      text { "Rust + SVG", x = 807, y = 611, font = "JetBrains Mono", size = 23, fill = "#bce788" }
    else
      text { "timeline!", x = 807, y = 611, font = "JetBrains Mono", size = 23, fill = "#c0a1ef" }
    end
  end)
end

-- One feature card: "code", "motion" or "feeling".
function M.draw(heroes, f, studio, card)
  local exposures = heroes[card]
  local pose = exposures[math.min(f.index, #exposures - 1) + 1]
  studio.background(f, 1, 0)
  studio.ink.draw(f)
  -- The other eleven tracks keep rotating off-screen. This is the selected
  -- track's same global pose, including both flights.
  pose.object:draw(f)
  group({ opacity = pose.title_opacity }, function() type_block(f, card) end)
end

return M
