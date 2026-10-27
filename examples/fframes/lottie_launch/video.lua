-- lottie-launch, after fframes' examples/lottie-launch: an 18 second vertical launch video
-- for Lottie support, 1080x1920 at 60 fps. Every animation in it is a
-- Lottie file from media/. The music is composed when the video renders (soundtrack.lua), on
-- the beat grid of beat.lua, which the picture reads too.
--
--     onimite render examples/fframes/lottie_launch/video.lua -o lottie-launch.mp4
--
-- All timing uses the beat of the whole video (`global_beat`). The scenes overlap for their
-- cross-fades, and this keeps the overlaps on the beat.

local B = require("beat")
local soundtrack = require("soundtrack")

local W, H = 1080, 1920

local BG = "#0b0b0b"
local BONE = "#ece8e1"
local ORANGE = "#fb6a22"
local EMBER = "#8a3712"
local SOOT = "#4a2010"
-- Secondary text: 7.5:1 on the background.
local MUTED = "#a8a39b"
local PEACH = "#ffb37a"
local SAND = "#f4d7b8"

local DISPLAY = "Anton"
local MONO = "IBM Plex Mono"
local SERIF = "Instrument Serif"

-- Phone apps cover the top and the bottom. Content stays inside x 8-92 % and y 12-78 %.
local SAFE_LEFT = 86.0
local SAFE_TOP = 230.0

local TAU = 2 * math.pi
local INF = math.huge

-- ------------------------------------------------------------------ Motion

-- The soft spring of the fframes design guide, and fframes' CSS curves.
local SPRING_SOFT = spring { mass = 1, stiffness = 150, damping = 18 }
local EASE_OUT = cubic_bezier(0, 0, 0.58, 1)
local EASE_IN = cubic_bezier(0.42, 0, 1, 1)
local EASE_IN_OUT = cubic_bezier(0.42, 0, 0.58, 1)

-- An element that enters at beat `at` of the video (rises 60 px, scales up from 0.92 and
-- fades in) and leaves at beat `out` (rises 60 px more and fades out in 0.2 s). (x, y) is its
-- center.
local function enter_exit(t, at, out, x, y, content)
  local enter = ease(SPRING_SOFT, t - B.beat_time(at), 3)
  local exit = ease(EASE_IN, t - B.beat_time(out), 0.2)
  local opacity = ease(EASE_OUT, t - B.beat_time(at), 0.3) * (1 - exit)
  if opacity <= 0 then return end
  group({ transform = { scale = 0.92 + 0.08 * enter, origin = { x, y }, translate = { 0, (1 - enter) * 60 - exit * 60 } },
    opacity = opacity }, content)
end

-- A Lottie file in a square box that starts playing at beat `at`; nothing before.
local function lottie_at(t, file, x, y, size, at)
  local s = t - B.beat_time(at)
  if s < 0 then return end
  lottie { src = file, x = x, y = y, w = size, h = size, time = s }
end

-- ------------------------------------------------------------------ Wordmark

-- "fframes" in Instrument Serif centered on `x`, with a trail of three f's on its left.
-- `appear` 0 -> 1 fans the trail out.
local function wordmark(x, y, size, appear)
  local word = text_width { "fframes", font = SERIF, size = size, italic = true }
  local fw = text_width { "f", font = SERIF, size = size, italic = true }
  local step = fw * 0.62
  -- center the visible part, "fframes" and the orange f. The two dark f's are on the left.
  local x0 = x - (word + step) / 2 + step
  return function()
    for _, k in ipairs { { 3, SOOT }, { 2, EMBER }, { 1, ORANGE } } do
      text { "f", x = x0 - k[1] * step * appear, y = y, font = SERIF, italic = true, size = size, fill = k[2] }
    end
    text { "fframes", x = x0, y = y, font = SERIF, italic = true, size = size, fill = BONE }
  end
end

-- ------------------------------------------------------------------ Scenes

