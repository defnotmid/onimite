-- Two podcast feeds decoded frame by frame. On the last bar the green
-- screen of the right feed is keyed out on the GPU and the shader of the
-- next scene shows through.

local beat = require("beat")
local ui = require("ui")
local prog, expo_out, expo_in, hash = beat.prog, beat.expo_out, beat.expo_in, beat.hash
local ORANGE, BONE, GREY, DISPLAY = ui.ORANGE, ui.BONE, ui.GREY, ui.DISPLAY
local label, timecode = ui.label, ui.timecode

local M = { name = "VideoScene", start = 66, stop = 72 }

local LEFT = { 150, 300, 790, 444 }
local RIGHT = { 980, 300, 790, 444 }
M.RIGHT = RIGHT

local function clip_input(src) return { src = src, start_from = 0, looping = true } end

-- The keyed guest from the right feed: footage (0) or halftone print (1).
function M.keyed_guest(f, r, halftone, alpha)
  shader(f, { src = "shaders/key.sksl", x = r[1], y = r[2], w = r[3], h = r[4], uniforms = {
    iChannel0 = clip_input("right_clip.mp4"),
    uImg = { 1280, 720 },
    uHalftone = halftone,
    uCell = 9,
    uAlpha = alpha,
    uInk = ORANGE,
    uPaper = BONE } })
end

function M.tunnel(f, speed, glow)
  shader(f, { src = "shaders/tunnel.sksl", x = 0, y = 0, w = 1920, h = 1080, uniforms = {
    uT = beat.gsec(f), uSpeed = speed, uGlow = glow, uHot = ORANGE, uBone = BONE } })
end

local function film(x, y, w, h)
  for i = 0, 21 do
    local hx = x + 10 + i * (w - 20) / 21
    rect { x = hx, y = y - 26, w = 14, h = 10, rx = 2, fill = "#2d2a27" }
    rect { x = hx, y = y + h + 16, w = 14, h = 10, rx = 2, fill = "#2d2a27" }
  end
end

local function feed(f, src, r)
  local v = clip_input(src)
  v.x, v.y, v.w, v.h = r[1], r[2], r[3], r[4]
  video_frame(f, v)
end

function M.render(f, lb)
  local enter_l = expo_out(prog(lb, 0, 0.7))
  local enter_r = expo_out(prog(lb, 0.5, 1.2))
  local keyed = lb >= 4
  local secs = f.index / f.fps
  local tc = timecode(secs + 28)
  local tc2 = timecode(secs + 246)
  local lx, ly, lw, lh = LEFT[1], LEFT[2], LEFT[3], LEFT[4]
  local rx, ry, rw, rh = RIGHT[1], RIGHT[2], RIGHT[3], RIGHT[4]
  local exit = expo_in(prog(lb, 5.75, 6))
  group({ opacity = 1 - exit }, function()
    text { "VIDEO", x = 150, y = 220, font = DISPLAY, size = 120, letter_spacing = -4, fill = BONE }
    label(154, 110, "03", ORANGE, 26, "start")
    group({ opacity = enter_l, transform = translate(0, (1 - enter_l) * 80) }, function()
      film(lx, ly, lw, lh)
      feed(f, "left_clip.mp4", LEFT)
      label(lx, ly + lh + 70, "LEFT.MP4  " .. tc, GREY, 18, "start")
    end)
    label(1770, 220, "DECODED BY FFMPEG · IN SYNC TO THE FRAME", GREY, 18, "end")
  end)
  group({ opacity = enter_r, transform = translate(0, (1 - enter_r) * 80) }, function()
    film(rx, ry, rw, rh)
    if keyed then
      local flicker = 1
      if lb < 4.25 then flicker = hash(lb * 211) > 0.5 and 1 or 0 end
      group({ clip = { x = rx, y = ry, w = rw, h = rh } }, function() M.tunnel(f, 3, 1) end)
      group({ opacity = flicker }, function() M.keyed_guest(f, RIGHT, 0, 1) end)
    else
      feed(f, "right_clip.mp4", RIGHT)
    end
    label(rx, ry + rh + 70, "RIGHT.MP4  " .. tc2, GREY, 18, "start")
    label(rx + rw, ry + rh + 70, keyed and "CHROMA KEY · SKSL" or "", ORANGE, 18, "end")
  end)
end

return M
