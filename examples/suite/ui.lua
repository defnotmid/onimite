-- Palette, type and the small parts the layers share. Each library keeps
-- the accent of its own demo.

local beat = require("beat")

local M = {}

M.BG, M.PANEL, M.LINE = "#07080c", "#10131b", "#2a3042"
M.TEXT, M.DIM = "#f3f1ea", "#8a90a2"
M.ONIMITE, M.OVG, M.ODECS, M.OKSL, M.O3D = "#2ef2a0", "#38e1ff", "#ffb020", "#ff4fa3", "#a07cff"

M.DISPLAY, M.SANS, M.MONO = "Bebas Neue", "Space Grotesk", "JetBrains Mono"

-- A filled label, popping from its centre.
function M.chip(x, y, label, fill, ink, size, pop)
  local w = text_width { label, font = M.MONO, size = size } + size * 1.4
  local h = size * 1.9
  group({ transform = { scale = pop, origin = { x + w / 2, y + h / 2 } } }, function()
    rect { x = x, y = y, w = w, h = h, rx = h / 2, fill = fill }
    text { label, x = x + w / 2, y = y + h / 2, align = "center", baseline = "middle", font = M.MONO, size = size,
      fill = ink }
  end)
  return w
end

-- The song's spectrum at the frame as `n` levels from 0 to 1: bands an
-- equal pitch step wide (94 Hz to 12 kHz), -20 to +26 dB.
function M.spectrum(f, n)
  return audio_spectrum(f, { src = "score", sample_size = 512, smooth = 2, window = "hann", bands = n,
    log = true, levels = { -20, 26 } }) or {}
end

return M
