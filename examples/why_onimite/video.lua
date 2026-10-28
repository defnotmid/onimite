-- Why onimite: a 53 second pitch made with onimite, music included. The
-- numbers on screen come from bench/facts.json, measured on each release
-- (facts.lua); the soundtrack is an odawg song (track.lua), UK garage at
-- 132 BPM, and the picture follows it: every scene starts on its section,
-- the picture pumps on the kicks the drums really play, flashes on the
-- booms, glitches on the cuts and the stutters, and the counters tick on
-- the song's glockenspiel (timeline.lua). The sounds that answer the
-- picture (DONEs, landings, blips, a recorded crash) belong to their scenes. media/transparent.mov isn't in the
-- repository: fetch.sh makes it, once, before the first run.
--
--     examples/why_onimite/fetch.sh
--     onimite render examples/why_onimite/video.lua -o why_onimite.mp4

local beat = require("beat")
local ui = require("ui")
local score = require("track")
local T = require("timeline")

local FPS = beat.FPS

local SCENES = {
  require("scenes.title"),
  require("scenes.race"),
  require("scenes.bill"),
  require("scenes.ship"),
  require("scenes.agents"),
  require("scenes.tricks"),
  require("scenes.outro"),
}

local LABELS = { title = "01 / TITLE", slam = "01 / TITLE", race = "02 / RENDER RACE", bill = "03 / THE BILL",
  ship = "04 / SHIPPING", agents = "05 / AGENTS", tricks = "06 / TRICKS", outro = "07 / OUTRO" }

-- Cuts that glitch for three frames: the scenes after the title, and the
-- tricks' cuts (the song's stutters). The impacts flash; inspect checks the
-- song really hits there.
local GLITCH_FRAMES = {}
for i = 2, #SCENES do GLITCH_FRAMES[#GLITCH_FRAMES + 1] = score.frame(SCENES[i].section, FPS) end
for _, t in ipairs(T.at.TRICK_CUTS) do GLITCH_FRAMES[#GLITCH_FRAMES + 1] = math.floor(t * FPS + 0.5) end
cue("impact", score.hits { part = "fx", note = "G1" }, { hit = "score" })

local KICK = { part = "drums", note = "kick", decay = 9 }
local IMPACT = { part = "fx", note = "G1", decay = 5 }

local function energy(f)
  local s = 1 + score.pulse(f, KICK) * 0.008
  local since_cut
  for _, c in ipairs(GLITCH_FRAMES) do
    local fr = f.global_index - c
    if fr >= 0 and fr < 3 then since_cut = fr end
  end
  group({ transform = { scale = s, origin = { 960, 540 } } }, function()
    if since_cut then
      -- the picture splits in bands pushed sideways
      local b = score.beat(f)
      for i = 0, 5 do
        local dx = (hash(i * 13 + since_cut * 7 + b) - 0.5) * 160 * (1 - since_cut / 3)
        group({ transform = translate(dx, 0), clip = { x = 0, y = i * 180, w = 1920, h = 180 } }, function()
          render_scenes(f)
        end)
      end
    else
      render_scenes(f)
    end
  end)
  local flash = score.pulse(f, IMPACT)
  if flash > 0.01 then rect { x = 0, y = 0, w = 1920, h = 1080, fill = ui.TEXT, opacity = flash * 0.5 } end
end

local function hud(f)
  local sec = score.section(f)
  if not sec or not LABELS[sec.name] then return end
  local bar, q = math.floor(score.bar(f)) + 1, math.floor(sec.beat) + 1
  group({ opacity = 0.8 }, function()
    text { "ONIMITE VS FFRAMES", x = 60, y = 66, font = ui.MONO, size = 16, fill = ui.DIM }
    text { string.format("%d BPM   BAR %02d.%d", score.sections[sec.index].bpm, bar, q), x = 1830, y = 66,
      align = "right", font = ui.MONO, size = 16, fill = ui.DIM }
    rect { x = 1844, y = 53, w = 14, h = 14, fill = ui.O, opacity = 0.2 + 0.8 * score.pulse(f, 7) }
    text { LABELS[sec.name], x = 1860, y = 1050, align = "right", font = ui.MONO, size = 16, fill = ui.DIM }
    rect { x = 60, y = 1062, w = 1800, h = 1, fill = ui.LINE }
    rect { x = 60, y = 1061, w = math.max(1800 * f.global_seconds / score.duration, 1), h = 3, fill = ui.DIM }
  end)
end

video {
  width = 1920, height = 1080, fps = FPS, background = ui.BG, duration = score.duration, motion_blur = { shutter = 180 },
  buses = { music = {}, sfx = { gain_db = 0 } },
  audio = { { "score", bus = "music", fade_out = 0.5 } },
  -- the song mixes near -21 LUFS: lifted to about -15 under the limiter
  -- (audio analyze: -14.0 LUFS, -1.5 dBTP)
  master_gain_db = 6,
  render = function(f)
    rect { x = 0, y = 0, w = 1920, h = 1080, fill = ui.BG }
    energy(f)
    hud(f)
  end,
}

-- A scene per section, from its first beat to the next scene's; its
-- sounds, given on the video clock, are placed from its start.
for _, s in ipairs(SCENES) do
  local start = score.time(s.section)
  local audio = {}
  for i, a in ipairs(s.audio or {}) do
    audio[i] = { a[1], start = a.start - start, gain_db = a.gain_db, pan = a.pan, bus = "sfx" }
  end
  scene { s.name, start = start, cue = s.section, audio = audio, render = function(f)
    s.render(f, score.beat(f) - score.beat(start))
  end }
end
