-- The shader library wall (src/catalog.rs): separate textured cards in
-- camera space. Geometry is prepared once when the script loads; each card
-- is a catalog.sksl layer over its visible screen bounds, which projects and
-- samples the card itself.

local layout = require("catalog_layout")

local M = {}

local RECTS, PORTAL, PORTAL_TILE = layout.RECTS, layout.PORTAL, layout.PORTAL_TILE
local PIXELS_PER_UNIT = 768
local FOCAL = 1.6 * 1080
local sin, cos, floor, ceil, min, max = math.sin, math.cos, math.floor, math.ceil, math.min, math.max

local function add(a, b) return { a[1] + b[1], a[2] + b[2], a[3] + b[3] } end
local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function mul(a, s) return { a[1] * s, a[2] * s, a[3] * s } end
-- Rotates p in the plane of axes a and b (1-based).
local function turn(p, a, b, angle)
  local s, c = sin(angle), cos(angle)
  local q = { p[1], p[2], p[3] }
  q[a], q[b] = c * p[a] - s * p[b], s * p[a] + c * p[b]
  return q
end
local function smooth(start, stop, value)
  local t = max(0, min(1, (value - start) / (stop - start)))
  return t * t * (3 - 2 * t)
end
local function random(index, salt)
  return ((index * 73 + salt * 151 + index * index * 17) % 997) / 997
end

-- A card's pose: its center and the directions of its right and down edges.
local function pose_point(pose, x, y)
  return add(pose.center, add(mul(pose.right, x), mul(pose.down, y)))
end

local function world_pose(index, frame)
  local r = RECTS[index + 1]
  local x, y, w, h = r[1], r[2], r[3], r[4]
  -- Reference frames 280-295: different cards release at slightly different
  -- times, open gaps, and overlap at different depths.
  local amount = smooth(23 + random(index, 1) * 3, 38, frame)
  local drift = smooth(36, 49, frame)
  local function rr(salt) return random(index, salt) * 2 - 1 end
  local angles = { rr(2) * 0.24, rr(3) * 0.28, rr(4) * 0.060 }
  local offset = { rr(5) * 0.042, rr(6) * 0.035, rr(7) * 0.19 - 0.035 }
  offset[2] = offset[2] + drift * (0.018 + random(index, 8) * 0.035)
  if index == PORTAL_TILE then
    angles = { 0.10, -0.13, 0.045 }
    offset = { -0.01, 0.015, -0.13 }
  end
  local function rotate(p)
    p = turn(p, 2, 3, angles[1] * amount)
    p = turn(p, 1, 3, angles[2] * amount)
    return turn(p, 1, 2, angles[3] * amount)
  end
  return {
    center = add({ (x + w * 0.5) / PIXELS_PER_UNIT, (y + h * 0.5) / PIXELS_PER_UNIT, 0 }, mul(offset, amount)),
    right = rotate({ 1, 0, 0 }),
    down = rotate({ 0, 1, 0 }),
  }
end

local function camera(frame)
  local entering = (1 - max(0, min(1, frame / 18))) ^ 2
  local leaving = smooth(39, 47, frame) * (1 - smooth(48, 50, frame))
  local distance
  if frame < 18 then
    distance = 2.25 - 2.01 * entering
  elseif frame < 43 then
    distance = 2.25
  elseif frame < 48 then
    distance = 2.25 - 1.80 * ((frame - 43) / 5) ^ 1.6
  elseif frame < 49 then
    distance = 0.45 - 0.19 * (frame - 48)
  else
    distance = 0.26 - 0.155 * max(0, min(1, frame - 49))
  end
  local r = RECTS[PORTAL_TILE + 1]
  local hero = pose_point(world_pose(PORTAL_TILE, frame),
    (PORTAL[1] - r[1] - r[3] * 0.5) / PIXELS_PER_UNIT,
    (PORTAL[2] - r[2] - r[4] * 0.5) / PIXELS_PER_UNIT)
  local base = { (2360 - 100 * entering) / PIXELS_PER_UNIT, 1100 / PIXELS_PER_UNIT, 0 }
  local target = add(base, mul(sub(hero, base), smooth(40, 49, frame)))
  local angles = {
    0.20 * entering - 0.10 * leaving,
    -0.48 * entering + 0.25 * leaving,
    0.12 * entering - 0.025 * leaving,
  }
  local forward = turn(turn({ 0, 0, 1 }, 1, 3, angles[2]), 2, 3, angles[3])
  return { origin = sub(target, mul(forward, distance)), angles = angles }
end

local function direction(cam, p)
  p = turn(p, 2, 3, -cam.angles[3])
  p = turn(p, 1, 3, -cam.angles[2])
  return turn(p, 1, 2, -cam.angles[1])
end

local function camera_pose(cam, pose)
  return {
    center = direction(cam, sub(pose.center, cam.origin)),
    right = direction(cam, pose.right),
    down = direction(cam, pose.down),
  }
end

local function project(p)
  return 960 + FOCAL * p[1] / p[3], 540 + FOCAL * p[2] / p[3]
