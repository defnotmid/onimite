local look = require("look")
local fx = require("fx")
local score = require("music.score")
local sfx = require("sfx")
local family = require("scenes.family")
local snap = look.snap


local SNIP = {
  { "void mainImage(out vec4 c, in vec2 p) {", look.INK }, { "  vec2 uv = p / iResolution.xy;", look.CYAN },
  { "  c = vec4(tunnel(uv), 1.0);", look.LEMON }, { "}", look.INK },
}

local function oksl(f, lb, gb)
  fx.pop(f, 2, "#ffe14d", "#ff6a3d", "#ff2d95", look.kick(gb))
  family.left(lb, "built on our own · 3/3 · ../oksl", "OKSL", { "A shader compiler inside your binary.", "SkSL and Shadertoy GLSL." },
    { "no glslang", "no shaderc", "no SPIRV-Cross", "hot reload" }, look.NIGHT)
  family.frame(lb, look.LEMON)
  local s = snap(lb - 0.5)
  group({ clip = { x = family.PANEL.x + 8, y = family.PANEL.y + 8, w = family.PANEL.w - 16, h = family.PANEL.h - 16, rx = 38 }, opacity = clamp01(s * 3) }, function()
    fx.tunnel(f, { x = family.PANEL.x, y = family.PANEL.y, w = family.PANEL.w, h = 380 })
    for i, l in ipairs(SNIP) do
      local p = progress(lb, 1 + i * 0.35, 1.4 + i * 0.35)
      text { l[1], x = family.PANEL.x + 40, y = family.PANEL.y + 440 + (i - 1) * 40, font = look.MONO, size = 25, fill = l[2], opacity = p }
    end
    local OUT = { { "SPIR-V", "Vulkan" }, { "MSL", "Metal" }, { "CPU", "no GPU at all" } }
    for i, o in ipairs(OUT) do
      local p = snap(lb - (3 + (i - 1) * 0.5))
      if p > 0.001 then
        local x = family.PANEL.x + 40 + (i - 1) * 250
        group({ opacity = clamp01(p * 3), transform = { scale = 0.7 + 0.3 * p, origin = { x + 110, family.PANEL.y + 680 } } }, function()
          rect { x = x, y = family.PANEL.y + 620, w = 230, h = 120, rx = 24, fill = "#1a1d30", stroke = look.LEMON, stroke_width = 2 }
          text { "→ " .. o[1], x = x + 24, y = family.PANEL.y + 676, font = look.MONO, size = 32, fill = look.LEMON }
          text { o[2], x = x + 24, y = family.PANEL.y + 716, font = look.MONO, size = 20, fill = look.DIM }
        end)
      end
    end
    local p = snap(lb - 5.5)
    if p > 0.001 then
      group({ opacity = clamp01(p * 3), transform = { scale = 0.7 + 0.3 * p, origin = { family.PANEL.x + family.PANEL.w / 2, family.PANEL.y + 790 } } },
        function()
          text { "GPU = CPU, pixel for pixel", x = family.PANEL.x + family.PANEL.w / 2, y = family.PANEL.y + 785, align = "center",
            font = look.MONO, size = 30, fill = look.O }
        end)
    end
  end)
end

-- Its sounds (sfx.lua), in beats into the scene.
local SOUNDS = { sfx.at("oksl", 5.5, sfx.done(), 0.16) } -- the equation holds
for i = 1, 3 do -- a blip per output
  SOUNDS[#SOUNDS + 1] = sfx.at("oksl", 3 + (i - 1) * 0.5, sfx.blip(880 * 2 ^ ((i - 1) * 3 / 12)), 0.14)
end

local AT = score.time("oksl")
scene { "OKSL", cue = "oksl", start = AT, audio = SOUNDS, render = function(f)
  local gb = score.beat(f)
  oksl(f, gb - score.beat(AT), gb)
end }
