-- The 2024 beta poster develops from an orange dither.

local beat = require("beat")
local ui = require("ui")
local prog, expo_out, expo_in, cubic_in_out = beat.prog, beat.expo_out, beat.expo_in, beat.cubic_in_out
local ORANGE, BONE, GREY, DISPLAY = ui.ORANGE, ui.BONE, ui.GREY, ui.DISPLAY

local function render(f, lb)
  local x, y, w, h = 560, 300, 1060, 596
  local enter = expo_out(prog(lb, 0, 0.6))
  local exit = expo_in(prog(lb, 3.7, 4))
  local s = 0.94 + 0.06 * enter
  group({ opacity = 1 - exit }, function()
    group({ transform = string.format("translate(960 %s) scale(%s) translate(-960 -%s)", y + h / 2, s, y + h / 2) },
      function()
        shader(f, { src = "shaders/develop.sksl", x = x, y = y, w = w, h = h, uniforms = {
          iChannel0 = "beta_poster.jpg",
          uImg = { 1920, 1080 },
          uReveal = prog(lb, 0, 0.7),
          uProgress = cubic_in_out(prog(lb, 0.9, 3.1)) * 1.02,
          uInk = "#1a1210",
          uHot = ORANGE } })
        ui.corners(x - 18, y - 18, w + 36, h + 36, 22, BONE, 2)
      end)
    text { "IMAGE", x = 150, y = 220, font = DISPLAY, size = 120, letter_spacing = -4, fill = BONE,
      opacity = prog(lb, 0.2, 0.3) }
    ui.label(154, 110, "02", ORANGE, 26, "start")
    ui.label(x, y + h + 60, "BETA_POSTER.JPG · 2024", GREY, 18, "start")
    ui.label(x + w, y + h + 60, "DITHER → COLOR · ONE SKSL PASS", ORANGE, 18, "end")
  end)
end

return { name = "ImageScene", start = 62, stop = 66, render = render }
