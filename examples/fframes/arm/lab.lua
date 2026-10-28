-- The lab (fframes' lab.rs): a polished concrete floor that mirrors the scene, the robot
-- cell's paint, the walls, benches with monitors, shelves of bins, the letter rack, the lights
-- and the studio light. The textures the original generates (the concrete's colour, roughness,
-- occlusion and normals, the cell's paint and stencils, the calibration grid, the monitors'
-- screens) are baked when the script loads; the concrete repeats in world space every 2.4 m
-- (two by two slabs).

local A = require("arm")
local L = {}

local PI, TAU = math.pi, 2 * math.pi
local mat, rbox, rboxes = A.mat, A.rbox, A.rboxes
local FONT = "Inter 18pt"


-- ------------------------------------------------------------------ the textures

-- The polished concrete, as lab.rs generates it: the colour (slab tones, mottling, fine
-- noise, specks, scuffs, 4 mm seams), roughness and occlusion, and the normals of the seams
-- and bumps. One GLSL program, `uKind` choosing the map.
local CONCRETE = [[
#version 300 es
precision highp float;
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;
uniform float uKind;
uniform float uSize;
float hash(uint n) {
  uint x = (n * 0x9E3779B9u) ^ 0x85EBCA6Bu;
  x ^= x >> 16u; x *= 0x7FEB352Du; x ^= x >> 15u; x *= 0x846CA68Bu; x ^= x >> 16u;
  return float(x >> 8u) / 16777216.0;
}
float noise(vec2 p, int period, uint seed) {
  vec2 i = floor(p), f = p - i;
  ivec2 c0 = (ivec2(i) % period + period) % period, c1 = (ivec2(i) + 1 + period) % period;
  uint s = seed * 31u;
  uvec2 a = uvec2(c0) * uvec2(7919u, 104729u), b = uvec2(c1) * uvec2(7919u, 104729u);
  float h00 = hash(a.x ^ a.y ^ s), h10 = hash(b.x ^ a.y ^ s), h01 = hash(a.x ^ b.y ^ s), h11 = hash(b.x ^ b.y ^ s);
  vec2 u = smoothstep(0.0, 1.0, f);
  return mix(mix(h00, h10, u.x), mix(h01, h11, u.x), u.y);
}
float fbm(vec2 p, uint seed) {
  float sum = 0.0, amp = 0.5;
  int period = 8;
  for (int o = 0; o < 5; o++) {
    sum += amp * noise(p * float(period), period, seed + uint(o));
    amp *= 0.5;
    period *= 2;
  }
  return sum;
}
float seam(vec2 p) {
  vec2 f = fract(p * 2.0);
  float w = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y)) / 2.0 * 2.4;
  return 1.0 - clamp((w - 0.002) / 0.003, 0.0, 1.0);
}
float height(vec2 p) { return -0.004 * seam(p) + 0.0005 * fbm(p, 3u); }
void main() {
  if (uKind < 0.5) {
    float slab = hash(uint(uv.x * 2.0) * 3u + uint(uv.y * 2.0) * 7u + 11u) * 0.05;
    float speck = hash(uint(uv.x * 900.0) * 977u + uint(uv.y * 900.0)) > 0.985 ? 0.06 : 0.0;
    float scuff = max(fbm(vec2(uv.x * 0.5 + 0.3, uv.y * 2.0), 21u) - 0.6, 0.0) * 0.3;
    float l = 0.52 + slab + (fbm(uv, 3u) - 0.5) * 0.1 + (noise(uv * 256.0, 256, 9u) - 0.5) * 0.04 - speck - scuff;
    float g = floor(clamp(l * (1.0 - 0.35 * seam(uv)) * 255.0, 0.0, 255.0));
    color = vec4(g, floor(min(g * 1.005, 255.0)), floor(min(g * 1.02, 255.0)), 255.0) / 255.0;
  } else if (uKind < 1.5) {
    float r = clamp(0.32 + (fbm(uv + vec2(0.17, 0.41), 13u) - 0.5) * 0.35 + seam(uv) * 0.4, 0.12, 1.0);
    color = vec4(1.0 - 0.6 * seam(uv), r, 0.0, 1.0);
  } else {
    float e = 1.0 / uSize, m = e * 2.4;
    float dx = (height(uv + vec2(e, 0.0)) - height(uv - vec2(e, 0.0))) / (2.0 * m);
    float dz = (height(uv + vec2(0.0, e)) - height(uv - vec2(0.0, e))) / (2.0 * m);
    color = vec4(normalize(vec3(-dx, dz, 1.0)) * 0.5 + 0.5, 1.0);
  }
}]]

