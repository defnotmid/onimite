-- fframes' audio-announce example: an audio visualisation of a voice-over
-- (the sound of video.mp4) with glowing word-wrapped subtitles, a looping
-- transparent avatar clip and four spectrum "waves".
--
--     onimite render examples/fframes/audio_announce/video.lua -o audio_announce.mp4
--
-- 1920x1080 @ 30 fps; as long as the voice-over (fframes' Duration::Auto).

local W, H = 1920, 1080
local FONT = "JetBrains Mono"
local AUDIO = "video.mp4"

-- The avatar: transparent.mov (ProRes 4444 with alpha), looping, resized to
-- 300x300 with its aspect not kept, as fframes' `into_resized_image`.
local AVATAR = "transparent.mov"
local AVATAR_SIZE, AVATAR_X, AVATAR_Y = 300, 80, 100

-- <filter id="glow" color-interpolation-filters="sRGB"> from the original:
-- a pink outer glow (blurred hard alpha, outside the shape) under the source.
local GLOW = {
  srgb = true,
  filter = {
    { "flood", color = "#000000", opacity = 0, result = "BackgroundImageFix" },
    { "color_matrix", input = "SourceAlpha", type = "matrix",
      values = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 127, 0 }, result = "hardAlpha" },
    { "offset", dx = 0, dy = 0, input = "hardAlpha", result = "r3" },
    { "blur", std = 18.3, input = "r3", result = "r4" },
    { "composite", op = "out", input = "r4", input2 = "hardAlpha", result = "r5" },
    { "color_matrix", input = "r5", type = "matrix",
      values = { 0, 0, 0, 0, 0.654173, 0, 0, 0, 0, 0.116095, 0, 0, 0, 0, 0.56808, 0, 0, 0, 1, 0 }, result = "r6" },
    { "blend", mode = "normal", input = "r6", input2 = "BackgroundImageFix", result = "effect1_dropShadow_8_18" },
    { "blend", mode = "normal", input = "SourceGraphic", input2 = "effect1_dropShadow_8_18", result = "shape" },
  },
}

-- svg_waves.rs: a closed cubic spline through the spectrum values (Thomas
-- algorithm for the control points), baseline at the bottom of the frame.
local function control_points(p)
  local n = #p - 1 -- points are p[1..n+1] (Rust 0..n)
  local a, b, c, r, p1, p2 = {}, {}, {}, {}, {}, {}
  for i = 0, n do a[i], b[i], c[i], r[i], p1[i], p2[i] = 0, 0, 0, 0, 0, 0 end
  local P = function(i) return p[i + 1] end
  a[0], b[0], c[0], r[0] = 0, 2, 1, P(0) + 2 * P(1)
  for i = 1, n - 1 do
    a[i], b[i], c[i], r[i] = 1, 4, 1, 4 * P(i) + 2 * P(i + 1)
  end
  a[n - 1], b[n - 1], c[n - 1], r[n - 1] = 2, 7, 0, 8 * P(n - 1) + P(n)
  for i = 1, n - 1 do
    local m = a[i] / b[i - 1]
    b[i] = b[i] - m * c[i - 1]
    r[i] = r[i] - m * r[i - 1]
  end
  p1[n - 1] = r[n - 1] / b[n - 1]
  for i = n - 1, 0, -1 do p1[i] = (r[i] - c[i] * p1[i + 1]) / b[i] end
  for i = 0, n - 2 do p2[i] = 2 * P(i + 1) - p1[i + 1] end
  p2[n - 1] = (P(n) + p1[n - 1]) / 2
  return p1, p2
end

local function fmt(v) return string.format("%.4f", v) end

local function frequencies_to_path(x_step, y_mul, freqs)
  local xs, ys = { 0 }, { 0 }
  for i, f in ipairs(freqs) do
    xs[#xs + 1] = i * x_step
    ys[#ys + 1] = math.min(f * y_mul, 600)
  end
  xs[#xs + 1] = (#freqs + 1) * x_step
  ys[#ys + 1] = 0
  local x1, x2 = control_points(xs)
  local y1, y2 = control_points(ys)
  local out = { " M ", fmt(xs[1]), " ", fmt(H - ys[1]) }
  for i = 2, #xs do
    local k = i - 2
    out[#out + 1] = string.format(" C %s %s %s %s %s %s", fmt(x1[k]), fmt(H - y1[k]), fmt(x2[k]),
      fmt(H - y2[k]), fmt(xs[i]), fmt(H - ys[i]))
  end
  out[#out + 1] = " z"
  return table.concat(out)
end

-- Iterator helpers: `iter().step_by(n)` and `into_iter().rev().step_by(n)`.
local function step_by(list, n)
  local out = {}
  for i = 1, #list, n do out[#out + 1] = list[i] end
  return out
end
local function rev_step_by(list, n)
  local out = {}
  for i = #list, 1, -n do out[#out + 1] = list[i] end
  return out
end

-- Wrapped lines per subtitle phrase (fframes caches text_break_lines too),
-- `trunc(i * 1.2 * 120)` apart.
local line_cache = {}
local function wrap(phrase)
  local lines = line_cache[phrase]
  if not lines then
    local trimmed = phrase:match("^%s*(.-)%s*$")
    lines = trimmed == "" and {} or text_lines { trimmed, font = FONT, size = 120, max_width = 1400 }
    line_cache[phrase] = lines
  end
  return lines
end

video { width = W, height = H, fps = 30, background = "#000000",
  duration = { audio = AUDIO },
  audio = { { AUDIO, start = 0 } },
  render = function(f)
    image { src = "background.png", x = 0, y = 0, w = W, h = H }

    -- Glowing subtitles (text_break_lines, width 1400, line height 1.2).
    local cue = subtitle_at(f, "subtitles.vtt")
    local phrase = cue and cue.text or ""
    group(GLOW, function()
      for i, l in ipairs(wrap(phrase)) do
        text { l, x = 450, y = 170 + math.floor((i - 1) * 1.2 * 120), font = FONT, size = 120, weight = 400,
          baseline = "middle", fill = "#ffffff", stroke = "#FF208B", stroke_width = 1 }
      end
    end)

    -- The looping avatar with the same glow.
    group(GLOW, function()
      video_frame(f, { src = AVATAR, x = AVATAR_X, y = AVATAR_Y, w = AVATAR_SIZE, h = AVATAR_SIZE,
        fit = "fill", looping = true })
    end)

    -- The waves: 256 spectrum values (512 samples, Hann, smoothed over 4 frames).
    local vis = audio_spectrum(f, { src = AUDIO, sample_size = 512, smooth = 4, window = "hann" }) or {}
    group({ opacity = 0.5 }, function()
      local st = { stroke = "#ffffff", stroke_width = 6 }
      path { d = frequencies_to_path(100, 1200, step_by(vis, 2)), fill = "#4C20A8", stroke = st.stroke, stroke_width = 6 }
      path { d = frequencies_to_path(100, 400, step_by(vis, 4)), fill = "#9370DB" --[[ mediumpurple ]], stroke = st.stroke, stroke_width = 6 }
      path { d = frequencies_to_path(100, 1200, step_by(vis, 6)), fill = "#db2777", stroke = st.stroke, stroke_width = 6 }
      group({ transform = translate(-1600, 0) }, function()
        path { d = frequencies_to_path(100, 1200, rev_step_by(vis, 7)), fill = "#ea580c", stroke = st.stroke, stroke_width = 6 }
      end)
    end)
  end,
}
