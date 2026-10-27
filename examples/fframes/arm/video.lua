-- FFRAMES, ASSEMBLED: arm, after fframes' examples/arm. A 37 second film about a lab robot
-- with a camera eye: it wakes in the dark lab, spells `fframes` with letter pieces from a
-- rack, throws the "a" across the floor by mistake, and fixes it. 1920x1080 at 60 fps; the
-- score and every effect are the original's, written by its arm-soundtrack
-- (examples/fframes/fetch.sh runs it).
--
--     onimite render examples/fframes/arm/video.lua -o arm.mp4
--
-- arm.lua: the robot and its inverse kinematics; lab.lua: the lab, its textures and its
-- lights; studio.sksl: the studio light; story.lua: the performance and the throw. README.md
-- says where the film differs from the original.

local A = require("arm")
local L = require("lab")
local S = require("story")

local W, H, FPS = 1920, 1080, 60
-- the word the robot spells, the row it spells it on, and the rack the pieces wait in
local WORD, WORD_Z, RACK_Z = "fframes", 1.25, -1.3
local MONO, INK, ORANGE = "IBM Plex Mono", "#1c1d20", "#ff4a00"
local PI = math.pi
local add, sub, sc, norm = vec3_add, vec3_sub, vec3_scale, vec3_normalize


-- ------------------------------------------------------------------ built once

local letters = S.letters(WORD, WORD_Z, RACK_Z)
local story = S.new(letters, WORD_Z, RACK_Z)
local beats, la = story.beats, story.dropped
local DURATION = beats["end"] + 0.6
local BASE, J, FINGERS = A.parts()
local LAB = L.build(RACK_Z)
-- the letters: lacquered, 10 cm deep, edges rounded 12 mm
local LACQUER = A.mat("#111113", 0.2, 0, { clearcoat = 1, clearcoat_roughness = 0.05 })
for _, l in ipairs(letters) do
  l.mesh = A.M({ type = "ExtrudeGeometry", shape = l.shape, depth = 0.076, bevel_thickness = 0.012,
    bevel_size = 0.0118, bevel_offset = -0.0118, bevel_segments = 2, crease_angle = PI / 4 }, LACQUER, { 0, 0, -0.038 })
end
-- the eye: its lamp, the iris that glows, the lid that blinks; the status light; the base's ring
local LENS = add(A.EYE, { 0, 0, 0.034 })
local IRIS = { type = "CircleGeometry", radius = 0.008, segments = 24 }
local DOT = { type = "SphereGeometry", radius = 0.008, width_segments = 16, height_segments = 8 }
local RING = { type = "TorusGeometry", radius = 0.336, tube = 0.008, radial_segments = 8, tubular_segments = 128 }
local function glow(color, intensity)
  return A.mat("#111111", 0.5, 0, { emissive = color, emissive_intensity = intensity })
end
-- the eye's beam in the dark: 16 cones inside each other, each fading along its length (the
-- beam image) and glowing a 16th of 5% of the eye
local BEAM = { geometry = { type = "CylinderGeometry", radius_top = 0.004, radius_bottom = 0.804, height = 2.6,
  radial_segments = 32, open_ended = true }, position = add(LENS, { 0, 0, 1.3 }), rotation = { -PI / 2, 0, 0 }, instances = {} }
for k = 0, 15 do BEAM.instances[k + 1] = { scale = { 1 - k / 16, 1, 1 - k / 16 } } end
-- the dust in the beam: 144 motes a cubic metre in four boxes along it, lit by the lamp with
-- the square of the distance (each as bright as 3 times its light, as opaque as its light)
local DUST, DUST_LIGHT = {}, {}
for k, d in ipairs { 0.4, 0.9, 1.5, 2.2 } do
  local r = math.tan(math.rad(13)) * d
  DUST[k] = { rate = 144 * (2 * r) ^ 2 * d * 0.5 / 6, lifetime = 6, seed = k, position = add(LENS, { 0, 0, d }),
    spread = { r, r, d * 0.25 }, velocity = { 0, -0.01, 0 }, velocity_spread = 0.02, size = 0.016, color = "#ffd6a8",
    map = "dot", additive = true }
  DUST_LIGHT[k] = 1 / (1 + d * d)
