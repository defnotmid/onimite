-- fframes' hello-world example as an onimite script.
--
--     onimite render examples/fframes/hello_world/video.lua -o hello.mp4

video { width = 1920, height = 1080, fps = 30, background = "#ffffff", duration = 30,
  render = function(f)
    rect { x = 0, y = 0, w = 1920, h = 1080, fill = animate(f, {
      { 0, nil, "#ffffff", "#f8fafc" },
      { 5, nil, "#f8fafc", "#fff7ed" },
      { 10, nil, "#fff7ed", "#fef2f2" },
      { 15, nil, "#fef2f2", "#f7fee7" },
      { 20, nil, "#f7fee7", "#ecfdf5" },
      { 25, 30, "#ecfdf5", "#faf5ff" },
    }) }

    -- Renders under the text.
    group({ transform = animate(f, {
      { 0, nil, translate(0, 0), translate(200, 480) },
      { 2, 6, translate(200, 480), translate(750, -400) },
      { 6, 10, translate(750, -400), translate(1310, 480) },
    }) }, function()
      rect { x = 400, y = 400, w = 200, h = 200, fill = "#0000ff" }
    end)

    text { "Hello onimite", x = 99, y = 300, font = "DM Sans", size = 150, fill = "#000000" }
    text { string.format("This frame index: %d, second: %.2f", f.index, f.seconds),
      x = 100, y = 440, font = "JetBrains Mono", size = 74, weight = 500, fill = "#3b5563" }
  end,
}
