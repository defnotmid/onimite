-- fframes' marketing example: an audio spectrum of pill-shaped bars with
-- coloured glows, Ferris peeking in, a code card with a hand-drawn arrow, and
-- the "fframes" outro with a drawn-on wave.
--
--     onimite render examples/fframes/marketing/video.lua -o marketing.mp4

local W, H = 1920, 1080

-- fframes' `SPRING` (mass 1.85, stiffness 130, damping 16).
local SPRING = spring { mass = 1.85, stiffness = 130, damping = 16 }
local CODE_SPRING = spring { mass = 0.85, stiffness = 80, damping = 16 }

-- Drawing order is the array order (stacking); `position` is the slot on
-- screen and `index` the spectrum value (0-based, as in the original).
local PRETTY_SPECTRUM = {
  { position = 6, index = 6, from = "#ec4899", to = "#f43f5e" },
  { position = 0, index = 3, from = "#d946ef", to = "#9333ea" },
  { position = 5, index = 5, from = "#facc15", to = "#f97316" },
  { position = 1, index = 7, from = "#38bdf8", to = "#6366f1" },
  { position = 4, index = 4, from = "#4ade80", to = "#06b6d4" },
  { position = 2, index = 2, from = "#22d3ee", to = "#0ea5e9" },
  { position = 3, index = 1, from = "#ffffff", to = "#ffffff" },
}

local BAR_SIZE = 96
local BAR_MARGIN = 20
local BAR_WIDTH_WITH_MARGIN = BAR_SIZE + BAR_MARGIN
-- viewbox width - space that all bars take - right margin
local SPECTRUM_LEN = W - BAR_WIDTH_WITH_MARGIN * #PRETTY_SPECTRUM - BAR_MARGIN

-- Static per-bar paints and glow filters, built once.
for _, bar in ipairs(PRETTY_SPECTRUM) do
  bar.x0 = SPECTRUM_LEN // 2 + bar.position * BAR_WIDTH_WITH_MARGIN
  bar.gradient = linear_gradient { units = "bbox", x1 = 0, y1 = 0, x2 = 1, y2 = 1,
    stops = { { 0, bar.from }, { 1, bar.to } } }
  bar.filter = {
    { "blur", std = 10.4, input = "SourceAlpha" },
    { "offset", dx = 0, dy = 3, result = "offsetblur" },
    { "flood", color = bar.to, opacity = 0.5 },
    { "composite", op = "in", input2 = "offsetblur", result = "shadow" },
    { "merge", "shadow", "SourceGraphic" },
  }
  bar.group = { filter = bar.filter }
end

local WAVE_GRADIENT = linear_gradient { units = "bbox", x1 = 0, y1 = 0, x2 = 1, y2 = 0,
  stops = { { 0, "#ec77ab" }, { 1, "#4f46e5" } } }

local function clamp01(v) return math.max(0, math.min(1, v)) end

-- A nested <svg x y width height viewBox> (preserveAspectRatio xMidYMid
-- meet, clipped to its viewport).
local function svg_viewport(x, y, w, h, vbw, vbh, content)
  local s = math.min(w / vbw, h / vbh)
  local tx = x + (w - vbw * s) / 2
  local ty = y + (h - vbh * s) / 2
  group({ clip = { x = x, y = y, w = w, h = h } }, function()
    group({ transform = { translate = { tx, ty }, scale = s } }, content)
  end)
end

-- <g transform="matrix(a b c d e f)">.
local function matrix(a, b, c, d, e, f)
  return { transform = { matrix = { a, b, c, d, e, f } } }
end

local function at(x, y) return { transform = { translate = { x, y } } } end

local function translate_group(x, y, content)
  group({ transform = translate(x, y) }, content)
end

-- Static group transforms of Ferris' parts.
local G_BODY, G_CLAW_R, G_CLAW_L = at(597.344, 637.02), at(1068.75, 575.642), at(149.064, 591.421)
local G_GEAR = matrix(-65.8097, -752.207, -752.207, 65.8097, 621.707, 796.312)
local G_MOUTH_L, G_MOUTH_R = at(450.328, 483.629), at(747.12, 477.333)
local G_SHADE1 = matrix(-1.53e-05, -267.211, -267.211, 1.53e-05, 809.465, 764.23)
local G_EYE_R_BG, G_EYE_L_BG = at(677.392, 509.61), at(483.3, 502.984)
local G_SHADE2 = matrix(-1.53e-05, -239.021, -239.021, 1.53e-05, 402.161, 775.388)

