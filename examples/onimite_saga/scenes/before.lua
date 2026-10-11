local look = require("look")
local fx = require("fx")
local C = require("cues")
local W = look.W

-- ---- before the first frame ------------------------------------------------------

local function before(f, lb)
  local out = 1 - progress(lb, 7.2, 8)
  fx.fog(f, "#1b2350", progress(lb, 0, 3) * 0.9 * out, 0)

  local a1 = progress(lb, 0.4, 2.2) * (1 - 0.55 * progress(lb, 3.2, 4))
  group({ opacity = a1 * out, transform = translate(0, (1 - ease(easing.exponential_out, progress(lb, 0.4, 2.4))) * 24) }, function()
    text { "To make a video with code,", x = W / 2, y = 470, align = "center", font = look.SERIF, italic = true,
      size = 92, fill = look.INK }
  end)

  local a2 = progress(lb, 3.2, 4.8)
  local line2 = "you needed a compiler or a browser."
  group({ opacity = a2 * out, transform = translate(0, (1 - ease(easing.exponential_out, a2)) * 30) }, function()
    text { line2, x = W / 2, y = 600, align = "center", font = look.SERIF, italic = true, size = 110, fill = look.INK }
    -- underline "compiler" then "browser"
    local x0 = W / 2 - look.width(line2, look.SERIF, 110) / 2
    for i, word in ipairs { { "you needed a ", "compiler" }, { "you needed a compiler or a ", "browser" } } do
      local x1 = x0 + look.width(word[1], look.SERIF, 110)
      local u = look.width(word[2], look.SERIF, 110) * ease(easing.exponential_out, progress(lb, 4.4 + i * 0.4, 5.4 + i * 0.4))
      if u > 0.5 then rect { x = x1, y = 626, w = u, h = 4, fill = look.CYAN, opacity = 0.8 } end
    end
  end)

  local a3 = progress(lb, 5.4, 6.4)
  group({ opacity = a3 * out }, function()
    text { "Rust and its crates  ·  Node and Chrome", x = W / 2, y = 760, align = "center",
      font = look.MONO, size = 30, fill = look.DIM }
  end)
  local a4 = progress(lb, 6.4, 7.0)
  group({ opacity = a4 * out * 0.7 }, function()
    text { "fframes · Remotion · Revideo · Motion Canvas", x = W / 2, y = 830, align = "center", font = look.MONO,
      size = 22, fill = look.DIM }
  end)
end

scene { "Before", cue = "BEFORE", start = C.time(C.BEFORE), render = function(f)
  local gb = C.beat(f)
  before(f, gb - C.BEFORE, gb)
end }
