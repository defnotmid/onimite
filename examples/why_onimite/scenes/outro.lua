-- The last drop: three lines slam in on the beat over the song's spectrum,
-- each with a crash, then the wordmark; the tail fades out.

local beat = require("beat")
local ui = require("ui")
local T = require("timeline")
local CRASH = require("library").CRASH
local INSTRUMENTS = require("library").INSTRUMENTS
local snap, soft = beat.snap, beat.soft

local LINES = {
  { "ONE BINARY.", ui.TEXT },
  { "LUA SCRIPTS.", ui.TEXT },
  { "ALL YOUR CORES.", ui.O },
}

local function spectrum(f, lb, fade)
  local bands = spectrum_centered(ui.spectrum(f, 48))
  local kick = pulse(lb, 6)
  for i, v in ipairs(bands) do
    local h = v * 300 * (0.85 + 0.15 * kick) + 6
    rect { x = 72 + (i - 1) * 37.5, y = 1040 - h, w = 26, h = h, rx = 6,
      fill = linear_gradient { x1 = 0, y1 = 0, x2 = 0, y2 = 1, units = "bbox",
        stops = { { 0, ui.O }, { 1, "#0b5f45" } } }, opacity = fade }
  end
end

local function render(f, lb)
  local fade = 1 - progress(lb, T.TAIL + 1, T.TAIL + 3.5)
  spectrum(f, lb, fade)

  local leave = ease(easing.exponential_in, progress(lb, T.WORDMARK - 0.5, T.WORDMARK))
  group({ opacity = 1 - leave, transform = translate(0, -leave * 120) }, function()
    for i, l in ipairs(LINES) do
      local at = T.OUTRO_LINES[i]
      if lb >= at then
        local s = snap(lb - at)
        local kick = 1 + 0.02 * pulse(lb, 9)
        group({ transform = { translate = { (1 - s) * -60, 0 }, scale = kick, origin = { 160, 250 + i * 160 } } },
          function()
            text { l[1], x = 160, y = 290 + i * 160, font = ui.DISPLAY, size = 190, fill = l[2] }
          end)
      end
    end
  end)

  if lb >= T.WORDMARK then
    local s = 1 + 0.3 * (1 - soft(lb - T.WORDMARK))
    local kick = lb < T.TAIL and 0.025 * pulse(lb, 8) or 0
    group({ opacity = fade, transform = { scale = s + kick, origin = { 960, 470 } } }, function()
      circle { cx = 960, cy = 470, r = 300 + 40 * pulse(lb, 5), fill = "none", stroke = ui.O, stroke_width = 3,
        stroke_opacity = 0.35 }
      text { "onimite", x = 960, y = 530, align = "center", font = ui.SANS, size = 210, fill = ui.TEXT }
    end)
    group({ opacity = progress(lb, T.WORDMARK + 2, T.WORDMARK + 2.3) * fade }, function()
      text { "Odin + Lua · this video is examples/why_onimite, music included", x = 960, y = 650, align = "center",
        font = ui.MONO, size = 28, fill = ui.DIM }
    end)
  end
end

local audio = {}
for i = 2, #T.at.OUTRO_LINES do audio[#audio + 1] = { CRASH, start = T.at.OUTRO_LINES[i], gain_db = -4 } end
audio[#audio + 1] = { CRASH, start = T.at.WORDMARK, gain_db = -2 }

return { name = "Outro", section = "outro", render = render, audio = audio }
