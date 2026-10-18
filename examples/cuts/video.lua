-- Cutting and joining clips: an edit written as a list of cuts. Each row
-- becomes a scene{ clip = ... }: it shows exactly that stretch of the file
-- and plays its sound over the same stretch, the sound crossfading wherever
-- a transition overlaps two cuts; `speed` plays a cut faster (its sound too,
-- tape-style). The clips differ in size and frame rate:
-- a 24 fps wide beach, a 9:16 phone clip at 60 fps (letterboxed), a 4:3
-- clip used whole. street.mp4, surf.mp4 and clip.mp4 are made by
-- tools/gen_media/gen.sh.
--
--     onimite preview examples/cuts/video.lua
--     onimite render examples/cuts/video.lua -o cuts.mp4

local W, H = 1280, 720

video { width = W, height = H, fps = 30, background = "#000" }

-- The edit: which file, which stretch, how each cut enters.
local CUTS = {
  { "Beach", clip = { "surf.mp4", from = 0.5, to = 4.5 } },
  { "Street", clip = { "street.mp4", from = 0.4, to = 5.2, speed = 2 }, transition = { "fade", duration = 0.5 } },
  { "Balloon", clip = "clip.mp4", transition = { "slide", from = "right", duration = 0.4, easing = ease_in_out } },
  { "Shore", clip = { "surf.mp4", from = 4.5, to = 8, picture = { fit = "cover" }, sound = { gain_db = -3 } },
    transition = { "wipe", duration = 0.6, softness = 120 } },
}

-- A label on each cut naming what it shows.
local function label(c)
  local clip = type(c.clip) == "string" and { c.clip } or c.clip
  local text_ = clip.from and string.format("%s  %.1f – %.1f s", clip[1], clip.from, clip.to) or clip[1] .. "  whole file"
  if clip.speed then text_ = string.format("%s  at %g×", text_, clip.speed) end
  local w = text_width { text_, font = "DM Sans", size = 26 } + 40
  return function(f)
    group({ opacity = animate(f, { { start = 0.3, stop = 0.7, from = 0, to = 1 } }) }, function()
      rect { x = 40, y = H - 92, w = w, h = 52, rx = 26, fill = "#0b1020cc" }
      text { text_, x = 60, y = H - 57, font = "DM Sans", size = 26, fill = "#f8fafc" }
    end)
  end
end

for _, c in ipairs(CUTS) do
  scene { c[1], clip = c.clip, transition = c.transition, render = label(c) }
end
