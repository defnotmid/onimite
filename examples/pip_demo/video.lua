-- Pip, the mascot, in every mood: happy (bouncing on the beat, blinking),
-- surprised, sleepy and boom (examples/common/pip.lua).
local pip = dofile("../common/pip.lua")
local clock = beat_clock(120)

video { width = 1280, height = 400, fps = 30, duration = 4, background = "#1a1630", render = function(f)
  for i, mood in ipairs { "happy", "surprised", "sleepy", "boom" } do
    pip.draw(f, { x = 40 + (i - 1) * 310, y = 40, size = 300, mood = mood, beat = clock.beat(f), seed = i })
  end
end }
