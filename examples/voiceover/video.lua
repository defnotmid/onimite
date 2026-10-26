-- A voiceover: three spoken lines (say: text to speech with word timings, by
-- ottis), their captions, an odawg score that the narration sizes and that
-- ducks under the voice, and every key and sound effect on the word it
-- belongs to (say_cue), or the word on the music (say_start).
--
--     onimite inspect examples/voiceover/video.lua
--     onimite show examples/voiceover/video.lua say/strike
--     onimite show examples/voiceover/video.lua song/score
--     onimite render examples/voiceover/video.lua -o voiceover.mp4
--
-- The voice is Pocket TTS by Kyutai (CC-BY-4.0), voice "alba".

-- The skill's library (skills/onimite-video/library: rows and styles to
-- copy into your media folder), from this example's media folder.
local LIB = "../../../skills/onimite-video/library/"
local INSTRUMENTS = { LIB .. "instruments/synths.json", LIB .. "instruments/classic.json", LIB .. "instruments/sfx.json" }

local W, H = 1920, 1080

-- The lines first: their lengths size the music below, their words place the keys.
local climb = say("climb", "The keeper climbed the spiral stairs.", { seed = 3 })
local top = say("top", "At the top, the great lamp was dark.", { seed = 5 })
local strike = say("strike", "He struck a match. Light swept across the sea.", { seed = 2 })

-- The score: ambient in A minor, a section per line. "climb" and "top" are as long as
-- their lines plus a breath (whole bars); "strike" is a bar of riser under the match;
-- "beam" lands on the word "Light" with an impact, the strings, a sub and a heartbeat kick.
local score = song { "score", instruments = INSTRUMENTS, key = "A minor", bpm = 120, seed = 11,
  sections = {
    { "climb", duration = { audio = "climb", plus = { seconds = 1.2 } }, style = LIB .. "styles/ambient.json", energy = 0.2, chords = "Am9 Fmaj7" },
    { "top", duration = { audio = "top", plus = { seconds = 1.2 } }, energy = 0.35, chords = "Cmaj7 G" },
    { "strike", duration = "1m", energy = 0.25, chords = "Em7" },
    { "beam", duration = "2m", energy = 0.85, chords = "Fmaj7 C" },
  },
  parts = {
    -- the bar of riser under the match, the impact and a crash on "Light"
    rise = { instrument = "riser", gain_db = 3, play = { { "strike", events = { { time = 0, duration = "1m", note = "C4", velocity = 0.35 } } } } },
    fx = { instrument = "impact", gain_db = -4, play = { { "beam", events = { { time = 0, duration = 2.5, note = "C2", velocity = 0.8 } } } } },
    fx_crash = { instrument = "crash", gain_db = -1, play = { { "beam", events = { { time = 0, duration = 1.6, note = "C4", velocity = 0.7 } } } } },
    -- the riser, the crash and ambient.json's bells (-14), drums (-8), strings (-16) and sub (-8) raised to where inspect's buried_part put it: 12 LU under the mix where the part plays loudest
    bells = { gain_db = -4 },
    drums = { gain_db = 1 },
    strings = { gain_db = -8 },
    sub = { gain_db = -5 },
  },
}

-- Where the lines start: a beat into their sections; the last so that "Light" lands on "beam".
local CLIMB_AT, TOP_AT = score.time("climb@4n"), score.time("top@4n")
local STRIKE_AT = say_start(strike, "light", score.time("beam"))

-- The words things happen on: video times, and cues inspect checks.
local CLIMBED = say_cue(climb, CLIMB_AT, "climbed")
local STAIRS = say_cue(climb, CLIMB_AT, "stairs")
local LAMP = say_cue(top, TOP_AT, "lamp")
local DARK = say_cue(top, TOP_AT, "dark")
local LIGHT = say_cue(strike, STRIKE_AT, "light")          -- = score.time("beam")
local SEA = say_cue(strike, STRIKE_AT, "sea")
-- Over the score's grid a sound snaps to the half beat, its key with it (no word cue).
local MATCH = score.snap(say_cue(strike, STRIKE_AT, "match"), "8n")
local SWEPT = score.snap(say_cue(strike, STRIKE_AT, "swept"), "8n")

