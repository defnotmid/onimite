-- Three scenes crossfading (an overlap fades both by itself), for the timeline and the preview.
--
--     onimite preview examples/scenes/video.lua

video { width = 1280, height = 720, fps = 60, background = "#0f172a" }

local function title(f, label, color)
  group({ transform = translate(0, animate(f, { { start = 0, stop = 0.6, from = 40, to = 0, easing = spring { stiffness = 180, damping = 18 } } })) }, function()
    rect { x = 240, y = 260, w = 800, h = 200, rx = 28, fill = color }
    text { label, x = 640, y = 385, font = "DM Sans", size = 72, align = "center", fill = "#ffffff" }
  end)
end

scene { "Intro", duration = 2, render = function(f) title(f, "Intro", "#0ea5e9") end }
scene { "Middle", duration = 3, overlap = { previous = 0.5 }, render = function(f) title(f, "Middle", "#8b5cf6") end }
scene { "Outro", duration = 2, overlap = { previous = 0.5 }, render = function(f) title(f, "Outro", "#f43f5e") end }
