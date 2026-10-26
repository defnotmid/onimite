-- An SVG asset drawn as vectors and animated by element id.
--
--     onimite render examples/svg_demo/video.lua -o svg_demo.mp4
--
-- media/bird.svg is parsed once when the media loads; each frame draws it
-- with overrides: the wings rotate about their shoulders (in the parts' own
-- coordinates), the sun changes colour, the pupil follows a path. A star
-- from inline markup is parsed once and drawn three times.

local STAR = [[
<svg xmlns="http://www.w3.org/2000/svg" viewBox="-50 -50 100 100">
  <polygon id="star" points="0,-46 13,-15 46,-14 20,7 28,40 0,22 -28,40 -20,7 -46,-14 -13,-15"
           fill="#facc15" stroke="#a16207" stroke-width="4" stroke-linejoin="round"/>
</svg>]]

video { width = 1280, height = 720, fps = 60, background = "#e0f2fe", duration = 4,
  render = function(f)
    local t = f.seconds
    local flap = math.sin(t * math.pi * 3) * 28

    rect { x = 0, y = 520, w = 1280, h = 200, fill = "#bbf7d0" }

    for i = 0, 2 do
      local s = 80 + 20 * math.sin(t * 2 + i)
      svg { markup = STAR, x = 120 + i * 180 - s / 2, y = 120 + i * 60 - s / 2, w = s, h = s,
        opacity = 0.6 + 0.4 * math.sin(t * 3 + i) ^ 2 }
    end

    svg(f, { src = "bird.svg", x = 340, y = 80 + math.sin(t * 2) * 30, w = 800, h = 600,
      overrides = {
        wing = { transform = rotate(-flap, 215, 150) },
        wing_back = { transform = rotate(flap * 0.6, 200, 150) },
        sun = { fill = t < 2 and "#fbbf24" or "orangered", opacity = 0.7 + 0.3 * math.cos(t * 4) },
        pupil = { transform = translate(2 * math.cos(t * 5), 2 * math.sin(t * 5)) },
      } })
  end,
}
