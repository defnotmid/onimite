-- Quote card: a giant auto-sized phrase (Bebas Neue) filling the frame.
-- Edit TEXT ("\n" separates lines).
--
--     onimite render examples/fframes/motion_graphics/quote.lua -o quote.mp4

local TEXT = "PERFORMANCE"
local SNAPPY = spring { mass = 1, stiffness = 300, damping = 26 }
local MAX_SIZE, MIN_SIZE, PAD, LINE_H = 500, 60, 200, 0.9
local TARGET = 1920 - PAD * 2

local lines = {}
for l in (TEXT .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end

-- Each line's font size: the largest (MAX_SIZE down to MIN_SIZE, in steps
-- of 10) that fits TARGET.
local sizes = {}
for i, line in ipairs(lines) do
  local size = MAX_SIZE
  while size > MIN_SIZE and text_width { line, font = "Bebas Neue", size = size, weight = 400 } > TARGET do
    size = size - 10
  end
  sizes[i] = math.max(size, MIN_SIZE)
end

video { width = 1920, height = 1080, fps = 60, background = "#000000", duration = 3,
  render = function(f)
    local total = 0
    for _, s in ipairs(sizes) do total = total + s * LINE_H end
    local scale_ = animate(f, { { 0, 0.8, 1.6, 1.0, SNAPPY } })
    local slide = animate(f, { { 0, 0.6, 80, 0, SNAPPY } })
    local op = animate(f, { { 0, 0.3, 0, 1, ease_out } })
    local fade = animate(f, { { 2.2, 2.8, 1, 0, ease_in } })

    rect { x = 0, y = 0, w = 1920, h = 1080, fill = "#000000" }
    group({ opacity = op * fade,
            transform = { translate = { 960 * (1 - scale_), 540 * (1 - scale_) + slide },
                          scale = { scale_, scale_ } } }, function()
      local y = 540 - total / 2
      for i, line in ipairs(lines) do
        y = y + sizes[i] * LINE_H
        text { line, x = 960, y = y, font = "Bebas Neue", size = sizes[i], fill = "#ffffff",
          align = "center", letter_spacing = 20 }
      end
    end)
  end,
}
