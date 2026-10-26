-- The onimite saga: a two minute film about onimite, made with onimite,
-- music included. Slow and dramatic, then K-pop, then a twist.
-- media/transparent.mov isn't in the repository: fetch.sh makes it, once,
-- before the first run.
--
--     examples/onimite_saga/fetch.sh
--     onimite render examples/onimite_saga/video.lua -o onimite_saga.mp4
--
-- This file is the manifest: the video, its music and the scenes in order.
-- The music is an odawg song (music/score.lua) whose sections are the
-- scenes: each scene starts on its section and places its own sound effects
-- (sfx.lua) in beats the song measures. README.md says how to find and
-- change any part.

local look = require("look")
local score = require("music.score")

-- ---- the whole film: the picture pumps with the kick, the drops flash ----------

-- The kicks the drums really play, in the K-pop acts.
local PUMPING = {
  { part = "drums", note = "kick", decay = 9, range = "one..slow" },
  { part = "drums", note = "kick", decay = 9, range = "montage..tape_stop" },
}
-- The drops' impacts (the song's transitions), each as strong as its section says.
local FLASH = { part = "fx", note = "C#2", decay = 5 }
local FLASH_STRENGTH = { one = 0.7, montage = 0.55 }
cue("flash", score.hits(FLASH), { hit = "score" })

video {
  width = look.W, height = look.H, fps = look.FPS, background = look.VOID, duration = score.duration,
  audio = { { "score", bus = "music", fade_out = 0.2 } },
  -- the score and the sound effects (each scene places its own, sfx.lua)
  buses = { music = { gain_db = 0 }, sfx = { gain_db = -3 } },
  -- audio analyze: about -14 LUFS, true peak under -1 dBTP (the song alone peaks under -1)
  master_gain_db = 8.5,
  render = function(f)
    local pump = 0
    for _, k in ipairs(PUMPING) do pump = math.max(pump, score.pulse(f, k)) end
    group({ transform = { scale = 1 + pump * 0.007, origin = { look.W / 2, look.H / 2 } } }, function() render_scenes(f) end)
    local sec = score.section(f)
    local flash = sec and score.pulse(f, FLASH) * (FLASH_STRENGTH[sec.name] or 0) or 0
    if flash > 0.01 then rect { x = 0, y = 0, w = look.W, h = look.H, fill = "#ffffff", opacity = flash } end
  end,
}

-- ---- the scenes, in order ------------------------------------------------------

-- act I: the void
require("scenes.before")
require("scenes.weight")
require("scenes.spark")
-- act II: K-pop
require("scenes.one")
require("scenes.download")
require("scenes.race")
require("scenes.bill")
require("scenes.reload")
require("scenes.slow")
require("scenes.hush")
require("scenes.rise")
-- act III: all it does, then what it is built on
require("scenes.montage")
require("scenes.ovg")
require("scenes.odecs")
require("scenes.oksl")
require("scenes.not_needed")
require("scenes.check")
require("scenes.last")
-- act IV: the twist
require("scenes.tape_stop")
require("scenes.fade")
require("scenes.slam")
require("scenes.rain")
