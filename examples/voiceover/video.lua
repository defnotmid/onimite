-- A voiceover: three spoken lines (say: text to speech with word timings, by
-- ottis), their captions, a pad underneath that ducks under the voice, and
-- every key and sound effect on the word it belongs to (say_cue).
--
--     onimite inspect examples/voiceover/video.lua
--     onimite show examples/voiceover/video.lua say/strike
--     onimite render examples/voiceover/video.lua -o voiceover.mp4
--
-- The voice is Pocket TTS by Kyutai (CC-BY-4.0), voice "alba".

local synth = dofile("../common/synth.lua")

local W, H = 1920, 1080
local LEAD, AFTER = 0.6, 0.7  -- each scene: silence before its line, after it

-- The lines. Their durations and word times lay out everything below.
local climb = say("climb", "The keeper climbed the spiral stairs.", { seed = 3 })
local top = say("top", "At the top, the great lamp was dark.", { seed = 5 })
local strike = say("strike", "He struck a match. Light swept across the sea.", { seed = 2 })

-- Scenes back to back; each line starts LEAD into its scene (video seconds).
local CLIMB_AT = LEAD
local TOP_START = CLIMB_AT + climb.duration + AFTER
local TOP_AT = TOP_START + LEAD
local STRIKE_START = TOP_AT + top.duration + AFTER
local STRIKE_AT = STRIKE_START + LEAD
local END = STRIKE_AT + strike.duration + 2.0

-- The words things happen on: video times, and cues inspect checks.
local CLIMBED = say_cue(climb, CLIMB_AT, "climbed")
local STAIRS = say_cue(climb, CLIMB_AT, "stairs")
local LAMP = say_cue(top, TOP_AT, "lamp")
local DARK = say_cue(top, TOP_AT, "dark")
local MATCH = say_cue(strike, STRIKE_AT, "match")
local LIGHT = say_cue(strike, STRIKE_AT, "light")
local SWEPT = say_cue(strike, STRIKE_AT, "swept")
local SEA = say_cue(strike, STRIKE_AT, "sea")

-- The score: slow pads with no beat, under the voice.
audio_add("pad", function()
  local s = synth.new(END, { seed = 11 })
  local chords = { { 45, 52, 57, 60 }, { 41, 48, 57, 60 }, { 43, 50, 55, 59 }, { 45, 52, 57, 64 } }
  local t, i = 0, 1
  while t < END do
    s.chord(t, 4.6, chords[i], 0.05, 900, 1.6, 0.05, 0, 1600)
    t, i = t + 4, i % #chords + 1
  end
  return s.finish(5000)
end)

-- Sound effects, one clip per kind.
audio_add("strike_fx", function()  -- a match struck: crackles and a hiss
  local s = synth.new(0.7, { seed = 2 })
  s.tick(0, 0.9, 2600)
  for k = 0, 9 do s.crackle(0.01 + k * 0.035, 0.6 - k * 0.05, (k % 2 == 0) and -0.3 or 0.3) end
  local n, x = s.note(0.6)
  local y = 0
  for k = 1, n do
    local t = (k - 1) / s.RATE
    y = y + s.lp(5000) * (s.noise() - y)
    x[k] = y * math.min(1, t * 200) * math.exp(-t * 6) * 0.25
  end
  s.put(0, x, n, 0)
  return s.finish()
end)
audio_add("swell", function()  -- the lamp catching: a low bell
  local s = synth.new(3, { seed = 3 })
  s.bell(0, 57, 0.6, 1.2)
  s.bell(0, 64, 0.3, 1.6, 0.2)
  return s.finish()
end)
audio_add("whoosh", function()  -- the beam passing
  local s = synth.new(1.2, { seed = 4 })
  local n, x = s.note(1.1)
  local y = 0
  for k = 1, n do
    local u = (k - 1) / n
    y = y + s.lp(300 + 2500 * math.sin(math.pi * u)) * (s.noise() - y)
    x[k] = y * math.min(1, u * 40) * (1 - u) ^ 1.5
  end
  s.put(0, x, n, 0)
  return s.finish()
end)
audio_add("step", function()  -- a footstep on iron
  local s = synth.new(0.2, { seed = 5 })
  s.tick(0, 0.8, 900)
  return s.finish()
end)

