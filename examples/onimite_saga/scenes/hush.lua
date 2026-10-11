local look = require("look")
local fx = require("fx")
local C = require("cues")
local facts = require("facts")
local W = look.W

-- ---- the hush -------------------------------------------------------------------

local function hush(f, lb, gb)
  fx.fog(f, "#2b1a55", 0.9 * progress(lb, 0, 1), 0)
  local function line(s, cue, y, size, fill)
    local p = progress(lb, cue, cue + 1.1)
    local fade = 1 - 0.55 * progress(lb, cue + 2.2, cue + 3)
    group({ opacity = p * fade, transform = translate(0, (1 - ease(easing.exponential_out, p)) * 22) }, function()
      text { s, x = W / 2, y = y, align = "center", font = look.SERIF, italic = true, size = size or 84, fill = fill or look.INK }
    end)
  end
  local function sub(s, cue, y)
    local p = progress(lb, cue, cue + 0.9)
    group({ opacity = p * 0.9 }, function()
      text { s, x = W / 2, y = y, align = "center", font = look.MONO, size = 26, fill = look.DIM }
    end)
  end
  line("We're not perfect.", 0.3, 300)
  line("fframes still wins hello_world and podcast.", 2, 450)
  sub(string.format("%.2f s against %.2f s, %.2f against %.2f: x264 on every core beats a hardware encoder",
    facts.HELLO.fframes, facts.HELLO.onimite, facts.PODCAST.fframes, facts.PODCAST.onimite), 2.7, 505)
  line("No WebM output. Not yet.", 4, 640)
  sub("WebM and VP9 alpha play fine as input. Encoding them: not yet.", 4.7, 695)
  line(string.format("But we're only a %.1f MB download,", facts.ONIMITE_MB), 5.6, 840, 84, look.LEMON)
  line("and we can do all of this.", 6.6, 950, 84, look.LEMON)
end

scene { "Hush", cue = "HUSH", start = C.time(C.HUSH), render = function(f)
  local gb = C.beat(f)
  hush(f, gb - C.HUSH, gb)
end }