end
-- the sparks where the "a" hits the floor
local SPARKS = {}
for i, c in ipairs(story.impacts) do
  if c.speed > 0.8 then
    local v = c.speed * 0.9
    SPARKS[#SPARKS + 1] = { rate = 0, bursts = { { t = c.t, count = math.floor(c.speed * 12) } }, seed = i,
      position = { c.at[1], 0.01, c.at[3] }, velocity = { 0, 0.3 + 0.45 * v, 0 },
      velocity_spread = { 0.65 * v, 0.35 * v, 0.65 * v }, gravity = { 0, -9.8, 0 }, lifetime = 0.65,
      size = 0.014, size_end = 0.006, color = "#fff2c0", color_end = "#ff5a10", opacity_end = 0, map = "dot", additive = true }
  end
end

-- ------------------------------------------------------------------ the story at t

local SHOW_OFF, REACTION = letters[3].placed + 0.45, beats.drop + 1.25
local R_START, LAST = letters[3].placed - 1.2, letters[7].placed

-- the light level of the lab: off, a flicker, then on
local function lights(t)
  local x = t - beats.lights
  if x < 0 then return 0 end
  if x < 0.35 then
    local n = 0
    for _, f in ipairs { 0, 0.06, 0.12, 0.2, 0.27 } do if x >= f then n = n + 1 end end
    return n % 2 == 1 and 0.75 or 0.08
  end
  return smoothstep(0.35, 0.6, x) * 0.25 + 0.75
end
-- how open the eye is: it opens after the boot and blinks
local function lid(t)
  local blink = 0
  for _, b in ipairs(story.blinks) do blink = math.max(blink, 1 - smoothstep(0, 0.07, math.abs(t - b))) end
  return smoothstep(beats.wake + 0.6, beats.wake + 1.0, t) * (1 - blink)
end

-- ------------------------------------------------------------------ the cameras

-- the mean of a point of the arm over the last 0.2 s, so that the cameras follow smoothly
local function lagged(t, point)
  local s = { 0, 0, 0 }
  for k = 0, 4 do s = add(s, point((S.sample(math.max(t - k * 0.05, 0))))) end
  return sc(s, 0.2)
end
local function tip(q) return (mat4_decompose(A.tip(q))) end
-- a camera and its depth of field: sharp at `focus` (a point or a distance), `blur` px at the
-- far end
local function cam(fov, position, target, focus, blur)
  return { type = "PerspectiveCamera", fov = fov, near = 0.05, far = 500, position = position, target = target },
    { focus = focus, blur = blur / H }
end
local function orbit(target, d, az, el)
  az, el = math.rad(az), math.rad(el)
  return add(target, sc({ math.sin(az) * math.cos(el), math.sin(el), math.cos(az) * math.cos(el) }, d))
end
-- each hit of the letter on the floor turns the camera by up to its speed x 0.35 degrees
local function shake(c, t)
  local amount = 0
  for _, h in ipairs(story.impacts) do
    if t >= h.t then amount = amount + 0.35 * h.speed * math.exp(-(t - h.t) * 10) end
  end
  local f = norm(sub(c.target, c.position))
  local right = norm(vec3_cross(f, { 0, 1, 0 }))
  local yaw, pitch = math.rad(amount * noise(t * 18, 1)), math.rad(amount * noise(t * 18, 2))
  c.target = add(c.position, add(add(sc(f, math.cos(yaw) * math.cos(pitch)), sc(right, -math.sin(yaw))),
    sc(vec3_cross(right, f), math.sin(pitch))))
  return c
end

