-- Why onimite: a 43 second pitch made with onimite, music included. The
-- numbers on screen come from BENCHMARK.md and the release builds
-- (facts.lua); the soundtrack is synthesized in Lua when the script loads
-- (track.lua) and every cut, pop and counter tick sits on its 140 BPM grid
-- (beat.lua, timeline.lua).
--
--     onimite render examples/why_onimite/video.lua -o why_onimite.mp4

local beat = require("beat")
local ui = require("ui")
local T = require("timeline")
local track = require("track")

local clock, FPS = beat.clock, beat.FPS

-- Synthesized once per render, registered as a media clip.
audio_add("track.wav", track.build)

local SCENES = {
  require("scenes.title"),
  require("scenes.race"),
  require("scenes.bill"),
  require("scenes.ship"),
  require("scenes.agents"),
  require("scenes.tricks"),
  require("scenes.outro"),
}

-- Where each section starts, as sync points: the scenes carry the same ids,
-- so `inspect` reports a scene that drifts off the music's grid and
-- `frame video.lua section[2]` shows a section's first frame.
local starts = {}
for i, sc in ipairs(SCENES) do starts[i] = clock.time(sc.start) end
cue("section", starts)

local SECTIONS = { "01 / TITLE", "02 / RENDER RACE", "03 / THE BILL", "04 / SHIPPING", "05 / AGENTS", "06 / TRICKS", "07 / OUTRO" }

-- Bars where the kick plays: the picture pumps with it.
local PUMPING = { { T.TITLE_SLAM, T.RACE - 2 }, { T.RACE, T.TRICKS }, { T.OUTRO, T.OUTRO + 16 } }
-- Cuts that glitch for three frames, and the impacts that flash.
local GLITCH_CUTS = { T.RACE, T.BILL, T.SHIP, T.AGENTS, T.TRICKS, T.TRICKS + 4, T.TRICKS + 8, T.TRICKS + 12, T.OUTRO }
local FLASHES = { T.TITLE_SLAM, T.OUTRO }

local function inside(b, spans)
  for _, s in ipairs(spans) do if b >= s[1] and b < s[2] then return true end end
  return false
end

local function energy(f, b)
  local s = 1 + (inside(b, PUMPING) and pulse(b, 9) or 0) * 0.008
  local since_cut
  for _, c in ipairs(GLITCH_CUTS) do
    local fr = f.global_index - clock.frame(c, FPS)
    if fr >= 0 and fr < 3 then since_cut = fr end
  end
  group({ transform = { scale = s, origin = { 960, 540 } } }, function()
    if since_cut then
      -- the picture splits in bands pushed sideways
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
  local flash = 0
  for _, d in ipairs(FLASHES) do
    if b >= d then flash = math.max(flash, math.exp(-(b - d) * 5)) end
  end
  if flash > 0.01 then rect { x = 0, y = 0, w = 1920, h = 1080, fill = ui.TEXT, opacity = flash * 0.5 } end
end

local function hud(f, b)
  if b >= T.OUTRO + 16 then return end
  local bar, q = math.floor(b / 4) + 1, math.floor(b % 4) + 1
  local section = 1
  for i, s in ipairs(SCENES) do if b >= s.start then section = i end end
  group({ opacity = 0.8 }, function()
    text { "ONIMITE VS FFRAMES", x = 60, y = 66, font = ui.MONO, size = 16, fill = ui.DIM }
    text { string.format("%d BPM   BAR %02d.%d", beat.BPM, bar, q), x = 1830, y = 66, align = "right",
      font = ui.MONO, size = 16, fill = ui.DIM }
    rect { x = 1844, y = 53, w = 14, h = 14, fill = ui.O, opacity = 0.2 + 0.8 * pulse(b, 7) }
    text { SECTIONS[section], x = 1860, y = 1050, align = "right", font = ui.MONO, size = 16, fill = ui.DIM }
    rect { x = 60, y = 1062, w = 1800, h = 1, fill = ui.LINE }
    rect { x = 60, y = 1061, w = math.max(1800 * b / T.TOTAL, 1), h = 3, fill = ui.DIM }
  end)
end

video {
  width = 1920, height = 1080, fps = FPS, background = ui.BG,
  audio = { { "track.wav", start = 0, fade_out = 0.5 } },
  -- the synth peaks at -1 dBFS: lift it to about -14 LUFS; the limiter's
  -- low ceiling keeps true peaks under -1 dBTP (audio analyze: -14.3 LUFS,
  -- -1.3 dBTP)
  master_gain_db = 5.5,
  limiter = { ceiling_db = -3.4 },
  render = function(f)
    local b = clock.beat(f.global_seconds)
    rect { x = 0, y = 0, w = 1920, h = 1080, fill = ui.BG }
    energy(f, b)
    hud(f, b)
  end,
}

for i, s in ipairs(SCENES) do
  local start, render = s.start, s.render
  local frames = clock.frame(s.stop, FPS) - clock.frame(start, FPS)
  scene { s.name, cue = ("section[%d]"):format(i - 1), duration = { frames = frames }, render = function(f)
    render(f, clock.beat(f.global_seconds) - start)
  end }
end
