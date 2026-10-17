local look = require("look")
local fx = require("fx")
local score = require("music.score")
local pip = dofile("../common/pip.lua")
local W, H = look.W, look.H

-- ---- the tape stops --------------------------------------------------------------

local function stop(f, lb, gb)
  local sat = 1 - progress(lb, 0.2, 3.2)
  fx.fog(f, "#3a1f7a", 0.9 * (1 - progress(lb, 2, 4)), 0)
  group({ filter = { { "color_matrix", type = "saturate", values = { sat } },
    region = { x = 0, y = 0, w = W, h = H, units = "userSpaceOnUse" } } }, function()
    local s = 1 - 0.18 * ease(easing.exponential_out, progress(lb, 0, 4))
    -- a slowing wobble: the lower the tempo, the lazier the picture; Pip,
    -- startled, ends at look.PIP_STILL (0.82 of this size about (960, 700))
    local wob = math.sin(lb * 2.4) * (4 - lb) * 2
    group({ transform = { scale = s, rotate = wob * 0.4, origin = { W / 2, 700 } } }, function()
      pip.draw(f, { x = 622.5, y = 140, size = 675, mood = "surprised" })
    end)
  end)
  -- the picture sinks into the dark as the music does
  rect { x = 0, y = 0, w = W, h = H, fill = look.VOID, opacity = ease(easing.exponential_in, progress(lb, 2.2, 4)) }
  local lit = 1 - progress(lb, 0, 0.8)
  if lit > 0 then rect { x = 0, y = 0, w = W, h = H, fill = "#ffffff", opacity = lit } end
end

local AT = score.time("tape_stop")
scene { "TapeStop", cue = "tape_stop", start = AT, render = function(f)
  local gb = score.beat(f)
  stop(f, gb - score.beat(AT), gb)
end }