-- The keeper's steps: one per stair, from "climbed" to "stairs" (the Stairs scene starts at 0,
-- so its times are video times).
local STEPS = 8
local steps = {}
for i = 0, STEPS - 1 do
  steps[#steps + 1] = { "step", start = CLIMBED + (STAIRS - CLIMBED) * i / STEPS, gain_db = -20, bus = "sfx",
    pan = (i % 2 == 0) and -0.2 or 0.2 }
end
steps[1].cue = "climbed"

video { width = W, height = H, fps = 30, duration = END, background = "#070b16",
  buses = { music = { gain_db = 0 }, voice = { gain_db = 0 }, sfx = { gain_db = -4 } },
  audio = {
    { "pad", start = 0, gain_db = -16, fade_in = 2, fade_out = 2, ducked = true, bus = "music" },
    { "climb", start = CLIMB_AT },     -- spoken lines go on the voice bus by themselves
    { "top", start = TOP_AT },
    { "strike", start = STRIKE_AT },
  },
  render = function(f)
    render_scenes(f)
    for _, l in ipairs({ { "climb", CLIMB_AT }, { "top", TOP_AT }, { "strike", STRIKE_AT } }) do
      captions(f, { src = l[1], start = l[2], x = 260, y = 960, w = W - 520, valign = "middle",
        font = "Space Grotesk", size = 58, line_height = 1.2, fill = "#e2e8f0", highlight = "fill",
        highlight_fill = "#fbbf24", upcoming_fill = "#64748b", max_duration = 1.8, hold = 0.4 })
    end
  end }

local function sky()
  rect { x = 0, y = 0, w = W, h = H,
    fill = linear_gradient { x1 = 0, y1 = 0, x2 = 0, y2 = H, stops = { { 0, "#0b1430" }, { 0.7, "#101b38" }, { 1, "#070b16" } } } }
end

-- The tower, its lantern at (cx, top).
local function tower(cx, top_y)
  local y0, y1 = top_y + 60, 860
  polygon { points = { cx - 70, y0, cx + 70, y0, cx + 120, y1, cx - 120, y1 }, fill = "#1e293b" }
  for k = 1, 3 do -- red bands, as wide as the tower where they sit
    local ya, yb = y0 + k * (y1 - y0) / 4 - 17, y0 + k * (y1 - y0) / 4 + 17
    local ha, hb = 70 + 50 * (ya - y0) / (y1 - y0), 70 + 50 * (yb - y0) / (y1 - y0)
    polygon { points = { cx - ha, ya, cx + ha, ya, cx + hb, yb, cx - hb, yb }, fill = "#7f1d1d", opacity = 0.8 }
  end
  rect { x = cx - 90, y = top_y + 40, w = 180, h = 24, rx = 4, fill = "#334155" }
  polygon { points = { cx - 60, top_y - 40, cx + 60, top_y - 40, cx, top_y - 110 }, fill = "#334155" }
end

scene { "Stairs", start = 0, audio = steps, render = function(f)
  local t = f.global_seconds
  sky()
  -- The stairs rise one by one from "climbed"; the keeper reaches the top on "stairs".
  for i = 0, STEPS - 1 do
    local at = CLIMBED + (STAIRS - CLIMBED) * i / STEPS
    local a = animate(t, { { start = at, stop = at + 0.25, from = 0, to = 1, easing = ease_out, cue = i == 0 and "climbed" or nil } })
    rect { x = 560 + i * 100, y = 820 - i * 70, w = 120, h = 22, rx = 4, fill = "#94a3b8", opacity = 0.15 + 0.85 * a }
  end
  local p = animate(t, { { start = CLIMBED, stop = STAIRS, from = 0, to = 1, easing = ease_in_out, cue = "climbed" } })
  local glow = animate(t, { { start = STAIRS, stop = STAIRS + 0.5, from = 0, to = 1, easing = ease_out, cue = "stairs" } })
  local x, y = 620 + p * (STEPS - 1) * 100, 790 - p * (STEPS - 1) * 70
  circle { cx = x, cy = y - 40, r = 26, fill = "#fbbf24" }
  rect { x = x - 18, y = y - 14, w = 36, h = 30, rx = 10, fill = "#fbbf24" }
  text { "the keeper", x = 160, y = 220, font = "Instrument Serif", size = 96, fill = "#e2e8f0",
    opacity = animate(t, { { start = 0.1, stop = 0.8, from = 0, to = 1, easing = ease_out } }) }
  circle { cx = x, cy = y - 40, r = 70, fill = "#fbbf24", opacity = 0.25 * glow }
end }

