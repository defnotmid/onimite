-- The onimite saga: a two minute film about onimite, made with onimite,
-- music included. Slow and dramatic, then K-pop, then a twist.
--
--     onimite render examples/onimite_saga/video.lua -o onimite_saga.mp4
--
-- This file is the manifest: the video, its music and the scenes in order.
-- Each scene is one file in scenes/ that places itself on its cue
-- (cues.lua) and places its own sound effects (sfx.lua); the score is one
-- clip per act (music/). README.md says how to find and change any part.

local look = require("look")
local C = require("cues")

-- ---- music: one clip per act, each built when sound is needed ----------------

local ACTS = { { "act1", C.BEFORE }, { "act2", C.ONE }, { "act3", C.CHORUS }, { "act4", C.STOP } }
local tracks = {}
for _, a in ipairs(ACTS) do
  audio_add(a[1], require("music." .. a[1]))
  tracks[#tracks + 1] = { a[1], start = C.time(a[2]), bus = "music" }
end
tracks[#tracks].fade_out = 0.2

-- ---- the whole film: the picture pumps with the kick, the hits flash ----------

local PUMPING = { { C.ONE, C.SLOW }, { C.CHORUS, C.STOP } }
local FLASHES = { { C.ONE, 0.7, 5 }, { C.CHORUS, 0.55, 5 }, { C.LOGO_HIT, 0.0, 6 } } -- beat, strength, decay

local function inside(b, spans)
  for _, s in ipairs(spans) do if b >= s[1] and b < s[2] then return true end end
  return false
end

video {
  width = look.W, height = look.H, fps = C.FPS, background = look.VOID, duration = C.TOTAL_SECONDS,
  audio = tracks,
  -- the score and the sound effects (each scene places its own, sfx.lua):
  -- the effects at the level the score is mixed at
  buses = { music = { gain_db = 0 }, sfx = { gain_db = 20 * math.log(require("music.parts").LEVEL, 10) } },
  -- the acts are mixed at one level (music/parts.lua): lift the mix toward
  -- -14 LUFS; the limiter's low ceiling keeps true peaks under -1 dBTP
  master_gain_db = 4,
  limiter = { ceiling_db = -3 },
  render = function(f)
    local b = C.beat(f)
    local s = 1 + (inside(b, PUMPING) and pulse(b, 9) or 0) * 0.007
    group({ transform = { scale = s, origin = { look.W / 2, look.H / 2 } } }, function() render_scenes(f) end)
    for _, fl in ipairs(FLASHES) do
      if b >= fl[1] and fl[2] > 0 then
        local a = fl[2] * math.exp(-(b - fl[1]) * fl[3])
        if a > 0.01 then rect { x = 0, y = 0, w = look.W, h = look.H, fill = "#ffffff", opacity = a } end
      end
    end
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
