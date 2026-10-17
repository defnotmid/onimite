local look = require("look")
local fx = require("fx")
local score = require("music.score")
local sfx = require("sfx")
local snap = look.snap
local W = look.W

-- ---- check without watching --------------------------------------------------------------

local function check_card(x, lb, cue, cmd, head, sub, body)
  local p = snap(lb - cue)
  if p <= 0.001 then return end
  group({ opacity = clamp01(p * 3), transform = { scale = 0.85 + 0.15 * p, origin = { x + 270, 500 } },
    box = { x = x, y = 240, w = 540, h = 640, name = head } }, function() -- inspect: nothing spills out of the card
    rect { x = x, y = 240, w = 540, h = 640, rx = 36, fill = "#0a0c14", opacity = 0.92, stroke = look.CYAN, stroke_width = 3 }
    text { cmd, x = x + 36, y = 310, font = look.MONO, size = 28, fill = look.CYAN }
    text { head, x = x + 36, y = 392, font = look.DISPLAY, size = 84, fill = look.INK }
    local sub_size = text_size { sub, font = look.MONO, max_width = 540 - 74, size = 20 }
    text { sub, x = x + 38, y = 436, font = look.MONO, size = sub_size, fill = look.DIM }
    body(x + 36, 480, p)
  end)
end

local function check(f, lb, gb)
  fx.pop(f, 0, "#0a1a3a", "#1d3a8a", "#19e3ff", look.kick(gb) * 0.5)
  group({ shadow = look.SHADOW }, function()
    look.pop_word("CHECK IT WITHOUT WATCHING", 100, 190, 130, lb, look.INK, look.DISPLAY, { each = 0.04 })
  end)
  check_card(100, lb, 1, "$ onimite inspect", "NO PROBLEMS", "missing fonts, clipped text, NaN, shader errors",
    function(x, y)
      local rows = { "fonts", "media", "text fits", "shaders compile", "no NaN" }
      for i, r in ipairs(rows) do
        local p = snap(lb - (1.5 + i * 0.125))
        if p > 0.001 then
          group({ opacity = clamp01(p * 3) }, function()
            look.tick(x, y + (i - 1) * 62 - 6, 36, look.O)
            text { r, x = x + 64, y = y + (i - 1) * 62 + 24, font = look.SANS, size = 32, fill = look.INK }
          end)
        end
      end
    end)
  check_card(690, lb, 2.5, "$ onimite strip", "CONTACT SHEET", "twelve frames, one image",
    function(x, y)
      -- 3 x 4 thumbnails filling the card's inner box (468 x 364 below the text)
      local TW, TH, GX, GY = 148, 76, 12, 20
      for i = 0, 11 do
        local p = snap(lb - (3 + i * 0.125))
        if p > 0.001 then
          local cx, cy = x + (i % 3) * (TW + GX), y + math.floor(i / 3) * (TH + GY)
          group({ opacity = clamp01(p * 3), transform = { scale = p, origin = { cx + TW / 2, cy + TH / 2 } } }, function()
            rect { x = cx, y = cy, w = TW, h = TH, rx = 10, fill = mix_color(look.PINK, look.CYAN, i / 11) }
            rect { x = cx + 12, y = cy + TH - 24, w = 30 + i * 8, h = 12, rx = 6, fill = look.NIGHT, opacity = 0.7 }
          end)
        end
      end
    end)
  check_card(1280, lb, 4, "$ onimite audio analyze", "LOUDNESS", "LUFS, true peak, clipping, silence",
    function(x, y)
      local p = snap(lb - 5)
      if p > 0.001 then
        group({ opacity = clamp01(p * 3) }, function()
          text { "-14 LUFS", x = x, y = y + 90, font = look.DISPLAY, size = 120, fill = look.O }
          text { "true peak under -1 dBTP", x = x + 2, y = y + 140, font = look.MONO, size = 22, fill = look.INK }
          for i = 0, 23 do
            local v = 0.3 + 0.7 * math.abs(math.sin(i * 0.7 + gb * 0.8)) * (0.5 + 0.5 * math.sin(i * 0.3))
            rect { x = x + i * 20, y = y + 330 - v * 150, w = 12, h = v * 150, rx = 4, fill = look.CYAN }
          end
        end)
      end
    end)
  group({ opacity = progress(lb, 6.2, 7) }, function()
    text { "built for agents, and for people who'd rather not watch.", x = W / 2, y = 970, align = "center", font = look.MONO,
      size = 28, fill = look.INK }
  end)
end

-- Its sounds (sfx.lua), in beats into the scene.
-- On the beat grid (inspect's off_beat): cards on beats and half-beats, the
-- list and the sheet as 16th rolls.
local SOUNDS = { sfx.at("check", 5, sfx.done(), 0.16) }
for _, c in ipairs { 1, 2.5, 4 } do SOUNDS[#SOUNDS + 1] = sfx.at("check", c, sfx.blip(880), 0.16) end -- the cards
for i, step in ipairs { 0, 2, 4, 7, 9 } do -- a tick down the list
  SOUNDS[#SOUNDS + 1] = sfx.at("check", 1.5 + i * 0.125, sfx.blip(600 * 2 ^ (step / 12)), 0.12)
end
for i = 0, 11 do SOUNDS[#SOUNDS + 1] = sfx.at("check", 3 + i * 0.125, sfx.blip(900 + i * 60), 0.07) end -- the contact sheet

local AT = score.time("check")
scene { "Check", cue = "check", start = AT, audio = SOUNDS, render = function(f)
  local gb = score.beat(f)
  check(f, gb - score.beat(AT), gb)
end }
