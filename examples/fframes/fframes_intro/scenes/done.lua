-- The silent bar: only a command being typed.

local beat = require("beat")
local ui = require("ui")
local prog, usize, fract = beat.prog, beat.usize, beat.fract
local ORANGE, BONE, MONO = ui.ORANGE, ui.BONE, ui.MONO

local COMMAND = "cargo fframes new my-video"

local function render(f, lb)
  local n = #COMMAND
  local typed = usize(prog(lb, 0.2, 3.2) * n)
  local shown = COMMAND:sub(1, typed)
  -- text is centered on the full command so it does not shift while typing
  local adv = 40 * 0.6
  local x0 = 960 - (n + 2) * adv / 2
  local caret_x = x0 + (2 + typed) * adv
  local caret_on = (typed >= n and fract(lb * 2) > 0.5) or typed < n
  rect { x = 0, y = 0, w = 1920, h = 1080, fill = "#050505" }
  text { "$", x = x0, y = 555, font = MONO, weight = 600, size = 40, fill = ORANGE }
  if shown ~= "" then text { shown, x = x0 + 2 * adv, y = 555, font = MONO, weight = 500, size = 40, fill = BONE } end
  rect { x = caret_x + 2, y = 522, w = 20, h = 44, fill = ORANGE, opacity = caret_on and 1 or 0 }
end

return { name = "DoneScene", start = 236, stop = 240, render = render }
