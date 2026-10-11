-- fframes' `fframes-intro` example: a 128 second introduction to fframes,
-- made with fframes. Sixteen scenes on the beat grid of the soundtrack
-- (beat.lua): the prompt that asked for the video, five years of git
-- history, code, the GPU, text, image, video, shaders, a 100,000 node
-- benchmark, the preview window, the agentic loop, this video's own frames,
-- a recap and the wordmark. A video-level pass adds the beat pump, drop
-- flashes, glitch cuts, film grain and the HUD.
--
--     onimite render examples/fframes/fframes_intro/video.lua -o intro.mp4
--
-- Scenes live in scenes/, one file per scene as in the original; shared
-- pieces in beat.lua (clock and easing), ui.lua (palette, type, HUD parts)
-- and facts.lua (the measured numbers on screen).

local beat = require("beat")
local ui = require("ui")
local agents = require("scenes.agents")
local gbeat, gsec, prog, pulse, hash, beat_time = beat.gbeat, beat.gsec, beat.prog, beat.pulse, beat.hash, beat.beat_time
local BG, BONE, ORANGE = ui.BG, ui.BONE, ui.ORANGE

local SCENES = {
  require("scenes.prompt"),
  require("scenes.origin"),
  require("scenes.code"),
  require("scenes.gpu"),
  require("scenes.text"),
  require("scenes.image"),
  require("scenes.video"),
  require("scenes.shader"),
  require("scenes.scale"),
  require("scenes.benchmark"),
  require("scenes.preview"),
  agents,
  require("scenes.render"),
  require("scenes.recap"),
  require("scenes.done"),
  (require("scenes.outro")),
}

-- Section titles for the HUD, by the beat they start on.
local SECTIONS = {
  { -99, "00 / PROMPT" }, { 0, "01 / ORIGIN" }, { 32, "02 / CODE" }, { 48, "03 / GPU" },
  { 56, "04 / TEXT" }, { 62, "05 / IMAGE" }, { 66, "06 / VIDEO" }, { 72, "07 / SHADER" },
  { 80, "08 / SCALE" }, { 96, "09 / BENCHMARK" }, { 128, "10 / PREVIEW" }, { 160, "11 / AGENTS" },
  { 208, "12 / GPU" }, { 224, "13 / RECAP" }, { 236, "14 / DONE" }, { 240, "15 / FFRAMES" },
}

-- Sound effects, placed on the beat minus the file's attack.
local function sfx(name, at, gain) return { name, start = math.max(at, 0), gain_db = gain } end

