-- fframes' tiktok example (one 1080x1920 frame), embedded by the beta's
-- "BetaExamples" scene with the global frame: blurred colour blobs, a
-- centred spectrum of thought.mp3, word-wrapped subtitles and the goose.

local W, H = 1080, 1920
local BAR_SIZE, BAR_PADDING = 30, 20
local SPECTRUM_WIDTH = 16 * (BAR_SIZE + BAR_PADDING) - BAR_PADDING

-- The four blobs: <g filter mix-blend-mode opacity><ellipse/></g>. Each
-- filter is flood(0) + blend + gaussian blur in sRGB over an explicit
-- userSpaceOnUse region, which cuts the blur.
local function blob(region, std, blend, opacity)
  region.units = "userSpaceOnUse"
  return { blend = blend, opacity = opacity, filter = { { "blur", std = std }, region = region }, srgb = true }
end
local BLOBS = {
  { g = blob({ x = -66.271, y = 140.76, w = 1031.86, h = 1023.68 }, 100, "hard-light"),
    t = { transform = rotate(70, 449.658, 652.599) },
    e = { cx = 449.658, cy = 652.599, rx = 311.126, ry = 316.462, fill = "#b011e8" } },
  { g = blob({ x = 194.823, y = 954.499, w = 983.941, h = 977.681 }, 140, nil),
    t = { transform = { .00844, .99996, -.99984, .01802, 686.793, 1443.34 } },
    e = { cx = 0, cy = 0, rx = 208.812, ry = 211.997, fill = "#b310ff" } },
  { g = blob({ x = 26.522, y = 550.447, w = 759.054, h = 753 }, 100, "lighten", 0.5),
    t = { transform = { .00844, .99996, -.99984, .01802, 406.049, 927.243 } },
    e = { cx = 0, cy = 0, rx = 176.773, ry = 179.55, fill = "#ff9900" } },
  { g = blob({ x = -15.573, y = 578.228, w = 1161.46, h = 1159.48 }, 100, "hard-light"),
    t = { transform = rotate(70, 565.155, 1157.97) },
    e = { cx = 565.155, cy = 1157.97, rx = 379.483, ry = 380.775, fill = "#454acf" } },
}
local SCREEN = { clip = { x = 0, y = 0, w = W, h = H } }

-- fframes' text_break_lines for a monospaced font: every char is
-- `size * advance / unitsPerEm` px (JetBrains Mono: 600 / 1000, integer),
-- words wrap at `width`, and each line is a tspan at x + dx (centred in
-- `width`), y + index * line_height.
local FONT, SIZE, CHAR_W = "JetBrains Mono", 100, 100 * 600 // 1000
local WRAP_WIDTH, LINE_HEIGHT = 1000, 1.2
local TEXT_X, TEXT_Y = 40, 0.34 * H

local wrap_cache = {}
local function break_lines(value)
  local cached = wrap_cache[value]
  if cached then return cached end
  local lines = { { words = {}, width = 0 } }
  for line in (value .. "\n"):gmatch("(.-)\n") do
    local first = true
    for word in line:gmatch("%S+") do
      local word_w = utf8.len(word) * CHAR_W
      local last = lines[#lines]
      local sep = last.width == 0 and 0 or CHAR_W
      if last.width + sep + word_w > WRAP_WIDTH and #last.words > 0 then
        lines[#lines + 1] = { words = { word }, width = word_w }
      else
        last.width = last.width + sep + word_w
        last.words[#last.words + 1] = word
      end
      first = false
    end
    if not first then lines[#lines + 1] = { words = {}, width = 0 } end
  end
  if #lines[#lines].words == 0 and lines[#lines].width == 0 then lines[#lines] = nil end
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = { text = table.concat(l.words, " "),
      x = TEXT_X + math.max(WRAP_WIDTH - l.width, 0) // 2,
      y = TEXT_Y + math.floor((i - 1) * LINE_HEIGHT * SIZE) }
  end
  wrap_cache[value] = out
  return out
end

local function render(f)
  local spectrum = audio_spectrum(f, { src = "thought.mp3", sample_size = 32, smooth = 4 })
  spectrum = spectrum and spectrum_centered(spectrum) or {}

  -- <svg width=1080 height=1920>: clipped to its viewport.
  group(SCREEN, function()
    -- Black background
    rect { x = 0, y = 0, w = W, h = H, fill = "#000000" }
    -- Background gradient ellipses
    for _, b in ipairs(BLOBS) do
      group(b.g, function()
        group(b.t, function() ellipse(b.e) end)
      end)
    end

    -- Audio visualization bars
    for i, value in ipairs(spectrum) do
      local h = math.max(30, math.min(400, value * 2000))
      rect { x = (i - 1) * (BAR_SIZE + BAR_PADDING) + (W - SPECTRUM_WIDTH) // 2, y = 300 - h / 2,
        w = BAR_SIZE, h = h, rx = 15, ry = 15, fill = "#ffffff" }
    end

    local cue = subtitle_at(f, "thought.vtt")
    if cue then
      for _, l in ipairs(break_lines(cue.text)) do
        text { l.text, x = l.x, y = l.y, font = FONT, size = SIZE, weight = 400, fill = "#ffffff" }
      end
    end

    image { src = "goose2.png", w = 950, h = 950, y = H - 950, x = W // 2 - 400 }
  end)
end

return render