end

local CORNERS = { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }

-- The card's pose at the shutter's opening, its motion until it closes, and
-- its screen bounds over that interval (nil when off screen).
local function new_card(index, start, stop)
  local pose = camera_pose(camera(start), world_pose(index, start))
  local last = camera_pose(camera(stop), world_pose(index, stop))
  local width, height = RECTS[index + 1][3], RECTS[index + 1][4]
  local lo = { 1920, 1080 }
  local hi = { 0, 0 }
  for _, sample in ipairs { pose, last } do
    local corners = {}
    for i, c in ipairs(CORNERS) do
      corners[i] = pose_point(sample, c[1] * width / (2 * PIXELS_PER_UNIT), c[2] * height / (2 * PIXELS_PER_UNIT))
    end
    -- Clip to the camera's near plane before projecting. During the icon
    -- dive, the large hero card straddles that plane.
    for i = 1, 4 do
      local a = corners[i]
      local b = corners[i % 4 + 1]
      local points = {}
      if a[3] >= 0.01 then points[#points + 1] = a end
      if (a[3] >= 0.01) ~= (b[3] >= 0.01) then
        points[#points + 1] = add(a, mul(sub(b, a), (0.01 - a[3]) / (b[3] - a[3])))
      end
      for _, point in ipairs(points) do
        local px, py = project(point)
        lo[1], hi[1] = min(lo[1], px), max(hi[1], px)
        lo[2], hi[2] = min(lo[2], py), max(hi[2], py)
      end
    end
  end
  local x = max(floor(lo[1] - 5), 0)
  local y = max(floor(lo[2] - 5), 0)
  local w = min(ceil(hi[1] + 5), 1920) - x
  local h = min(ceil(hi[2] + 5), 1080) - y
  if not (w > 0 and h > 0) then return nil end
  return {
    index = index,
    pose = pose,
    motion = {
      center = sub(last.center, pose.center),
      right = sub(last.right, pose.right),
      down = sub(last.down, pose.down),
    },
    bounds = { x, y, w, h },
  }
end

-- The 51 frames of the shot, once.
local FRAMES = {}
for index = 0, 50 do
  local frame = index
  local shutter = index < 7 or (index >= 44 and index < 49)
  local exposure = shutter and 0.35 or 0
  local cards = {}
  for i = 0, #RECTS - 1 do
    local card = new_card(i, max(frame - exposure * 0.5, 0), frame + exposure * 0.5)
    if card then cards[#cards + 1] = card end
  end
  -- Far cards first (a stable sort, as the original's).
  table.sort(cards, function(a, b)
    local za, zb = a.pose.center[3], b.pose.center[3]
    if za ~= zb then return za > zb end
    return a.index < b.index
  end)
  local portal_clip
  if index >= 49 then
    local pose = camera_pose(camera(frame), world_pose(PORTAL_TILE, frame))
    local r = RECTS[PORTAL_TILE + 1]
    local parts = {}
    for i = 0, 95 do
      local angle = i * 2 * math.pi / 96
      local px, py = project(pose_point(pose,
        (PORTAL[1] - r[1] - r[3] * 0.5 + 23 * cos(angle)) / PIXELS_PER_UNIT,
        (PORTAL[2] - r[2] - r[4] * 0.5 + 23 * sin(angle)) / PIXELS_PER_UNIT))
      parts[#parts + 1] = string.format("%s%.9g %.9g", i == 0 and "M" or "L", px, py)
    end
    portal_clip = table.concat(parts, " ") .. " Z"
  end
  FRAMES[index] = { cards = cards, portal_clip = portal_clip, shutter = shutter }
end

-- `index`: the shot's frame (0..50); `sksl`: the catalog program.
function M.render(f, index, sksl)
  local state = FRAMES[index]
  if not state then return end
  rect { x = 0, y = 0, w = 1920, h = 1080, fill = "#08080a" }
  for _, card in ipairs(state.cards) do
    local b = card.bounds
    local a = RECTS[card.index + 1]
    local p, m = card.pose, card.motion
    shader(f, { sksl = sksl, x = b[1], y = b[2], w = b[3], h = b[4], uniforms = {
      uMask = "catalog.png",
      uClock = index * 1001 / 30000,
      uProgress = index / 51,
      uVariant = 0,
      uBeat = 0,
      uShutter = state.shutter and 1 or 0,
      uHero = card.index == PORTAL_TILE and 1 or 0,
      uOrigin = { b[1], b[2] },
      uPortal = PORTAL,
      uAtlas = a,
      uCenter = p.center, uRight = p.right, uDown = p.down,
      uCenterMotion = m.center, uRightMotion = m.right, uDownMotion = m.down,
    } })
  end
  if state.portal_clip then
    group({ clip_path = state.portal_clip }, function()
      text { "SkSL + SHADERTOY", x = 960, y = 576, align = "center", font = "DM Sans", weight = 500, size = 64,
        letter_spacing = -1.8, fill = "#fcf5ff" }
    end)
  end
end

return M