local AUDIO = {
  { "music.wav", start = 0, fade_out = 1.5 },
  sfx("sfx_typing.mp3", 0.02, -15),
  sfx("sfx_enter.mp3", beat_time(-1) - 0.067, -9),
  sfx("sfx_impact.mp3", beat_time(48), -10),
  sfx("sfx_shutter.mp3", beat_time(62) - 0.02, -2),
  sfx("sfx_glitch.mp3", beat_time(70) - 0.2, -8),
  sfx("sfx_impact.mp3", beat_time(96), -10),
  sfx("sfx_impact.mp3", beat_time(144), -12),
  sfx("sfx_impact.mp3", beat_time(208), -11),
  sfx("sfx_typing.mp3", beat_time(236.2), -18),
  sfx("sfx_impact.mp3", beat_time(240), -7),
  sfx("sfx_braam.mp3", beat_time(240), -9),
}
for _, b in ipairs { 56, 62, 66, 72, 80, 128, 160, 224 } do
  AUDIO[#AUDIO + 1] = sfx("sfx_whoosh.mp3", beat_time(b) - 0.18, -15)
end
for _, b in ipairs(agents.CARD_BEATS) do
  AUDIO[#AUDIO + 1] = sfx("sfx_blip.mp3", beat_time(b), -9)
end

local function hud(f, b)
  -- the HUD sits out the silent bar and the logo slam
  local hidden = b >= 236 and b < 244
  local t = gsec(f)
  local appear = prog(t, 0.1, 0.5)
  if hidden or appear <= 0 then return end
  local section = ""
  for _, s in ipairs(SECTIONS) do if b >= s[1] then section = s[2] end end
  local bar = b < 0 and 0 or math.floor(b / 4) + 1
  local beat_in_bar = b < 0 and 0 or math.floor(b % 4) + 1
  -- a tick that flashes on every beat
  local tick = b < 0 and 0 or pulse(b, 7)
  local progress = math.max(t / beat.TOTAL_SECONDS * 1788, 0.5)
  local label = ui.label
  group({ opacity = appear * 0.9, blend = "difference" }, function()
    ui.corners(36, 36, 1848, 1008, 26, "#d8d4cc", 2)
    label(66, 78, "FFRAMES — INTRO", "#d8d4cc", 17, "start")
    label(1854, 78, string.format("132 BPM   BAR %03d.%d", bar, beat_in_bar), "#d8d4cc", 17, "end")
    rect { x = 1840, y = 92, w = 14, h = 14, fill = ORANGE, opacity = 0.25 + tick * 0.75 }
    label(66, 1018, ui.timecode(t), "#d8d4cc", 17, "start")
    label(290, 1018, string.format("F %05d", f.global_index), "#77736d", 17, "start")
    label(1854, 1018, section, "#d8d4cc", 17, "end")
    rect { x = 66, y = 1034, w = 1788, h = 1, fill = "#d8d4cc", opacity = 0.25 }
    rect { x = 66, y = 1033, w = progress, h = 3, fill = "#d8d4cc" }
  end)
end

-- Sections where the full beat plays: the picture pumps with the kick.
local PUMPING = { { 48, 80 }, { 96, 160 }, { 208, 236 }, { 240, 268 } }
-- Cuts that glitch for a few frames.
local GLITCH_CUTS = { 32, 56, 62, 66, 72, 80, 128, 144, 224 }
-- Drops that flash.
local DROPS = { 48, 96, 144, 208 }

local function energy(f, b)
  local pumping = false
  for _, p in ipairs(PUMPING) do if b >= p[1] and b < p[2] then pumping = true end end
  local s = 1 + (pumping and pulse(b, 9) or 0) * 0.008
  local flash = 0
  for _, d in ipairs(DROPS) do
    if b >= d then flash = math.max(flash, math.exp(-(b - d) * 7)) end
  end
  -- a cut glitches for 3 frames: the picture splits in bands pushed sideways
  local since_cut
  for _, c in ipairs(GLITCH_CUTS) do
    local fr = (b - c) * beat.BEAT * beat.FPS
    if fr >= 0 and fr < 3 then since_cut = fr break end
  end
  group({ transform = string.format("translate(960 540) scale(%s) translate(-960 -540)", s) }, function()
    if since_cut then
      for i = 0, 5 do
        local dx = (hash(i * 13 + math.floor(since_cut) * 7) - 0.5) * 140 * (1 - since_cut / 3)
        group({ transform = translate(dx, 0), clip = { x = 0, y = i * 180, w = 1920, h = 180 } }, function()
          render_scenes(f)
        end)
      end
    else
      render_scenes(f)
    end
  end)
  rect { x = 0, y = 0, w = 1920, h = 1080, fill = BONE, opacity = flash * 0.55 }
end

video {
  width = 1920, height = 1080, fps = beat.FPS, background = "#000000",
  audio = AUDIO,
  -- the music edit measures about -17.5 LUFS; lift it to about -14 for the
  -- web, with room for inter-sample peaks (true peak under -1 dBTP)
  master_gain_db = 3.5,
  limiter = { ceiling_db = -1.3 },
  render = function(f)
    local b = gbeat(f)
    rect { x = 0, y = 0, w = 1920, h = 1080, fill = BG }
    energy(f, b)
    shader(f, { src = "shaders/grain.sksl", x = 0, y = 0, w = 1920, h = 1080,
      uniforms = { uGrain = 0.07, uVignette = 0.55 } })
    hud(f, b)
  end,
}

for _, s in ipairs(SCENES) do
  local start, render = s.start or 0, s.render
  scene { s.name, duration = { frames = beat.span_frames(s.start, s.stop) }, render = function(f)
    render(f, gbeat(f) - start)
  end }
end
