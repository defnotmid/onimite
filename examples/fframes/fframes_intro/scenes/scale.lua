-- The riser asks HOW FAST? as a wall of text nodes fills in and the
-- counter climbs to 100,000.

local beat = require("beat")
local ui = require("ui")
local prog, expo_in, cubic_in_out, snap, lerp, hash, round =
  beat.prog, beat.expo_in, beat.cubic_in_out, beat.snap, beat.lerp, beat.hash, beat.round
local ORANGE, BONE, GREY, BG, MONO, DISPLAY, SERIF = ui.ORANGE, ui.BONE, ui.GREY, ui.BG, ui.MONO, ui.DISPLAY, ui.SERIF
local Slam, thousands, label = ui.Slam, ui.thousands, ui.label

local NODES_PER_FRAME, COLS, ROWS = 3334, 62, 54
local WORDS = { "ff", "fx", "0x", "60", "rs", "gp", "sk", "vk", "mt", "tx" }

-- The wall's static layout: position, wave key, word and the hash seed.
local X0, Y0 = 150, 345
local DX, DY = (1770 - X0) / COLS, (900 - Y0) / ROWS
local WALL = {}
for i = 0, NODES_PER_FRAME - 1 do
  local c, r = i % COLS, i // COLS
  WALL[i + 1] = {
    x = X0 + c * DX, y = Y0 + r * DY,
    key = (c / COLS) * 0.7 + (r / ROWS) * 0.3,
    word = WORDS[math.floor(hash(i) * #WORDS) % #WORDS + 1],
    seed = i * 1.37,
  }
end

-- HOW / FAST? on beats 0 and 1, then it shrinks into a heading.
local function question(lb)
  local shrink = cubic_in_out(prog(lb, 3, 4))
  local s = lerp(1, 0.28, shrink)
  group({ transform = string.format("translate(%s %s) scale(%s)", lerp(0, 150 - 150 * s, shrink), lerp(0, 34, shrink), s) },
    function()
      Slam(150, 440, "HOW", DISPLAY, 330, BONE):draw(lb, -260, 0)
      Slam(150, 760, "FAST?", DISPLAY, 330, ORANGE):draw(lb - 1, 260, 0)
    end)
end

-- 3,334 tiny text nodes filling in with a diagonal wave.
local function wall(lb)
  local l = lb - 4
  if l < 0 then return end
  local fill = cubic_in_out(prog(l, 0, 8)) * 1.02
  local step = math.floor(lb * 4)
  local exit = expo_in(prog(l, 9.6, 10))
  group({ opacity = 1 - exit }, function()
    local shown = 0
    for _, n in ipairs(WALL) do
      if n.key <= fill then
        shown = shown + 1
        local h = hash(n.seed + step)
        local color
        if fill - n.key < 0.03 or h > 0.97 then color = ORANGE
        elseif h > 0.55 then color = "#b3aca2"
        else color = "#6b665f" end
        text { n.word, x = n.x, y = n.y, font = MONO, size = 13, weight = 500, fill = color }
      end
    end
    local count = round(shown / NODES_PER_FRAME * 100000)
    rect { x = 1010, y = 130, w = 760, h = 140, fill = BG }
    text { thousands(count), x = 1770, y = 232, align = "end", font = DISPLAY, size = 110, letter_spacing = -3, fill = BONE }
    label(1770, 290, "TEXT NODES TO RENDER", ORANGE, 20, "end")
    label(150, 940, "ONE FRAME = " .. thousands(100000) .. " TEXT NODES  ×  300 FRAMES", GREY, 20, "start")
  end)
end

-- The near silent bar before the drop: two names, then nothing.
local function countdown(l)
  local a = snap(l)
  local v = prog(l, 0.5, 0.55)
  local b = snap(l - 0.5)
  local out = prog(l, 1.55, 1.6)
  group({ opacity = 1 - out }, function()
    text { "REMOTION", x = 960, y = 470 + (1 - a) * 40, align = "middle", font = DISPLAY, size = 120, letter_spacing = -3,
      fill = GREY }
    text { "vs", x = 960, y = 560, align = "middle", font = SERIF, italic = true, size = 70, fill = BONE, opacity = v }
    text { "FFRAMES", x = 960, y = 690 + (1 - b) * 40, align = "middle", font = DISPLAY, size = 120, letter_spacing = -3,
      fill = ORANGE, opacity = v }
  end)
end

local function render(f, lb)
  if lb >= 14 then return countdown(lb - 14) end
  wall(lb)
  question(lb)
end

return { name = "ScaleScene", start = 80, stop = 96, render = render }
