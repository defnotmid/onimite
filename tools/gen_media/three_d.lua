-- The three_d example's textures, one frame each (--set texture=sky or
-- texture=checker):
--   sky      a 256x128 equirectangular sky (zenith blue to a warm horizon,
--            a dim ground below, a sun 35 degrees up): the environment
--   checker  a 256x256 floor tile, 8x8 warm greys with soft lines
--
--     onimite frame tools/gen_media/three_d.lua 0 --set texture=sky -o sky.png

local sky = (props.texture or "sky") == "sky"
local W, H = 256, sky and 128 or 256

video { width = W, height = H, fps = 1, duration = 1, render = function(f)
  if sky then
    rect { x = 0, y = 0, w = W, h = H, fill = linear_gradient { x1 = 0, y1 = 0, x2 = 0, y2 = H,
      stops = { { 0, "#4678c8" }, { 0.32, "#8fb0d8" }, { 0.5, "#fad6aa" }, { 0.5, "#786c5c" }, { 1, "#282426" } } } }
    -- Azimuth 40 degrees, elevation 35: x from the left edge (-180), y from the top (+90).
    local sx, sy = (40 + 180) / 360 * W, (90 - 35) / 180 * H
    circle { cx = sx, cy = sy, r = 14, fill = radial_gradient { cx = sx, cy = sy, r = 14,
      stops = { { 0, "#fffaeb" }, { 0.35, "#fff3d6" }, { 1, rgba(255, 243, 214, 0) } } } }
  else
    for row = 0, 7 do
      for col = 0, 7 do
        rect { x = col * 32, y = row * 32, w = 32, h = 32, fill = (row + col) % 2 == 0 and "#a8a096" or "#c4bcb0",
          stroke = "#8c847c", stroke_width = 1 }
      end
    end
  end
end }
