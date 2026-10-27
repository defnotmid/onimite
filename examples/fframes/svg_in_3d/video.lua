-- svg-in-3d, after fframes' examples/svg-in-3d: an svgr UI on the screen of a turning 3D
-- monitor, and in the UI a 3D render of its own, a cube with an svgr logo on its faces. The
-- logo, which never changes, is baked once; the UI is a panel of the monitor's view:
--
--     logo -> cube (3D) -> UI -> monitor (3D) -> frame
--
-- studio.sksl: the original's studio light. README.md says where it differs from the original.

local W, H, FPS = 1920, 1080, 30
local SECONDS = 8.0
local TAU = 2 * math.pi
local function deg(d) return d * math.pi / 180 end

-- the original's studio light, drawn once relative to its brightest softbox (3.3)
local STUDIO = bake { name = "studio", w = 1024, h = 512, draw = function()
  shader { src = "studio.sksl", x = 0, y = 0, w = 1024, h = 512 }
end }
local STUDIO_PEAK = 3.3

-- the monitor: Material::metal(0x2a2d33, 0.35).clearcoat(0.6) on the body, the stand and the base
local FRAME = { type = "MeshPhysicalMaterial", color = "#2a2d33", metalness = 1, roughness = 0.35, clearcoat = 0.6 }
local function solid(geometry, position)
  return { geometry = geometry, position = position, material = FRAME, cast_shadow = true, receive_shadow = true }
end
local function rounded_box(w, h, d, r, segments)
  return { type = "RoundedBoxGeometry", width = w, height = h, depth = d, radius = r, segments = segments }
end
local BODY = solid(rounded_box(1.84, 1.2, 0.09, 0.035, 4))
local STAND = solid({ type = "CylinderGeometry", radius_top = 0.05, radius_bottom = 0.06, height = 0.62,
  radial_segments = 24 }, { 0, 0.5, -0.06 })
local BASE = solid(rounded_box(0.8, 0.04, 0.42, 0.02, 3), { 0, 0.2, -0.06 })
local FLOOR = { geometry = { type = "PlaneGeometry", width = 20, height = 20 }, position = { 0, 0.18, 0 },
  rotation = { -math.pi / 2, 0, 0 }, material = { type = "ShadowMaterial", opacity = 0.55 }, receive_shadow = true }

