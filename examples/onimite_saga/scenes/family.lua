-- The family cards (OVG, ODECS, OKSL share them): what onimite is built
-- on, after the montage showed what it does. The repo on the left, a panel
-- on the right that each scene fills.

local look = require("look")
local snap = look.snap

local M = {}

M.PANEL = { x = 1000, y = 130, w = 800, h = 820 }

-- Left side shared by the three cards: the repo, its name, two lines, chips.
function M.left(lb, tag, name, lines, chips, fill)
  group({ opacity = progress(lb, 0, 0.4) }, function()
    look.chip(100, 110, tag, look.INK, look.NIGHT, 28, 1)
  end)
  group({ shadow = look.SHADOW }, function()
    look.pop_word(name, 96, 520, 400, lb, fill, look.DISPLAY, { each = 0.1 })
  end)
  for i, l in ipairs(lines) do
    local p = snap(lb - (1.2 + (i - 1) * 0.6))
    group({ opacity = clamp01(p * 3), transform = translate((1 - p) * -80, 0) }, function()
      text { l, x = 104, y = 610 + (i - 1) * 62, font = look.SANS, size = 44, fill = look.INK }
    end)
  end
  local x, y = 100, 770
  for i, c in ipairs(chips) do
    local w = look.width(c, look.MONO, 26) + 36
    if x + w > 920 then x, y = 100, y + 74 end
    look.chip(x, y, c, "#ffffff22", look.INK, 26, snap(lb - (2.6 + i * 0.35)))
    x = x + w + 14
  end
end

function M.frame(lb, stroke)
  local p = snap(lb - 0.2)
  group({ opacity = clamp01(p * 3), transform = { scale = 0.9 + 0.1 * p, origin = { M.PANEL.x + M.PANEL.w / 2, M.PANEL.y + M.PANEL.h / 2 } } },
    function()
      rect { x = M.PANEL.x, y = M.PANEL.y, w = M.PANEL.w, h = M.PANEL.h, rx = 44, fill = "#080a14", opacity = 0.92,
        stroke = stroke, stroke_width = 4 }
    end)
end

return M
