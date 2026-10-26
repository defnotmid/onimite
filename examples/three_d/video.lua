-- 3D in three.js's terms: view3d{} draws a scene (a camera, lights,
-- meshes with materials) into a box that composites like any layer, here
-- over a 2D gradient and under a 2D title card.
--
--     onimite render examples/three_d/video.lua -o three_d.mp4
--
-- The camera orbits through `animate`; the cube and the torus spin and the
-- ball bounces through their transforms (rotation, position), never through
-- their geometry's parameters: o3d keeps one mesh per set of parameters.
-- Two meshes use custom GLSL ES `ShaderMaterial`s (one displacing vertices
-- along their normals, one animating bands in the fragment shader).
-- media/sky.png (generated) lights the scene as an environment map, so the
-- metal ball has something to reflect; media/checker.png (generated) is the
-- floor's texture, the floor a flat cylinder. A label lies on the floor:
-- an outline as ShapeGeometry in a transparent material, drawn from its
-- curves, so its edges stay clean as the orbit lowers it toward grazing.

local W, H = 1280, 720
local TAU = 2 * math.pi
local LABEL = outline { "view3d", font = "Instrument Serif", italic = true, size = 1.1, align = "center", baseline = "middle" }

local WAVE_VERT = [[
varying vec3 vNormal;
varying vec2 vUv;
uniform float uTime;
uniform float uAmount;
void main() {
  vNormal = normalize(normalMatrix * normal);
  vUv = uv;
  vec3 p = position + normal * (uAmount * sin(uTime * 3.0 + position.y * 6.0));
  gl_Position = projectionMatrix * modelViewMatrix * vec4(p, 1.0);
}
]]

local WAVE_FRAG = [[
varying vec3 vNormal;
varying vec2 vUv;
uniform vec3 uColor;
void main() {
  float l = 0.35 + 0.65 * max(dot(normalize(vNormal), normalize(vec3(0.4, 0.8, 1.0))), 0.0);
  gl_FragColor = vec4(uColor * l + vec3(vUv * 0.12, 0.0), 1.0);
}
]]

local PULSE_VERT = [[
varying vec3 vNormal;
varying vec2 vUv;
void main() {
  vNormal = normalize(normalMatrix * normal);
  vUv = uv;
  gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
}
]]

local PULSE_FRAG = [[
varying vec3 vNormal;
varying vec2 vUv;
uniform float uTime;
uniform vec3 uColorA;
uniform vec3 uColorB;
void main() {
  float band = 0.5 + 0.5 * sin(vUv.y * 18.0 - uTime * 4.0);
  float l = 0.4 + 0.6 * max(dot(normalize(vNormal), normalize(vec3(0.5, 0.9, 0.6))), 0.0);
  gl_FragColor = vec4(mix(uColorA, uColorB, band) * l, 1.0);
}
]]

video { width = W, height = H, fps = 60, background = "#101218", duration = 6,
  render = function(f)
    local t = f.seconds
    rect { x = 0, y = 0, w = W, h = H,
      fill = linear_gradient { x1 = 0, y1 = 0, x2 = 0, y2 = H, stops = { { 0, "#1b2333" }, { 1, "#0b0c10" } } } }

    -- A third of a turn around the scene, easing in and out.
    local orbit = animate(f, { { start = 0, stop = 6, from = -0.6, to = TAU / 3 - 0.6, easing = ease_in_out } })
    local spin = t * 1.4
    local bounce = math.abs(math.sin(t * 2.6)) * 0.9

    view3d {
      camera = { type = "PerspectiveCamera", fov = 38,
        position = { 8.6 * math.sin(orbit), 3.9, 8.6 * math.cos(orbit) }, target = { 0, 0.3, 0 } },
      environment = "sky.png", environment_intensity = 0.6,
      lights = {
        { type = "HemisphereLight", color = "#dbe6ff", ground_color = "#3b3034", intensity = 0.8 },
        { type = "DirectionalLight", color = "#fff1dc", intensity = 2.6, position = { 4, 7, 3 },
          cast_shadow = true, shadow = { map_size = 1024, height = 9, bias = -0.0005, normal_bias = 0.02 } },
        { type = "PointLight", color = "#ff7a3d", intensity = 5, position = { -1.2, 1.4, 1.6 }, distance = 6 },
      },
      meshes = {
        { geometry = { type = "CylinderGeometry", radius_top = 4, radius_bottom = 4, height = 0.2, radial_segments = 96 },
          position = { 0, -0.1, 0 }, material = { map = "checker.png", roughness = 0.85 }, receive_shadow = true },
        { geometry = { type = "ShapeGeometry", shape = LABEL }, position = { 0.2, 0.005, 2.9 }, rotation = { -TAU / 4, 0, 0 },
          material = { type = "MeshBasicMaterial", color = "#1b2333", opacity = 0.8, transparent = true } },
        { geometry = { type = "BoxGeometry", width = 1, height = 1, depth = 1 },
          position = { -1.8, 0.5, 0.2 }, rotation = { 0, spin, 0 },
          material = { color = "#ff5a4d", roughness = 0.35 }, cast_shadow = true, receive_shadow = true },
        { geometry = { type = "SphereGeometry", radius = 0.6 }, position = { 0, 0.6 + bounce, 0.4 },
          material = { color = "#f2f2f7", metalness = 1, roughness = 0.2 }, cast_shadow = true },
        { geometry = { type = "TorusGeometry", radius = 0.5, tube = 0.18, radial_segments = 24, tubular_segments = 64 },
          position = { 1.8, 0.75, 0 }, rotation = { spin, spin * 0.5, 0 },
          material = { color = "#4dd6ff", roughness = 0.4, emissive = "#0a3d55" }, cast_shadow = true, receive_shadow = true },
        { geometry = { type = "CylinderGeometry", radius_top = 0, radius_bottom = 0.45, height = 1.1 },
          position = { -0.6, 0.55, -1.9 }, material = { type = "MeshBasicMaterial", color = "#ffd54d" }, cast_shadow = true },
        { geometry = { type = "SphereGeometry", radius = 0.5, width_segments = 48, height_segments = 24 },
          position = { 0.85, 0.5, 1.8 },
          material = { type = "ShaderMaterial", vertex_shader = WAVE_VERT, fragment_shader = WAVE_FRAG,
            uniforms = { uTime = t, uColor = "#ff00aa", uAmount = 0.06 } },
          cast_shadow = true },
        { geometry = { type = "CylinderGeometry", radius_top = 0.35, radius_bottom = 0.35, height = 1.1 },
          position = { -1.9, 0.55, -1.2 },
          material = { type = "ShaderMaterial", vertex_shader = PULSE_VERT, fragment_shader = PULSE_FRAG,
            uniforms = { uTime = t, uColorA = "#38bdf8", uColorB = "#a855f7" } },
          cast_shadow = true },
      },
    }

    -- 2D on top: a title card fading in.
    local a = animate(f, { { start = 0.3, stop = 1.1, from = 0, to = 1, easing = ease_out } })
    group({ opacity = a }, function()
      rect { x = 48, y = 48, w = 380, h = 112, rx = 16, fill = rgba(10, 12, 18, 0.72) }
      text { "view3d", x = 76, y = 108, font = "DM Sans", size = 44, weight = 700, fill = "#ffffff" }
      text { "three.js terms, composited in 2D", x = 76, y = 140, font = "DM Sans", size = 20, fill = "#9aa4b8" }
    end)
  end }

