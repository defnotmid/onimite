-- Camera gestures and transition windows measured in source frames
-- (src/transitions.rs).

local M = {}

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function progress(index, start, stop)
  return clamp((index - start) / (stop - start), 0, 1)
end

-- Draws `content()` (the shot) through the shot's camera gesture, then the
-- glitch bars and the white flash, clipped to the canvas.
function M.apply(index, name, content)
  local scale, rotation, skew, dx, dy, opacity = 1, 0, 0, 0, 0, 1
  if name == "Glass" then
    scale = 1 + 3 * (1 - progress(index, 26, 35)) ^ 3
  elseif name == "Halftone" then
    scale = 1 + progress(index, 253, 256) ^ 3 * 1.3
  elseif name == "Flow" then
    scale = 1 + progress(index, 443, 447) ^ 3 * 8
  elseif name == "ShaderModeEditor" then
    scale, skew, rotation = 0.85, -3, -0.6
  elseif name == "ShaderModeZoom" then
    scale = 1.14
    dx = -60 * (1 - progress(index, 586, 610))
    skew = -3
  elseif name == "ShaderModeWide" then
    scale, skew = 0.86, -2
  elseif name == "Eclipse" then
    local p = progress(index, 836, 849) ^ 2
    scale = 1 - p * 0.97
    rotation = p * 14
    dy = p * 170
    opacity = progress(index, 654, 680) ^ 2 * (1 - p)
  end
  local flash = 0
  if index >= 137 and index < 148 then
    flash = math.exp(-((index - 141) / 2.7) ^ 2)
  elseif index >= 445 and index < 450 then
    flash = math.exp(-((index - 446) / 1.3) ^ 2) * 0.45
  end
  local glitch = 0
  if index >= 608 and index < 610 then
    glitch = 0.18
  elseif index >= 636 and index < 640 then
    glitch = progress(index + 1, 636, 640)
  end
  local transform = string.format("translate(%.9g %.9g) rotate(%.9g) skewX(%.9g) scale(%.9g) translate(-960 -540)",
    960 + dx, 540 + dy, rotation, skew, scale)
  group({ clip = { x = 0, y = 0, w = 1920, h = 1080 } }, function()
    group({ opacity = opacity, transform = transform }, content)
    if glitch > 0 then
      for row = 0, 27 do
        local hash = ((row * 73 + index * 19) % 101) / 101
        local y = row * 1080 / 28
        local height = 1080 / 28 * clamp(glitch * 1.5 - hash * 0.45, 0.02, 1)
        rect { x = 0, y = y, w = 1920, h = height, fill = "#000" }
      end
    end
    rect { x = 0, y = 0, w = 1920, h = 1080, fill = "#fffcf2", opacity = flash }
  end)
end

return M
