-- A program of passes in two dialects: an SkSL trail that reads its own
-- last frame (feedback) and a GLSL pass that colours it.
--
--     onimite render examples/shader_passes/video.lua -o passes.mp4
--
-- `trail` (SkSL) draws this frame's dots, a group input the script draws,
-- over its own last frame, swirled and faded. `show` (GLSL) reads this
-- frame's trail and maps its density through a palette; it is the last
-- pass, so it is drawn.

local W, H = 1280, 720

-- Five dots on Lissajous paths.
local function dots(t)
  for i = 0, 4 do
    local x = W / 2 + 420 * math.sin(t * (0.9 + 0.13 * i) + i * 1.3)
    local y = H / 2 + 230 * math.sin(t * (1.3 + 0.07 * i) + i * 2.1)
    circle { cx = x, cy = y, r = 14, fill = "#fff" }
  end
end

video { width = W, height = H, fps = 30, duration = 6, background = "#06070b",
  render = function(f)
    local t = f.index / f.fps
    shader(f, { x = 0, y = 0, w = W, h = H,
      passes = {
        { name = "trail", src = "shaders/trail.sksl",
          inputs = { uLast = "trail", uDots = function() dots(t) end } },
        { name = "show", src = "shaders/show.frag", inputs = { uTrail = "trail" } },
      },
      uniforms = { uFade = 0.965 } })
  end,
}
