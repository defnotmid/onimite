local look = require("look")
local fx = require("fx")
local score = require("music.score")
local sfx = require("sfx")
local family = require("scenes.family")
local snap = look.snap
local H = look.H


local CODECS = { { "H.264 · H.265", "encode + decode" }, { "AAC", "encode + decode" }, { "ProRes 4444", "decode, with alpha" },
  { "VP9 · WebM", "decode, with alpha" }, { "WebP · Opus · FLAC · MP3", "decode" }, { "MP4 · WAV · WebM", "read + write" } }

local function odecs(f, lb, gb)
  fx.pop(f, 1, "#06223f", "#0ea5e9", "#19e3ff", look.kick(gb))
  family.left(lb, "built on our own · 2/3 · ../odecs", "ODECS", { "Codecs and containers, in plain Odin.", "No FFmpeg at runtime." },
    { "Vulkan Video encode", "native fallback", "no libav", "no libx264" }, look.CYAN)
  family.frame(lb, look.CYAN)
  local s = snap(lb - 0.5)
  group({ clip = { x = family.PANEL.x + 8, y = family.PANEL.y + 8, w = family.PANEL.w - 16, h = family.PANEL.h - 16, rx = 38 }, opacity = clamp01(s * 3) }, function()
    -- Pip, a ProRes 4444 clip, decoded with its alpha
    rect { x = family.PANEL.x, y = family.PANEL.y, w = family.PANEL.w, h = 330, fill = "#101628" }
    look.pip_clip(f, family.PANEL.x + 80, family.PANEL.y + 10, 640, 320, gb)
    text { "this is a ProRes 4444 clip, decoded in Odin", x = family.PANEL.x + family.PANEL.w / 2, y = family.PANEL.y + 365, align = "center",
      font = look.MONO, size = 22, fill = look.CYAN }
    for i, c in ipairs(CODECS) do
      local y = family.PANEL.y + 400 + (i - 1) * 66
      local p = snap(lb - (1 + (i - 1) * 0.5))
      if p > 0.001 then
        group({ opacity = clamp01(p * 3), transform = translate((1 - p) * 140, 0) }, function()
          look.tick(family.PANEL.x + 40, y - 8, 34, look.O)
          text { c[1], x = family.PANEL.x + 100, y = y + 20, font = look.SANS, size = 32, fill = look.INK }
          text { c[2], x = family.PANEL.x + family.PANEL.w - 40, y = y + 18, align = "right", font = look.MONO, size = 20, fill = look.DIM }
        end)
      end
    end
  end)
end

-- Its sounds (sfx.lua), in beats into the scene.
local SOUNDS = {}
for i = 1, 6 do -- a blip per row of codecs
  SOUNDS[#SOUNDS + 1] = sfx.at("odecs", 1 + (i - 1) * 0.5, sfx.blip(700 * 2 ^ ((i - 1) * 2 / 12)), 0.14)
end

local AT = score.time("odecs")
scene { "ODECS", cue = "odecs", start = AT, audio = SOUNDS, render = function(f)
  local gb = score.beat(f)
  odecs(f, gb - score.beat(AT), gb)
end }
