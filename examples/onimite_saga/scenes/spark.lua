local look = require("look")
local fx = require("fx")
local C = require("cues")
local sfx = require("sfx")
local code = require("code")
local W, H = look.W, look.H

-- ---- the spark ----------------------------------------------------------------

local MONO_SIZE = 40

local CW = text_width { "M", font = look.MONO, size = MONO_SIZE }

local PANEL = { x = 240, y = 170, w = 1440, h = 470 }

local function typed(tokens, x, y, size, count, cw)
  local used = 0
  for _, t in ipairs(tokens) do
    local n = math.min(#t[1], math.max(0, count - used))
    if n > 0 then
      text { t[1]:sub(1, n), x = x + used * cw, y = y, font = look.MONO, size = size, fill = t[2] }
    end
    used = used + #t[1]
  end
  return used
end

local function spark(f, lb)
  fx.fog(f, "#10304a", 0.35 + 0.5 * progress(lb, 0, 14), 0)
  -- the drop is coming: a pink glow climbs from the bottom
  rect { x = 0, y = 0, w = W, h = H, opacity = 0.55 * progress(lb, 8, 16),
    fill = linear_gradient { x1 = 0, y1 = 1, x2 = 0, y2 = 0.2, units = "bbox",
      stops = { { 0, look.PINK }, { 1, "#ff2d9500" } } } }

  local appear = ease(easing.exponential_out, progress(lb, 0, 1))
  group({ opacity = appear, transform = translate(0, (1 - appear) * 30) }, function()
    rect { x = PANEL.x, y = PANEL.y, w = PANEL.w, h = PANEL.h, rx = 22, fill = "#0a0c14", stroke = look.LINE,
      stroke_width = 2 }
    for i, c in ipairs { look.PINK, look.LEMON, look.O } do
      circle { cx = PANEL.x + 36 + (i - 1) * 30, cy = PANEL.y + 34, r = 9, fill = c, opacity = 0.9 }
    end
    text { "video.lua", x = PANEL.x + PANEL.w - 40, y = PANEL.y + 42, align = "right", font = look.MONO, size = 22,
      fill = look.DIM }
  end)

  -- the script, character by character, in beats: it types faster as the tempo climbs
  local n = code.CODE_CHARS * progress(lb, C.CODE_FROM, C.CODE_TO)
  local done, cursor_at = 0, nil
  for i, tokens in ipairs(code.LINES) do
    local y = PANEL.y + 120 + (i - 1) * 78
    local used = typed(tokens, PANEL.x + 56, y, MONO_SIZE, math.floor(n - done), CW)
    if n - done >= 0 and n - done < used + 0.5 and not cursor_at then cursor_at = { PANEL.x + 56 + math.floor(n - done) * CW, y } end
    done = done + used
  end
  if appear > 0.9 and lb < C.CMD_FROM then
    cursor_at = cursor_at or { PANEL.x + 56, PANEL.y + 120 }
    if math.floor(lb * 3) % 2 == 0 or n < code.CODE_CHARS then
      rect { x = cursor_at[1], y = cursor_at[2] - MONO_SIZE * 0.8, w = CW, h = MONO_SIZE * 1.1, fill = look.INK, opacity = 0.85 }
    end
  end

  -- the command
  local c = code.COMMAND_CHARS * progress(lb, C.CMD_FROM, C.CMD_TO)
  if lb >= C.CMD_FROM - 0.3 then
    local used = typed(code.COMMAND, 240, 800, 46, math.floor(c), text_width { "M", font = look.MONO, size = 46 })
    local cw = text_width { "M", font = look.MONO, size = 46 }
    if lb < C.BAR_FROM and (math.floor(lb * 3) % 2 == 0 or c < code.COMMAND_CHARS) then
      rect { x = 240 + math.floor(c) * cw, y = 800 - 46 * 0.8, w = cw, h = 46 * 1.1, fill = look.INK, opacity = 0.85 }
    end
  end

  -- the render bar
  if lb >= C.BAR_FROM then
    local p = ease(easing.exponential_out, progress(lb, C.BAR_FROM, 15.7))
    rect { x = 240, y = 870, w = 1440, h = 14, rx = 7, fill = look.LINE }
    rect { x = 240, y = 870, w = math.max(1440 * p, 1), h = 14, rx = 7, fill = look.O }
    group({ opacity = progress(lb, 15.2, 15.7) }, function()
      text { "video.mp4 written", x = 240, y = 940, font = look.MONO, size = 30, fill = look.O }
    end)
  end
  -- the last half beat: everything is lit
  local lit = progress(lb, 15.5, 16)
  if lit > 0 then rect { x = 0, y = 0, w = W, h = H, fill = "#ffffff", opacity = lit * 0.5 } end
end

-- Its sounds (sfx.lua), in beats into the scene.
local SOUNDS = sfx.add({},
  -- the script types itself, then the command: a key per character
  sfx.typing(C.SPARK, C.CODE_FROM, C.CODE_TO, code.CODE_TEXT, 0.08, 1),
  sfx.typing(C.SPARK, C.CMD_FROM, C.CMD_TO, code.COMMAND_TEXT, 0.1, 500),
  -- the render bar fills, then DONE
  sfx.at(C.SPARK, C.BAR_FROM, sfx.whoosh(C.seconds(C.SPARK + C.BAR_FROM, 1.1), 0.3), 0.12),
  sfx.at(C.SPARK, 15.2, sfx.done(), 0.18))

scene { "Spark", cue = "SPARK", start = C.time(C.SPARK), audio = SOUNDS, render = function(f)
  local gb = C.beat(f)
  spark(f, gb - C.SPARK, gb)
end }
