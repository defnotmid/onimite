-- The first drop on "GPU", then the render pipeline, which has no browser in it.

local beat = require("beat")
local ui = require("ui")
local prog, expo_out, expo_in, snap, hash, fract =
  beat.prog, beat.expo_out, beat.expo_in, beat.snap, beat.hash, beat.fract
local ORANGE, BONE, GREY, INK, MONO, DISPLAY = ui.ORANGE, ui.BONE, ui.GREY, ui.INK, ui.MONO, ui.DISPLAY

local function slam(lb)
  local s = 1 + (1 - expo_out(lb / 0.35)) * 0.18
  local shake = (1 - prog(lb, 0, 0.5)) * 14
  local dx = (hash(lb * 97) - 0.5) * shake
  local dy = (hash(lb * 53 + 3) - 0.5) * shake
  local dot = snap(lb - 1)
  rect { x = 0, y = 0, w = 1920, h = 1080, fill = ORANGE }
  group({ transform = string.format("translate(%s %s) translate(150 790) scale(%s) translate(-150 -790)", dx, dy, s) },
    function()
      text { "GPU", x = 120, y = 880, font = DISPLAY, size = 760, letter_spacing = -40, fill = INK }
      group({ transform = translate(0, (1 - dot) * -300) }, function()
        rect { x = 1605, y = 765, w = 115, h = 115, fill = INK, opacity = prog(lb, 1, 1.05) }
      end)
    end)
  local function t(s_, x, align)
    text { s_, x = x, y = 170, align = align, font = MONO, weight = 600, size = 22, letter_spacing = 4, fill = INK }
  end
  t("SKIA", 130)
  t("METAL", 330)
  t("VULKAN", 540)
  t("NO BROWSER IN THE LOOP", 1790, "end")
  rect { x = 130, y = 196, w = 1660, h = 3, fill = INK }
end

local NODES = {
  { "svgr!", "SVG TREE / FRAME" },
  { "SKIA", "GANESH, GPU" },
  { "METAL", "VULKAN ON LINUX" },
  { "FFMPEG", "H.264 · HEVC · VP9" },
  { ".MP4", "OUT.MP4" },
}

-- The pipeline from svgr! through Skia, the GPU and ffmpeg to an .mp4, with
-- packets moving on the beat.
local function pipeline(l)
  local title_in = snap(l)
  local exit = expo_in(prog(l, 5.7, 6))
  local x0, gap, y = 190, 330, 640
  group({ opacity = 1 - exit }, function()
    group({ transform = translate(0, (1 - title_in) * 60), opacity = prog(l, 0, 0.1) }, function()
      text { "DIRECTLY ON", x = 186, y = 330, font = DISPLAY, size = 120, letter_spacing = -4, fill = BONE }
      text { "THE GPU.", x = 186, y = 450, font = DISPLAY, size = 120, letter_spacing = -4, fill = ORANGE }
    end)
    -- links and packets
    for i = 0, 3 do
      local at = 0.6 + i * 0.35
      local p = expo_out(prog(l, at, at + 0.5))
      local xa = x0 + i * gap + 250
      local len = gap - 250
      rect { x = xa, y = y - 1, w = math.max(len * p, 0.5), h = 2, fill = "#5a564f" }
      for k = 0, 2 do
        local phase = fract(l * 2 + k / 3 + i * 0.21)
        if l > at + 0.5 then
          rect { x = xa + phase * len - 6, y = y - 4, w = 12, h = 8, fill = ORANGE }
        end
      end
    end
    for i, node in ipairs(NODES) do
      local at = 0.4 + (i - 1) * 0.35
      local s = snap(l - at)
      local hot = i == 3
      group({ opacity = prog(l, at, at + 0.1), transform = translate(x0 + (i - 1) * gap, y + (1 - s) * 50) }, function()
        rect { x = 0, y = -70, w = 250, h = 140, fill = hot and ORANGE or "#121110", stroke = hot and ORANGE or "#5a564f",
          stroke_width = 2 }
        text { node[1], x = 125, y = 8, align = "middle", font = DISPLAY, size = 40, fill = hot and INK or BONE }
        text { node[2], x = 125, y = 46, align = "middle", font = MONO, weight = 500, size = 15, letter_spacing = 1.5,
          fill = hot and INK or GREY }
      end)
    end
    ui.label(190, 820, "NO HEADLESS BROWSER. NO SCREENSHOTS. NO REACT.", GREY, 22, "start")
    text { "1920×1080 · 60 FPS", x = 1730, y = 450, align = "end", font = MONO, weight = 600, size = 30, fill = ORANGE,
      opacity = prog(l, 2, 2.2) }
  end)
end

local function render(f, lb)
  if lb < 2 then slam(lb) else pipeline(lb - 2) end
end

return { name = "GpuScene", start = 48, stop = 56, render = render }
