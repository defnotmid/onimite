-- Quick cuts, a bar each (a series: every part counts its beats from 0):
-- the SVG bird flapping by id override, shaped ligatures, Arabic joining,
-- and Pip, the mascot, as an alpha video clip with a glow.

local beat = require("beat")
local ui = require("ui")
local T = require("timeline")
local snap, soft = beat.snap, beat.soft

-- Ligatures: where "ffi" and "ffl" sit in the shaped line, measured at load.
local LIGA = { text = "office affluent", font = ui.SERIF, size = 240, italic = true }
local function width(s) return text_width { s, font = LIGA.font, size = LIGA.size, italic = true } end
LIGA.x = 960 - width(LIGA.text) / 2
LIGA.marks = {
  { "ffi", LIGA.x + width("o"), width("offi") - width("o"), 1 },
  { "ffl", LIGA.x + width("office a"), width("office affl") - width("office a"), 2 },
}

local WORD = "مرحبا"
local LETTERS = "م  ر  ح  ب  ا" -- the same letters alone: isolated forms
local WORD_W = text_width { WORD, font = ui.ARABIC, size = 300 }

local GLOW = { filter = {
  { "blur", std = 22, input = "SourceAlpha", result = "b" },
  { "flood", color = ui.O, opacity = 0.9, result = "c" },
  { "composite", op = "in", input = "c", input2 = "b", result = "g" },
  { "merge", "g", "SourceGraphic" },
} }

local function label(lb, n, s)
  ui.chip(120, 130, string.format("%02d · %s", n, s), ui.LINE, ui.TEXT, 24, snap(lb))
end

local function bird(f, lb)
  local flap = math.cos(lb * 2 * math.pi) * 32 -- one flap per beat, wings up on the beat
  rect { x = 0, y = 0, w = 1920, h = 1080,
    fill = radial_gradient { cx = 960, cy = 520, r = 700, stops = { { 0, "#123047" }, { 1, ui.BG } } } }
  svg(f, { src = "bird.svg", x = 360 + lb * 40, y = 160 + math.sin(lb * math.pi) * 25, w = 1100, h = 825,
    overrides = {
      wing = { transform = rotate(-flap, 215, 150) },
      wing_back = { transform = rotate(flap * 0.6, 200, 150) },
      sun = { fill = math.floor(lb) % 2 == 0 and ui.O or "#fbbf24" },
      pupil = { transform = translate(2 * math.cos(lb * 3), 2 * math.sin(lb * 3)) },
    } })
  label(lb, 1, "svg{} · wings and sun by element id")
end

local function ligatures(f, lb)
  local s = 1 + 0.12 * (1 - soft(lb))
  group({ transform = { scale = s, origin = { 960, 560 } } }, function()
    text { LIGA.text, x = LIGA.x, y = 600, font = LIGA.font, size = LIGA.size, italic = true, fill = ui.TEXT }
  end)
  for _, m in ipairs(LIGA.marks) do
    local p = ease(easing.exponential_out, progress(lb, m[4], m[4] + 0.5))
    if p > 0 then
      rect { x = m[2], y = 650, w = m[3] * p, h = 10, rx = 5, fill = ui.O }
      group({ opacity = p }, function()
        text { m[1], x = m[2] + m[3] / 2, y = 720, align = "center", font = ui.MONO, size = 34, fill = ui.O }
      end)
    end
  end
  label(lb, 2, "shaped text · ligatures")
end

local function arabic(f, lb)
  group({ opacity = progress(lb, 0, 0.1) * 0.6 }, function()
    text { LETTERS, x = 960, y = 330, align = "center", font = ui.ARABIC, size = 110, fill = ui.DIM }
  end)
  -- the joined word wipes in right to left, the way it reads
  local p = ease(easing.exponential_out, progress(lb, 1, 2))
  local x1 = 960 + WORD_W / 2 + 40
  group({ clip = { x = x1 - (WORD_W + 80) * p, y = 360, w = (WORD_W + 80) * p + 1, h = 440 } }, function()
    text { WORD, x = 960, y = 700, align = "center", font = ui.ARABIC, size = 300, fill = ui.O }
  end)
  group({ opacity = progress(lb, 2, 2.3) }, function()
    text { "marhaba · letters joined by kb_text_shape, right to left", x = 960, y = 860, align = "center",
      font = ui.MONO, size = 28, fill = ui.TEXT }
  end)
  label(lb, 3, "shaped text · Arabic joining")
end

local function avatar(f, lb)
  local fx = 960 + math.cos(lb * 1.4) * 260
  rect { x = 0, y = 0, w = 1920, h = 1080, fill = radial_gradient { cx = 960, cy = 560, r = 760, fx = fx, fy = 420,
    stops = { { 0, "#2b1d5c" }, { 0.55, "#151131" }, { 1, ui.BG } } } }
  local s = 1 + 0.03 * pulse(lb, 8) + 0.15 * (1 - soft(lb))
  group({ transform = { scale = s, origin = { 960, 560 } } }, function()
    group(GLOW, function()
      video_frame(f, { src = "transparent.mov", x = 400, y = 245, w = 1120, h = 630,
        fit = "contain" })
    end)
  end)
  label(lb, 4, "ProRes 4444 alpha video · glow filter")
end

-- each part gets its own frame and its beats since it began
local function part(fn) return function(g) fn(g, g.seconds / beat.BEAT) end end
local CUTS, beats = T.TRICK_CUTS, beat.clock.seconds
local PARTS = {
  { beats(CUTS[1]), part(bird) },
  { beats(CUTS[2] - CUTS[1]), part(ligatures) },
  { beats(CUTS[3] - CUTS[2]), part(arabic) },
  { nil, part(avatar) },
}

local function render(f) series(f, PARTS) end

return { name = "Tricks", start = T.TRICKS, stop = T.OUTRO, render = render }
