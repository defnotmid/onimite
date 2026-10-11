-- fframes' `shaders` example: GPU shader layers composed with regular
-- drawing. An aurora background (fframes' SkSL), a Shadertoy raymarcher
-- clipped into a sliding card, and text on top.
--
--     onimite render examples/fframes/shaders/video.lua -o shaders.mp4

-- The card's rounded rect (x 1040, y 160, 760 x 760, rx 40) as a clip path.
local CARD = "M1080 160 H1760 A40 40 0 0 1 1800 200 V880 A40 40 0 0 1 1760 920 " ..
  "H1080 A40 40 0 0 1 1040 880 V200 A40 40 0 0 1 1080 160 Z"

video { width = 1920, height = 1080, fps = 30, duration = 8,
  render = function(f)
    shader(f, { src = "shaders/aurora.sksl", x = 0, y = 0, w = 1920, h = 1080,
      uniforms = {
        uColorA = animate(f, { { 0, 8, "#22d3ee", "#a855f7", ease_in_out } }),
        uColorB = "#f472b6",
        uSpeed = 0.6,
      } })

    local card_slide = animate(f, {
      { 0.3, nil, translate(0, 140), translate(0, 0), spring { mass = 1, stiffness = 180, damping = 20 } } })
    local card_opacity = animate(f, { { 0.3, 0.9, 0, 1, ease_out } })
    local title_opacity = animate(f, { { 0.6, 1.4, 0, 1, ease_out } })

    group({ transform = card_slide, opacity = card_opacity }, function()
      group({ clip_path = CARD }, function()
        shader(f, { src = "shaders/torus.glsl", x = 1040, y = 160, w = 760, h = 760 })
      end)
      rect { x = 1040, y = 160, w = 760, h = 760, rx = 40,
        fill = "none", stroke = "#ffffff", stroke_opacity = 0.2, stroke_width = 2 }
    end)

    group({ opacity = title_opacity }, function()
      text { "GPU shaders", x = 120, y = 500, font = "DM Sans", weight = 500, size = 128, fill = "#ffffff" }
      text { "SkSL and Shadertoy, drawn by Skia", x = 126, y = 580, font = "DM Sans", weight = 500,
        size = 40, fill = "#f5f3ff", fill_opacity = 0.8 }
    end)
  end,
}
