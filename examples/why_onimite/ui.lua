-- Palette, type and the small parts the scenes share.

local beat = require("beat")

local M = {}

M.BG, M.PANEL, M.LINE = "#07080c", "#10131b", "#232838"
M.TEXT, M.DIM = "#f3f1ea", "#7d8394"
M.O, M.F = "#2ef2a0", "#ff6a3d" -- onimite, fframes

M.DISPLAY, M.SANS, M.MONO = "Bebas Neue", "Space Grotesk", "JetBrains Mono"
M.SERIF, M.ARABIC = "Instrument Serif", "Noto Sans Arabic"

-- A section title that slams in on its first beat.
function M.header(lb, title, sub)
  local s = beat.snap(lb)
  group({ transform = translate(0, (1 - s) * 70) }, function()
    text { title, x = 120, y = 190, font = M.DISPLAY, size = 130, fill = M.TEXT }
    text { sub, x = 124, y = 236, font = M.MONO, size = 24, fill = M.DIM }
  end)
end

-- A filled label, popping from its left edge.
function M.chip(x, y, label, fill, ink, size, pop)
  size = size or 22
  local w = text_width { label, font = M.MONO, size = size } + size * 1.4
  local h = size * 1.9
  group({ transform = { scale = pop or 1, origin = { x, y + h / 2 } } }, function()
    rect { x = x, y = y, w = w, h = h, rx = h / 2, fill = fill }
    text { label, x = x + size * 0.7, y = y + h / 2, baseline = "middle", font = M.MONO, size = size, fill = ink or M.BG }
  end)
  return w
end

-- A tick mark `s` pixels wide with its top-left at x, y.
function M.check(x, y, s, color, width)
  path { d = string.format("M%f %f L%f %f L%f %f", x, y + s * 0.55, x + s * 0.38, y + s * 0.9, x + s, y + s * 0.1),
    fill = "none", stroke = color, stroke_width = width or s * 0.16, line_cap = "round", line_join = "round" }
end

-- The song's spectrum at the frame as `n` levels from 0 to 1: bands an
-- equal pitch step wide (94 Hz to 12 kHz), -20 to +26 dB.
function M.spectrum(f, n)
  return audio_spectrum(f, { src = "score", sample_size = 512, smooth = 2, window = "hann", bands = n,
    log = true, levels = { -20, 26 } }) or {}
end

-- 0..1 of a counter that ticks on the given beats, each tick easing in
-- over 0.4 beats.
function M.ticked(lb, ticks)
  local v = 0
  for _, t in ipairs(ticks) do v = v + ease(easing.exponential_out, progress(lb, t, t + 0.4)) end
  return v / #ticks
end

return M
