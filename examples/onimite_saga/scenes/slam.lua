local look = require("look")
local fx = require("fx")
local score = require("music.score")
local sfx = require("sfx")
local W, H = look.W, look.H

local function logo_nodes(lb, tint)
  local hit = lb - 1
  local s = 1 + 2.2 * (1 - look.snap(hit)) -- from three times the size, snapping down
  local shake = hit > 0 and math.exp(-hit * 3) * 26 or 0
  local dx = (hash(math.floor(lb * 30)) - 0.5) * 2 * shake
  local dy = (hash(math.floor(lb * 30) + 7) - 0.5) * 2 * shake
  group({ transform = { scale = s, translate = { dx, dy }, origin = { W / 2, 530 } } }, function()
    svg { src = "logo.svg", x = look.LOGO.x, y = look.LOGO.y, w = look.LOGO.w, h = look.LOGO.h, fit = "contain" }
  end)
  local ws = 1 + 1.4 * (1 - look.snap(hit - 0.15))
  group({ transform = { scale = ws, translate = { -dx, dy }, origin = { W / 2, 960 } } }, function()
    text { look.NAME, x = W / 2, y = 1000, align = "center", font = look.DISPLAY, size = look.NAME_SIZE,
      letter_spacing = 18, fill = tint or look.INK }
  end)
end

local function slam(f, lb, gb)
  if lb < 1 then
    -- a beat of nothing; one dim pixel of light in the middle, flickering
    local flick = hash(math.floor(lb * 60)) > 0.5 and 0.5 or 0.1
    rect { x = W / 2 - 3, y = 537, w = 6, h = 6, fill = look.INK, opacity = flick * progress(lb, 0.3, 0.9) }
    return
  end
  local hit = lb - 1
  -- more glitch the longer it stays
  local amount = math.max(0.85 * math.exp(-hit * 5), 0.15 + 0.85 * progress(lb, 2.4, 3.9))
  local green = progress(lb, 3, 3.9)
  local m = 1 - green
  -- colour matrix easing from the identity to "everything is green"
  local gm = { m + 0 * green, 0, 0, 0, 0,
               0.35 * green, m + 0.6 * green, 0.05 * green, 0, 0,
               0, 0, m, 0, 0,
               0, 0, 0, 1, 0 }
  group({ filter = { { "color_matrix", type = "matrix", values = gm },
    region = { x = 0, y = 0, w = W, h = H, units = "userSpaceOnUse" } } }, function()
    fx.glitch(f, function() logo_nodes(lb) end, amount, math.floor(lb * 14), { x = 0, y = 0, w = W, h = H }, 12)
  end)
  local flash = math.exp(-hit * 6)
  if flash > 0.01 then rect { x = 0, y = 0, w = W, h = H, fill = "#ffffff", opacity = flash } end
end

-- Its sounds (sfx.lua), in beats into the scene.
local SOUNDS = {
  -- the hit, a beat in
  sfx.at("slam", 1, sfx.impact(), 1.0, nil, "logo_hit"),
  sfx.at("slam", 1, sfx.tom(55), 0.8),
  sfx.at("slam", 1, sfx.crash(), 0.8),
  -- and a riser into the matrix
  sfx.at("slam", 3, sfx.whoosh(sfx.seconds("slam", 3, 1), 0.2), 0.2),
}
for _, g in ipairs { 1.0, 2.0, 2.5, 3.0, 3.5, 3.625, 3.75, 3.875 } do -- glitches, faster and faster
  SOUNDS[#SOUNDS + 1] = sfx.at("slam", g, sfx.glitch(sfx.seconds("slam", g, 0.25)), 0.1)
end

local AT = score.time("slam")
scene { "Slam", cue = "slam", start = AT, audio = SOUNDS, render = function(f)
  local gb = score.beat(f)
  slam(f, gb - score.beat(AT), gb)
end }
