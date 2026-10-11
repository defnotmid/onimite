-- fframes' tiktok example as an onimite script: a vertical 1080x1920 video
-- over thought.mp3 with blurred, blended colour blobs, a centred audio
-- spectrum, word-wrapped subtitles from thought.vtt and a goose portrait.
--
--     onimite render examples/fframes/tiktok/video.lua -o tiktok.mp4

local W, H = 1080, 1920
local BAR_SIZE, BAR_PADDING = 30, 20
local SPECTRUM_WIDTH = 16 * (BAR_SIZE + BAR_PADDING) - BAR_PADDING

-- Bar x positions, built once: i * (BAR_SIZE + BAR_PADDING) + (WIDTH - SPECTRUM_WIDTH) / 2
-- (integer division, as the usize maths of the original).
local BAR_X = {}
for i = 0, 15 do
  BAR_X[i + 1] = i * (BAR_SIZE + BAR_PADDING) + (W - SPECTRUM_WIDTH) // 2
end

-- The <filter> regions (filterUnits="userSpaceOnUse"): they cut the blur.
local REGION_HARD = { x = -66.271, y = 140.76, w = 1031.86, h = 1023.68, units = "userSpaceOnUse" }
local REGION_PURPLE = { x = 194.823, y = 954.499, w = 983.941, h = 977.681, units = "userSpaceOnUse" }
local REGION_ORANGE = { x = 26.522, y = 550.447, w = 759.054, h = 753, units = "userSpaceOnUse" }
local REGION_BLUE = { x = -15.573, y = 578.228, w = 1161.46, h = 1159.48, units = "userSpaceOnUse" }

local PURPLE_T = "matrix(.00844 .99996 -.99984 .01802 686.793 1443.34)"
local ORANGE_T = "matrix(.00844 .99996 -.99984 .01802 406.049 927.243)"

-- frame.text_break_lines(BreakLinesOpts { width: 1000, line_height: 1.2,
-- x: "40", y: "34%", JetBrains Mono 100/400, align: Center, fill: white }):
-- captions{} wraps the cue's words within 1000 px and centres each line,
-- line i's baseline at 34% + i * 120. No word is highlighted.
local SUBS = { src = "thought.vtt", x = 40, w = 1000, y = 0.34 * H - 60, baseline = "alphabetic",
  font = "JetBrains Mono", size = 100, weight = 400, line_height = 1.2, fill = "white", active_fill = "white", active_scale = 1 }

video { width = W, height = H, fps = 60, background = "#00000000",
  duration = { audio = "thought.mp3" },
  audio = {
    { "thought.mp3", start = { frame = 0 } },
  },
  render = function(f)
    -- The mono downmix of the music.
    local vis = audio_spectrum(f, { src = "thought.mp3", sample_size = 32, smooth = 4 }) or {}
    vis = spectrum_centered(vis)

    group({ clip = { x = 0, y = 0, w = W, h = H } }, function()
      -- Black background
      rect { x = 0, y = 0, w = W, h = H, fill = "#000" }

      -- Background gradient ellipses: each <g mix-blend-mode filter> is a
      -- gaussian blur in sRGB over its filter region, blended.
      group({ blend = "hard-light", filter = { { "blur", std = 100 }, region = REGION_HARD }, srgb = true }, function()
        group({ transform = rotate(70, 449.658, 652.599) }, function()
          ellipse { cx = 449.658, cy = 652.599, rx = 311.126, ry = 316.462, fill = "#B011E8" }
        end)
      end)
      group({ filter = { { "blur", std = 140 }, region = REGION_PURPLE }, srgb = true }, function()
        group({ transform = PURPLE_T }, function()
          ellipse { cx = 0, cy = 0, rx = 208.812, ry = 211.997, fill = "#B310FF" }
        end)
      end)
      group({ blend = "lighten", opacity = 0.5, filter = { { "blur", std = 100 }, region = REGION_ORANGE }, srgb = true }, function()
        group({ transform = ORANGE_T }, function()
          ellipse { cx = 0, cy = 0, rx = 176.773, ry = 179.55, fill = "#F90" }
        end)
      end)
      group({ blend = "hard-light", filter = { { "blur", std = 100 }, region = REGION_BLUE }, srgb = true }, function()
        group({ transform = rotate(70, 565.155, 1157.97) }, function()
          ellipse { cx = 565.155, cy = 1157.97, rx = 379.483, ry = 380.775, fill = "#454ACF" }
        end)
      end)
    end)

    -- Audio visualization bars
    for i, value in ipairs(vis) do
      local bar_height = math.min(math.max(value * 2000, 30), 400)
      rect { x = BAR_X[i], y = 300 - bar_height / 2, w = BAR_SIZE, h = bar_height,
        rx = 15, fill = "white" }
    end

    captions(f, SUBS)

    -- 766x944 PNG in a 950x950 box: preserveAspectRatio xMidYMid meet.
    image { src = "goose2.png", w = 950, h = 950, y = H - 950, x = W // 2 - 400 }
  end,
}
