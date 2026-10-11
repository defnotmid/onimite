-- Vector wordmark animation from fframes-intro's outro (src/outro.rs): the
-- intro's font, spring parameters, stagger and orange echo palette.

local M = {}

local FONT = "Instrument Serif"
local WORD_SIZE = 300
local BEAT = 0.454522

-- The wordmark's and its first letter's widths, measured once when the
-- script loads (Instrument Serif's italic is the family's only face).
local WORD_W = text_width { "fframes", font = FONT, size = WORD_SIZE, weight = 400, italic = true }
local F_W = text_width { "f", font = FONT, size = WORD_SIZE, weight = 400, italic = true }

-- The same damped spring and exponential scale-in as fframes-intro's beat.rs.
local function spring(seconds, stiffness, damping)
  if seconds <= 0 then return 0 end
  local natural = math.sqrt(stiffness)
  local ratio = damping / (2 * natural)
  local damped = natural * math.sqrt(1 - ratio * ratio)
  return 1 - math.exp(-ratio * natural * seconds)
    * (math.cos(damped * seconds) + ratio * natural / damped * math.sin(damped * seconds))
end

local function expo_out(p)
  p = math.max(0, math.min(1, p))
  if p >= 1 then return 1 end
  return 1 - 2 ^ (-10 * p)
end

local ECHOES = { "#fb6a22", "#c4531c", "#8a3712" }

-- `seconds`: time since the Eclipse shot started.
function M.render(seconds)
  local beats = seconds / BEAT
  local step = F_W * 0.78
  local total = WORD_W + step * 3
  local x = 960 - total / 2 + step * 3
  local y = 530
  local word_opacity = math.min(spring(seconds, 260, 20), 1)
  local word_scale = 1 + (1 - expo_out(beats / 0.5)) * 0.25
  for index = #ECHOES - 1, 0, -1 do
    local amount = spring((beats - 0.5 - index * 0.5) * BEAT, 170, 15)
    local dx = -step * (index + 1) * amount
    text { "f", x = x + dx, y = y, font = FONT, italic = true, weight = 400, size = WORD_SIZE,
      fill = ECHOES[index + 1], opacity = math.max(0, math.min(1, amount)) * (1 - index * 0.18) }
  end
  local tag = math.max(0, math.min(1, (beats - 4) / 0.6))
  group({ transform = string.format("translate(960 %d) scale(%.9g) translate(-960 -%d)", y, word_scale, y),
    opacity = word_opacity }, function()
    text { "fframes", x = x, y = y, font = FONT, italic = true, weight = 400, size = WORD_SIZE, fill = "#ece8e1" }
  end)
  text { "SHADER MODE", x = 960, y = 636, align = "center", font = "JetBrains Mono", size = 30,
    letter_spacing = 3, fill = "#c6b4ef", opacity = tag }
end

return M
