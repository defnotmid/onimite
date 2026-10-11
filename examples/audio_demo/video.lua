-- Sound placed from the same constants that drive the motion, as in fframes'
-- audio guide. The music and effects in media/ are synthesized and the two
-- voice lines are espeak-ng placeholders, all made by tools/gen_media/gen.sh.
--
--     onimite audio analyze examples/audio_demo/video.lua -o waveform.png
--     onimite render examples/audio_demo/video.lua -o audio_demo.mp4

local CARD_IN = 0.8      -- the card lands
local TITLE_AT = 3.0     -- the second scene's title pops

video { width = 1280, height = 720, fps = 30, background = "#0f172a",
  audio = {
    { "music.mp3", start = 0, gain_db = -14, fade_in = 1.0, fade_out = 2.0,
      curve = "equal_power", ducked = true },
  },
}

scene { "Intro", duration = 4,
  audio = {
    { "whoosh.ogg", start = CARD_IN - 0.15, gain_db = -8 },
    { "vo.wav", start = 1.2, voice = true },
  },
  render = function(f)
    local x = animate(f, { { start = 0, stop = CARD_IN, from = -500, to = 0, easing = spring { stiffness = 180, damping = 18 } } })
    group({ transform = translate(x, 0) }, function()
      rect { x = 340, y = 260, w = 600, h = 200, rx = 28, fill = "#38bdf8" }
      text { "Sound on the beat", x = 640, y = 375, align = "center", font = "DM Sans", size = 44, fill = "#0f172a" }
    end)
  end }

scene { "Title", duration = 6, overlap = { previous = 0.5 },
  audio = {
    { "pop.wav", start = TITLE_AT + 0.03, gain_db = -10, pan = 0.3 },
    { "vo2.m4a", start = 3.6, voice = true },
  },
  render = function(f)
    local s = animate(f, { { start = TITLE_AT, stop = TITLE_AT + 0.4, from = 0.6, to = 1, easing = spring { stiffness = 260, damping = 14 } } })
    local a = animate(f, { { start = 0, stop = 0.5, from = 0, to = 1 } })
    group({ opacity = a }, function()
      group({ transform = scale(s, s, 640, 360) }, function()
        text { "onimite", x = 640, y = 390, align = "center", font = "DM Sans", size = 96, fill = "#f8fafc" }
      end)
    end)
  end }