scene { "Lamp", start = TOP_START, render = function(f)
  local t = f.global_seconds
  sky()
  tower(960, 300)
  -- The lamp swells in on "lamp", its last ember dies on "dark".
  local s = animate(t, { { start = LAMP, stop = LAMP + 0.5, from = 0.6, to = 1, easing = spring { stiffness = 220, damping = 18 }, cue = "lamp" } })
  local ember = animate(t, { { start = TOP_START, stop = LAMP, from = 0.5, to = 0.5 }, { start = DARK, stop = DARK + 0.7, from = 0.5, to = 0, easing = ease_in, cue = "dark" } })
  group({ transform = scale(s, s, 960, 280) }, function()
    circle { cx = 960, cy = 280, r = 70, fill = "#1f2937", stroke = "#475569", stroke_width = 6 }
    circle { cx = 960, cy = 280, r = 46, fill = "#f59e0b", opacity = ember }
  end)
end }

scene { "Light", start = STRIKE_START, render = function(f)
  local t = f.global_seconds
  sky()
  -- The sea rises on "sea".
  local swell = animate(t, { { start = SEA, stop = SEA + 0.8, from = 0, to = 1, easing = ease_out, cue = "sea" } })
  for k = 0, 2 do
    local y = 880 + k * 50 - 30 * swell
    local pts = {}
    for i = 0, 24 do
      pts[#pts + 1] = i * 80
      pts[#pts + 1] = y + 12 * math.sin(i * 0.9 + t * 1.5 + k)
    end
    polyline { points = pts, stroke = "#38bdf8", stroke_width = 4, opacity = 0.25 + 0.5 * swell - k * 0.1 }
  end
  tower(960, 300)
  -- A spark on "match", the lamp catches on "light", the beam sweeps on "swept".
  local spark = animate(t, { { start = MATCH, stop = MATCH + 0.08, from = 0, to = 1, cue = "match" }, { start = MATCH + 0.08, stop = MATCH + 0.6, from = 1, to = 0, easing = ease_in } })
  local lit = animate(t, { { start = LIGHT, stop = LIGHT + 0.4, from = 0, to = 1, easing = ease_out, cue = "light" } })
  local sweep = animate(t, { { start = SWEPT, stop = SWEPT + 1.4, from = -60, to = 40, easing = ease_in_out, cue = "swept" } })
  if spark > 0 then
    circle { cx = 1000, cy = 280, r = 14, fill = "#fde68a", opacity = spark }
    circle { cx = 1000, cy = 280, r = 60 * spark, fill = "#fde68a", opacity = 0.3 * spark }
  end
  group({ transform = rotate(sweep, 960, 280), opacity = 0.35 * lit }, function()
    polygon { points = { 960, 270, 960, 290, 2400, 470, 2400, 90 },
      fill = linear_gradient { x1 = 960, y1 = 280, x2 = 2400, y2 = 280, stops = { { 0, "#fde68a" }, { 1, "#fde68a00" } } } }
  end)
  circle { cx = 960, cy = 280, r = 70, fill = "#1f2937", stroke = "#475569", stroke_width = 6 }
  circle { cx = 960, cy = 280, r = 46, fill = "#fbbf24", opacity = lit }
  circle { cx = 960, cy = 280, r = 140, fill = "#fbbf24", opacity = 0.18 * lit }
end, audio = {
  { "strike_fx", start = MATCH - STRIKE_START, gain_db = -6, bus = "sfx", cue = "match" },
  { "swell", start = LIGHT - STRIKE_START, gain_db = -10, bus = "sfx", cue = "light" },
  { "whoosh", start = SWEPT - STRIKE_START, gain_db = -8, bus = "sfx", cue = "swept" },
} }
