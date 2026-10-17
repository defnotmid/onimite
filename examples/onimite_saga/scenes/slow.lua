local look = require("look")
local fx = require("fx")
local score = require("music.score")
local W, H = look.W, look.H

-- ---- the tape slows ------------------------------------------------------------

local function slow(f, lb, gb)
  local sat = 1 - 0.85 * progress(lb, 0, 3.6)
  fx.fog(f, "#2a1d5c", 0.9 - 0.4 * progress(lb, 0, 4), 0)
  group({ filter = { { "color_matrix", type = "saturate", values = { sat } },
    region = { x = 0, y = 0, w = W, h = H, units = "userSpaceOnUse" } } }, function()
    local cx, cy, R = 960, 540, 400
    local angle = lb * 80 -- degrees per beat: it slows as the tempo falls
    group({ transform = { rotate = angle, origin = { cx, cy } } }, function()
      circle { cx = cx, cy = cy, r = R, fill = "#0b0b14", stroke = look.PINK, stroke_width = 4 }
      for i = 1, 9 do
        circle { cx = cx, cy = cy, r = 140 + i * 26, fill = "none", stroke = "#2a2c44", stroke_width = 2 }
      end
      circle { cx = cx, cy = cy, r = 128, fill = look.PINK }
      circle { cx = cx, cy = cy, r = 14, fill = look.NIGHT }
      text { "onimite", x = cx, y = cy - 40, align = "center", font = look.MONO, size = 26, fill = look.NIGHT }
      path { d = string.format("M%f %f L%f %f L%f %f Z", cx, cy, cx + R, cy - 90, cx + R, cy + 90),
        fill = "#ffffff", opacity = 0.07 }
    end)
  end)
  local p = progress(lb, 3, 4)
  group({ opacity = p }, function()
    text { "wait.", x = W / 2, y = 1000, align = "center", font = look.SERIF, italic = true, size = 120, fill = look.INK }
  end)
end

local AT = score.time("slow")
scene { "Slow", cue = "slow", start = AT, render = function(f)
  local gb = score.beat(f)
  slow(f, gb - score.beat(AT), gb)
end }