-- The first frame shows the wordmark and the party popper. "NOW PLAYS LOTTIE" is complete at
-- 1.3 s.
-- "NOW PLAYS" is one centered line with 40 px between the words. The letter-spacing takes
-- 2 px per letter, and the measured width does not include it.
local NOW = text_width { "NOW", font = DISPLAY, size = 170 } - 2 * 3
local PLAYS = text_width { "PLAYS", font = DISPLAY, size = 170 } - 2 * 5
local WORDS_LEFT = 540 - (NOW + 40 + PLAYS) / 2
local WORDS = {
  { "NOW", B.WORD_NOW, WORDS_LEFT, NOW },
  { "PLAYS", B.WORD_PLAYS, WORDS_LEFT + NOW + 40, PLAYS },
}
-- The beginnings of "LOTTIE": each letter goes after the measured width of the letters before it.
local LOTTIE_TOTAL = text_width { "LOTTIE", font = DISPLAY, size = 300 }
local LETTER_X = {}
for i = 1, 6 do
  LETTER_X[i] = 540 - LOTTIE_TOTAL / 2 + text_width { ("LOTTIE"):sub(1, i - 1), font = DISPLAY, size = 300 }
end
local HOOK_MARK = wordmark(540, 330, 96, 1.0)

scene { "Hook", duration = { frames = B.beat_frames(B.GRID - B.HOOK) }, render = function(f)
  local t = f.global_seconds
  local out = B.GRID - 0.5
  enter_exit(t, B.HOOK - 1, out, 540, 300, HOOK_MARK)
  for _, w in ipairs(WORDS) do
    enter_exit(t, w[2], out, w[3] + w[4] / 2, 520, function()
      text { w[1], x = w[3], y = 580, font = DISPLAY, size = 170, letter_spacing = -2, fill = BONE }
    end)
  end
  for i = 1, 6 do
    local x = LETTER_X[i]
    enter_exit(t, B.LETTERS + (i - 1) * B.LETTER_STEP, out, x, 760, function()
      text { ("LOTTIE"):sub(i, i), x = x, y = 860, font = DISPLAY, size = 300, fill = ORANGE }
    end)
  end
  enter_exit(t, B.HOOK - 1, out, 550, 1190, function()
    lottie_at(t, "party.json", 290, 930, 520, B.HOOK)
  end)
end }

-- Twelve animations pop in, one per sixteenth note, and float.
local TILE_FILES = {
  "fire.json", "rocket.json", "unicorn.json", "earth.json", "cool.json", "mind_blown.json",
  "switch.json", "rainbow.json", "cat.json", "watermelon.json", "popcorn.json", "clapper.json",
}
-- The grid: 3 x 4 animations between the title and the bottom of the safe area.
local TILE, COLUMN, ROW, GRID_TOP = 220.0, 300.0, 255.0, 490.0

