-- Shot titles over the shaders (src/titles.rs).

local M = {}

local SANS, MONO = "DM Sans", "JetBrains Mono"

local function center(s, y, size, color)
  text { s, x = 960, y = y, align = "center", font = SANS, weight = 500, size = size,
    letter_spacing = -1.8, fill = color }
end

local function code(seconds)
  local opacity = math.max(0, math.min(1, (seconds - 0.2) / 0.3))
  text { "fframes / shader mode", x = 76, y = 82, font = MONO, size = 23, fill = "#eeecf8" }
  text { "Skia GPU", x = 1844, y = 82, align = "right", font = MONO, size = 23, fill = "#c1becd" }
  group({ opacity = opacity }, function()
    rect { x = 64, y = 715, w = 1792, h = 301, rx = 10, fill = "#08080d", fill_opacity = 0.88, stroke = "#45414f" }
    path { d = "M64 765H1856 M970 765V1016", stroke = "#39353e" }
    local function line(s, x, y, size, color) text { s, x = x, y = y, font = MONO, size = size, fill = color } end
    line("light.sksl", 95, 748, 20, "#cfc9da")
    line("src/lib.rs", 1006, 748, 20, "#cfc9da")
    line("uniform float iTime;", 95, 818, 25, "#bea4f1")
    line("half4 main(float2 coord) {", 95, 864, 25, "#e5e1ed")
    line("  return half4(light(coord, iTime), 1);", 95, 910, 25, "#afd8d7")
    line("}", 95, 956, 25, "#e5e1ed")
    line("let shader = Shader::sksl(source);", 1006, 818, 25, "#e5e1ed")
    line("let layer = shader.draw(&frame, uniforms);", 1006, 864, 25, "#afd8d7")
    line("svgr!(<image href={layer.href()}", 1006, 910, 25, "#e2c19d")
    line("  width=\"1920\" height=\"1080\" />)", 1006, 956, 25, "#e2c19d")
  end)
end

-- `seconds`: the shot clock (frames since its clock_start, at 30 fps).
function M.render(name, seconds)
  if name == "Glass" then
    group({ transform = translate(1.2, 1.4) }, function() center("FFRAMES HAS SHADERS", 638, 68, "#ff7c51") end)
    group({ transform = translate(-1, -1) }, function() center("FFRAMES HAS SHADERS", 638, 68, "#6989ff") end)
    center("FFRAMES HAS SHADERS", 638, 68, "#f8f8f8")
  elseif name == "Gradient" then
    center("SkSL + SHADERTOY", 576, 64, "#fcf5ff")
  elseif name == "OpenSource" then
    text { "YOURS TO CREATE.", x = 152, y = 278, font = MONO, size = 26, letter_spacing = 3, fill = "#565967" }
    text { "open", x = 142, y = 478, font = SANS, weight = 500, size = 174, letter_spacing = -7, fill = "#171922" }
    text { "source", x = 142, y = 645, font = SANS, weight = 500, size = 174, letter_spacing = -7, fill = "#171922" }
    path { d = "M154 722H222", stroke = "#79758b", stroke_width = 2 }
    text { "Made with fframes.", x = 152, y = 785, font = SANS, size = 32, fill = "#565967" }
  elseif name == "ShaderMode" or name == "SpectralCut" then
    text { "FFRAMES", x = 960, y = 381, align = "center", font = MONO, size = 27, letter_spacing = 4, fill = "#c9c4df" }
    text { "shader mode", x = 960, y = 554, align = "center", font = SANS, weight = 500, size = 152,
      letter_spacing = -6, fill = "#f6f4ff" }
    text { "Your code. In motion.", x = 960, y = 637, align = "center", font = SANS, size = 32,
      letter_spacing = 0.5, fill = "#c9c4df" }
  elseif name == "Code" then
    code(seconds)
  end
end

return M
