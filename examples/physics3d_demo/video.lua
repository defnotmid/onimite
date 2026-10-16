-- 3D Box3D Physics Demo: Wrecking Ball vs Block Tower + Bouncing Spheres
video {
  width = 1280,
  height = 720,
  fps = 60,
  background = "#0b0f19",
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

local PALETTE = {
  "#38bdf8", "#f472b6", "#fbbf24", "#34d399", "#a78bfa", "#fb7185",
}

scene {
  "WreckingTower",
  duration = 4.0,
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
          shadow = { map_size = 1024, bias = -0.001 },
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
