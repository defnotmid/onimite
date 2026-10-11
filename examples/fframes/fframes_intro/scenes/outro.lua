-- The fframes wordmark slams in with its trail of f's, followed by the
-- install commands.

local beat = require("beat")
local ui = require("ui")
local facts = require("facts")
local prog, expo_out, snap, soft, spring = beat.prog, beat.expo_out, beat.snap, beat.soft, beat.spring
local ORANGE, BONE, GREY, EMBER, MONO, SERIF = ui.ORANGE, ui.BONE, ui.GREY, ui.EMBER, ui.MONO, ui.SERIF

local WORD_SIZE = 300
-- The wordmark's and its first letter's widths (Instrument Serif's italic is
-- the only face of the family in media/).
local WORD_W = text_width { "fframes", font = SERIF, size = WORD_SIZE }
local F_W = text_width { "f", font = SERIF, size = WORD_SIZE }
local ECHO_COLORS = { ORANGE, "#c4531c", EMBER }
local CMDS = {
  { "npx skills add https://fframes.studio", "WITH YOUR CODING AGENT" },
  { "cargo fframes new my-video", "OR BY HAND" },
}

local function render(f, lb)
  local t_end = beat.TOTAL_SECONDS - beat.gsec(f)
  local fade_out = prog(1.6 - t_end, 0, 1.6)
  local flash = math.exp(-lb * 9)

  shader(f, { src = "shaders/contour.sksl", x = 0, y = 0, w = 1920, h = 1080, uniforms = {
    uWell = { 0.5, 0.47 }, uDepth = 1.1, uDensity = 18, uBright = 0.25 + 0.5 * (1 - expo_out(prog(lb, 0, 6))),
    uInk = "#8a857c", uHot = ORANGE } })

  local w, fw = WORD_W, F_W
  -- the trail makes the whole mark wider: center mark + trail
  local trail = 3
  local step = fw * 0.78
  local total = w + step * trail
  local x0 = 960 - total / 2 + step * trail
  local y = 520
  local word_in = spring(lb * beat.BEAT, 260, 20)
  local word_s = 1 + (1 - expo_out(lb / 0.5)) * 0.25
  local tag = prog(lb, 4, 4.6)
  local url = prog(lb, 12, 12.5)

  group({ opacity = 1 - fade_out }, function()
    for k = 2, 0, -1 do
      local s = soft(lb - 0.5 - k * 0.5)
      text { "f", x = x0 - step * (k + 1) * s, y = y, font = SERIF, italic = true, size = WORD_SIZE,
        fill = ECHO_COLORS[k + 1], opacity = math.min(math.max(s, 0), 1) * (1 - k * 0.18) }
    end
    group({ transform = string.format("translate(960 %s) scale(%s) translate(-960 -%s)", y, word_s, y),
      opacity = math.min(word_in, 1) }, function()
      text { "fframes", x = x0, y = y, font = SERIF, italic = true, size = WORD_SIZE, fill = BONE }
    end)
    text { facts.RELEASE_LABEL, x = 1470, y = 265, align = "end", font = MONO, weight = 500, size = 28, letter_spacing = 2,
      fill = GREY, opacity = tag }
    text { "video vibe coding framework that is actually fast", x = 960, y = 590, align = "middle", font = MONO,
      weight = 500, size = 30, letter_spacing = 2, fill = BONE, opacity = tag }
    for i, c in ipairs(CMDS) do
      local at = 8 + (i - 1)
      local s = snap(lb - at)
      local cy = 760 + (i - 1) * 78
      group({ opacity = prog(lb, at, at + 0.1), transform = translate(0, (1 - s) * 30) }, function()
        rect { x = 400, y = cy - 44, w = 1120, h = 62, fill = "#0f0e0d", fill_opacity = 0.9, stroke = "#3d3a35",
          stroke_width = 1.5 }
        text { "$", x = 428, y = cy, font = MONO, weight = 600, size = 26, fill = ORANGE }
        text { c[1], x = 458, y = cy, font = MONO, weight = 500, size = 26, fill = BONE }
        text { c[2], x = 1500, y = cy, align = "end", font = MONO, weight = 500, size = 15, letter_spacing = 2, fill = GREY }
      end)
    end
    group({ opacity = url }, function()
      text { "GITHUB.COM/DMTRKOVALENKO/FFRAMES", x = 960, y = 990, align = "middle", font = MONO, weight = 600, size = 26,
        letter_spacing = 3, fill = ORANGE }
    end)
  end)
  rect { x = 0, y = 0, w = 1920, h = 1080, fill = BONE, opacity = flash }
  rect { x = 0, y = 0, w = 1920, h = 1080, fill = "#000000", opacity = fade_out }
end

return { name = "OutroScene", start = 240, stop = nil, render = render }