-- the monitors' screen: a grid, a trace and a level meter
local SCREEN = [[
#version 300 es
precision highp float;
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;
float line(float d, float w) { return 1.0 - smoothstep(0.0, w, abs(d)); }
void main() {
  float grid = max(line(fract(uv.x * 8.0) - 0.5, 0.06), line(fract(uv.y * 5.0) - 0.5, 0.06));
  float trace = line(uv.y - 0.5 - 0.18 * sin(uv.x * 19.0) * cos(uv.x * 3.0 + 1.0), 0.012);
  float l = min(max(0.1 * grid + trace, (uv.x > 0.86 && uv.y > 0.4) ? 0.8 : 0.0), 1.0);
  color = vec4(floor(vec3(40.0, 190.0, 255.0) * l) / 255.0, 1.0);
}]]

-- the eye's beam fades along its length: bright near the lamp, gone at its end
local BEAM = [[
#version 300 es
precision highp float;
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;
void main() {
  float a = uv.y;
  float f = pow(1.0 - a, 1.6) * smoothstep(0.0, 0.06, a);
  f = f <= 0.0031308 ? f * 12.92 : 1.055 * pow(f, 1.0 / 2.4) - 0.055;
  color = vec4(vec3(f), 1.0);
}]]

-- The cell's floor paint, 6 x 5.05 m at 340 px a metre, x from -3 and z from -2.35: the hazard
-- border, the reach circle, the ring, the output tray and the stencils.
local PAINT_X, PAINT_Z, PAINT_W, PAINT_H, PPM = -3.0, -2.35, 6.0, 5.05, 340
local function paint()
  group({ transform = { matrix = { PPM, 0, 0, PPM, -PAINT_X * PPM, -PAINT_Z * PPM } } }, function()
    -- the hazard border: black, yellow diagonals 30 cm apart
    local border = "M-2.97 -2.29 H2.97 V2.49 H-2.97 Z M-2.83 -2.08 H2.83 V2.28 H-2.83 Z"
    path { d = border, fill = "#161618", fill_rule = "evenodd" }
    local stripes = {}
    for k = -40, 40 do
      local c = k * 0.3
      stripes[#stripes + 1] = string.format("M%f -3 L%f -3 L%f 3 L%f 3 Z", c + 3, c + 3.15, c - 2.85, c - 3)
    end
    group({ clip_path = border, clip_rule = "evenodd" }, function()
      path { d = table.concat(stripes, " "), fill = "#ecb400" }
    end)
    -- the reach: a dashed circle; the base's ring; the output tray
    for i = 0, 47, 2 do
      local a0, a1 = i / 48 * TAU, (i + 1) / 48 * TAU
      line { x1 = math.sin(a0) * 2.05, y1 = math.cos(a0) * 2.05, x2 = math.sin(a1) * 2.05, y2 = math.cos(a1) * 2.05,
        stroke = "#f3f3f0", stroke_width = 0.035 }
    end
    circle { cx = 0, cy = 0, r = 0.64, fill = "none", stroke = "#f3f3f0", stroke_width = 0.04 }
    rect { x = -1.75, y = 0.95, w = 3.5, h = 0.6, fill = "none", stroke = "#f3f3f0", stroke_width = 0.025 }
    -- the stencils: { text, size, x, z, turn }
    for _, s in ipairs { { "R-07", 0.22, 1.15, -0.75, -30 }, { "OUTPUT", 0.13, 1.95, 1.95, 0 },
      { "PARTS", 0.13, 2.1, -1.85, 0 }, { "KEEP CLEAR", 0.11, 0, 2.6, 0 } } do
      text { s[1], x = s[3], y = s[4], align = "center", baseline = "middle", font = FONT, weight = 800, size = s[2],
        fill = "#f3f3f0", transform = rotate(-s[5], s[3], s[4]) }
    end
  end)
end

-- The calibration grid in the tray: 5 cm cells, a thick line every 25 cm, 3.45 x 0.55 m.
local GRID_W, GRID_H = 2048, 326
local function grid()
  rect { x = 0, y = 0, w = GRID_W, h = GRID_H, fill = "#a8aaa7" }
  local s = GRID_W / 3.45
  for i = 0, 69 do
    local w = i % 5 == 0 and 3 or 0.9
    rect { x = i * 0.05 * s - w / 2, y = 0, w = w, h = GRID_H, fill = w > 1 and "#50545a" or "#7c7f80" }
  end
  for i = 0, 11 do
    local w = i % 5 == 0 and 3 or 0.9
    rect { x = 0, y = i * 0.05 * s - w / 2, w = GRID_W, h = w, fill = w > 1 and "#50545a" or "#7c7f80" }
  end
end

-- The textures, drawn once (with mipmaps): a size x size image of the concrete's map `kind`,
-- the paint, the grid, the screens, the beam's fade, the particles' dot and the studio light.
local function concrete(name, kind, size)
  bake { name = name, w = size, h = size, draw = function()
    shader { glsl = CONCRETE, x = 0, y = 0, w = size, h = size, uniforms = { uKind = kind, uSize = size } }
  end }
end
concrete("concrete", 0, 1024)
concrete("concrete_orm", 1, 512)
concrete("concrete_n", 2, 1024)
bake { name = "paint", w = math.floor(PAINT_W * PPM), h = math.floor(PAINT_H * PPM), background = "transparent", draw = paint }
bake { name = "grid", w = GRID_W, h = GRID_H, draw = grid }
bake { name = "screen", w = 256, h = 160, draw = function() shader { glsl = SCREEN, x = 0, y = 0, w = 256, h = 160 } end }
bake { name = "beam", w = 4, h = 256, draw = function() shader { glsl = BEAM, x = 0, y = 0, w = 4, h = 256 } end }
bake { name = "dot", w = 64, h = 64, background = "transparent", draw = function()
  circle { cx = 32, cy = 32, r = 32, fill = radial_gradient { cx = 32, cy = 32, r = 32,
    stops = { { 0, "#ffffff" }, { 0.3, "#ffffff" }, { 0.65, "#7f7f7f" }, { 1, "#00000000" } } } }
end }
-- the studio, relative to its brightest light (3.2): the environment at L.STUDIO_PEAK
L.STUDIO, L.STUDIO_PEAK = bake { name = "studio", w = 1024, h = 512, draw = function()
  shader { src = "studio.sksl", x = 0, y = 0, w = 1024, h = 512 }
end }, 3.2
-- the floor mirrors the scene, as the original's polished concrete does
L.REFLECTOR = { point = { 0, 0, 0 }, normal = { 0, 1, 0 }, scale = 0.5 }

-- ------------------------------------------------------------------ the lab, built once

local function flat(w, h, x, y, z, material) -- a rectangle lying on the floor
  return { geometry = { type = "PlaneGeometry", width = w, height = h }, material = material, position = { x, y, z },
    rotation = { -PI / 2, 0, 0 }, receive_shadow = true }
end
local function box(w, h, d, material, position, extra)
  return merge({ geometry = { type = "BoxGeometry", width = w, height = h, depth = d }, material = material,
    position = position, receive_shadow = true }, extra)
end
L.STRIPS = mat("#ffffff", 0.5, 0, { emissive = "#fff4e6", emissive_intensity = 0 })
function L.build(rack_z)
  local out = {}
  out[#out + 1] = flat(60, 60, 0, 0, 0, { type = "MeshStandardMaterial", roughness = 1, reflector = true,
    environment_intensity = 0.9,
    map = "concrete", normal_map = "concrete_n", roughness_map = "concrete_orm", ao_map = "concrete_orm",
    projection = "world", projection_scale = 1 / 2.4, projection_sharpness = 8 })
  out[#out + 1] = flat(PAINT_W, PAINT_H, PAINT_X + PAINT_W / 2, 0.003, PAINT_Z + PAINT_H / 2,
    { type = "MeshStandardMaterial", map = "paint", transparent = true, roughness = 0.6 })
  out[#out + 1] = flat(3.45, 0.55, 0, 0.0025, 1.25, { type = "MeshStandardMaterial", map = "grid", roughness = 0.7 })
  -- walls far away, with panel seams and light strips
  local wall = mat("#c9ccd0", 0.8)
  out[#out + 1] = box(30, 7, 0.3, wall, { 0, 3.5, -9 })
  out[#out + 1] = box(0.3, 7, 30, wall, { -9, 3.5, 0 })
  local seams = {}
  for i = -6, 6 do seams[#seams + 1] = { position = { i * 2.4, 3.5, -8.84 } } end
  out[#out + 1] = box(0.03, 7, 0.04, mat("#b9bcc0", 0.7), nil, { instances = seams })
  out[#out + 1] = rbox(16, 0.12, 0.05, 0.02, 1, L.STRIPS, { 0, 2.6, -8.82 })
  out[#out + 1] = rbox(0.05, 0.12, 16, 0.02, 1, L.STRIPS, { -8.82, 2.6, 0 })
  -- benches along the back wall, with monitors
  for _, x in ipairs { -4.5, 3.2 } do
    out[#out + 1] = rbox(2.6, 0.06, 0.8, 0.02, 2, mat("#d7d9dc", 0.5), { x, 0.92, -7.9 })
    out[#out + 1] = rbox(2.5, 0.85, 0.7, 0.03, 2, mat("#b4b8bd", 0.6), { x, 0.44, -7.95 })
    out[#out + 1] = rbox(0.5, 0.35, 0.05, 0.02, 2, mat("#1b1c1f", 0.15), { x - 0.6, 1.2, -8.1 })
    local screen = { type = "PlaneGeometry", width = 0.5, height = 0.35 }
    out[#out + 1] = { geometry = screen, position = { x - 0.6, 1.2, -8.074 },
      material = mat("#1b1c1f", 0.15, 0, { emissive = "#ffffff", emissive_intensity = 1.2, emissive_map = "screen" }) }
  end
  -- shelves with parts bins: one instanced mesh, a colour each
  local shelf = mat("#8d9196", 0.45, 1)
  local ys = { 0.3, 0.82, 1.34, 1.86 }
  for _, y in ipairs(ys) do out[#out + 1] = box(4.5, 0.03, 0.5, shelf, { -0.6, y, -8.58 }) end
  for _, x in ipairs { -2.85, -0.6, 1.65 } do out[#out + 1] = box(0.04, 2, 0.5, shelf, { x, 1, -8.58 }) end
  local colors, bins = { "#2f6fd0", "#2f6fd0", "#2f6fd0", "#f2bd00", "#d8422b", "#9ea3a8" }, {}
  for row = 0, 3 do
    for i = 0, 9 do
      if hash(row * 10 + i, 1) > 0.12 then
        local color = colors[math.floor(hash(row * 10 + i, 2) * 6) + 1]
        bins[#bins + 1] = { { -2.6 + i * 0.445 + (i >= 5 and 0.04 or 0), ys[row + 1] + 0.145, -8.55 }, nil, color }
      end
    end
  end
  out[#out + 1] = rboxes(0.4, 0.26, 0.42, 0.02, 2, mat("#ffffff", 0.55), bins)
  -- the letter rack: an aluminium frame on a base plate
  out[#out + 1] = rbox(4.3, 0.02, 0.36, 0.008, 2, mat("#34363b", 0.45, 1), { 0, 0.01, rack_z })
  local alu, rails, posts = mat("#c9ccd1", 0.32, 1), {}, {}
  for _, z in ipairs { rack_z - 0.14, rack_z + 0.14 } do
    rails[#rails + 1] = { { 0, 0.12, z } }
    for i = 0, 7 do posts[#posts + 1] = { { -1.82 + i * 0.52, 0.06, z } } end
    out[#out + 1] = rbox(4.2, 0.006, 0.012, 0.002, 1, mat("#5b5e64", 0.5, 1), { 0, 0.142, z })
  end
  out[#out + 1] = rboxes(4.2, 0.04, 0.04, 0.006, 2, alu, rails)
  out[#out + 1] = rboxes(0.04, 0.12, 0.04, 0.006, 1, alu, posts)
  return out
end

-- The lights at the light `level` (0: dark, 1: lit) and the air: the background and the fog.
function L.lights(level)
  local air = mix_color("#0c1220", "#bfc3c7", level, "linear")
  return {
    { type = "DirectionalLight", color = "#fff6ea", intensity = 2.4 * level, position = { 1.8, 7, 4 },
      target = { 0, 0.5, 0.2 }, cast_shadow = true, shadow = { map_size = 3072 } },
    { type = "DirectionalLight", color = "#cfe0ff", intensity = 0.6 * level, position = { -4, 3, -2 } },
    { type = "HemisphereLight", color = "#f2f4f6", ground_color = "#8a8680", intensity = level + 0.25 },
  }, air
end

return L
