-- A downloaded, skinned glTF model in view3d{}: the Khronos glTF sample Fox
-- (media/Fox.glb; model CC0 by PixelMannen, rigging and animations CC-BY 4.0
-- by @tomkranis, from github.com/KhronosGroup/glTF-Sample-Assets). Its three
-- clips, then Run again under a ShaderMaterial override on the whole model.
video { width = 1280, height = 720, fps = 60, background = "#14161c", motion_blur = { shutter = 180 } }

-- Iridescent stripes that flow along the body, plus a breathing swell (on the
-- skinned pose): each vertex pushed out from low in the body by a wave that
-- runs along it. By position alone, not along the normals: the fox is
-- flat-shaded, its faces sharing corners but not normals, and pushing each
-- along its own face's normal would part them.
local TRIP_VERT = [[
varying vec3 vNormal;
varying vec3 vPos;
uniform float uTime;
const vec3 MIDDLE = vec3(0.0, 15.0, -10.0);   // in the model's units: feet at 0, nose to tail along z
void main() {
  vNormal = normalize(normalMatrix * normal);
  vec3 p = position + (position - MIDDLE) * (0.02 + 0.02 * sin(uTime * 4.0 + position.z * 0.08));
  vPos = (modelMatrix * vec4(p, 1.0)).xyz;
  gl_Position = projectionMatrix * modelViewMatrix * vec4(p, 1.0);
}
]]

local TRIP_FRAG = [[
varying vec3 vNormal;
varying vec3 vPos;
uniform float uTime;
void main() {
  vec3 n = normalize(vNormal);
  float band = vPos.x * 3.0 + vPos.y * 5.0 + vPos.z * 2.0 - uTime * 3.0;
  // a palette picked by eye (display colours), as light: a ShaderMaterial writes light
  vec3 col = sRGBTransferEOTF(vec4(0.5 + 0.5 * cos(6.2831 * (band * 0.25 + vec3(0.0, 0.33, 0.67))), 1.0)).rgb;
  float rim = pow(1.0 - abs(dot(n, vec3(0.0, 0.0, 1.0))), 2.0);
  float l = 0.35 + 0.65 * max(dot(n, normalize(vec3(0.4, 0.9, 0.5))), 0.0);
  gl_FragColor = vec4(col * l + rim * vec3(1.0, 0.9, 1.0) * 0.6, 1.0);
}
]]

local CLIPS = {
  { "Survey", "Survey", 3.4 },
  { "Walk", "Walk", 3 },
  { "Run", "Run", 3 },
  { "Shader", "Run", 4 },
}

local function fox(f, label, clip, shader)
  local t = f.seconds * 0.35
  local model = { src = "Fox.glb", animation = clip, time = f.seconds, scale = 0.02,
    rotation = { 0, 0.6, 0 }, cast_shadow = true }
  if shader then
    model.material = { type = "ShaderMaterial", vertex_shader = TRIP_VERT, fragment_shader = TRIP_FRAG,
      uniforms = { uTime = f.seconds } }
  end
  view3d {
    camera = { type = "PerspectiveCamera", fov = 35, target = { 0, 0.7, 0 },
      position = { 5.2 * math.sin(t), 2.4, 5.2 * math.cos(t) } },
    lights = {
      { type = "HemisphereLight", color = "#e6ecff", ground_color = "#3a2f2a", intensity = 1.2 },
      { type = "DirectionalLight", color = "#fff1dc", intensity = 2.8, position = { 3, 6, 2 },
        cast_shadow = true, shadow = { map_size = 2048 } },
    },
    meshes = {
      { geometry = { type = "CylinderGeometry", radius_top = 3, radius_bottom = 3, height = 0.1, radial_segments = 64 },
        position = { 0, -0.05, 0 },
        material = { type = "MeshStandardMaterial", color = "#3d4452", roughness = 0.9 }, receive_shadow = true },
    },
    models = { model },
  }
  group({}, function()
    rect { x = 48, y = 40, w = 330, h = 96, rx = 14, fill = "#0b0d12", opacity = 0.85 }
    text { "Fox.glb", x = 76, y = 92, font = "DM Sans", weight = 700, size = 40, fill = "#f5f5f5" }
    text { label == "Shader" and "Run · ShaderMaterial" or clip, x = 76, y = 122, font = "JetBrains Mono", size = 22, fill = "#7dd3fc" }
  end)
end

for _, c in ipairs(CLIPS) do
  scene { c[1], duration = c[3], render = function(f) fox(f, c[1], c[2], c[1] == "Shader") end }
end
