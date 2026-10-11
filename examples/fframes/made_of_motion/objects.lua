-- objects.rs: independently rotating pixel objects in camera space. Camera
-- moves and ring deformation are sampled from timelines once, when the
-- script loads.
local M = {}

local PI, TAU = math.pi, 2 * math.pi
local sin, cos, floor, ceil, min, max, sqrt = math.sin, math.cos, math.floor, math.ceil, math.min, math.max, math.sqrt

-- Each return finishes before the next object leaves. The wheel keeps its
-- position and angular phase even while hidden behind the feature cards.
M.EXCURSIONS = {
  { start = 200, departure = 190, arrival = 205, return_start = 214, return_end = 225 },
  { start = 237, departure = 227, arrival = 242, return_start = 249, return_end = 259 },
  { start = 265, departure = 261, arrival = 270, return_start = 280, return_end = 294 },
}

local function turn(p, a, b, angle)
  local s, c = sin(angle), cos(angle)
  local q = { p[1], p[2], p[3] }
  q[a], q[b] = c * p[a] - s * p[b], s * p[a] + c * p[b]
  return q
end

local Object = {}
Object.__index = Object
M.Object = Object

function Object.new(icon, center, size, angles, heat)
  local function rotate(p)
    return turn(turn(turn(p, 1, 3, angles[1]), 2, 3, angles[2]), 1, 2, angles[3])
  end
  local o = setmetatable({
    icon = icon,
    center = { center[1], center[2], center[3] },
    right = rotate { 1, 0, 0 },
    down = rotate { 0, 1, 0 },
    size = size,
    stretch = { 1, 1 },
    heat = heat,
    soot = 0,
    pixels = 32,
    angles = { angles[1], angles[2], angles[3] },
    bounds = { 0, 0, 0, 0 },
  }, Object)
  return o:with_stretch { 1, 1 }
end

function Object:clone()
  local o = setmetatable({}, Object)
  for k, v in pairs(self) do
    if type(v) == "table" then
      local c = {}
      for i, x in ipairs(v) do c[i] = x end
      o[k] = c
    else
      o[k] = v
    end
  end
  return o
end

function Object:with_stretch(stretch)
  self.stretch = { stretch[1], stretch[2] }
  local low = { 1440, 1080 }
  local high = { 0, 0 }
  for _, corner in ipairs { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } } do
    local x, y = corner[1], corner[2]
    local p = {}
    for i = 1, 3 do
      p[i] = self.center[i] + (x * self.right[i] * stretch[1] + y * self.down[i] * stretch[2]) * self.size * 0.5
    end
    local screen = { 720 + 1250 * p[1] / p[3], 540 + 1250 * p[2] / p[3] }
    for i = 1, 2 do
      low[i] = min(low[i], screen[i])
      high[i] = max(high[i], screen[i])
    end
  end
  local x = max(floor(low[1] - 2), 0)
  local y = max(floor(low[2] - 2), 0)
  local w = min(ceil(high[1] + 2), 1440) - x
  local h = min(ceil(high[2] + 2), 1080) - y
  self.bounds = { x, y, w, h }
  return self
end

-- Shared camera-space interpolation keeps the selected ring object alive
-- through the edit; rebuilding a separate hero entrance caused the jump.
function Object:handoff(target, progress, lift)
  local function mix(a, b) return a + (b - a) * progress end
  local center = {}
  for i = 1, 3 do center[i] = mix(self.center[i], target.center[i]) end
  center[2] = center[2] - sin(progress * PI) * lift
  local angles = {}
  for i = 1, 3 do angles[i] = mix(self.angles[i], target.angles[i]) end
  local o = Object.new(self.icon, center, mix(self.size, target.size), angles, mix(self.heat, target.heat))
  o.soot = mix(self.soot, target.soot)
  o.pixels = mix(self.pixels, target.pixels)
  return o:with_stretch { mix(self.stretch[1], target.stretch[1]), mix(self.stretch[2], target.stretch[2]) }
end

