-- Shadertoy multipass: Common + two buffers with feedback + Image.
--
--     onimite render examples/shadertoy_multipass/video.lua -o multipass.mp4
--
-- Buffer A keeps the ink from frame to frame (it reads itself, the previous
-- frame's output): it drifts along a swirl and fades while seven comets and
-- six dots on a turning ring, drawn by the script as a group channel, add
-- colour.
-- Buffer B blurs this frame's ink into a glow; the Image pass composes
-- both. Common holds the palette, the flow and the comet paths every pass
-- shares.
--
-- The shader box is 960x540 units scaled 2x: the buffers have the box's
-- resolution, the Image pass runs at the 1920x1080 on-screen size.

local W, H = 960, 540

-- Six dots on a turning ring: the emitter Buffer A reads as iChannel1.
local function emitter(t, grow)
  for i = 0, 5 do
    local a = t * 0.5 + i * math.pi / 3
    local r = (90 + 40 * math.sin(t * 0.9 + i)) * grow
    circle { cx = W / 2 + r * math.cos(a), cy = H / 2 + r * math.sin(a), r = 13, fill = "#fff" }
  end
end

video { width = 1920, height = 1080, fps = 60, duration = 12, background = "#05060c",
  render = function(f)
    local t = f.index / f.fps
    local grow = animate(f, { { start = 0, stop = 2.5, from = 0.2, to = 1, easing = ease_out } })
    group({ transform = scale(2, 2) }, function()
      shader(f, { x = 0, y = 0, w = W, h = H,
        shadertoy = {
          common = "shaders/common.glsl",
          buffer_a = { src = "shaders/ink.glsl", channels = { "buffer_a", function() emitter(t, grow) end } },
          buffer_b = { src = "shaders/glow.glsl", channels = { "buffer_a" } },
          image = { src = "shaders/image.glsl", channels = { "buffer_a", "buffer_b" } },
        },
        uniforms = { uSwirl = animate(f, { { start = 0, stop = 6, from = 0.35, to = 0.8, easing = ease_in_out } }) } })
    end)
  end,
}