-- the cut list: one camera for each part of the story
local function camera(t)
  if t < beats.work then
    -- hello: a low camera at the front right; the robot looks into this lens
    local x, e = progress(t, 0, beats.work), lagged(t, A.eye)
    local position = add(S.HELLO, { 0.25 * (1 - x), 0.05 * x, 0.35 * (1 - x) })
    return cam(30, position, vec3_lerp(e, { 0, 0.9, 0.6 }, 0.35), e, 5)
  elseif t < R_START then
    -- work: a slow orbit that follows the gripper
    local x, p = progress(t, beats.work, R_START), lagged(t, tip)
    local target = vec3_lerp({ 0, 0.75, 0.2 }, p, 0.25)
    return cam(32, orbit(target, 5.4 - 0.4 * x, -42 + 24 * x, 13), target, p, 8)
  elseif t < SHOW_OFF then
    -- low at the word when the r arrives
    local target = { -0.35, 0.33, WORD_Z }
    return cam(30, { 1.35, 0.42, 3.15 }, target, target, 12)
  elseif t < REACTION then
    -- wide for the swing and the throw, shaken by the hits
    local x = progress(t, SHOW_OFF, REACTION)
    local c, focus = cam(36, { 3.7 - 0.3 * x, 1.75, 4.4 - 0.3 * x }, { -0.25, 0.75, 0.25 }, 5.6, 5)
    return shake(c, t), focus
  elseif t < beats.recover then
    -- close on the eye; the robot looks into the lens
    local e = lagged(t, A.eye)
    return cam(28, S.GUILTY, vec3_lerp(e, { -0.2, 0.6, 0.6 }, 0.15), e, 14)
  elseif t < beats.finish then
    -- low near the fallen letter while the robot moves over carefully
    local letter = mat4_decompose(S.world(story, la, t))
    local target = vec3_lerp(letter, lagged(t, tip), 0.4)
    return cam(34, { 2.9, 0.75, 2.9 }, add(target, { 0, 0.1, 0 }), target, 9)
  elseif t < LAST + 0.3 then
    -- high and wide for the fast work
    local x = progress(t, beats.finish, LAST + 0.3)
    return cam(32, orbit({ 0, 0.55, 0.35 }, 6.4, 28 - 18 * x, 24 - 4 * x), { 0, 0.55, 0.35 }, 6.4, 4)
  end
  -- the word, with the robot behind it as it bows
  local x = smoothstep(LAST + 0.3, beats["end"], t)
  return cam(30, add(S.FINAL, { 0, -0.05 * x, -0.5 * x }), { 0, 0.92, 0.55 }, S.FINAL[3] - WORD_Z - 0.5 * x, 6)
end

-- ------------------------------------------------------------------ a moment: the scene at t

