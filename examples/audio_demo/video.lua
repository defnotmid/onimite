-- Sound placed from the same constants that drive the motion, as in fframes'
-- audio guide. The music and effects in media/ are synthesized by
-- tools/gen_media/gen.sh; the two voice lines are say(), spoken where the script
-- loads, and they duck the music by themselves.
--
--     onimite audio analyze examples/audio_demo/video.lua --waveform waveform.png
--     onimite render examples/audio_demo/video.lua -o audio_demo.mp4
--
-- The voice is Pocket TTS by Kyutai (CC-BY-4.0), voice "alba". The first run
-- downloads its files (835 MB on Linux, 866 MB on macOS), once.

local CARD_IN = 0.8      -- the card lands
local TITLE_AT = 3.0     -- the second scene's title pops

say("beat", "Every sound lands on the beat.", { seed = 1 })
say("made", "Made with onimite.", { seed = 1 })

video { width = 1280, height = 720, fps = 60, background = "#0f172a", master_gain_db = 6.5, -- about -14 LUFS
  audio = {
    { "music.mp3", start = 0, gain_db = -14, fade_in = 1.0, fade_out = 2.0,
      curve = "equal_power", ducked = true },
  },
}

scene { "Intro", duration = 4,
  audio = {
    { "whoosh.ogg", start = CARD_IN - 0.15, gain_db = -8 },
    { "beat", start = CARD_IN + 0.4 },
  },
  render = function(f)
    local x = animate(f, { { start = 0, stop = CARD_IN, from = -500, to = 0, easing = spring { stiffness = 180, damping = 18 } } })
    -- the card slides in across the canvas edge: a clip says the cut is meant
    group({ clip = { x = 0, y = 0, w = 1280, h = 720 } }, function()
      group({ transform = translate(x, 0) }, function()
        rect { x = 340, y = 260, w = 600, h = 200, rx = 28, fill = "#38bdf8" }
        text { "Sound on the beat", x = 640, y = 375, align = "center", font = "DM Sans", size = 44, fill = "#0f172a" }
      end)
    end)
  end }

scene { "Title", duration = 6, transition = { "fade", duration = 0.5 },
  audio = {
    { "pop.wav", start = TITLE_AT + 0.03, gain_db = -10, pan = 0.3 },
    { "made", start = TITLE_AT + 0.6 },
  },
  render = function(f)
    local s = animate(f, { { start = TITLE_AT, stop = TITLE_AT + 0.4, from = 0.6, to = 1, easing = spring { stiffness = 260, damping = 14 } } })
    group({ transform = scale(s, s, 640, 360) }, function()
      text { "onimite", x = 640, y = 390, align = "center", font = "DM Sans", size = 96, fill = "#f8fafc" }
    end)
  end }
