local look = require("look")
local fx = require("fx")
local score = require("music.score")
local sfx = require("sfx")
local W, H = look.W, look.H

local TOTAL = score.frame("end")
-- The lines typed, in beats into the scene.
local RAIN_LINES = { 4, 8, 12, 16 }

local LINES = {
  "> where did pip go",
  string.format("> frame %d / %d", TOTAL, TOTAL),
  string.format("> frame %d / %d", TOTAL + 1, TOTAL),
  "> pip is still rendering",
}

local function rain(f, lb, gb)
  local fade = 1 - ease(easing.exponential_in, progress(lb, 17.2, 20))
  local logo = 1 - progress(lb, 0.5, 5)
  local boA = smoothstep(0, 1, progress(lb, 3.5, 8)) * (1 - progress(lb, 15, 18.5))
  -- the logo shrinks into the rain as it fades: the rain's own copy too
  local shrink = lerp(1, 0.35, ease(easing.cubic_in_out, progress(lb, 0, 4)))
  local function small_logo()
    group({ transform = { scale = shrink, origin = { W / 2, H / 2 } } }, look.plain_logo)
  end
  fx.rain(f, fade, boA * 0.9, logo, small_logo)
  -- the logo and its name, green, still drawn for a moment, then only its code is left
  if lb < 3 then
    group({ opacity = (1 - progress(lb, 0.2, 2.8)) * 0.9, filter = { { "color_matrix", type = "matrix",
      values = { 0, 0, 0, 0, 0, 0.35, 0.66, 0.05, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0 } },
      region = { x = 0, y = 0, w = W, h = H, units = "userSpaceOnUse" } } }, function()
      group({ transform = { scale = shrink, origin = { W / 2, H / 2 } } }, function()
        look.plain_logo()
        text { look.NAME, x = W / 2, y = 1000, align = "center", font = look.DISPLAY, size = look.NAME_SIZE,
          letter_spacing = 18, fill = look.INK }
      end)
    end)
  end

  -- the dialogue: typed, green, on a dark plate so the rain does not eat it
  local x, y0, size = 150, 800, 46
  local cw = text_width { "M", font = look.MONO, size = size }
  local final_at = RAIN_LINES[4]
  for i, l in ipairs(LINES) do
    local at = RAIN_LINES[i]
    local n = math.floor(#l * progress(lb, at, at + (i == 4 and 3 or 2)) + 0.001)
    if n > 0 then
      local y = y0 + (i - 1) * 62 - (i == 4 and 0 or 0)
      local alpha = (i == 4 and 1 or 0.75) * (1 - progress(lb, 17, 19))
      rect { x = x - 20, y = y - size * 0.85, w = cw * #l + 40, h = size * 1.2, fill = "#000000", opacity = 0.72 * alpha }
      text { l:sub(1, n), x = x, y = y, font = look.MONO, size = size, fill = look.RAIN, opacity = alpha }
      if i == 4 or n < #l then
        -- the cursor; after the last line it is all that is left
        if i < 4 or math.floor(lb * 2) % 2 == 0 or lb < 17 then
          local cursor_alpha = i == 4 and 1 - progress(lb, 19.4, 19.9) * 0 or alpha
          rect { x = x + n * cw + 4, y = y - size * 0.8, w = cw * 0.7, h = size * 1.05, fill = look.RAIN, opacity = cursor_alpha }
        end
      end
    end
  end
end

-- Its sounds (sfx.lua), in beats into the scene.
local SOUNDS = {}
for i, l in ipairs(LINES) do -- a beep as each visible character of a line appears
  local at = RAIN_LINES[i]
  sfx.add(SOUNDS, sfx.typing("rain", at, at + (i == 4 and 3 or 2), l, 0.05, i * 31, function(k)
    return sfx.beep(1000 + math.floor(hash(k * 7 + i * 31) * 36) * 25)
  end))
end

local AT = score.time("rain")
scene { "Rain", cue = "rain", start = AT, audio = SOUNDS, render = function(f)
  local gb = score.beat(f)
  rain(f, gb - score.beat(AT), gb)
end }
