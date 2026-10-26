-- French touch, hard and electronic: synth voices of our own with someone
-- else's recorded instruments. The song is media/song.json (the same file
-- odawg's CLI renders): one loop (a driven synth bass with a fingered bass
-- in it, funk guitar, saw-and-piano stabs, a string pad) through a grain of
-- distortion and one low-pass whose cutoff is the arrangement, a talk-box
-- lead, the violins and an arpeggio over it, everything ducking under the
-- 909 kick. The libraries are CC0,
-- fetched from where their authors publish them, pinned by SHA-256, and only
-- the samples the notes reach.
--
-- The picture reads the song: a scene per section over one ray-traced club
-- (shaders/): a mirror ball whose facets throw flecks of the spots across
-- the room, beams in the haze, a light-up floor whose columns are the
-- spectrum, the spots coming on as the loop's filter opens (the light reads
-- the same automation lane the engine plays), a strobe on the drop's kicks.
--
--     onimite preview examples/disco/video.lua
--     onimite audio analyze examples/disco/video.lua --waveform disco.png

local W, H = 1280, 720
local file = assert(io.open(SCRIPT_DIR .. "/media/song.json"))
local score = song(json_decode(file:read("a")))
file:close()

local INK, DIM = "#fdf4ff", "#c4b5fd"
local NEON = { "#f472b6", "#fb923c", "#facc15", "#a78bfa", "#22d3ee" }
local TILES = 16 -- the floor's columns: bands of the spectrum

local function kick(f) return score.pulse(f, { part = "drums", note = "kick", decay = 10 }) end
local function hat(f) return score.pulse(f, { part = "drums", note = "open_hat", decay = 18 }) end

-- how open the loop is: its filter's cutoff (the lane the engine plays),
-- 0 shut to 1 wide open on a log scale
local SHUT, OPEN = 260, 16000
local function energy(f)
  local hz = score.automation("buses/loop/Filter/frequency", f)
  return clamp01(math.log(hz / SHUT) / math.log(OPEN / SHUT))
end

-- the club: one ray-traced room (shaders/common.sksl), its haze, its
-- surfaces and its lens a pass each. The ball turns, three spots light it (more as the
-- song lifts, colours moving every two bars), its facets throw flecks
-- across the walls and the floor, and the floor's columns are the spectrum.
local function club(f)
  local t = f.global_seconds
  local beat = score.beat(t)
  local e = energy(f)
  local levels = audio_spectrum(f, { src = score.name, sample_size = 1024, smooth = 1, window = "hann",
    bands = TILES, log = true, levels = { -20, 26 } })
  local turn = math.floor(beat / 8)
  local fade = clamp01((beat % 8) - 7) -- the last beat of every two bars
  local function colour(k) return mix_color(NEON[(turn + k) % #NEON + 1], NEON[(turn + k + 1) % #NEON + 1], fade) end
  local drop = score.section(f).name == "drop" and 1 or 0
  local u = {
    uSpin = t * 0.2, -- about two turns a minute
    uKick = kick(f),
    uHat = hat(f),
    uEnergy = e,
    uBeat = beat,
    uLevels = spectrum_centered(levels),
    uCol1 = colour(0),
    uCol2 = colour(2),
    -- the back spot: white, and on the drop it strobes on the kick
    uCol3 = "#fff4e8",
    uLights = { 1.4, 1.5 * clamp01((e - 0.45) * 4), 1.6 * clamp01((e - 0.7) * 4) * (1 - drop + drop * (0.3 + 1.7 * kick(f))) },
  }
  -- the haze is soft and the costliest: traced at half the resolution,
  -- softened, and scaled up into the room
  local function air()
    group({ transform = scale(2, 2) }, function()
      shader(f, { x = 0, y = 0, w = W / 2, h = H / 2, common = "shaders/common.sksl",
        passes = {
          { name = "haze", src = "shaders/haze.sksl" },
          { name = "soft", src = "shaders/soft.sksl", inputs = { uAir = "haze" } },
        },
        uniforms = u })
    end)
  end
  shader(f, { x = 0, y = 0, w = W, h = H, common = "shaders/common.sksl",
    passes = {
      { name = "room", src = "shaders/room.sksl", inputs = { uHaze = air } },
      { name = "glow", src = "shaders/glow.sksl", inputs = { uRoom = "room" } },
    },
    uniforms = u })
end

-- where the song is: its section, bar and beat
local function hud(f, s)
  local beat = score.beat(f.global_seconds) - score.beat(s.start)
  local bar = math.floor(beat / 4 + 1e-6) + 1 -- a frame on a bar line is that bar
  text { string.upper(s.name), x = 48, y = 72, font = "Bebas Neue", size = 56, fill = INK }
  text { string.format("bar %d · %d bpm · %s", bar, s.bpm, score.key), x = 48, y = 104, font = "JetBrains Mono", size = 18, fill = DIM }
end

video { width = W, height = H, fps = 60, duration = score.duration, background = "#0b0613",
  audio = { { score, fade_out = 1.5 } },
  -- the song mixes near -24 LUFS: lifted to about -15 under the limiter
  master_gain_db = 6,
  render = function(f)
    club(f)
    render_scenes(f) -- each section's words over the club
  end,
}

-- what each section says, over the floor
local SAYS = {
  intro = function(f)
    local a = animate(f, { { start = 0.5, stop = 2, from = 0, to = 1 } })
    group({ opacity = a }, function()
      text { "French touch", x = W / 2, y = 450, align = "center", font = "Instrument Serif", size = 88, fill = INK }
      text { "one filter on the whole loop · four CC0 libraries · fetched, pinned, verified", x = W / 2, y = 488,
        align = "center", font = "DM Sans", size = 22, fill = DIM }
    end)
  end,
  groove = function(f)
    text { "everything breathes on the kick: each part ducks under drums/kick", x = W - 48, y = 72,
      align = "right", font = "DM Sans", size = 20, fill = DIM }
  end,
  hook = function(f)
    text { "the filter is open: the spots read the same lane", x = W - 48, y = 72,
      align = "right", font = "DM Sans", size = 20, fill = DIM }
  end,
  ["break"] = function(f)
    text { "the loop falls back behind the filter, and it sings", x = W - 48, y = 72,
      align = "right", font = "DM Sans", size = 20, fill = DIM }
  end,
  outro = function(f)
    local lines = {
      "Fashionbass, Emilyguitar · Karoryfer Samples",
      "VS Chamber Orchestra 2 CE, VCSL · Versilian Studios",
      "all CC0 · composed by odawg from media/song.json",
    }
    local a = animate(f, { { start = 0.2, stop = 0.8, from = 0, to = 1 } })
    rect { x = W / 2 - 330, y = 380, w = 660, h = 128, rx = 14, fill = "#0b0613", opacity = 0.82 * a }
    for i, l in ipairs(lines) do
      local li = animate(f, { { start = 0.3 * i, stop = 0.3 * i + 0.8, from = 0, to = 1 } })
      text { l, x = W / 2, y = 390 + i * 32, align = "center", font = "DM Sans", size = 22, fill = INK, opacity = li }
    end
  end,
}

for _, s in ipairs(score.sections) do
  scene { s.name, start = s.start, duration = s.stop - s.start, cue = s.name, render = function(f)
    hud(f, s)
    if SAYS[s.name] then SAYS[s.name](f) end
  end }
end
