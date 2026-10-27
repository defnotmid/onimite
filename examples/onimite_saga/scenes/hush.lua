local look = require("look")
local fx = require("fx")
local score = require("music.score")
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
  if #facts.losses > 0 then
    local times = {}
    for i, r in ipairs(facts.losses) do
      times[i] = string.format("%s: %.2f s against %.2f s", r.name, r.fframes, r.onimite)
    end
    line(facts.losses_line, 2, 450)
    sub(table.concat(times, " · "), 2.7, 505)
  else
    local r = facts.CLOSEST
    line("fframes comes closest on " .. r.name .. ".", 2, 450)
    sub(string.format("%.2f s against %.2f s", r.fframes, r.onimite), 2.7, 505)
  end
  line("No WebM output. Not yet.", 4, 640)
  sub("WebM and VP9 alpha play fine as input. Encoding them: not yet.", 4.7, 695)
  line(string.format("But the whole download is %.1f MB,", facts.download_mb), 5.6, 840, 84, look.LEMON)
  line("and we can do all of this.", 6.6, 950, 84, look.LEMON)
end

local AT = score.time("hush")
scene { "Hush", cue = "hush", start = AT, render = function(f)
  local gb = score.beat(f)
  hush(f, gb - score.beat(AT), gb)
end }