-- the title enters while the hook leaves
scene { "Grid", duration = { frames = B.beat_frames(B.CODE - B.GRID) }, overlap = { previous = 0.3 },
  render = function(f)
    local t = f.global_seconds
    local b = B.global_beat(f) - B.GRID
    local out = B.CODE - 0.5
    enter_exit(t, B.GRID - 0.4, out, 540, 300, function()
      text { "ANY LOTTIE FILE", x = 540, y = 340, align = "center", font = DISPLAY, size = 130, letter_spacing = -2,
        fill = BONE }
    end)
    enter_exit(t, B.GRID + 0.3, out, 540, 400, function()
      text { "from After Effects or LottieFiles", x = 540, y = 420, align = "center", font = SERIF, italic = true,
        size = 56, fill = MUTED }
    end)
    for i = 0, B.TILES - 1 do
      local at = B.TILE_POP + i * B.TILE_STEP
      local x = 540 + ((i % 3) - 1) * COLUMN - TILE / 2
      -- a slow float, with a different phase for each tile
      local float = math.sin(b * B.BEAT * TAU / 6 + i * 1.7) * 8
      local y = GRID_TOP + (i // 3) * ROW + float
      enter_exit(t, at, out, x + TILE / 2, y + TILE / 2, function()
        lottie_at(t, TILE_FILES[i + 1], x, y, TILE, at)
      end)
    end
  end }

-- The tiger plays above the code that plays it.
-- The position of the tiger in the code scene. The zoom starts from this position.
local TIGER_X, TIGER_Y, TIGER_SIZE = 240.0, SAFE_TOP, 600.0
-- The tiger loop (5.1 s) starts again when the zoom starts. The zoom freezes that first
-- frame, so the cut does not show.
local TIGER_START = B.ZOOM - 5.1 / B.BEAT

local TOKEN_COLORS = { plain = BONE, punct = MUTED, method = ORANGE, key = ORANGE, str = PEACH, type = SAND }

-- The code with the first `typed` characters visible and a blinking cursor after them.
local function code_block(typed, beat)
  local SIZE = 40.0
  -- IBM Plex Mono advances 0.6 em per character
  local CHAR = SIZE * 0.6
  local X = SAFE_LEFT + 22.0
  local Y = 960.0
  local LINE = 64.0
  return function()
    local left = typed
    local cursor
    for row, line in ipairs(B.CODE_LINES) do
      local y = Y + (row - 1) * LINE
      local chars, spans = 0, {}
      for _, token in ipairs(line) do
        if left > 0 then
          local shown = token[1]:sub(1, math.min(left, #token[1]))
          left = left - #shown
          chars = chars + #shown
          spans[#spans + 1] = { shown, fill = TOKEN_COLORS[token[2]] }
        end
      end
      if chars > 0 then
        local x = X + line.indent * CHAR
        cursor = { x + chars * CHAR, y }
        text { x = x, y = y, font = MONO, weight = 500, size = SIZE, spans = spans }
      end
    end
    if cursor then
      local blink = (beat - math.floor(beat)) < 0.5 and 1 or 0
      rect { x = cursor[1] + 2, y = cursor[2] - SIZE * 0.8, w = CHAR * 0.9, h = SIZE, fill = ORANGE, opacity = blink }
    end
  end
end

-- the tiger enters while the grid leaves
scene { "Code", duration = { frames = B.beat_frames(B.ZOOM - B.CODE) }, overlap = { previous = 0.3 },
  render = function(f)
    local t = f.global_seconds
    local b = B.global_beat(f) - B.CODE
    -- the tiger stays for the zoom, the text leaves before the zoom
    enter_exit(t, B.CODE - 0.4, INF, TIGER_X + TIGER_SIZE / 2, TIGER_Y + TIGER_SIZE / 2, function()
      lottie_at(t, "tiger.json", TIGER_X, TIGER_Y, TIGER_SIZE, TIGER_START)
    end)
    local out = B.ZOOM - 0.5
    local typed = math.floor(math.max((b - (B.TYPE_START - B.CODE)) * B.CHARS_PER_BEAT, 0))
    enter_exit(t, B.CODE, out, 540, 1050, code_block(typed, b))
    enter_exit(t, B.CAPTION, out, 540, 1410, function()
      text { "one call.", x = SAFE_LEFT + 22, y = 1440, font = SERIF, italic = true, size = 96, fill = BONE }
    end)
  end }

-- The camera dives into the tiger's eye until the pupil fills the screen.
-- The pupil of the tiger in its own units (the file is 1024 x 1024).
local PUPIL_X, PUPIL_Y = 160.0, 440.0
-- The pupil covers the whole screen from about 70x. That is just before the outro.
local ZOOM_MAX = 80.0

scene { "Zoom", duration = { frames = B.beat_frames(B.OUTRO - B.ZOOM) }, render = function(f)
  local t = f.global_seconds
  local base = TIGER_SIZE / 1024
  local px, py = TIGER_X + PUPIL_X * base, TIGER_Y + PUPIL_Y * base
  local dive = ease(EASE_IN_OUT, t - B.beat_time(B.ZOOM), (B.OUTRO - B.ZOOM) * B.BEAT)
  -- the pupil travels to the middle of the safe area while the camera dives
  local tx, ty = 540 + (px - 540) * (1 - dive), 865 + (py - 865) * (1 - dive)
  -- the dark pupil fills the screen, then fades out for the outro
  local fade = 1 - ease(EASE_OUT, t - B.beat_time(B.OUTRO - 0.4), 0.3)
  group({ transform = string.format("translate(%f %f) scale(%f) translate(%f %f) scale(%f)", tx, ty, ZOOM_MAX ^ dive,
    TIGER_X - px, TIGER_Y - py, base), opacity = fade }, function()
    -- the first frame of the loop, frozen, because the code scene ends on it
    lottie { src = "tiger.json", x = 0, y = 0, w = 1024, h = 1024, frame = 0 }
  end)
  enter_exit(t, B.ZOOM + 0.5, B.OUTRO - 0.8, 540, 1350, function()
    text { "VECTOR.", x = 540, y = 1450, align = "center", font = DISPLAY, size = 260, letter_spacing = -3, fill = BONE }
  end)
end }

-- The wordmark, the feature flag and the address.
-- the wordmark rises while the pupil fades
scene { "Outro", duration = { frames = B.beat_frames(B.END - B.OUTRO) }, overlap = { previous = 0.3 },
  render = function(f)
    local t = f.global_seconds
    local b = B.global_beat(f) - B.OUTRO
    enter_exit(t, B.OUTRO + 0.2, INF, 540, 390, function()
      lottie_at(t, "star_struck.json", 400, SAFE_TOP + 20, 280, B.OUTRO)
    end)
    enter_exit(t, B.OUTRO + 0.6, INF, 895, 595, function()
      lottie_at(t, "sparkles.json", 820, 520, 150, B.OUTRO + 0.5)
    end)
    local fan = ease(SPRING_SOFT, t - B.beat_time(B.OUTRO - 0.5), 3)
    enter_exit(t, B.OUTRO - 0.5, INF, 540, 740, wordmark(540, 800, 200, fan))
    local typed = math.floor(math.max((b - (B.FEATURE_TYPE_START - B.OUTRO)) * B.FEATURE_CHARS_PER_BEAT, 0))
    local feature = B.FEATURE_LINE:sub(1, math.min(typed, #B.FEATURE_LINE))
    enter_exit(t, B.OUTRO + 0.75, INF, 540, 950, function()
      text { "NEW: LOTTIE FILES", x = 540, y = 930, align = "center", font = MONO, weight = 600, size = 30,
        letter_spacing = 6, fill = ORANGE }
      if #feature > 0 then
        text { feature, x = 540, y = 1010, align = "center", font = MONO, weight = 500, size = 42, fill = BONE }
      end
    end)
    enter_exit(t, B.OUTRO + 3.0, INF, 540, 1200, function()
      text { "fframes.studio", x = 540, y = 1220, align = "center", font = SERIF, italic = true, size = 92, fill = BONE }
      text { "github.com/dmtrkovalenko/fframes", x = 540, y = 1290, align = "center", font = MONO, weight = 500,
        size = 30, fill = MUTED }
    end)
    enter_exit(t, B.OUTRO + 3.5, INF, 540, 1460, function()
      text { "Emoji: Noto Animated Emoji, CC BY 4.0", x = 540, y = 1470, align = "center", font = MONO, weight = 500,
        size = 28, fill = MUTED }
    end)
  end }

-- ------------------------------------------------------------------ Video

-- Contour rings behind everything. They drift, and one turn of the wobble takes 8 s.
local function rings(beat)
  group({ transform = rotate(beat * B.BEAT * 3, 540, 960) }, function()
    for i = 1, 25 do
      local r = i * 62
      local wobble = math.sin(i * 0.9 + beat * B.BEAT * TAU / 8) * 10
      ellipse { cx = 540, cy = 960, rx = r + wobble, ry = r * 0.86 - wobble, fill = "none", stroke = EMBER,
        stroke_width = 2, opacity = math.max(0.32 - i * 0.012, 0) }
    end
  end)
end

video { width = W, height = H, fps = B.FPS, background = BG,
  -- the music from the start; its last 0.3 s fade out, as the original's do
  audio = { { soundtrack.score, start = 0, stop = B.beat_time(B.END), fade_out = 0.3, bus = "music" } },
  buses = { music = {} },
  master_gain_db = soundtrack.MASTER_GAIN_DB,
  limiter = { ceiling_db = -1.3 },
  render = function(f)
    rings(B.global_beat(f))
    render_scenes(f)
  end }