-- Sound effects, one sound{} per kind.
local STEP = sound { "tick", instruments = INSTRUMENTS, note = "A5" }                                  -- a footstep on iron
local SCRAPE = sound { { "NoiseSynth", noise = { type = "pink" },          -- the match struck
  envelope = { attack = 0.004, decay = 0.45, sustain = 0, release = 0.1 } }, duration = 0.5 }
local EMBER = sound { "crackle", instruments = INSTRUMENTS }
local BELL = sound { "bell", instruments = INSTRUMENTS, note = score.note("1", "beam"), duration = "1m", gain_db = -4.6 }   -- the lamp catching (sound{}'s -10, +5.4 for synths.json's bell level)
local WHOOSH = sound { "whoosh", instruments = INSTRUMENTS, duration = 0.7 }                            -- the beam passing

-- The keeper's steps: one per stair, from "climbed" to "stairs" (a roll, not beat-checked).
local STEPS = 8
local steps = {}
for i = 0, STEPS - 1 do
  steps[#steps + 1] = { STEP, start = CLIMBED + (STAIRS - CLIMBED) * i / STEPS - score.time("climb"),
    gain_db = 2, bus = "sfx", pan = (i % 2 == 0) and -0.2 or 0.2 }
end
steps[1].cue = "climbed"

-- The match struck, the lamp catching, the beam passing (from the Light scene's start).
local at = score.time("strike")
local light_fx = {
  { SCRAPE, start = MATCH - at, gain_db = 14, bus = "sfx" },
  { BELL, start = LIGHT - at, gain_db = 3, bus = "sfx", cue = "light" },
  { WHOOSH, start = SWEPT - at, gain_db = 10, bus = "sfx" },
}
for k = 0, 9 do  -- the match's crackle: a roll after the scrape
  light_fx[#light_fx + 1] = { EMBER, start = MATCH - at + 0.01 + k * 0.035, gain_db = 14 - k, bus = "sfx",
    pan = k % 2 == 0 and -0.3 or 0.3 }
end

video { width = W, height = H, fps = 30, duration = score.duration, background = "#070b16",
  buses = { music = { gain_db = 0 }, voice = { gain_db = 0 }, sfx = { gain_db = -5 } },
  master_gain_db = 6, limiter = { ceiling_db = -1.2 },
  audio = {
    { "score", gain_db = -6, fade_in = 1, fade_out = 1.5, ducked = true, bus = "music" },
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

scene { "Stairs", start = score.time("climb"), audio = steps, render = function(f)
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

scene { "Lamp", start = score.time("top"), render = function(f)
  local t = f.global_seconds
  sky()
  tower(960, 300)
  -- The lamp swells in on "lamp", its last ember dies on "dark".
  local s = animate(t, { { start = LAMP, stop = LAMP + 0.5, from = 0.6, to = 1, easing = spring { stiffness = 220, damping = 18 }, cue = "lamp" } })
  local ember = animate(t, { { start = score.time("top"), stop = LAMP, from = 0.5, to = 0.5 }, { start = DARK, stop = DARK + 0.7, from = 0.5, to = 0, easing = ease_in, cue = "dark" } })
  group({ transform = scale(s, s, 960, 280) }, function()
    circle { cx = 960, cy = 280, r = 70, fill = "#1f2937", stroke = "#475569", stroke_width = 6 }
    circle { cx = 960, cy = 280, r = 46, fill = "#f59e0b", opacity = ember }
  end)
end }

scene { "Light", start = score.time("strike"), render = function(f)
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
  local spark = animate(t, { { start = MATCH, stop = MATCH + 0.08, from = 0, to = 1 }, { start = MATCH + 0.08, stop = MATCH + 0.6, from = 1, to = 0, easing = ease_in } })
  local lit = animate(t, { { start = LIGHT, stop = LIGHT + 0.4, from = 0, to = 1, easing = ease_out, cue = "light" } })
  local sweep = animate(t, { { start = SWEPT, stop = SWEPT + 1.4, from = -60, to = 40, easing = ease_in_out } })
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
end, audio = light_fx }