local FERRIS_RED = rgb(165, 43, 0)
local LINEAR1 = linear_gradient { x1 = 0, y1 = 0, x2 = 1, y2 = 0,
  transform = { 1, 0, 1.38778e-17, -1, 0, -0.000650515 },
  stops = { { 0, rgb(247, 76, 0) }, { 0.33, rgb(247, 76, 0) }, { 1, rgb(244, 150, 0) } } }
local LINEAR2 = linear_gradient { x1 = 0, y1 = 0, x2 = 1, y2 = 0,
  transform = { 1, 0, 0, -1, 0, 1.23438e-06 },
  stops = { { 0, rgb(204, 58, 0) }, { 0.15, rgb(204, 58, 0) }, { 0.74, rgb(247, 76, 0) }, { 1, rgb(247, 76, 0) } } }
local LINEAR3 = linear_gradient { x1 = 0, y1 = 0, x2 = 1, y2 = 0,
  transform = { 1, 1.32349e-23, 1.32349e-23, -1, 0, -9.1568e-07 },
  stops = { { 0, rgb(204, 58, 0) }, { 0.15, rgb(204, 58, 0) }, { 0.74, rgb(247, 76, 0) }, { 1, rgb(247, 76, 0) } } }

-- Ferris in its 1200x800 viewBox; `right_eye` / `left_eye` are the x
-- translations of the two pupils.
local function ferris(right_eye, left_eye)
  -- Ferris body
  group(G_BODY, function()
    path { d = "M0,-279.559C-121.238,-279.559 -231.39,-264.983 -312.939,-241.23L-312.939,-38.329C-231.39,-14.575 -121.238,0 0,0C138.76,0 262.987,-19.092 346.431,-49.186L346.431,-230.37C262.987,-260.465 138.76,-279.559 0,-279.559", fill = FERRIS_RED }
  end)
  -- Right claw
  group(G_CLAW_R, function()
    path { d = "M0,-53.32L-14.211,-82.761C-14.138,-83.879 -14.08,-84.998 -14.08,-86.121C-14.08,-119.496 -48.786,-150.256 -107.177,-174.883L-107.177,2.643C-79.932,-8.849 -57.829,-21.674 -42.021,-35.482C-46.673,-16.775 -62.585,21.071 -75.271,47.686C-96.121,85.752 -103.671,118.889 -102.703,120.53C-102.086,121.563 -94.973,110.59 -84.484,92.809C-60.074,58.028 -13.82,-8.373 -4.575,-25.287C5.897,-44.461 0,-53.32 0,-53.32", fill = FERRIS_RED }
  end)
  -- Left claw
  group(G_CLAW_L, function()
    path { d = "M0,-99.954C0,-93.526 1.293,-87.194 3.788,-80.985L-4.723,-65.835C-4.723,-65.835 -11.541,-56.989 0.465,-38.327C11.055,-21.872 64.1,42.54 92.097,76.271C104.123,93.564 112.276,104.216 112.99,103.187C114.114,101.554 105.514,69.087 81.631,32.046C70.487,12.151 57.177,-14.206 49.189,-33.675C71.492,-19.559 100.672,-6.755 135.341,4.265L135.341,-204.17C51.797,-177.622 0,-140.737 0,-99.954", fill = FERRIS_RED }
  end)
  -- Ferris logo/gear detail
  group(G_GEAR, function()
    path { d = "M0.991,-0.034L0.933,0.008C0.933,0.014 0.933,0.02 0.933,0.026L0.99,0.069C0.996,0.073 0.999,0.08 0.998,0.087C0.997,0.094 0.992,0.1 0.986,0.103L0.92,0.133C0.919,0.139 0.918,0.145 0.916,0.15L0.964,0.203C0.968,0.208 0.97,0.216 0.968,0.222C0.965,0.229 0.96,0.234 0.953,0.236L0.882,0.254C0.88,0.259 0.877,0.264 0.875,0.27L0.91,0.33C0.914,0.336 0.914,0.344 0.91,0.35C0.907,0.356 0.9,0.36 0.893,0.361L0.82,0.365C0.817,0.369 0.813,0.374 0.81,0.379L0.832,0.445C0.835,0.452 0.833,0.459 0.828,0.465C0.824,0.47 0.816,0.473 0.809,0.472L0.737,0.462C0.733,0.466 0.729,0.47 0.724,0.474L0.733,0.544C0.734,0.551 0.731,0.558 0.725,0.562C0.719,0.566 0.711,0.568 0.704,0.565L0.636,0.542C0.631,0.546 0.626,0.549 0.621,0.552L0.615,0.621C0.615,0.629 0.61,0.635 0.604,0.638C0.597,0.641 0.589,0.641 0.583,0.638L0.521,0.602C0.52,0.603 0.519,0.603 0.518,0.603L0.406,0.729C0.406,0.729 0.394,0.747 0.359,0.725C0.329,0.705 0.206,0.599 0.141,0.543C0.109,0.52 0.089,0.504 0.09,0.502C0.093,0.499 0.149,0.509 0.217,0.554C0.278,0.588 0.371,0.631 0.38,0.619C0.38,0.619 0.396,0.604 0.406,0.575C0.406,0.575 0.406,0.575 0.406,0.575C0.407,0.576 0.407,0.576 0.406,0.575C0.406,0.575 0.091,0.024 0.305,-0.531C0.311,-0.593 0.275,-0.627 0.275,-0.627C0.266,-0.639 0.178,-0.598 0.12,-0.566C0.055,-0.523 0.002,-0.513 0,-0.516C-0.001,-0.518 0.018,-0.533 0.049,-0.555C0.11,-0.608 0.227,-0.707 0.256,-0.726C0.289,-0.748 0.301,-0.73 0.301,-0.73L0.402,-0.615C0.406,-0.614 0.41,-0.613 0.415,-0.613L0.47,-0.658C0.475,-0.663 0.483,-0.664 0.49,-0.662C0.497,-0.66 0.502,-0.655 0.504,-0.648L0.522,-0.58C0.527,-0.578 0.533,-0.576 0.538,-0.574L0.602,-0.608C0.608,-0.612 0.616,-0.612 0.623,-0.608C0.629,-0.605 0.633,-0.599 0.633,-0.592L0.637,-0.522C0.642,-0.519 0.647,-0.515 0.652,-0.512L0.721,-0.534C0.728,-0.536 0.736,-0.535 0.741,-0.531C0.747,-0.526 0.75,-0.519 0.749,-0.512L0.738,-0.443C0.742,-0.439 0.746,-0.435 0.751,-0.431L0.823,-0.439C0.83,-0.44 0.837,-0.437 0.842,-0.432C0.847,-0.426 0.848,-0.419 0.845,-0.412L0.821,-0.347C0.824,-0.342 0.828,-0.337 0.831,-0.332L0.903,-0.327C0.911,-0.327 0.917,-0.322 0.92,-0.316C0.924,-0.31 0.924,-0.302 0.92,-0.296L0.883,-0.236C0.885,-0.231 0.887,-0.226 0.889,-0.22L0.959,-0.202C0.966,-0.2 0.972,-0.195 0.974,-0.188C0.976,-0.181 0.974,-0.174 0.969,-0.168L0.92,-0.116C0.921,-0.111 0.923,-0.105 0.924,-0.099L0.988,-0.068C0.995,-0.065 0.999,-0.059 1,-0.052C1.001,-0.045 0.997,-0.038 0.991,-0.034ZM0.406,0.575C0.406,0.575 0.406,0.575 0.406,0.575C0.406,0.575 0.406,0.575 0.406,0.575Z", fill = LINEAR1 }
  end)
  group(G_MOUTH_L, function()
    path { d = "M0,167.33C-1.664,165.91 -2.536,165.068 -2.536,165.068L140.006,153.391C23.733,0 -69.418,122.193 -79.333,135.855L-79.333,167.33L0,167.33Z", fill = "#000000" }
  end)
  group(G_MOUTH_R, function()
    path { d = "M0,171.974C1.663,170.554 2.536,169.71 2.536,169.71L-134.448,159.687C-18.12,0 69.421,126.835 79.335,140.497L79.335,171.974L0,171.974Z", fill = "#000000" }
  end)
  group(G_SHADE1, function()
    path { d = "M1,-0.586C1,-0.586 0.768,-0.528 0.524,-0.165L0.5,-0.064C0.5,-0.064 1.1,0.265 0.424,0.731C0.424,0.731 0.508,0.586 0.405,0.197C0.405,0.197 0.131,0.376 0.14,0.736C0.14,0.736 -0.275,0.391 0.324,-0.135C0.324,-0.135 0.539,-0.691 1,-0.736L1,-0.586Z", fill = LINEAR2 }
  end)
  group(G_EYE_R_BG, function()
    path { d = "M0,-92.063C0,-92.063 43.486,-139.678 86.974,-92.063C86.974,-92.063 121.144,-28.571 86.974,3.171C86.974,3.171 31.062,47.615 0,3.171C0,3.171 -37.275,-31.75 0,-92.063", fill = "#000000" }
  end)
  translate_group(right_eye, 435.209, function()
    path { d = "M0,0.002C0,18.543 -10.93,33.574 -24.408,33.574C-37.885,33.574 -48.814,18.543 -48.814,0.002C-48.814,-18.539 -37.885,-33.572 -24.408,-33.572C-10.93,-33.572 0,-18.539 0,0.002", fill = "#ffffff" }
  end)
  group(G_EYE_L_BG, function()
    path { d = "M0,-98.439C0,-98.439 74.596,-131.467 94.956,-57.748C94.956,-57.748 116.283,28.178 33.697,33.028C33.697,33.028 -71.613,12.745 0,-98.439", fill = "#000000" }
  end)
  translate_group(left_eye, 436.428, function()
    path { d = "M0,0C0,19.119 -11.27,34.627 -25.173,34.627C-39.071,34.627 -50.344,19.119 -50.344,0C-50.344,-19.124 -39.071,-34.627 -25.173,-34.627C-11.27,-34.627 0,-19.124 0,0", fill = "#ffffff" }
  end)
  group(G_SHADE2, function()
    path { d = "M0.367,0.129C-0.364,-0.441 0.223,-0.711 0.223,-0.711C0.259,-0.391 0.472,-0.164 0.472,-0.164C0.521,-0.548 0.525,-0.77 0.525,-0.77C1.203,-0.256 0.589,0.161 0.589,0.161C0.627,0.265 0.772,0.372 0.906,0.451L1,0.77C0.376,0.403 0.367,0.129 0.367,0.129Z", fill = LINEAR3 }
  end)
