-- When everything happens, in beats: the scenes start on these cues, the
-- music (music/) puts its hits on them, and each is a sync point `inspect`
-- checks and the command line can address (`onimite frame video.lua RACE`).
-- The tempo map turns beats into seconds: the film slows down and speeds up,
-- and picture and sound follow it together.

local tempo = dofile("../common/tempo.lua")

local C = {}

C.FPS = 60

-- The tempo: name, beats, bpm [, the bpm it ramps to].
C.map = tempo.map {
  { "void", 16, 60 },          -- act I: slow and dramatic
  { "build", 16, 60, 128 },    -- the accelerando into the drop
  { "verse", 40, 128 },        -- act II: K-pop
  { "slow", 4, 128, 64 },      -- the tape slows
  { "hush", 8, 64 },           -- half time: the honest part
  { "rise", 4, 64, 144 },      -- and back up, faster
  { "chorus", 56, 144 },       -- act III
  { "last", 16, 144, 168 },    -- the final chorus keeps accelerating
  { "stop", 4, 168, 36 },      -- act IV: tape stop
  { "fade", 8, 54 },           -- Pip fades
  { "slam", 4, 140 },          -- the logo
  { "rain", 20, 90 },          -- the matrix
}
local at = C.map.at

-- Seconds at a beat, and the beat at a frame (or at seconds).
C.time, C.beat = C.map.time, C.map.beat
-- Seconds `d` beats from beat `b` last.
C.seconds = C.map.seconds

-- ---- the scenes, in order (each starts on its cue) ----------------------------

C.BEFORE, C.WEIGHT, C.SPARK = 0, 8, at.build
C.ONE = at.verse
C.DOWNLOAD, C.RACE, C.BILL, C.RELOAD = C.ONE + 8, C.ONE + 16, C.ONE + 24, C.ONE + 32
C.SLOW, C.HUSH, C.RISE = at.slow, at.hush, at.rise
-- act III: all it does (the montage), then what it is built on (the family)
C.CHORUS = at.chorus
C.MONTAGE = C.CHORUS
C.OVG, C.ODECS, C.OKSL, C.NOT, C.CHECK = C.CHORUS + 16, C.CHORUS + 24, C.CHORUS + 32, C.CHORUS + 40, C.CHORUS + 48
C.LAST = at.last
C.STOP, C.FADE, C.SLAM, C.RAIN = at.stop, at.fade, at.slam, at.rain
C.END = C.map.total_beats

C.SCENES = { "BEFORE", "WEIGHT", "SPARK", "ONE", "DOWNLOAD", "RACE", "BILL", "RELOAD", "SLOW", "HUSH",
  "RISE", "MONTAGE", "OVG", "ODECS", "OKSL", "NOT", "CHECK", "LAST", "STOP", "FADE", "SLAM", "RAIN" }

-- ---- hits ----------------------------------------------------------------------

-- The slam lands one beat into its segment (a beat of silence before it).
C.LOGO_HIT = C.SLAM + 1
-- The drops of the verse and the chorus: impacts and flashes.
C.DROP, C.CHORUS_DROP = C.ONE, C.CHORUS

-- ---- beats inside a scene that picture and music share ---------------------------

-- Spark: the code types over [CODE_FROM, CODE_TO], the command over
-- [CMD_FROM, CMD_TO], the render bar fills from BAR_FROM to beat 16.
C.CODE_FROM, C.CODE_TO, C.CMD_FROM, C.CMD_TO, C.BAR_FROM = 1, 10.5, 11.5, 14, 14.4

-- Rain: the lines typed, in beats from RAIN.
C.RAIN_LINES = { 4, 8, 12, 16 }

C.TOTAL_SECONDS = C.map.total_seconds
C.TOTAL_FRAMES = math.floor(C.TOTAL_SECONDS * C.FPS + 0.5)

-- The named moments as sync points (seconds on the video).
for _, name in ipairs(C.SCENES) do cue(name, C.time(C[name])) end
for _, name in ipairs { "LOGO_HIT", "DROP", "CHORUS_DROP" } do cue(name, C.time(C[name])) end

return C
