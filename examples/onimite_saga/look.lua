-- The look: palette, type, easing, and the small parts several scenes share
-- (the beat pulse, Pip, titles, ticks and crosses, the logo). A scene's own
-- parts live in its own file.

local M = {}

-- Act I is cold and dark, the K-pop acts are hot, the twist is green.
M.VOID, M.INK, M.DIM, M.LINE = "#05060a", "#ece9f5", "#6d7088", "#262a3c"
M.PINK, M.CYAN, M.LEMON, M.VIOLET, M.NIGHT = "#ff2d95", "#19e3ff", "#ffe14d", "#8a5cff", "#120a2a"
M.O, M.F = "#2ef2a0", "#ff6a3d"      -- onimite, fframes
M.RAIN = "#00ff66"

M.DISPLAY, M.SANS, M.MONO, M.SERIF = "Bebas Neue", "Space Grotesk", "JetBrains Mono", "Instrument Serif"

M.W, M.H, M.FPS = 1920, 1080, 60

-- Springs run in seconds; a beat is about half a second in the loud acts.
local SNAP = spring { stiffness = 320, damping = 22 }
local SOFT = spring { stiffness = 170, damping = 13 }
local BEAT_S = 0.42
function M.snap(beats) return ease(SNAP, beats * BEAT_S) end
function M.soft(beats) return ease(SOFT, beats * BEAT_S) end

-- A filled label, popping from its left edge.
function M.chip(x, y, label, fill, ink, size, pop)
  size = size or 22
  local w = text_width { label, font = M.MONO, size = size } + size * 1.4
  local h = size * 1.9
  group({ transform = { scale = pop or 1, origin = { x, y + h / 2 } }, opacity = clamp01((pop or 1) * 3) }, function()
    rect { x = x, y = y, w = w, h = h, rx = h / 2, fill = fill }
    text { label, x = x + size * 0.7, y = y + h / 2, baseline = "middle", font = M.MONO, size = size, fill = ink or M.VOID }
  end)
  return w
end

-- Width of a string (text_width keeps its results: measure freely).
function M.width(s, font, size, extra)
  return text_width { s, font = font, size = size, italic = font == M.SERIF, letter_spacing = extra }
end

-- A word whose letters spring up one after another, starting `lb` beats
-- after its cue. Returns the word's width.
function M.pop_word(word, x, y, size, lb, fill, font, opts)
  font = font or M.DISPLAY
  opts = opts or {}
  local each = opts.each or 0.12
  local from = opts.from or 70
  local total = M.width(word, font, size)
  if opts.align == "center" then x = x - total / 2 elseif opts.align == "right" then x = x - total end
  local chars = text_chars { word, font = font, size = size, italic = font == M.SERIF }
  for i, c in ipairs(chars) do
    local s = M.snap(lb - i * each * 0.5)
    if s > 0.001 then
      group({ transform = { translate = { 0, (1 - s) * from }, rotate = (1 - s) * (opts.tilt or 0),
        origin = { x + c.x, y } }, opacity = clamp01(s * 4) }, function()
        text { c.text, x = x + c.x, y = y, font = font, size = size, fill = fill, stroke = opts.stroke,
          stroke_width = opts.stroke_width }
      end)
    end
  end
  return total
end

-- The soundtrack's spectrum at the frame as `n` levels from 0 to 1: bands
-- an equal pitch step wide (94 Hz to 12 kHz), -20 to +26 dB.
function M.spectrum(f, n)
  return audio_spectrum(f, { src = "score", sample_size = 512, smooth = 2, window = "hann", bands = n,
    log = true, levels = { -20, 26 } }) or {}
end

-- ---- shared parts ---------------------------------------------------------------

-- The kick under the picture: 1 on every beat, decaying.
function M.kick(gb) return pulse(gb, 7) end

M.SHADOW = { dx = 0, dy = 8, blur = 14, color = "#1a0630", opacity = 0.55 }

-- Pip, the mascot (../common/pip.lua), standing at the bottom middle of the
-- box (x, y, w, h), bouncing on the beat; `mood` as pip.draw takes it.
local pip = dofile("../common/pip.lua")
function M.pip(f, x, y, w, h, gb, mood)
  local size = math.min(w, h)
  pip.draw(f, { x = x + (w - size) / 2, y = y + h - size, size = size, beat = gb, mood = mood })
end

-- Pip as an alpha video clip (transparent.mov, ProRes 4444): where the film
-- shows clips with transparency decoding, bouncing a little on the kick.
function M.pip_clip(f, x, y, w, h, gb)
  local s = 1 + 0.04 * M.kick(gb)
  group({ transform = { scale = s, origin = { x + w / 2, y + h } } }, function()
    video_frame(f, { src = "transparent.mov", x = x, y = y, w = w, h = h, fit = "contain", looping = true })
  end)
end

-- A title that springs in `cue` beats into the scene.
function M.title(lb, cue, s, x, y, size, fill)
  local p = M.snap(lb - cue)
  if p < 0.001 then return end
  group({ opacity = clamp01(p * 3), transform = { scale = 0.8 + 0.2 * p, origin = { x, y } } }, function()
    text { s, x = x, y = y, font = M.DISPLAY, size = size or 90, fill = fill or M.INK }
  end)
end

function M.tick(x, y, s, color)
  path { d = string.format("M%f %f L%f %f L%f %f", x, y + s * 0.55, x + s * 0.38, y + s * 0.9, x + s, y + s * 0.1),
    fill = "none", stroke = color, stroke_width = s * 0.18, line_cap = "round", line_join = "round" }
end

-- A cross drawn on as `p` goes 0..1.
function M.cross(x, y, s, color, p)
  local d = s * p
  line { x1 = x, y1 = y, x2 = x + d, y2 = y + d, stroke = color, stroke_width = s * 0.16, line_cap = "round" }
  line { x1 = x + s, y1 = y, x2 = x + s - d, y2 = y + d, stroke = color, stroke_width = s * 0.16, line_cap = "round" }
end

-- The logo (logo.svg: Pip, the project's logo, assets/logo.svg) and where it
-- sits: square.
M.LOGO = { w = 756, h = 756 }
M.LOGO.x, M.LOGO.y = (M.W - M.LOGO.w) / 2, 150

function M.plain_logo()
  svg { src = "logo.svg", x = (M.W - M.LOGO.w) / 2, y = (M.H - M.LOGO.h) / 2, w = M.LOGO.w, h = M.LOGO.h, fit = "contain" }
end

-- The logo's name, under it: as wide as the logo allows.
M.NAME = "PIP"
M.NAME_SIZE = text_size { M.NAME, font = M.DISPLAY, letter_spacing = 18, max_width = 1500, size = 190 }

-- Where Pip rests when the tape stops (TapeStop leaves Pip there, Fade picks
-- Pip up): the box Pip stands in.
M.PIP_STILL = { x = 683, y = 241, size = 554 }

return M