end

local function render_ferris(f)
  if not (f.seconds >= 2.3 and f.seconds < 5.0) then return end
  local y = animate(f, {
    { 2.3, nil, 1400, 770, SPRING },
    { 4.8, nil, 770, 1400, SPRING },
  })
  local right_eye = animate(f, {
    { 3.4, 3.65, 727, 777, linear },
    { 4.1, 4.35, 777, 727, linear },
  })
  local left_eye = animate(f, {
    { 3.4, 3.65, 520, 570, linear },
    { 4.1, 4.35, 570, 520, linear },
  })
  svg_viewport(1456, y, 400, 400, 1200, 800, function() ferris(right_eye, left_eye) end)
end

video { width = W, height = H, fps = 60, background = "#000000",
  -- fframes' Duration::Auto: the end of the last audio track (end.mp3 at 16 s).
  duration = { { seconds = 16 }, { audio = "end.mp3" } },
  -- The original embeds its media with include_media_dir!, which decodes
  -- audio to mono through swresample: 0.707 * (L + R), played on both
  -- channels (`mono = true`; end.mp3 is mono already). audio_spectrum's
  -- default analyses the same downmix.
  audio = {
    { "marketing.mp3", start = 0, mono = true },
    { "woosh.mp3", start = 6, mono = true },
    { "end.mp3", start = 16 },
  },
  render = function(f)
    local spectrum = audio_spectrum(f, { src = "marketing.mp3", sample_size = 16, smooth = 3 })

    rect { x = 0, y = 0, w = W, h = H, fill = "#111827" }

    for _, bar in ipairs(PRETTY_SPECTRUM) do
      local val = spectrum and spectrum[bar.index + 1] or 0
      -- A square-root scale: the upper bins of a 16-sample FFT are faint.
      local bar_height = math.sqrt(val) * 600
      if bar_height ~= bar_height or bar_height < BAR_SIZE then
        bar_height = BAR_SIZE
      elseif bar_height > 720 then
        bar_height = 720
      end
      -- fframes' animate_runtime with a spring runtime of at most 10 s.
      local x = animate(f, { { start = 16, from = bar.x0, to = 944, easing = SPRING } })
      local y = 500 - bar_height / 2

      rect { x = x, y = y, w = BAR_SIZE + 8, h = bar_height + 8, rx = BAR_SIZE // 2, ry = BAR_SIZE // 2,
        fill = "transparent", stroke = "#ffffff", stroke_width = 4 }
      group(bar.group, function()
        rect { x = x, y = y, w = BAR_SIZE, h = bar_height, rx = BAR_SIZE // 2, ry = BAR_SIZE // 2, fill = bar.gradient }
      end)
    end

    -- The hand-drawn arrow: <svg x=200 y=290 width=298> (height 100%).
    local arrow_opacity = clamp01(animate(f, {
      { 5.8, nil, 0, 1, SPRING },
      { 9.0, nil, 1, 0, SPRING },
    }))
    if arrow_opacity > 0 then
      group({ opacity = arrow_opacity }, function()
        svg_viewport(200, 290, 298, H, 598.3520004127504, 417.989493060112, function()
          translate_group(12.76795062351539, 11.630295608565234, function()
            path { d = "M-2.19 -1.63 C8.29 53.64, -34.21 264.71, 62.09 331.05 C158.39 397.38, 490.59 385.91, 575.58 396.36",
              stroke = "#ffffff", stroke_width = 4.5, fill = "none", stroke_dasharray = { 8, 12 }, line_cap = "round" }
            path { d = "M544.61 406.42 C552.39 404.4, 562.6 396.92, 572.02 395.84", stroke = "#ffffff", stroke_width = 4.5, fill = "none" }
            path { d = "M545.58 385.92 C553.02 389.43, 562.97 387.49, 572.02 395.84", stroke = "#ffffff", stroke_width = 4.5, fill = "none" }
          end)
        end)
      end)
    end

    local cue = subtitle_at(f, "subtitles.vtt")
    if cue then
      text { cue.text, x = W / 2, y = H * 0.87, align = "center", size = 64, fill = "#ffffff", font = "Fredoka One" }
    end

    image { src = "code.png", w = 900, h = 900, y = 10, x = animate(f, {
      { 5.8, nil, -1000, 40, CODE_SPRING },
      { 9.0, nil, 40, -1200, CODE_SPRING },
    }) }

    render_ferris(f)

    local r = animate(f, { { 16.2, 16.5, 0, 1200, linear } })
    if r > 0 then
      circle { cx = 960, cy = 500, r = r, fill = "#ffffff" }
    end

    if f.seconds > 16.25 then
      text { x = 960, y = 570, font = "Bubble Bobble", size = 154, align = "center", fill = "#000000", spans = {
        { "ff", fill = f.seconds > 18.8 and "#7351d8" or "#000000" },
        { "rames" },
      } }
      text { "Write some code. Get video. Enjoy!", x = 960, y = 610, font = "Fredoka One", size = 30,
        align = "center", fill = "#000000" }
      -- <g transform="scale(2.7) translate(-218, 110)">
      group({ transform = scale(2.7) }, function()
        group({ transform = translate(-218, 110) }, function()
          path { fill = "none", stroke = WAVE_GRADIENT,
            stroke_width = 10, line_cap = "round", line_join = "round", miter_limit = 10,
            stroke_dashoffset = animate(f, { { 16.3, 18.8, -700, 41, linear } }),
            stroke_dasharray = { 40.4579, 796.447 },
            d = "M505,55c0-27.6-22.4-50-50-50s-50,22.4-50,50c0-27.6-22.4-50-50-50s-50,22.4-50,50c0-27.6-22.4-50-50-50s-50,22.4-50,50c0-27.6-22.4-50-50-50s-50,22.4-50,50c0-27.6-22.4-50-50-50S5,27.4,5,55" }
          path { fill = "none", stroke = "#4f46e5", stroke_width = 6, line_cap = "round", line_join = "round",
            opacity = animate(f, { { 18.6, 18.9, 1, 0.55, linear } }),
            stroke_dashoffset = animate(f, { { 18.7, 19.0, -40, 0, linear } }),
            stroke_dasharray = { animate(f, { { 18.7, 19.0, 30, 12, linear } }), 137 },
            d = "M549.7,46.6l-21.8,12.6 M531.9,25.8l-12.6,21.8 M504.2,18.3v25.1 M476.4,25.8L489,47.6 M458.7,46.6l21.8,12.6" }
        end)
      end)
    end
  end,
}
