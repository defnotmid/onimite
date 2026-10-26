-- Lottie animations (After Effects exports) composed with onimite text and
-- shapes.
--
--     onimite render examples/lottie_demo/video.lua -o lottie_demo.mp4
--
-- The .json files in media/ load as Lottie documents, parsed once and shared
-- by every frame builder. Each lottie{} draws its animation at the frame the
-- clock maps to: by default the scene's clock at the file's own frame rate.

local W, H = 1280, 720
local INK = "#e2e8f0"
local MUTED = "#94a3b8"

local dalek = nil

video { width = W, height = H, fps = 60, background = "#0f172a", duration = 8,
  render = function(f)
    dalek = dalek or lottie_info("dalek.json")
    local t = f.seconds
    local intro = animate(f, { { start = 0, stop = 0.8, from = 0, to = 1, easing = ease_out } })
    local outro = animate(f, { { start = 7.3, stop = 8, from = 1, to = 0, easing = ease_in } })

    group({ opacity = outro }, function()
      text { "Lottie in onimite", x = 60, y = 70, font = "DM Sans", size = 44,
        fill = rgba(226, 232, 240, intro), baseline = "central" }
      text { "After Effects exports drawn as vectors, frame by frame", x = 60, y = 112,
        font = "DM Sans", size = 22, fill = MUTED, baseline = "central" }

      -- The dalek (1920x1080, 30 fps) in a card that slides up.
      local card_y = animate(f, { { start = 0.2, stop = 1.2, from = 200, to = 150, easing = ease_out } })
      group({ opacity = intro }, function()
        rect { x = 52, y = card_y - 8, w = 736, h = 430, rx = 18, fill = "#1e293b" }
        group({ clip_path = string.format("M60 %f h720 v414 h-720 Z", card_y) }, function()
          lottie { src = "dalek.json", x = 60, y = card_y, w = 720, h = 405, fit = "cover" }
        end)
        text { string.format("dalek.json  %.1f / %.1f s", math.min(t, dalek.duration), dalek.duration),
          x = 68, y = card_y + 450, font = "DM Sans", size = 20, fill = MUTED, baseline = "central" }
      end)

      -- The repeater spiral at 1.5x speed, starting two seconds in (its
      -- composition has a white background), recoloured by a per-layer
      -- override (keyed by the layer's name in the file).
      local spiral_in = animate(f, { { start = 0.6, stop = 1.6, from = 0, to = 1, easing = ease_out } })
      group({ opacity = spiral_in }, function()
        rect { x = 840, y = 142, w = 380, h = 380, rx = 18, fill = "#ffffff" }
        lottie { src = "spiral.json", x = 850, y = 152, w = 360, h = 360, speed = 1.5, offset = 2,
          overrides = { ["Shape Layer 1"] = { fill = "#0ea5e9" } } }
      end)

      -- Trim paths on a frame the script picks (ping-pong).
      local trim_in = animate(f, { { start = 1.2, stop = 2.2, from = 0, to = 1, easing = ease_out } })
      local ping = 300 + 280 * math.sin(t * 0.9)
      group({ opacity = trim_in }, function()
        rect { x = 840, y = 534, w = 140, h = 140, rx = 14, fill = "#ffffff" }
        lottie { src = "trim.json", x = 845, y = 539, w = 130, h = 130, frame = ping }
        text { "spiral.json  speed = 1.5", x = 1000, y = 580, font = "DM Sans", size = 20,
          fill = MUTED, baseline = "central" }
        text { string.format("trim.json  frame = %d", math.floor(ping)), x = 1000, y = 620,
          font = "DM Sans", size = 20, fill = MUTED, baseline = "central" }
      end)

      -- A Lottie text layer: a character animator (letters rise in, then a
      -- wave scales and recolours them) and a drop shadow effect, laid out
      -- with the media's DM Sans; its string replaced by an override.
      lottie { src = "title.json", x = 840, y = 36, w = 380, h = 90, loop = false,
        overrides = { ["Title"] = { text = "Lottie text" } } }

      -- A progress bar on the video clock.
      rect { x = 60, y = 650, w = 728, h = 6, rx = 3, fill = "#334155" }
      if t > 0 then
        rect { x = 60, y = 650, w = 728 * t / 8, h = 6, rx = 3, fill = "#38bdf8" }
      end
    end)
  end,
}