-- Continue the feature's last measured velocity through the background
-- cut. The return destination is sampled separately from the real slot.
function Object:continued(previous, elapsed)
  local function extend(a, b) return a + (a - b) * elapsed end
  local center, angles = {}, {}
  for i = 1, 3 do
    center[i] = extend(self.center[i], previous.center[i])
    angles[i] = extend(self.angles[i], previous.angles[i])
  end
  local o = Object.new(self.icon, center, extend(self.size, previous.size), angles, self.heat)
  o.soot = self.soot
  o.pixels = self.pixels
  return o:with_stretch(self.stretch)
end

function Object:foreground(amount)
  -- Scale camera position and physical size together: the projected pose
  -- is identical, but the flying icon clears the other ring objects.
  local ratio = 1 + (min(550, self.center[3]) / self.center[3] - 1) * amount
  local o = Object.new(self.icon,
    { self.center[1] * ratio, self.center[2] * ratio, self.center[3] * ratio },
    self.size * ratio, self.angles, self.heat)
  o.soot = self.soot
  o.pixels = self.pixels
  return o:with_stretch(self.stretch)
end

function Object:draw(f)
  local x, y, w, h = self.bounds[1], self.bounds[2], self.bounds[3], self.bounds[4]
  if w <= 0 or h <= 0 then return end
  shader(f, { src = "shaders/object.sksl", x = x, y = y, w = w, h = h, uniforms = {
    uAtlas = "objects.png",
    uOrigin = { x, y },
    uCenter = self.center,
    uRight = self.right,
    uDown = self.down,
    uSize = self.size,
    uStretch = self.stretch,
    uCell = { (self.icon % 4) * 64, (self.icon // 4) * 64 },
    uHeat = self.heat,
    uSoot = self.soot,
    uPixels = self.pixels,
  } })
end

-- Back to front, keeping the order of equal depths (Rust's stable sort_by).
local function sort_by_depth(objects)
  for i = 2, #objects do
    local o, j = objects[i], i - 1
    while j >= 1 and objects[j].center[3] < o.center[3] do
      objects[j + 1] = objects[j]
      j = j - 1
    end
    objects[j + 1] = o
  end
end

local function find_icon(objects, icon)
  for i, o in ipairs(objects) do
    if o.icon == icon then return i, o end
  end
end

local EASE_IN_OUT_CSS = cubic_bezier(0.42, 0, 0.58, 1)

-- Replace one permanent slot's occupant with a complete excursion, including
-- the feature hold. Feature cards show only the selected track; the hidden
-- wheel keeps rotating so its vacant slot remains the exact return target.
function M.ring_excursion(frames, heroes, schedule, keep_spinning)
  local start, departure, arrival = schedule.start, schedule.departure, schedule.arrival
  local return_start, return_end = schedule.return_start, schedule.return_end
  local outward_seconds = (arrival - departure) / 24
  local return_seconds = (return_end - return_start) / 24
  local pull = { { 0, outward_seconds, 0, 1, EASE_IN_OUT_CSS } }
  local rejoin = { { 0, return_seconds, 0, 1, EASE_IN_OUT_CSS } }
  -- All feature poses live in front of the wheel, with the same projected
  -- size as the authored card. Flight depth now interpolates continuously.
  local original = {}
  for i, pose in ipairs(heroes) do original[i - 1] = pose:foreground(1) end
  local count = #heroes
  local target = original[arrival - start]:clone()
  local icon = target.icon
  local stop = start + count
  local _, destination = find_icon(frames[return_end], icon)
  if not destination then return end
  local destination_roll = destination.angles[3]
  local roll_offset = 0
  if keep_spinning then
    roll_offset = ceil((original[return_start - start].angles[3] - destination_roll) / TAU) * TAU
  end
  for index = departure, return_end do
    local objects = frames[index]
    local k, selected = find_icon(objects, icon)
    if selected then
      -- This exact, still-moving slot exists for every frame, including
      -- the black cards. Replace its occupant once; never draw a duplicate
      -- in the wheel, and never reconstruct its location across a cut.
      local slot = selected:clone()
      local pose
      if index <= arrival then
        pose = slot:handoff(target, animate((index - departure) / 24, pull), 90)
      elseif index < return_start then
        pose = original[index - start]:clone()
      else
        local source
        if index < stop then
          source = original[index - start]:clone()
        else
          source = original[count - 1]:continued(original[count - 2], index + 1 - stop)
        end
        slot.angles[3] = slot.angles[3] + roll_offset
        pose = source:handoff(slot, animate((index - return_start) / 24, rejoin), -55)
      end
      objects[k] = pose:clone()
      if index >= start and index < stop then heroes[index - start + 1] = pose end
    end
    sort_by_depth(objects)
  end
end

function M.hero(icon, x, y, size, time)
  return Object.new(icon, { x - 720, y - 540, 1250 }, size, {
    sin(time * 6.0 + 0.4) * 0.8,
    0.15 * cos(time * 4),
    -0.10 + sin(time * 2.7) * 0.25,
  }, 0)
end

local function base_choreography()
  local tilt = {
    { 6.541667, 7.291667, 0.34, 0.63, cubic_bezier(0.65, 0, 0.35, 1) },
    { 7.291667, 7.833333, 0.63, 0.50, ease_in_out },
    { 7.833333, 8.333333, 0.50, 0.48, ease_in_out },
    { 11.916667, 12.5, 0.48, 0.98, cubic_bezier(0.16, 1, 0.3, 1) },
  }
  local explode = { { 12.583333, 13.0, 0, 1, cubic_bezier(0.16, 1, 0.3, 1) } }
  -- Arrange the three featured objects along the approaching arc. At their
  -- departure frames (190, 227, 261), each sits just left of the nearest
  -- point, rather than being lifted through the ring from its far side.
  -- Keep angular velocity continuous across the hero/background cuts.
  local front_angle = 1.95
  local departure_rotation = front_angle + PI * 0.5 - 2 * TAU / 12
  local scatter_rotation = departure_rotation + (302 - 190) / 24
  local spin = { { 153 / 24, 302 / 24, departure_rotation + (153 - 190) / 24, scatter_rotation, linear } }
  local order = { 10, 7, 0, 6, 11, 9, 3, 2, 1, 4, 8, 5 }
  local targets = {
    { 0, -420 }, { 150, -100 }, { 420, -280 }, { 350, 140 }, { 530, 100 }, { 520, 340 },
    { -80, 30 }, { -360, 350 }, { -480, -130 }, { -360, -50 }, { -240, 70 }, { 180, 200 },
  }
  local frames = {}
  for index = 0, 488 do
    local t = index / 24
    local open = animate(t, explode)
    local plane = animate(t, tilt)
    local rotation = animate(t, spin)
    local objects = {}
    if index >= 48 and index < 93 then
      local positions = { { 735, 351 }, { 1060, 348 }, { 960, 665 }, { 1120, 869 } }
      for i, icon in ipairs { 7, 1, 11, 0 } do
        local local_index = index - 48
        local phase = local_index * 0.11 + (i - 1) * 2.3
        local x = positions[i][1] + sin(phase) * 15
        local y = positions[i][2] + cos(phase * 0.8) * 13
        local o = Object.new(icon, { x - 720, y - 540, 1250 }, 104,
          { sin(phase * 0.82) * 0.68, 0.12, sin(phase) * 0.16 }, 0)
        -- The source briefly breaks these distant objects down into big
        -- mosaic pixels, then resolves their detail again.
        if index <= 54 then o.pixels = 16
        elseif index >= 75 and index <= 77 then o.pixels = 12
        elseif index >= 78 and index <= 81 then o.pixels = 6
        elseif index >= 82 and index <= 84 then o.pixels = 10
        end
        objects[#objects + 1] = o
      end
    elseif index >= 153 and index < 331 then
      for n, icon in ipairs(order) do
        local i = n - 1
        local a = i * TAU / 12 + rotation - PI * 0.5
        local s, c = sin(a), cos(a)
        local radius = 355
        local x = c * radius
        local y = s * radius * plane
        local z = 1250 - s * 600 * sqrt(1 - plane * plane)
        -- Explosion retains tangential momentum. Individual pieces then
        -- drift and tumble; it is not a flat scaling of the whole ring.
        if open > 0 then
          local a0 = i * TAU / 12 + scatter_rotation - PI * 0.5
          local drift = max(t - 13, 0)
          x = cos(a0) * radius * (1 - open) + targets[n][1] * open + drift * 45 * sin(a0)
          y = sin(a0) * radius * 0.98 * (1 - open) + targets[n][2] * open + drift * 32 * cos(a0)
          z = 1250 + open * sin(i * 3.7) * 140
        end
        local roll = sin(t * 0.9 + i) * 0.12 + open * (t - 12.58) * (i - 5) * 0.17
        local yaw = sin(t * 1.05 + i * 1.7) * 0.35 + open * (t - 12.58) * 0.75
        local heat = 0
        if index < 157 then
          heat = 1 - (index - 153) * 0.14
        elseif icon == 3 or icon == 5 then
          heat = max(sin(t * 3 + i) - 0.85, 0) * 4
        end
        objects[#objects + 1] = Object.new(icon, { x, y, z }, 195 - open * 35, { yaw, 0.1, roll }, heat)
      end
    end
    sort_by_depth(objects)
    frames[index] = objects
  end
  return frames
end

-- The objects of every frame (0..488, back to front) and the six impacts.
function M.choreography()
  local frames = base_choreography()
  local impacts = {}
  -- Pick the object at each reference contact point so the nib, flare and
  -- response all use one event. This remains correct if the ring is retimed.
  for _, hit in ipairs {
    { 172, { 1045, 592 }, { 0.65, 0.6 } },
    { 177, { 767, 659 }, { 0.0, 1.0 } },
    { 182, { 425, 671 }, { -0.75, 0.65 } },
    { 188, { 340, 487 }, { -0.91, -0.41 } },
    { 312, { 1080, 575 }, { 0.45, 0.9 } },
    { 318, { 400, 878 }, { -0.9, -0.1 } },
  } do
    local at, desired, direction = hit[1], hit[2], hit[3]
    local last = impacts[#impacts]
    local nearest, best
    for _, o in ipairs(frames[at]) do
      if not last or last.icon ~= o.icon then
        local x = 720 + o.center[1] * 1250 / o.center[3]
        local y = 540 + o.center[2] * 1250 / o.center[3]
        local d = (x - desired[1]) ^ 2 + (y - desired[2]) ^ 2
        if not best or d < best then nearest, best = o, d end
      end
    end
    if nearest then
      impacts[#impacts + 1] = {
        at = at, icon = nearest.icon, direction = direction, position = desired,
        approach = {
          (desired[1] - 720) * nearest.center[3] / 1250 - nearest.center[1],
          (desired[2] - 540) * nearest.center[3] / 1250 - nearest.center[2],
        },
      }
    end
  end
  local response = {
    { 0.0, 0.083333, 0, 1, ease_out },
    { start = 0.083333, from = 1, to = 0, easing = spring { mass = 1.0, stiffness = 190.0, damping = 14.0 } },
  }
  local approach = {
    { 0.0, 0.125, 0, 1, ease_in_out },
    { 0.125, 0.75, 1, 0, ease_out },
  }
  for index = 0, 488 do
    local objects = frames[index]
    for k, o in ipairs(objects) do
      local center = { o.center[1], o.center[2], o.center[3] }
      local angles = { o.angles[1], o.angles[2], o.angles[3] }
      local heat, soot = o.heat, 0
      for _, hit in ipairs(impacts) do
        if hit.icon == o.icon and index + 3 >= hit.at and index <= hit.at + 25 then
          local arrive = animate((index + 3 - hit.at) / 24, approach)
          center[1] = center[1] + hit.approach[1] * arrive
          center[2] = center[2] + hit.approach[2] * arrive
          if index >= hit.at then
            local elapsed = index - hit.at
            local kick = animate(elapsed / 24, response)
            center[1] = center[1] + hit.direction[1] * 98 * kick
            center[2] = center[2] + hit.direction[2] * 72 * kick
            center[3] = center[3] - 85 * kick
            angles[1] = angles[1] + kick * 0.84
            angles[3] = angles[3] + kick * hit.direction[1] * 0.43
            heat = max(heat, max(1 - elapsed / 5, 0) * 0.83)
            soot = max(soot, math.min(math.max((elapsed - 3) / 4, 0), 1)
              * max(1 - max(elapsed - 11, 0) / 12, 0) * 0.92)
          end
        end
      end
      local pixels = o.pixels
      local n = Object.new(o.icon, center, o.size, angles, heat)
      n.soot = soot
      n.pixels = pixels
      objects[k] = n
    end
    sort_by_depth(objects)
  end
  return frames, impacts
end

return M
