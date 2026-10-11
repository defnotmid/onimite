-- A wall of marquee rows; the lit row jumps on every beat.

local beat = require("beat")
local ui = require("ui")
local prog, expo_out, expo_in, pulse = beat.prog, beat.expo_out, beat.expo_in, beat.pulse
local ORANGE, BONE, GREY, BG, COND, DISPLAY = ui.ORANGE, ui.BONE, ui.GREY, ui.BG, ui.COND, ui.DISPLAY

local ROWS = {
  "TEXT · SHAPED · MEASURED · WRAPPED · ",
  "KERNING · LIGATURES · 60 FPS · ",
  "EVERY GLYPH ON THE GPU · ",
  "TEXT · TEXT · TEXT · TEXT · ",
  "FONTS COMPILED INTO THE BINARY · ",
  "TYPOGRAPHY IS CODE · ",
  "TEXT · SHAPED · MEASURED · ",
  "WORD BY WORD · LINE BY LINE · ",
}

local ROW_H, SIZE = 140, 160
local ROW_W = {}
for i, s in ipairs(ROWS) do ROW_W[i] = text_width { s, font = COND, size = SIZE } end

local function render(f, lb)
  local exit = expo_in(prog(lb, 5.7, 6))
  local lit = (math.floor(math.max(lb, 0)) * 3 + 1) % #ROWS
  group({ opacity = 1 - exit }, function()
    for idx, s in ipairs(ROWS) do
      local i = idx - 1
      local w = ROW_W[idx]
      local dir = i % 2 == 0 and -1 or 1
      local speed = 260 + (i * 37) % 140
      local enter = expo_out(prog(lb, i * 0.05, 0.6 + i * 0.05))
      local offset = (lb * beat.BEAT * speed * dir) % w - w + (1 - enter) * 900 * dir
      local y = 150 + i * ROW_H
      local is_lit = i == lit
      local flash = is_lit and pulse(lb, 5) or 0
      group({ opacity = 0.7 + flash * 0.3 }, function()
        for k = 0, 3 do
          if is_lit then
            text { s, x = offset + k * w, y = y, font = COND, size = SIZE, fill = ORANGE }
          else
            text { s, x = offset + k * w, y = y, font = COND, size = SIZE, fill = "none", stroke = "#4b4741",
              stroke_width = 1.6 }
          end
        end
      end)
    end
    rect { x = 120, y = 360, w = 690, h = 270, fill = BG }
    text { "TEXT", x = 150, y = 560, font = DISPLAY, size = 170, letter_spacing = -6, fill = BONE }
    ui.label(154, 408, "01", ORANGE, 26, "start")
    ui.label(154, 610, "SHAPED · MEASURED · WRAPPED", GREY, 18, "start")
  end)
end

return { name = "TextScene", start = 56, stop = 62, render = render }
