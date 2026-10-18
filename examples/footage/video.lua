-- Footage anywhere a picture goes: clips inside Pip's silhouette (an SVG as a
-- mask), inside the word RAIN (text as a mask), through a ripple shader, and
-- in a grid at four speeds. Each scene's clip row (scene{ clip = ... },
-- picture = false) places the clip's sound and the scene's length; its
-- render draws the same row's picture where it wants it, so picture and
-- sound read one stretch at one speed. street.mp4, surf.mp4 and clip.mp4
-- are made by tools/gen_media/gen.sh (as examples/cuts' are).
--
--     onimite preview examples/footage/video.lua
--     onimite render examples/footage/video.lua -o footage.mp4

local pip = dofile("../common/pip.lua")
local W, H = 1280, 720
local BG = "#14121f"

video { width = W, height = H, fps = 30, background = BG }

-- A clip row's picture in a box, from the row: where it starts in the file
-- and how fast it plays.
local function footage(f, c, box)
  local speed = c.speed or 1
  video_frame(f, { src = c[1], x = box[1], y = box[2], w = box[3], h = box[4], fit = "cover",
    clip_start = speed < 0 and c.to or c.from, speed = speed })
end

local function caption(f, s)
  group({ opacity = animate(f, { { start = 0.4, stop = 0.9, from = 0, to = 1 } }) }, function()
    text { s, x = W / 2, y = H - 48, align = "center", font = "DM Sans", weight = 500, size = 28, fill = "#cbd5e1" }
  end)
end

local FADE = { "fade", duration = 0.5 }

-- Pip, cut out of the beach.
local BEACH = { "surf.mp4", from = 0.5, to = 4.5, picture = false }
scene { "Pip", clip = BEACH, render = function(f)
  local size = 520
  local x, y = (W - size) / 2, 40
  group({ mask_type = "alpha", mask = function()
    svg { markup = pip.MARKUP, x = x, y = y, w = size, h = size,
      overrides = { eyes_open = { visible = false }, mouth_smile = { visible = false }, spark_a = { visible = false } } }
  end }, function()
    footage(f, BEACH, { x, y, size, size })
  end)
  caption(f, "an SVG as a mask")
end }

-- The street, through the letters.
local STREET = { "street.mp4", from = 0.5, to = 4.5, picture = false }
scene { "Rain", clip = STREET, transition = FADE, render = function(f)
  group({ mask_type = "alpha", mask = function()
    text { "RAIN", x = W / 2, y = 520, align = "center", font = "Bebas Neue", size = 560, fill = "#fff" }
  end }, function()
    footage(f, STREET, { 0, 0, W, H })
  end)
  caption(f, "text as a mask")
end }

-- The balloon through a ripple: the clip is the shader's child, sampled
-- where the waves push it.
local RIPPLE = [[
uniform float3 iResolution;
uniform float iTime;
uniform shader uClip;
half4 main(float2 coord) {
  float2 c = iResolution.xy * 0.5;
  float r = length(coord - c);
  float2 off = normalize(coord - c + 0.001) * sin(r * 0.045 - iTime * 5.0) * 9.0 * smoothstep(0.0, 1.5, iTime);
  return uClip.eval(coord + off);
}]]
local BALLOON = { "clip.mp4", from = 0, to = 4, picture = false }
scene { "Ripple", clip = BALLOON, transition = FADE, render = function(f)
  local w, h = 760, 570
  shader(f, { sksl = RIPPLE, x = (W - w) / 2, y = 40, w = w, h = h,
    uniforms = { uClip = { src = "clip.mp4", clip_start = BALLOON.from } } })
  caption(f, "a clip through a shader")
end }

-- Four cuts at four speeds; the sound is the top left one's.
local GRID = {
  { "surf.mp4", from = 0, to = 2, speed = 0.5, label = "0.5×" },
  { "street.mp4", from = 0, to = 6, speed = 1.5, label = "1.5×" },
  { "clip.mp4", from = 0, to = 4, speed = -1, label = "backwards" },
  { "surf.mp4", from = 3, to = 7, label = "1×" },
}
local first = GRID[1]
scene { "Grid", clip = { first[1], from = first.from, to = first.to, speed = first.speed, picture = false },
  transition = FADE, render = function(f)
  local gap, cw, ch = 16, 420, 300
  local x0, y0 = (W - 2 * cw - gap) / 2, 30
  for i, c in ipairs(GRID) do
    local x, y = x0 + ((i - 1) % 2) * (cw + gap), y0 + math.floor((i - 1) / 2) * (ch + gap)
    group({ clip = { x, y, cw, ch, rx = 16 } }, function()
      rect { x = x, y = y, w = cw, h = ch, fill = "#000" }
      footage(f, c, { x, y, cw, ch })
    end)
    text { c.label, x = x + 16, y = y + ch - 18, font = "DM Sans", weight = 700, size = 24, fill = "#fff" }
  end
  caption(f, "one clip row per cut: speed, and backwards")
end }
