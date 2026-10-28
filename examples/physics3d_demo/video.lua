-- 3D Box3D Physics Demo: Wrecking Ball vs Block Tower + Bouncing Spheres,
-- then a ragdoll down a staircase (ball joints with cone and twist limits,
-- hinges with limits: knees and elbows bend one way only).
-- physics3d{} once at load; its contacts place the sound: a wood crash where
-- the ball first hits the tower, a wooden thud per block, ragdoll part and
-- letter landing, a rubber ball's bounce per orb bounce (pitched per orb),
-- louder for harder hits and panned to where they land. The sounds are CC0
-- recordings fetch.sh downloads.
--
--     examples/physics3d_demo/fetch.sh
--     onimite render examples/physics3d_demo/video.lua -o physics3d_demo.mp4
video {
  motion_blur = { shutter = 180 },
  width = 1280,
  height = 720,
  fps = 60,
  background = "#0b0f19",
  buses = { sfx = { gain_db = -2 } },
  master_gain_db = 6, -- the impacts at about -14.6 LUFS
}

local BLOCK_W, BLOCK_H, BLOCK_D = 1.2, 0.35, 0.4
local LAYERS = 8

local sim = shared("wrecking_tower", function()
  local bodies = {
    -- Static stage floor
    { name = "floor", box = { 24, 1, 24 }, position = { 0, -0.5, 0 }, static = true, friction = 0.7, bounce = 0.2 },
    -- Kinematic rotating sweeper bar on the left
    {
      name = "sweeper",
      box = { 2.6, 0.35, 0.35 },
      position = { -3.5, 0.25, 1.5 },
      kinematic = true,
      move = function(t)
        return { -3.5, 0.25, 1.5 }, { 0, t * 3.5, 0 }
      end,
    },
    -- Wrecking ball pulled back to the right
    {
      name = "wrecking_ball",
      sphere = 0.75,
      position = { 4.2, 4.8, 0.15 },
      density = 8.0,
      friction = 0.4,
      bounce = 0.3,
    },
  }

  local block_names = {}
  for layer = 0, LAYERS - 1 do
    local y = 0.175 + layer * BLOCK_H
    local even = (layer % 2 == 0)
    for i = -1, 1 do
      local idx = #block_names + 1
      local name = "block_" .. idx
      block_names[idx] = name
      local offset = i * 0.42
      bodies[#bodies + 1] = {
        name = name,
        box = { BLOCK_W, BLOCK_H, BLOCK_D },
        position = even and { 0, y, offset } or { offset, y, 0 },
        rotation = even and { 0, 0, 0 } or { 0, math.pi * 0.5, 0 },
        friction = 0.6,
        bounce = 0.15,
      }
    end
  end

  local sphere_names = {}
  for i = 1, 6 do
    local name = "orb_" .. i
    sphere_names[i] = name
    bodies[#bodies + 1] = {
      name = name,
      sphere = 0.28,
      position = { -3.5 + (i - 3.5) * 0.45, 2.5 + i * 0.55, 1.4 + (i % 2) * 0.25 },
      bounce = 0.65,
      friction = 0.3,
    }
  end

  local res = physics3d {
    duration = 4.0,
    rate = 120,
    gravity = { 0, -9.81, 0 },
    bodies = bodies,
    joints = {
      -- Pendulum rod anchored high above the tower
      { "rod", b = "wrecking_ball", from = { 0, 5.8, 0.15 }, to = { 4.2, 4.8, 0.15 } },
    },
  }
  res.block_names = block_names
  res.sphere_names = sphere_names
  return res
end)

-- A sound per impact worth hearing: the hard ones, a body's at most every
-- GAP seconds (a collapsing tower touches hundreds of times).
-- the recordings (fetch.sh): the crash's first hit is 0.93 s in, one
-- bounce of the ball 0.82 s in; the orbs' bounces pitched up a major
-- chord (tape-style, `speed`)
local function thud(t, gain, pan, k)
  return { "thud.mp3", start = t, gain_db = gain, pan = pan, bus = "sfx", speed = 0.92 + 0.16 * hash(k, 3) }