-- The lab at t. Returns the camera.
local function moment(t)
  local q, gap = S.sample(t)
  local level = lights(t)
  local c, dof = camera(t)
  local world = A.joints_world(q)
  local booting = smoothstep(beats.wake, beats.wake + 0.5, t)
  -- the eye flickers when it comes on; it glows up to 7
  local waking = t >= beats.wake + 0.5 and t < beats.wake + 0.8
  local flicker = (waking and hash(math.floor((t - beats.wake) * 40), 5) > 0.5) and 0.3 or 1
  local iris = 7 * smoothstep(beats.wake + 0.5, beats.wake + 0.8, t) * flicker
  local open = clamp01(lid(t))
  local ring = 0.8 + booting * (2.2 + 0.8 * math.max(math.sin(t * 2), 0)) + 3 * smoothstep(beats.tada, beats.tada + 0.3, t)
  local beam = clamp01(1 - level) * iris * open

  -- the letters: in the gripper (in J6) or in the world
  local carrying, held, placed = false, {}, {}
  for _, l in ipairs(letters) do
    local p = S.phase(l, t)
    if p.carried then
      carrying = true
      local position, rotation = mat4_decompose(mat4_multiply(mat4_compose({ 0, 0, A.GRIP }), p.carried))
      held[#held + 1] = { position = position, rotation = rotation, meshes = { l.mesh } }
    else
      local position, rotation = mat4_decompose(S.world(story, l, t))
      placed[#placed + 1] = { position = position, rotation = rotation, meshes = { l.mesh } }
    end
  end
  gap = clamp(gap, 0, A.OPEN)
  held[#held + 1] = { position = { -gap, 0, 0 }, meshes = FINGERS[1] }
  held[#held + 1] = { position = { gap, 0, 0 }, meshes = FINGERS[2] }
  -- J6: the status light, the eye, the gripper, the beam and the dust in it
  local j6 = {
    A.M(DOT, glow(ORANGE, carrying and 7 or 0.5 * booting), { 0.11, -0.043, 0.09 }),
    A.M(IRIS, glow("#ffb070", iris), add(A.EYE, { 0, 0, 0.0325 }), nil, { scale = { 1, math.max(open, 0.05), 1 } }),
    A.rbox(0.056, 0.03, 0.006, 0.003, 1, A.P.graphite, add(A.EYE, { 0, 0.012 + 0.018 * open, 0.036 }), nil,
      { scale = { 1, 1 - 0.7 * open, 1 } }),
  }
  for _, m in ipairs(J[6]) do j6[#j6 + 1] = m end
  local dust = {}
  if beam > 0 then
    j6[#j6 + 1] = merge(BEAM, { material = { type = "MeshBasicMaterial", color = "#ffd6a8", map = "beam",
      blending = "additive", opacity = beam * 0.05 / 16 } })
    for k, d in ipairs(DUST) do
      local light = DUST_LIGHT[k] * beam / 7
      dust[k] = merge(d, { opacity = math.min(3 * light * light, 1), time = t + 6 })
    end
  end
  local g = { position = A.JOINT_AT[6], rotation = A.joint_euler(q, 6), meshes = j6, groups = held, particles = dust }
  for i = 5, 1, -1 do
    g = { position = A.JOINT_AT[i], rotation = A.joint_euler(q, i), meshes = J[i], groups = { g } }
  end
  local base = { A.M(RING, glow(ORANGE, ring), { 0, 0.385, 0 }, { PI / 2, 0, 0 }) }
  for _, m in ipairs(BASE) do base[#base + 1] = m end
  placed[#placed + 1] = { meshes = base, groups = { g } }

  local meshes = A.spring(world)
  for _, m in ipairs(LAB) do meshes[#meshes + 1] = m end
  local sparks = {}
  for k, s in ipairs(SPARKS) do sparks[k] = merge(s, { time = t }) end
  L.STRIPS.emissive_intensity = 2.2 * level
  local lamps, air = L.lights(level)
  local lens = vec3_apply_mat4(LENS, world[6])
  local _, _, axis = mat4_extract_basis(world[6])
  lamps[#lamps + 1] = { type = "SpotLight", color = "#ffd6a8", intensity = iris * open * 0.55, position = lens,
    target = add(lens, axis), angle = math.rad(17), penumbra = 0.55, decay = 2 }
  lamps[#lamps + 1] = { type = "PointLight", color = ORANGE, intensity = ring * 0.08, position = { 0, 0.385, 0 },
    distance = 1.6, decay = 2 }
  local view = { x = 0, y = 0, w = W, h = H, camera = c, background = air,
    fog = { type = "FogExp2", color = air, density = 0.045 },
    tone_mapping = "neutral", tone_mapping_exposure = 0.92, bloom = { threshold = 0.95, intensity = 0.4, radius = 24 },
    depth_of_field = dof,
    environment = L.STUDIO, environment_intensity = L.STUDIO_PEAK * 0.6 * math.max(level, 0.04), reflector = L.REFLECTOR,
    lights = lamps, meshes = meshes, groups = placed, particles = sparks }
  view3d(view)
  return c
end

-- ------------------------------------------------------------------ the overlay

-- a bracket on the thrown letter while it lies on the floor, pinned to it
local function marker(t, c)
  local p = S.phase(la, t)
  local shown = smoothstep(beats.drop + 0.3, beats.drop + 0.5, t)
  if not (p.falling or (p.still and not p.placed)) or shown <= 0 then return end
  local center = vec3_apply_mat4(la.center, S.world(story, la, t))
  local at = view3d_project(c, center, { width = W, height = H })
  if not at.in_front then return end
  local depth = vec3_dot(sub(center, c.position), norm(sub(c.target, c.position)))
  local s = 0.42 / (2 * depth * math.tan(math.rad(c.fov) / 2)) * H
  local x0, y0, x1, y1, k = at.x - s / 2, at.y - s / 2, at.x + s / 2, at.y + s / 2, math.max(s * 0.22, 8)
  local away = vec3_distance(center, vec3_apply_mat4(la.center, la.slot))
  group({ opacity = shown }, function()
    path { d = string.format("M%f %f V%f H%f M%f %f H%f V%f M%f %f V%f H%f M%f %f H%f V%f", x0, y0 + k, y0, x0 + k,
      x1 - k, y0, x1, y0 + k, x1, y1 - k, y1, x1 - k, x0 + k, y1, x0, y1 - k), fill = "none", stroke = ORANGE,
      stroke_width = 2.5 }
    text { 'PIECE 04  "a"', x = x1 + 12, y = y0 + 14, font = MONO, weight = 600, size = 15, letter_spacing = 2, fill = ORANGE }
    text { string.format("%.2f M FROM SLOT", away), x = x1 + 12, y = y0 + 34, font = MONO, size = 13,
      letter_spacing = 1.5, fill = ORANGE }
  end)
end

-- the console, the counter, the caption and the fades
local function overlay(t)
  local placed = 0
  for _, l in ipairs(letters) do if S.phase(l, t).placed then placed = placed + 1 end end
  -- the console is dark ink; it shows once the lab is lit
  local ui = smoothstep(beats.lights, beats.lights + 0.4, t) * (1 - smoothstep(beats["end"] - 0.6, beats["end"], t))
  group({ opacity = ui }, function()
    local function line(s, x, y, o)
      text(merge({ s, x = x, y = y, font = MONO, weight = 600, size = 14, letter_spacing = 3, fill = INK }, o))
    end
    line("OD-ARM 7.2", 96, 100)
    line("LAB 3  /  CELL R-07", 96, 122, { opacity = 0.5 })
    line(string.format("%02d / %02d", placed, #letters), 1824, 100, { align = "right" })
    line("PIECES IN PLACE", 1824, 122, { align = "right", opacity = 0.5 })
    -- the last five lines type out, the newest at the bottom with a cursor
    local shown = {}
    for _, l in ipairs(story.log) do if l.t <= t then shown[#shown + 1] = l end end
    local first = math.max(#shown - 4, 1)
    local n = #shown - first + 1
    for i = first, #shown do
      local l, k = shown[i], i - first
      local cursor = (k == n - 1 and fract(t * 2.5) < 0.5) and "_" or ""
      line("> " .. l.text:sub(1, math.floor((t - l.t) * 45)) .. cursor, 96, 1000 - (n - 1 - k) * 24,
        { weight = 400, size = 15, letter_spacing = 1.5, fill = l.alert and ORANGE or INK, opacity = 0.35 + 0.65 * (k + 1) / n })
    end
  end)
  group({ opacity = smoothstep(beats.tada + 0.3, beats.tada + 0.8, t) }, function()
    rect { x = 938, y = 968, w = 44, h = 2, fill = ORANGE }
    text { "BUILT WITH FFRAMES-3D", x = 960, y = 1004, align = "center", font = MONO, size = 13, letter_spacing = 6,
      fill = INK, opacity = 0.6 }
  end)
  local black = math.max(1 - smoothstep(0, 0.4, t), smoothstep(DURATION - 0.5, DURATION, t))
  rect { x = 0, y = 0, w = W, h = H, fill = "#000000", opacity = black }
end

-- ------------------------------------------------------------------ the sound

local GAINS = { lights = -4, boot = -16, blink = -16, curious = -15, happy = -16, grip = -10, place = -5, whoosh = -16,
  scratch = -4, uhoh = -13, sigh = -14, pat = -9, proud = -15, tada = -14 }
local tracks = { { "music.wav", start = 0, gain_db = -4 }, { "room.wav", start = 0, gain_db = -18, fade_in = 0.5 },
  { "servos.wav", start = 0, gain_db = -11 } }
for _, s in ipairs(story.sounds) do
  tracks[#tracks + 1] = { s.name .. ".wav", start = math.max(s.t, 0), gain_db = s.gain or GAINS[s.name] }
end

video { width = W, height = H, fps = FPS, duration = { frames = math.floor(DURATION * FPS + 1e-4) },
  background = "#000000", audio = tracks, master_gain_db = 6.5, limiter = { ceiling_db = -1.3 },
  render = function(f)
    local c = moment(f.seconds)
    marker(f.seconds, c)
    overlay(f.seconds)
  end }
