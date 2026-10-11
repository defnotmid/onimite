-- One word per beat on alternating full-bleed colors.

local beat = require("beat")
local ui = require("ui")
local prog, expo_out, expo_in = beat.prog, beat.expo_out, beat.expo_in
local ORANGE, BONE, INK, BG, PAPER, MONO, DISPLAY, SERIF = ui.ORANGE, ui.BONE, ui.INK, ui.BG, ui.PAPER, ui.MONO, ui.DISPLAY, ui.SERIF

local WORDS = { "TEXT", "IMAGES", "VIDEO", "SHADERS", "AUDIO", "GPU", "EFFECTS", "AGENTS" }

local function render(f, lb)
  local i = math.floor(math.max(lb, 0))
  local l = lb - i
  if i < #WORDS then
    local bg, fg
    if i % 3 == 0 then bg, fg = ORANGE, INK elseif i % 3 == 1 then bg, fg = BG, BONE else bg, fg = PAPER, INK end
    local punch = 1 + (1 - expo_out(l / 0.4)) * 0.12
    rect { x = 0, y = 0, w = 1920, h = 1080, fill = bg }
    group({ transform = string.format("translate(960 560) scale(%s) translate(-960 -560)", punch) }, function()
      text { WORDS[i + 1], x = 960, y = 690, align = "middle", font = DISPLAY, size = 360, letter_spacing = -16, fill = fg }
    end)
    text { string.format("%02d", i + 1), x = 150, y = 200, font = MONO, weight = 600, size = 30, letter_spacing = 6, fill = fg }
    text { "/ 08", x = 1770, y = 200, align = "end", font = MONO, weight = 600, size = 30, letter_spacing = 6, fill = fg }
    return
  end
  -- beats 8-12: ALL OF IT. / in Rust.
  l = lb - 8
  local exit = expo_in(prog(l, 3.7, 4))
  group({ opacity = 1 - exit }, function()
    rect { x = 0, y = 0, w = 1920, h = 1080, fill = BG }
    ui.Slam(960, 520, "ALL OF IT.", DISPLAY, 220, BONE):with_anchor("middle"):draw(l, 0, 170)
    ui.Slam(960, 760, "in Rust.", SERIF, 220, ORANGE):with_anchor("middle"):with_italic():draw(l - 2, 0, 170)
  end)
end

return { name = "RecapScene", start = 224, stop = 236, render = render }