end
local ORB_SPEEDS = { 1, 1.26, 1.5, 1.68, 2, 2.52 }
local hits, last, crashed = {}, {}, false
local last_thump = -1 -- the tower's thumps at least 40 ms apart, all blocks together
local function kind(name)
  if name == "wrecking_ball" then return "ball" end
  if name:sub(1, 4) == "orb_" then return "orb" end
  if name:sub(1, 6) == "block_" then return "block" end
end
for _, c in ipairs(sim.contacts) do
  local na, nb = sim.bodies[c.a].name, sim.bodies[c.b].name
  local ka, kb = kind(na), kind(nb)
  local who = (ka == "ball" or kb == "ball") and "ball" or (ka == "orb" and na) or (kb == "orb" and nb)
    or (ka == "block" and na) or (kb == "block" and nb)
  local block = who and who:sub(1, 6) == "block_"
  local min_speed, gap = (block and 2.0 or 1.0), (block and 0.25 or 0.15)
  if who and c.speed > min_speed and (last[who] or -1) < c.t - gap then
    last[who] = c.t
    local pan = clamp(c.x / 5, -0.8, 0.8)
    if who == "ball" then
      if not crashed then
        crashed = true
        hits[#hits + 1] = { "crash.mp3", start = c.t, offset = 0.93, gain_db = remap(c.speed, 1, 6, -14, -4), pan = pan, bus = "sfx" }
      else
        hits[#hits + 1] = thud(c.t, remap(c.speed, 1, 6, -16, -4), pan, #hits)
      end
    elseif who:sub(1, 4) == "orb_" then
      local n = tonumber(who:sub(5))
      hits[#hits + 1] = { "bounce.mp3", start = c.t, offset = 0.82, stop = c.t + 0.35, speed = ORB_SPEEDS[n],
        gain_db = remap(c.speed, 1, 5, -20, -8), pan = pan, bus = "sfx" }
    elseif c.t - last_thump >= 0.04 then
      last_thump = c.t
      hits[#hits + 1] = thud(c.t, remap(c.speed, 2, 6, -22, -10), pan, #hits)
    end
  end
end

local PALETTE = {
  "#38bdf8", "#f472b6", "#fbbf24", "#34d399", "#a78bfa", "#fb7185",
}

scene {
  "WreckingTower",
  duration = 4.0,
  audio = hits,
  render = function(f)
    local t = f.seconds
    local wb_pos, wb_rot = physics3d_at(sim, "wrecking_ball", t)
    local sw_pos, sw_rot = physics3d_at(sim, "sweeper", t)

    local blocks = physics3d_instances(sim, t, sim.block_names)
    for i = 1, #blocks do
      -- A colour per layer (odd layers lie crosswise by their rotation)
      local layer = math.floor((i - 1) / 3)
      blocks[i].color = PALETTE[(layer % #PALETTE) + 1]
    end

    local orbs = physics3d_instances(sim, t, sim.sphere_names)
    for i = 1, #orbs do
      orbs[i].color = PALETTE[((i + 2) % #PALETTE) + 1]
    end

    local cam_angle = -0.35 + t * 0.12
    local cam_dist = 8.8
    view3d {
      tone_mapping = "agx",
      tone_mapping_exposure = 1.15,
      camera = {
        position = { math.sin(cam_angle) * cam_dist, 3.6, math.cos(cam_angle) * cam_dist },
        target = { -0.6, 1.4, 0.2 },
        fov = 42,
      },
      lights = {
        { type = "HemisphereLight", color = "#dceeff", ground_color = "#1e293b", intensity = 0.7 },
        {
          type = "DirectionalLight",
          color = "#fff7ed",
          intensity = 3.2,
          position = { 6, 10, 7 },
          cast_shadow = true,
          shadow = { map_size = 1024 },
        },
      },
      meshes = {
        -- Floor
        {
          geometry = { type = "BoxGeometry", width = 20, height = 1, depth = 20 },
          position = { 0, -0.5, 0 },
          material = { color = "#1e293b", roughness = 0.85, metalness = 0.1 },
          receive_shadow = true,
        },
        -- Instanced Jenga blocks
        {
          geometry = { type = "BoxGeometry", width = BLOCK_W, height = BLOCK_H, depth = BLOCK_D },
          material = { color = "#ffffff", roughness = 0.35, metalness = 0.15 },
          cast_shadow = true,
          receive_shadow = true,
          instances = blocks,
        },
        -- Instanced bouncing orbs
        {
          geometry = { type = "SphereGeometry", radius = 0.28, width_segments = 24, height_segments = 16 },
          material = { color = "#ffffff", roughness = 0.2, metalness = 0.4 },
          cast_shadow = true,
          receive_shadow = true,
          instances = orbs,
        },
        -- Wrecking ball
        {
          geometry = { type = "SphereGeometry", radius = 0.75, width_segments = 32, height_segments = 24 },
          position = wb_pos,
          rotation = wb_rot,
          material = { color = "#e2e8f0", roughness = 0.2, metalness = 0.85 },
          cast_shadow = true,
          receive_shadow = true,
        },
        -- Pendulum cable
        {
          geometry = { type = "LineGeometry", points = { { 0, 5.8, 0.15 }, wb_pos } },
          material = { color = "#94a3b8", linewidth = 0.035 },
        },
        -- Kinematic sweeper bar
        {
          geometry = { type = "BoxGeometry", width = 2.6, height = 0.35, depth = 0.35 },
          position = sw_pos,
          rotation = sw_rot,
          material = { color = "#f97316", roughness = 0.3, metalness = 0.3 },
          cast_shadow = true,
          receive_shadow = true,
        },
      },
    }
  end,
}

-- The ragdoll: eleven bodies standing at the top of the stairs, a hop forward
-- off the top step. Shoulders, hips, neck and spine are ball joints whose
-- `axis` points along the limb at rest (the cone limits the swing about it,
-- `twist` the turn around it); elbows and knees are hinges about X with
-- limits, so they fold one way like joints do.
local STEP_W, STEP_H, STEPS = 0.55, 0.28, 6
local TOP = STEP_H * STEPS                       -- the landing's height

-- The staircase, `width` deep in z about z0: a landing at x < 0, each step one
-- lower going +x, as static bodies and as meshes.
local function stair_boxes(width, z0)
  local list = { { "landing", { 2, TOP, width }, { -1, TOP / 2, z0 } } }
  for i = 1, STEPS - 1 do
    local h = TOP - i * STEP_H
    list[#list + 1] = { "step_" .. i, { STEP_W, h, width }, { (i - 0.5) * STEP_W, h / 2, z0 } }
  end
  return list
end
local function stair_bodies(width, z0)
  local bodies = { { name = "floor", box = { 30, 1, 30 }, position = { 0, -0.5, 0 }, static = true, friction = 0.8 } }
  for _, b in ipairs(stair_boxes(width, z0)) do
    bodies[#bodies + 1] = { name = b[1], box = b[2], position = b[3], static = true, friction = 0.8 }
  end
  return bodies
end
local function stair_meshes(width, z0)
  local meshes = { { geometry = { type = "BoxGeometry", width = 20, height = 1, depth = 20 }, position = { 0, -0.5, 0 },
    material = { color = "#1e293b", roughness = 0.85 }, receive_shadow = true } }
  for i, b in ipairs(stair_boxes(width, z0)) do
    meshes[#meshes + 1] = { geometry = { type = "BoxGeometry", width = b[2][1], height = b[2][2], depth = b[2][3] },
      position = b[3], cast_shadow = true, receive_shadow = true,
      material = { color = i % 2 == 0 and "#3b4a61" or "#334155", roughness = 0.7 } }
  end
  return meshes
end
local function is_stairs(name) return name == "floor" or name == "landing" or name:match("^step_") ~= nil end

local ragdoll = shared("ragdoll", function()
  local bodies = stair_bodies(3, 0)
  local x0, y0 = -0.35, TOP                      -- feet on the landing, near its edge
  local hop = { 1.6, 2.2, 0.15 }
  local function limb(name, x, y_top, y_bottom, r)
    local h = y_top - y_bottom - 2 * r
    bodies[#bodies + 1] = { name = name, capsule = { radius = r, height = h },
      position = { x0 + x, y0 + (y_top + y_bottom) / 2, 0 }, velocity = hop, friction = 0.5, bounce = 0.1 }
  end
  bodies[#bodies + 1] = { name = "pelvis", box = { 0.32, 0.2, 0.2 }, position = { x0, y0 + 1.0, 0 }, velocity = hop }
  bodies[#bodies + 1] = { name = "chest", box = { 0.38, 0.42, 0.22 }, position = { x0, y0 + 1.33, 0 },
    velocity = hop, spin = { 0.4, 0, -2.5 } }
  bodies[#bodies + 1] = { name = "head", sphere = 0.12, position = { x0, y0 + 1.69, 0 }, velocity = hop }
  for _, side in ipairs { { "l", -1 }, { "r", 1 } } do
    local n, sx = side[1], side[2]
    limb("upper_arm_" .. n, sx * 0.25, 1.53, 1.25, 0.05)
    limb("lower_arm_" .. n, sx * 0.25, 1.24, 0.96, 0.045)
    limb("thigh_" .. n, sx * 0.1, 0.9, 0.52, 0.065)
    limb("shin_" .. n, sx * 0.1, 0.51, 0.06, 0.055)
  end
  local function at(x, y) return { x0 + x, y0 + y, 0 } end
  local joints = {
    { "ball", a = "pelvis", b = "chest", at = at(0, 1.11), axis = { 0, 1, 0 }, cone = 0.45, twist = { -0.35, 0.35 } },
    { "ball", a = "chest", b = "head", at = at(0, 1.56), axis = { 0, 1, 0 }, cone = 0.6, twist = { -0.7, 0.7 } },
  }
  for _, side in ipairs { { "l", -1 }, { "r", 1 } } do
    local n, sx = side[1], side[2]
    joints[#joints + 1] = { "ball", a = "chest", b = "upper_arm_" .. n, at = at(sx * 0.25, 1.53),
      axis = { 0, -1, 0 }, cone = 1.6, twist = { -0.8, 0.8 } }
    joints[#joints + 1] = { "hinge", a = "upper_arm_" .. n, b = "lower_arm_" .. n, at = at(sx * 0.25, 1.245),
      axis = { 1, 0, 0 }, limit = { -2.5, 0 } }
    joints[#joints + 1] = { "ball", a = "pelvis", b = "thigh_" .. n, at = at(sx * 0.1, 0.9),
      axis = { 0, -1, 0 }, cone = 1.1, twist = { -0.4, 0.4 } }
    joints[#joints + 1] = { "hinge", a = "thigh_" .. n, b = "shin_" .. n, at = at(sx * 0.1, 0.515),
      axis = { 1, 0, 0 }, limit = { 0, 2.5 } }
  end
  return physics3d { duration = 5, rate = 240, gravity = { 0, -9.81, 0 }, bodies = bodies, joints = joints }
end)

-- A thump per hard landing of a part, each part at most every 0.2 s.
local falls, last_hit = {}, {}
for _, c in ipairs(ragdoll.contacts) do
  for _, b in ipairs { c.a, c.b } do
    local name = ragdoll.bodies[b].name
    if not is_stairs(name) and c.speed > 1.2
      and (last_hit[name] or -1) < c.t - 0.2 then
      last_hit[name] = c.t
      falls[#falls + 1] = thud(c.t, remap(c.speed, 1.2, 6, -24, -8), clamp(c.x / 4, -0.7, 0.7), #falls)
    end
  end
end

local PARTS = {
  { "head", { type = "SphereGeometry", radius = 0.12, width_segments = 24, height_segments = 16 }, "#fbbf24" },
  { "chest", { type = "BoxGeometry", width = 0.38, height = 0.42, depth = 0.22 }, "#38bdf8" },
  { "pelvis", { type = "BoxGeometry", width = 0.32, height = 0.2, depth = 0.2 }, "#38bdf8" },
}
for _, n in ipairs { "l", "r" } do
  PARTS[#PARTS + 1] = { "upper_arm_" .. n, { type = "CapsuleGeometry", radius = 0.05, height = 0.18 }, "#f472b6" }
  PARTS[#PARTS + 1] = { "lower_arm_" .. n, { type = "CapsuleGeometry", radius = 0.045, height = 0.19 }, "#f472b6" }
  PARTS[#PARTS + 1] = { "thigh_" .. n, { type = "CapsuleGeometry", radius = 0.065, height = 0.25 }, "#a78bfa" }
  PARTS[#PARTS + 1] = { "shin_" .. n, { type = "CapsuleGeometry", radius = 0.055, height = 0.34 }, "#a78bfa" }
end

scene {
  "Ragdoll",
  duration = 5.0,
  audio = falls,
  render = function(f)
    local t = f.seconds
    local meshes = stair_meshes(3, 0)
    for _, p in ipairs(PARTS) do
      local pos, rot = physics3d_at(ragdoll, p[1], t)
      meshes[#meshes + 1] = { geometry = p[2], position = pos, rotation = rot, cast_shadow = true,
        receive_shadow = true, material = { color = p[3], roughness = 0.4, metalness = 0.1 } }
    end
    local follow = physics3d_at(ragdoll, "chest", t)
    view3d {
      tone_mapping = "agx",
      tone_mapping_exposure = 1.15,
      camera = { position = { follow[1] + 1.4, follow[2] + 1.3, 3.4 }, target = { follow[1] + 0.2, follow[2] - 0.2, 0 }, fov = 45 },
      lights = {
        { type = "HemisphereLight", color = "#dceeff", ground_color = "#1e293b", intensity = 0.7 },
        { type = "DirectionalLight", color = "#fff7ed", intensity = 3.2, position = { 4, 9, 6 },
          cast_shadow = true, shadow = { map_size = 2048 } },
      },
      meshes = meshes,
    }
  end,
}

-- Ragdoll letters: ONIMITE in stick strokes, a body per stroke. Wherever a
-- stroke's end touches another stroke they are joined by a ball joint with
-- a cone and a soft spring back to the letter's shape, so each letter holds
-- together but flops. They stand on the landing facing +x (the camera) and
-- hop off one after another, down a staircase as wide as the word.
local WORD = "ONIMITE"
local LW, LH, GAP = 0.42, 0.7, 0.24              -- a letter's box and the space between
local THICK, SLAB = 0.07, 0.1                    -- a stroke's width and depth
local GLYPHS = {                                 -- strokes { u1, v1, u2, v2 } in the letter's box (0..1)
  O = { { 0, 0, 1, 0 }, { 1, 0, 1, 1 }, { 1, 1, 0, 1 }, { 0, 1, 0, 0 } },
  N = { { 0, 0, 0, 1 }, { 0, 1, 1, 0 }, { 1, 0, 1, 1 } },
  I = { { 0.5, 0, 0.5, 1 }, { 0.15, 1, 0.85, 1 }, { 0.15, 0, 0.85, 0 } },
  M = { { 0, 0, 0, 1 }, { 0, 1, 0.5, 0.45 }, { 0.5, 0.45, 1, 1 }, { 1, 1, 1, 0 } },
  T = { { 0, 1, 1, 1 }, { 0.5, 1, 0.5, 0 } },
  E = { { 0, 0, 0, 1 }, { 0, 1, 1, 1 }, { 0, 0.5, 0.8, 0.5 }, { 0, 0, 1, 0 } },
}
local SPAN = #WORD * LW + (#WORD - 1) * GAP
local letters = shared("ragdoll_letters", function()
  local bodies = stair_bodies(SPAN + 1.5, -SPAN / 2)
  local joints, strokes = {}, {}
  for li = 1, #WORD do
    local glyph = GLYPHS[WORD:sub(li, li)]
    local z_left = -(li - 1) * (LW + GAP)        -- screen right is -z, looking from +x
    local x0, start = -0.3, 0.4 + (li - 1) * 0.35
    local hop = { 2.1 + hash(li, 3) * 0.6, 2.2 + hash(li, 5) * 0.8, (hash(li, 9) - 0.5) * 0.6 }
    local function world(u, v) return { x0, TOP + 0.005 + THICK / 2 + v * LH, z_left - u * LW } end
    local first = #bodies + 1
    for k, st in ipairs(glyph) do
      local a, b = world(st[1], st[2]), world(st[3], st[4])
      local dy, dz = b[2] - a[2], b[3] - a[3]
      local len = math.sqrt(dy * dy + dz * dz)
      local name = string.format("%d%s_%d", li, WORD:sub(li, li), k)
      bodies[#bodies + 1] = { name = name, box = { SLAB, len, THICK }, start = start, velocity = hop,
        spin = { 0, 0, -1.5 - hash(li, 11) }, friction = 0.5, bounce = 0.15,
        position = { x0, (a[2] + b[2]) / 2, (a[3] + b[3]) / 2 }, rotation = { math.atan(dz, dy), 0, 0 } }
      strokes[#strokes + 1] = { name = name, letter = li, len = len }
    end
    -- A joint where an end of stroke i lies on stroke j (within a hair).
    for i = 1, #glyph do
      for j = 1, #glyph do
        if i ~= j then
          local si, sj = glyph[i], glyph[j]
          for _, e in ipairs { { si[1], si[2] }, { si[3], si[4] } } do
            local du, dv = sj[3] - sj[1], sj[4] - sj[2]
            local t = clamp(((e[1] - sj[1]) * du + (e[2] - sj[2]) * dv) / (du * du + dv * dv), 0, 1)
            local pu, pv = sj[1] + t * du - e[1], sj[2] + t * dv - e[2]
            -- each touching pair once: i < j, or j's end isn't also on i
            if pu * pu + pv * pv < 1e-6 and (i < j or (t > 1e-3 and t < 1 - 1e-3)) then
              joints[#joints + 1] = { "ball", a = bodies[first + i - 1].name, b = bodies[first + j - 1].name,
                at = world(e[1], e[2]), cone = 1.3, twist = { -0.7, 0.7 }, hertz = 1.2, damping = 0.15 }
            end
          end
        end
      end
    end
  end
  local sim = physics3d { duration = 7, rate = 240, gravity = { 0, -9.81, 0 }, bodies = bodies, joints = joints }
  sim.strokes = strokes
  return sim
end)

local tumbles, letter_last = {}, {}
for _, c in ipairs(letters.contacts) do
  local na, nb = letters.bodies[c.a].name, letters.bodies[c.b].name
  local who = (not is_stairs(na) and na) or (not is_stairs(nb) and nb)
  local li = who and tonumber(who:match("^(%d+)"))
  if li and c.speed > 1.0 and (letter_last[li] or -1) < c.t - 0.12 then
    letter_last[li] = c.t
    tumbles[#tumbles + 1] = thud(c.t, remap(c.speed, 1, 6, -26, -10), clamp(-c.z / SPAN * 1.6, -0.8, 0.8), #tumbles)
  end
end

scene {
  "RagdollLetters",
  duration = 7.0,
  audio = tumbles,
  render = function(f)
    local t = f.seconds
    local meshes = stair_meshes(SPAN + 1.5, -SPAN / 2)
    for _, st in ipairs(letters.strokes) do
      local pos, rot = physics3d_at(letters, st.name, t)
      meshes[#meshes + 1] = { geometry = { type = "BoxGeometry", width = SLAB, height = st.len, depth = THICK },
        position = pos, rotation = rot, cast_shadow = true, receive_shadow = true,
        material = { color = PALETTE[(st.letter - 1) % #PALETTE + 1], roughness = 0.35, metalness = 0.1 } }
    end
    view3d {
      tone_mapping = "agx",
      tone_mapping_exposure = 1.15,
      camera = { position = { 5.4 + t * 0.1, 3.3, -SPAN / 2 + 1.2 }, target = { 1.0, 0.6, -SPAN / 2 }, fov = 50 },
      lights = {
        { type = "HemisphereLight", color = "#dceeff", ground_color = "#1e293b", intensity = 0.7 },
        { type = "DirectionalLight", color = "#fff7ed", intensity = 3.2, position = { 6, 9, 3 },
          cast_shadow = true, shadow = { map_size = 2048 } },
      },
      meshes = meshes,
    }
  end,
}
