-- fframes' motion-graphics example ("I FIXED CLAUDE CODE (for real)").
--
--     onimite render examples/fframes/motion_graphics/video.lua -o motion.mp4
--
-- The two sibling videos of the original live in quote.lua and install.lua.

local SNAPPY = spring { mass = 1, stiffness = 300, damping = 26 }

video { width = 1920, height = 1080, fps = 60, background = "#000000", duration = 4,
  render = function(f)
    local l1_scale = animate(f, { { 0.2, 0.6, 1.4, 1.0, SNAPPY } })
    local l1_op = animate(f, { { 0.2, 0.5, 0, 1, ease_out } })
    local l1_y = animate(f, {
      { 0.2, 0.7, 540, 540, linear },
      { 0.7, 1.1, 540, 280, ease_in_out },
    })
    local l2_op = animate(f, { { 0.8, 1.4, 0, 1, ease_in_out } })
    local l2_y = animate(f, { { 0.8, 1.5, 720, 620, ease_in_out } })
    local accent_w = animate(f, { { 1.0, 1.6, 0.5, 1000, ease_in_out } })
    local l3_y = animate(f, { { 1.3, 1.8, 890, 810, ease_out } })
    local l3_op = animate(f, { { 1.3, 1.8, 0, 0.6, ease_out } })
    local fade = animate(f, { { 3.2, 3.8, 1, 0, ease_in } })

    rect { x = 0, y = 0, w = 1920, h = 1080, fill = "#000000" }
    group({ opacity = fade }, function()
      -- "I FIXED": scale punch about (960, y), then moves up
      group({ opacity = l1_op,
              transform = { translate = { 960 * (1 - l1_scale), l1_y * (1 - l1_scale) },
                            scale = { l1_scale, l1_scale } } }, function()
        text { "I FIXED", x = 960, y = l1_y, font = "Inter 24pt", size = 340,
          weight = 700, fill = "#ffffff", align = "center", baseline = "central", letter_spacing = 20 }
      end)

      text { "CLAUDE CODE", x = 960, y = l2_y, font = "Bebas Neue", size = 280,
        fill = rgba(255, 255, 255, l2_op), align = "center", baseline = "central", letter_spacing = 14 }

      rect { x = 960 - accent_w / 2, y = 455, w = accent_w, h = 3, rx = 2, fill = "#ffffff40" }

      text { "(for real)", x = 960, y = l3_y, font = "Inter 24pt", size = 60, weight = 300, italic = true,
        fill = rgba(255, 255, 255, l3_op), align = "center", letter_spacing = 6 }
    end)
  end,
}
