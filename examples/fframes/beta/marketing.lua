-- fframes' marketing video as one frame function, embedded by the beta's
-- "BetaExamples" scene (the same code as examples/fframes/marketing/video.lua). The
-- beta calls it with the scene's frame, so the spectrum and the timings are
-- scene relative, as in the original.

local shared = dofile("shared.lua")
local clamp01, svg_viewport, translate_group, ferris = shared.clamp01, shared.svg_viewport, shared.translate_group, shared.ferris

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

local function render(f)
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
end

return render
