local look = require("look")
local fx = require("fx")
local C = require("cues")
local family = require("scenes.family")
local snap = look.snap


local function star(cx, cy, R, r, rot)
  local pts = {}
  for i = 0, 9 do
    local a = (i * 36 + rot - 90) * math.pi / 180
    local rr = i % 2 == 0 and R or r
    pts[#pts + 1] = string.format("%s%f %f", i == 0 and "M" or "L", cx + math.cos(a) * rr, cy + math.sin(a) * rr)
  end
  return table.concat(pts, " ") .. " Z"
end

local function ovg(f, lb, gb)
  fx.pop(f, 0, "#ff2d95", "#8a5cff", "#ffe14d", look.kick(gb))
  family.left(lb, "built on our own · 1/3 · ../ovg", "OVG", { "A 2D vector canvas for Odin.", "Femtovg, grown way past it." },
    { "Vulkan · Metal · D3D12", "software fallback", "every SVG filter", "Lottie + SVG in", "shaped text" }, look.LEMON)
  family.frame(lb, look.PINK)
  local s = snap(lb - 0.5)
  group({ clip = { x = family.PANEL.x + 8, y = family.PANEL.y + 8, w = family.PANEL.w - 16, h = family.PANEL.h - 16, rx = 38 }, opacity = clamp01(s * 3) }, function()
    local cx, cy = family.PANEL.x + family.PANEL.w / 2, family.PANEL.y + 330
    -- a gradient star, dashed outline drawing on, with orbiting blended discs
    local grad = linear_gradient { x1 = cx - 200, y1 = cy - 200, x2 = cx + 200, y2 = cy + 200,
      stops = { { 0, look.PINK }, { 0.5, look.VIOLET }, { 1, look.CYAN } } }
    local rot = gb * 12
    path { d = star(cx, cy, 230, 100 + 30 * look.kick(gb), rot), fill = grad }
    path { d = star(cx, cy, 262, 124, -rot), fill = "none", stroke = look.LEMON, stroke_width = 5, path_length = 1,
      stroke_dasharray = { 0.5, 0.5 }, stroke_dashoffset = -gb * 0.12, line_join = "round" }
    for i = 0, 2 do
      local a = gb * 0.6 + i * 2.094
      group({ blend = "screen" }, function()
        circle { cx = cx + math.cos(a) * 250, cy = cy + math.sin(a) * 250, r = 90,
          fill = ({ look.PINK, look.CYAN, look.LEMON })[i + 1], opacity = 0.9 }
      end)
    end
    -- shaped text bent by SVG turbulence on the GPU
    group({ filter = { { "turbulence", type = "fractalNoise", base_frequency = 0.012, octaves = 2, seed = 3, result = "n" },
      { "displacement_map", input = "SourceGraphic", input2 = "n", scale = 40 + 50 * look.kick(gb), x_channel = "R", y_channel = "G" },
      region = { x = family.PANEL.x, y = family.PANEL.y + 640, w = family.PANEL.w, h = 170, units = "userSpaceOnUse" } } }, function()
      text { "office  مرحبا", x = cx, y = family.PANEL.y + 760, align = "center", font = look.SERIF, italic = true, size = 130,
        fill = look.INK }
    end)
  end)
end

scene { "OVG", cue = "OVG", start = C.time(C.OVG), render = function(f)
  local gb = C.beat(f)
  ovg(f, gb - C.OVG, gb)
end }