-- m:ss.cc of t seconds
local function timer(t)
  local centis = math.floor(t * 100 + 0.5)
  return string.format("%d:%02d.%02d", centis // 6000, centis // 100 % 60, centis % 100)
end

-- level 1: the logo, drawn once
local LOGO = bake { name = "logo", w = 256, h = 256, draw = function()
  rect { x = 0, y = 0, w = 256, h = 256, fill = "#2f81f7" }
  rect { x = 14, y = 14, w = 228, h = 228, rx = 28, fill = "none", stroke = "#ffffff", stroke_width = 10 }
  text { "ff", x = 128, y = 168, align = "center", font = "DM Sans", size = 116, fill = "#ffffff" }
end }

-- level 2: the logo on the faces of a turning cube, 480 x 480 at x, y in the UI
local function cube(t, x, y)
  view3d { x = x, y = y, w = 480, h = 480, tone_mapping = "neutral", environment = STUDIO,
    environment_intensity = STUDIO_PEAK,
    camera = { type = "PerspectiveCamera", fov = 35, near = 0.05, far = 500, position = { 0, 0, 3.4 } },
    lights = { { type = "DirectionalLight", intensity = 2, position = { 2, 3, 4 } } },
    meshes = { { geometry = { type = "BoxGeometry" }, rotation = { t * 0.7, t * 1.1, 0.25 },
      material = { type = "MeshStandardMaterial", map = LOGO, roughness = 0.35 } } } }
end

-- level 3: the UI with a live timer and the cube
local function ui(t, index)
  rect { x = 0, y = 0, w = 1280, h = 800, fill = "#0d1117" }
  rect { x = 0, y = 0, w = 1280, h = 96, fill = "#161b22" }
  circle { cx = 52, cy = 48, r = 12, fill = "#ff5f56" }
  circle { cx = 88, cy = 48, r = 12, fill = "#ffbd2e" }
  circle { cx = 124, cy = 48, r = 12, fill = "#27c93f" }
  text { "ctx.render_svgr", x = 168, y = 62, font = "DM Sans", size = 38, fill = "#e6edf3" }
  text { timer(t), x = 1232, y = 64, align = "right", font = "JetBrains Mono", size = 40, fill = "#ff7b72" }
  rect { x = 64, y = 148, w = 528, h = 528, rx = 24, fill = "#161b22" }
  cube(t, 88, 172)
  text { "svg  -> 3D", x = 660, y = 236, font = "JetBrains Mono", size = 34, fill = "#7ee787" }
  text { "3D   -> svg", x = 660, y = 296, font = "JetBrains Mono", size = 34, fill = "#79c0ff" }
  text { "svg  -> 3D", x = 660, y = 356, font = "JetBrains Mono", size = 34, fill = "#d2a8ff" }
  text { "3D   -> frame", x = 660, y = 416, font = "JetBrains Mono", size = 34, fill = "#ffa657" }
  text { "frame " .. index, x = 660, y = 520, font = "DM Sans", size = 30, fill = "#8b949e" }
  rect { x = 660, y = 600, w = 540, h = 18, rx = 9, fill = "#30363d" }
  rect { x = 660, y = 600, w = 18 + 522 * t / SECONDS, h = 18, rx = 9, fill = "#2f81f7" }
end

-- level 4: the UI on the monitor's unlit screen, in the frame
video { width = W, height = H, fps = FPS, duration = SECONDS, background = "#000000", render = function(f)
  local t = f.seconds
  rect { x = 0, y = 0, w = W, h = H, fill = radial_gradient { units = "bbox", cx = 0.5, cy = 0.38, r = 0.75,
    stops = { { 0, "#3a4150" }, { 1, "#0b0d12" } } } }
  -- the monitor turns far enough that the text on the screen is seen at a low angle; the
  -- camera orbits 4.6 away, 9 degrees up
  local turn = { 0, math.sin(t / SECONDS * TAU) * deg(52), 0 }
  local azimuth, elevation, target = deg(12 * math.sin(t * 0.4)), deg(9), { 0, 1.1, 0 }
  view3d {
    camera = { type = "PerspectiveCamera", fov = 30, near = 0.05, far = 500, target = target,
      position = vec3_add(target, vec3_scale({ math.sin(azimuth) * math.cos(elevation), math.sin(elevation),
        math.cos(azimuth) * math.cos(elevation) }, 4.6)) },
    tone_mapping = "neutral", environment = STUDIO, environment_intensity = STUDIO_PEAK,
    panels = { ui = { w = 1280, h = 800, draw = function() ui(t, f.index) end } },
    -- the sun from (2.5, 6, 4), its shadow over the monitor and the floor below it
    lights = { { type = "DirectionalLight", intensity = 2.5, position = { 2.5, 7, 4 }, target = { 0, 1, 0 },
      cast_shadow = true, shadow = { map_size = 2048, height = 4 } } },
    groups = { { position = { 0, 1.32, 0 }, rotation = turn, meshes = {
      BODY,
      { geometry = { type = "PlaneGeometry", width = 1.68, height = 1.05 }, position = { 0, 0, 0.0455 },
        material = { type = "MeshBasicMaterial", map = "ui" } },
    } } },
    meshes = { STAND, BASE, FLOOR },
  }
  text { "An svgr UI on a 3D screen. The UI holds a 3D render with an svgr logo.", x = 96, y = 1010,
    font = "DM Sans", size = 34, fill = "#8b949e" }
end }
