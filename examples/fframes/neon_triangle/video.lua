-- fframes' `neon-triangle` example: one neon triangle rotating on pure
-- black at a constant speed, a shader test clip where banding, chroma
-- bleeding and motion artifacts are easy to spot.
--
--     onimite render examples/fframes/neon_triangle/video.lua -o neon.mp4

local TAU = 2 * math.pi

video { width = 1920, height = 1080, fps = 60, duration = 6, background = "#000000",
  render = function(f)
    -- Constant angular speed (one full turn every 4 s, a slow roll on top)
    -- so any stutter or smearing is a defect, not easing.
    local seconds = f.seconds
    local yaw = seconds * TAU / 4
    local roll = seconds * TAU / 12

    -- The title switches on like a neon tube: a few quick flickers, then steady.
    local title = animate(f, {
      { 0.20, 0.24, 0, 1, linear },
      { 0.30, 0.33, 1, 0.15, linear },
      { 0.40, 0.43, 0.15, 1, linear },
      { 0.56, 0.58, 1, 0.4, linear },
      { 0.66, 0.80, 0.4, 1, linear },
    })
    local subtitle = animate(f, { { 0.9, 1.5, 0, 1, ease_out } })
    local subtitle_slide = animate(f, {
      { 0.9, nil, translate(-40, 0), translate(0, 0), spring { mass = 1, stiffness = 140, damping = 20 } } })

    local readout = string.format("yaw %03.0f°  roll %03.0f°  frame %03d",
      math.fmod(math.deg(yaw), 360), math.fmod(math.deg(roll), 360), f.index)

    -- The shader covers only the right side; iResolution follows the box.
    shader(f, { src = "shaders/triangle.sksl", x = 820, y = 0, w = 1100, h = 1080,
      uniforms = { uYaw = yaw, uRoll = roll, uColor = "#ff2bd6" } })

    -- White text with a tight and a wide magenta bloom.
    group({ opacity = title, filter = {
      { "blur", std = 5, input = "SourceAlpha", result = "tight" },
      { "blur", std = 18, input = "SourceAlpha", result = "wide" },
      { "merge", "tight", "wide", result = "blur" },
      { "flood", color = "#ff2bd6", result = "tint" },
      { "composite", op = "in", input = "tint", input2 = "blur", result = "glow" },
      { "merge", "glow", "glow", "SourceGraphic" },
    } }, function()
      text { "NEON", x = 140, y = 480, font = "DM Sans", weight = 500, size = 190, letter_spacing = 6, fill = "#ffffff" }
      text { "TRIANGLE", x = 146, y = 620, font = "DM Sans", weight = 500, size = 104, letter_spacing = 14, fill = "#ffffff" }
    end)

    group({ opacity = subtitle, transform = subtitle_slide }, function()
      text { "one SkSL shader, drawn by Skia on the GPU", x = 148, y = 720, font = "JetBrains Mono", size = 30, fill = "#f5d0fe" }
    end)

    text { readout, x = 148, y = 1000, font = "JetBrains Mono", size = 24, fill = "#a78bfa", opacity = subtitle }
  end,
}
