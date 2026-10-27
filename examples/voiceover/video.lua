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
-- The voice is Pocket TTS by Kyutai (CC-BY-4.0), voice "alba". Run fetch.sh first: it
-- downloads the sound effects (CC0 recordings) into media/.

local W, H = 1920, 1080

-- The lines first: their lengths size the music below, their words place the keys.
local climb = say("climb", "The keeper climbed the spiral stairs.", { seed = 3 })
local top = say("top", "At the top, the great lamp was dark.", { seed = 5 })
local strike = say("strike", "He struck a match. Light swept across the sea.", { seed = 2 })

-- The score, a section per line: "climb" and "top" are as long as their lines plus a
-- breath (whole bars), "strike" is a held bar under the match, and "beam" lands on the
-- word "Light".
--
-- Why: a quiet story told close to the ear, so an intimate chamber underscore after
-- Ólafur Arnalds' "Near Light": a soft felt piano turning a broken-chord figure, a cello
-- section under it, violas joining at the lamp, and the light as the harmony's
-- arrival. F major, but it stays on its dark side (Dm9, Bbmaj7, Gm9) until "Light",
-- where it lands home on F, the violins swell in and a solo violin sings over them
-- (its pickup on "He struck a match"). The strings are VS Chamber Orchestra 2's own
-- SFZ files read through `sources` and pinned (media/pins/vsco.pins, by `onimite
-- audio pin`), the piano is the osiris soft grand. No riser, no impact, no crash.
local score = song { "score", key = "F major", bpm = 84, seed = 11,
  sources = {
    vsco = { url = "https://raw.githubusercontent.com/sgossner/VSCO-2-CE/6dd651d55dde97fd4028699be9d4481f26917891/",
      page = "https://github.com/sgossner/VSCO-2-CE/tree/SFZ", licence = "CC0-1.0",
      credit = "VS Chamber Orchestra 2: Community Edition by Versilian Studios LLC, CC0 1.0", pins = "pins/vsco.pins" },
  },
  sections = {
    { "climb", duration = { audio = "climb", plus = { seconds = 1.2 } }, chords = "Dm9 Bbmaj7" },
    { "top", duration = { audio = "top", plus = { seconds = 1.2 } }, chords = "Gm9 Bbmaj7" },
    { "strike", duration = "1m", chords = "Csus4" },
    { "beam", duration = "2m", chords = "F Am7 Bbmaj7 F" },
  },
  returns = { hall = { { "Reverb", decay = 3.2, pre_delay = 0.03 }, { "Filter", type = "highpass", frequency = 250 } } },
  parts = {
    -- the piano: a broken chord in eighths, held still for the match, opening out at the light
    piano = { instrument = { "Sampler", set = "osiris/soft_piano", release = 1.2 }, gain_db = -3, sends = { hall = -12 }, play = {
      { "climb..top", arpeggio = { pattern = "up", interval = "8n", octaves = 2 }, octave = 3, velocity = 0.42, humanize = 0.008 },
      { "strike", chords = { voicing = "spread", rhythm = "x..............." }, octave = 3, duration = "1m", velocity = 0.32 },
      { "beam", arpeggio = { pattern = "upDown", interval = "8n", octaves = 2 }, octave = 3, velocity = 0.55, humanize = 0.008 },
    } },
    -- the cello section: the roots, long and soft
    cellos = { instrument = { "vsco/CelloEnsSusVib-Quiet.sfz", ampeg_attack = 0.35, ampeg_release = 0.9 }, gain_db = 4, sends = { hall = -14 }, play = {
      { "climb..strike", degrees = "1", subdivision = "1m", octave = 2, velocity = 0.5 },
      { "beam", degrees = "1 1", subdivision = "2n", octave = 2, velocity = 0.7 },
    } },
    -- violas from the lamp: the chord held, swelling into the light
    violas = { instrument = { "vsco/ViolaEnsSusVib-Quiet.sfz", ampeg_attack = 0.6, ampeg_release = 1 }, gain_db = 2, sends = { hall = -12 }, play = {
      { "top..strike", chords = { voicing = "close", rhythm = "x..............." }, octave = 3, duration = "1m", velocity = 0.45 },
      { "beam", chords = { voicing = "close", rhythm = "x.......x......." }, octave = 3, duration = "2n", velocity = 0.6 },
    } },
    -- the light: the violin section in, a solo violin singing over it
    violins = { instrument = { "vsco/ViolinEnsSusVib.sfz", ampeg_attack = 0.45, ampeg_release = 1.2 }, gain_db = 10, sends = { hall = -10 }, play = {
      { "beam", chords = { voicing = "open", rhythm = "x.......x......." }, octave = 4, duration = "2n", velocity = 0.55 },
    } },
    solo = { instrument = { "vsco/SViolinVib.sfz", ampeg_attack = 0.06, ampeg_release = 0.5 }, gain_db = 8, sends = { hall = -8 }, play = {
      { "beam", notes = "A5 - - G5 F5 - C6 - A5 - - - - - - -", subdivision = "8n", velocity = 0.65, humanize = 0.006, pickup = "F5 G5" },
    } },
  },
  automation = {
    ["parts/violas/gain_db"] = { { "top", -8 }, { "beam", 0 } },      -- on the part's own level
    ["parts/violins/gain_db"] = { { "beam", -12 }, { "beam@1m", 0 } },
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

-- Sound effects: real recordings (CC0, from Freesound), downloaded by fetch.sh into
-- media/ and checked against their SHA-256; they aren't in the repository, so
-- run `sh examples/voiceover/fetch.sh` once first. Each placement takes the part of its
-- file it needs (`offset` into the file, `stop`); the files are left as recorded.
local FX = ""   -- where fetch.sh puts them: media/, beside the fonts

-- The keeper's steps: one per stair, from "climbed" to "stairs" (a roll, not beat-checked),
-- each a single footfall cut from one take on metal stairs (four of its steps, in turn).
local STEP_AT = { 0.63, 2.32, 4.22, 6.94 }   -- the footfalls' onsets in steps.mp3
local STEPS = 8
local steps = {}
for i = 0, STEPS - 1 do
  local t = CLIMBED + (STAIRS - CLIMBED) * i / STEPS - score.time("climb")
  steps[#steps + 1] = { FX .. "steps.mp3", start = t, stop = t + 0.14, offset = STEP_AT[i % 4 + 1],
    gain_db = 6, bus = "sfx", pan = (i % 2 == 0) and -0.25 or 0.25 }
end
steps[1].cue = "climbed"

-- The match struck and catching (its strike at 2.21 s in match.mp3) on the half beat
-- nearest "match"; the lamp's flame catching on "Light" (the burst at 1.35 s in
-- flame.mp3); the beam passing with a whoosh near "swept" (from the Light scene's start).
local at = score.time("strike")
local light_fx = {
  { FX .. "match.mp3", start = MATCH - at, offset = 2.21, stop = MATCH - at + 1.6, gain_db = 8, fade_out = 0.4, bus = "sfx" },
  { FX .. "flame.mp3", start = LIGHT - at, offset = 1.35, stop = LIGHT - at + 3, gain_db = -4, fade_out = 1.2, bus = "sfx", cue = "light" },
  { FX .. "whoosh.mp3", start = SWEPT - at, offset = 0.015, gain_db = 2, bus = "sfx" },
}

video { width = W, height = H, fps = 60, duration = score.duration, background = "#070b16",
  buses = { music = { gain_db = -1 }, voice = { gain_db = 0 }, sfx = { gain_db = -6 } },  -- music and effects as far under the voice as on ottis v0.0.7 (its lines were 1 LU louder)
  master_gain_db = 8.5,
  audio = {
    { "score", gain_db = -6, fade_in = 1, fade_out = 1.5, ducked = true, bus = "music" },
    { "climb", start = CLIMB_AT },     -- spoken lines go on the voice bus by themselves
    { "top", start = TOP_AT },
    { "strike", start = STRIKE_AT },
    -- the sea under it all, night waves on a beach, rising for "the sea"
    { FX .. "sea.mp3", start = 0, gain_db = 4, fade_in = 2, fade_out = 1.5, bus = "sfx" },
    { FX .. "sea.mp3", start = SEA - 0.8, offset = 12, gain_db = 2, fade_in = 1.2, fade_out = 1.5, bus = "sfx" },
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
