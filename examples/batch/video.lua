-- A personalized title card, one per row of rows.json / rows.csv: every row
-- arrives as the table `props` (name, role, color; duration optional).
--
--     onimite render examples/batch/video.lua --batch examples/batch/rows.json -o out/{name}.mp4
--     onimite render examples/batch/video.lua --props examples/batch/one.json -o card.mp4
--     onimite render examples/batch/video.lua --set name="Ken Thompson" --set role=Unix
local name = tostring(props.name or "Your Name")
local role = tostring(props.role or "Your role")
local color = props.color or "#38bdf8"
local duration = tonumber(props.duration) or 3

local W, H = 1280, 720
-- A long name is cut to fit beside the badge (measured at load).
local shown = text_fit { name, font = "DM Sans", size = 84, max_width = W - 480 }

-- Initials for the badge: the first letter of the first two words.
local initials = ""
for word in name:gmatch("%S+") do
  if #initials < 2 then initials = initials .. word:sub(1, 1):upper() end
end

video { width = W, height = H, fps = 30, background = "#0b1020", duration = duration,
  render = function(f)
    local t = f.seconds
    local out = animate(t, { { start = duration - 0.4, stop = duration, from = 1, to = 0, easing = ease_in } })
    group({ opacity = out }, function()
      -- Accent bar sweeping in from the left.
      local bar = animate(f, { { start = 0, stop = 0.6, from = 0, to = W, easing = ease_out } })
      if bar > 0 then rect { x = 0, y = 0, w = bar, h = 12, fill = color } end
      -- Badge with the initials.
      local r = animate(f, { { start = 0.1, from = 0, to = 110, easing = spring { stiffness = 160, damping = 14 } } })
      if r > 0 then circle { cx = 260, cy = H / 2, r = r, fill = color } end
      text { initials, x = 260, y = H / 2, align = "center", baseline = "middle", font = "DM Sans",
        size = 96, fill = "#0b1020", opacity = animate(f, { { start = 0.3, stop = 0.6, from = 0, to = 1 } }) }
      -- Name and role sliding in.
      local slide = animate(f, { { start = 0.3, stop = 0.9, from = 60, to = 0, easing = ease_out } })
      text { shown, x = 430 + slide, y = H / 2 - 10, font = "DM Sans", size = 84, fill = "#f8fafc",
        opacity = animate(f, { { start = 0.3, stop = 0.9, from = 0, to = 1 } }) }
      text { role, x = 432 + slide * 1.5, y = H / 2 + 60, font = "DM Sans", size = 40, fill = color,
        opacity = animate(f, { { start = 0.5, stop = 1.1, from = 0, to = 1 } }) }
    end)
  end,
}
