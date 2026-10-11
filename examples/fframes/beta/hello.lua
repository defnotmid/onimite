-- fframes' hello-world video (one frame), embedded by the beta's
-- "BetaExamples" scene with the scene frame (60 fps) and the slug
-- "Hello, Beta!".

local SLUG = "Hello, Beta!"

local BG_KEYS = {
  { 0, nil, "#ffffff", "#f8fafc" },
  { 5, nil, "#f8fafc", "#fff7ed" },
  { 10, nil, "#fff7ed", "#fef2f2" },
  { 15, nil, "#fef2f2", "#f7fee7" },
  { 20, nil, "#f7fee7", "#ecfdf5" },
  { 25, 30, "#ecfdf5", "#faf5ff" },
}
local SQUARE_KEYS = {
  { 0, nil, translate(0, 0), translate(200, 480) },
  { 2, 6, translate(200, 480), translate(750, -400) },
  { 6, 10, translate(750, -400), translate(1310, 480) },
}
local VIEWPORT = { clip = { x = 0, y = 0, w = 1920, h = 1080 } }
local TITLE = "Hello " .. SLUG

local function render(f)
  -- <svg viewBox="0 0 1920 1080" width=1920 height=1080>
  group(VIEWPORT, function()
    rect { x = 0, y = 0, w = 1920, h = 1080, fill = animate(f, BG_KEYS) }
    -- renders under the text
    group({ transform = animate(f, SQUARE_KEYS) }, function()
      rect { x = 400, y = 400, w = 200, h = 200, fill = "#0000ff" }
    end)
    text { TITLE, x = 99, y = 300, font = "DM Sans", size = 150, fill = "#000000" }
    text { string.format("This frame index: %d, second: %.2f", f.index, f.seconds),
      x = 100, y = 440, font = "JetBrains Mono", size = 74, weight = 500, fill = "#3b5563" }
  end)
end

return render
