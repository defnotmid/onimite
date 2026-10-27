-- The clock of the video (fframes' src/beat.rs). The music runs at 120 BPM, so one beat
-- is 30 frames. Every cut, pop and keystroke is on this beat grid. soundtrack.lua reads the
-- same constants, so the sound follows the picture.

local B = {}

B.FPS = 60
-- One beat in seconds (120 BPM).
B.BEAT = 0.5
B.FRAMES_PER_BEAT = 30

-- First beat of each scene.
B.HOOK = 0.0
B.GRID = 8.0
B.CODE = 16.0
B.ZOOM = 24.0
B.OUTRO = 28.0
B.END = 36.0

-- The hook is complete before 1.5 s. "NOW PLAYS" comes on beat 1, with its words 50 ms apart.
-- The letters of "LOTTIE" come on beat 2, 30 ms apart.
B.WORD_NOW = 1.0
B.WORD_PLAYS = 1.1
B.LETTERS = 2.0
B.LETTER_STEP = 0.06

-- The tiles of the grid pop on sixteenth notes (125 ms apart).
B.TILE_POP = B.GRID + 0.5
B.TILE_STEP = 0.25
B.TILES = 12

-- The code types from TYPE_START, CHARS_PER_BEAT characters per beat.
B.TYPE_START = B.CODE + 0.5
B.CHARS_PER_BEAT = 30.0
-- "one call." comes after the code and stays 2 s.
B.CAPTION = B.CODE + 4.0

-- The outro types the `features = ["lottie"]` line from this beat.
B.FEATURE_TYPE_START = B.OUTRO + 1.0
B.FEATURE_CHARS_PER_BEAT = 16.0

function B.beat_time(beat) return beat * B.BEAT end

function B.beat_frames(beats) return math.floor(beats * B.FRAMES_PER_BEAT + 0.5) end

-- Position on the beat grid of the whole video.
function B.global_beat(f) return f.global_index / B.FRAMES_PER_BEAT end

-- The code of the code scene, line by line: its indentation (not typed) and its tokens
-- { text, kind }.
B.CODE_LINES = {
  { indent = 0, { "frame", "plain" }, { ".", "punct" }, { "play_lottie", "method" }, { "(", "punct" },
    { "ctx", "plain" }, { ", ", "punct" }, { '"tiger.json"', "str" }, { ",", "punct" } },
  { indent = 4, { "LottieOptions", "type" }, { " {", "punct" } },
  { indent = 8, { "looping", "plain" }, { ": ", "punct" }, { "true", "key" }, { ",", "punct" } },
  { indent = 8, { "..", "punct" }, { "Default", "type" }, { "::", "punct" }, { "default", "method" }, { "()", "punct" } },
  { indent = 4, { "})", "punct" } },
}

-- Characters typed in the code scene.
function B.code_chars()
  local n = 0
  for _, line in ipairs(B.CODE_LINES) do
    for _, token in ipairs(line) do n = n + #token[1] end
  end
  return n
end

B.FEATURE_LINE = 'features = ["lottie"]'

-- The beats of the keystrokes, for the typing sound.
function B.key_beats()
  local beats = {}
  for i = 0, B.code_chars() - 1 do
    beats[#beats + 1] = B.TYPE_START + i / B.CHARS_PER_BEAT
  end
  for i = 0, #B.FEATURE_LINE - 1 do
    beats[#beats + 1] = B.FEATURE_TYPE_START + i / B.FEATURE_CHARS_PER_BEAT
  end
  return beats
end

return B
