-- Three scenes with cross-fades (overlaps), for the timeline and the preview.
--
--     onimite preview examples/scenes/video.lua

video { width = 1280, height = 720, fps = 60, background = "#0f172a" }

local function title(f, label, color)
  local fade_in = animate(f, { { start = 0, stop = 0.5, from = 0, to = 1, easing = ease_out } })
  local fade_out = f.scene.is_last and 1 or animate(f, { { start = f.scene.frames / f.fps - 0.5, stop = f.scene.frames / f.fps, from = 1, to = 0, easing = ease_in } })
  group({ opacity = fade_in * fade_out,
          transform = translate(0, animate(f, { { start = 0, stop = 0.6, from = 40, to = 0, easing = spring { stiffness = 180, damping = 18 } } })) }, function()
    rect { x = 240, y = 260, w = 800, h = 200, rx = 28, fill = color }
    text { label, x = 640, y = 385, font = "DM Sans", size = 72, align = "center", fill = "#ffffff" }
  end)
end

scene { "Intro", duration = 2, render = function(f) title(f, "Intro", "#0ea5e9") end }
scene { "Middle", duration = 3, overlap = { previous = 0.5 }, render = function(f) title(f, "Middle", "#8b5cf6") end }
scene { "Outro", duration = 2, overlap = { previous = 0.5 }, render = function(f) title(f, "Outro", "#f43f5e") end }
