local look = require("look")
local fx = require("fx")
local score = require("music.score")
local snap = look.snap
local W, H = look.W, look.H

-- ---- the countdown ----------------------------------------------------------------

local function rise(f, lb, gb)
  fx.fog(f, "#3b1a8a", 0.7 + 0.3 * progress(lb, 0, 3), 0.5 * pulse(lb, 3))
  for i = 1, 3 do
    local ring = progress(lb, i - 1, i)
    circle { cx = W / 2, cy = H / 2, r = 1200 * (1 - ease(easing.exponential_out, ring)) + 60, fill = "none",
      stroke = i % 2 == 0 and look.CYAN or look.PINK, stroke_width = 8 * (1 - ring) + 1, stroke_opacity = ring > 0 and 1 - ring or 0 }
  end
  local n = 3 - math.floor(lb)
  if lb < 3 then
    local s = snap(lb % 1)
    group({ opacity = clamp01(s * 3), transform = { scale = 0.6 + 0.6 * s, origin = { W / 2, 700 } } }, function()
      text { tostring(n), x = W / 2, y = 760, align = "center", font = look.DISPLAY, size = 620,
        fill = n == 2 and look.CYAN or look.INK }
    end)
  elseif lb < 3.75 then
    local s = snap(lb - 3)
    group({ opacity = clamp01(s * 3), transform = { scale = 0.8 + 0.2 * s, origin = { W / 2, 620 } } }, function()
      text { "MEET THE FAMILY", x = W / 2, y = 620, align = "center", font = look.DISPLAY, size = 230, fill = look.LEMON }
    end)
  end
end

local AT = score.time("rise")
scene { "Rise", cue = "rise", start = AT, render = function(f)
  local gb = score.beat(f)
  rise(f, gb - score.beat(AT), gb)
end }
