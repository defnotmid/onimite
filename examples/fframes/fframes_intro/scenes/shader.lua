-- The tunnel that showed through the keyed feed grows to the whole frame,
-- its SkSL source scrolls on the left and the guest becomes a halftone print.

local beat = require("beat")
local ui = require("ui")
local video = require("scenes.video")
local prog, expo_out, expo_in, snap, lerp = beat.prog, beat.expo_out, beat.expo_in, beat.snap, beat.lerp
local ORANGE, BONE, INK, MONO, DISPLAY = ui.ORANGE, ui.BONE, ui.INK, ui.MONO, ui.DISPLAY

-- The non-empty lines of tunnel.sksl, 60 characters at most.
local LINES = {}
do
  local file = assert(io.open(SCRIPT_DIR .. "/shaders/tunnel.sksl", "rb"))
  local src = file:read("a")
  file:close()
  for line in src:gmatch("([^\n]*)\n?") do
    line = line:gsub("\r$", "")
    if line:match("%S") then
      local n = utf8.offset(line, 61)
      LINES[#LINES + 1] = n and line:sub(1, n - 1) or line
    end
  end
end

local function render(f, lb)
  -- the right feed's frame grows to the full canvas
  local open = expo_out(prog(lb, 0, 1))
  local R = video.RIGHT
  local cx, cy, cw, ch = lerp(R[1], 0, open), lerp(R[2], 0, open), lerp(R[3], 1920, open), lerp(R[4], 1080, open)
  -- the guest moves from the feed to the right half and prints as halftone
  local gx, gy, gw, gh = lerp(R[1], 860, open), lerp(R[2], 150, open), lerp(R[3], 1280, open), lerp(R[4], 720, open)
  local halftone = prog(lb, 0.8, 1.6)
  local panel = prog(lb, 1, 1.6)
  local title = snap(lb - 0.8)
  local all = snap(lb - 4)
  local exit = expo_in(prog(lb, 7.7, 8))
  group({ opacity = 1 - exit }, function()
    group({ clip = { x = cx, y = cy, w = math.max(cw, 1), h = math.max(ch, 1) } }, function() video.tunnel(f, 3, 1) end)
    video.keyed_guest(f, { gx, gy, gw, gh }, halftone, 1)
    group({ opacity = panel }, function()
      rect { x = 120, y = 250, w = 720, h = 650, fill = "#0b0b0b", fill_opacity = 0.72 }
      group({ clip = { x = 120, y = 250, w = 720, h = 650 } }, function()
        for i, s in ipairs(LINES) do
          local y = 300 + (i - 1) * 26 - lb * 40
          -- lines outside 250..900 have opacity 0
          if y >= 250 and y < 900 then
            text { s, x = 150, y = y, font = MONO, size = 17, fill = "#d8d0c4", opacity = 0.85 }
          end
        end
      end)
      ui.corners(120, 250, 720, 650, 18, ORANGE, 2)
      ui.label(140, 935, "TUNNEL.SKSL · RAYMARCHED · 80 STEPS/PIXEL", ORANGE, 18, "start")
    end)
    group({ opacity = prog(lb, 0.8, 0.9), transform = translate(0, (1 - title) * 50) }, function()
      text { "SHADER", x = 150, y = 220, font = DISPLAY, size = 120, letter_spacing = -4, fill = BONE }
      ui.label(154, 110, "04", ORANGE, 26, "start")
    end)
    group({ opacity = prog(lb, 4, 4.1), transform = translate(0, (1 - all) * 60) }, function()
      rect { x = 860, y = 850, w = 930, h = 120, fill = ORANGE }
      text { "ALL IN ONE FRAME.", x = 890, y = 940, font = DISPLAY, size = 74, letter_spacing = -2, fill = INK }
    end)
  end)
end

return { name = "ShaderScene", start = 72, stop = 80, render = render }
