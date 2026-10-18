-- French disco: a song on a style of its own, played by someone else's
-- recorded instruments. The song is media/song.json (the same file odawg's
-- CLI renders); its style, media/styles/french_disco.json, brings the band:
-- four CC0 libraries fetched from where their authors publish them, pinned
-- by SHA-256, and only the samples the notes reach. Its mix pumps under the
-- kick (a compressor on the `pump` bus keyed by it).
--
-- The picture reads the song: a scene per section, the floor's tiles are
-- the spectrum, the mirror ball breathes on the real kicks.
--
--     onimite preview examples/disco/video.lua
--     onimite audio analyze examples/disco/video.lua --waveform disco.png

local W, H = 1280, 720
local file = assert(io.open(SCRIPT_DIR .. "/media/song.json"))
local score = song(json_decode(file:read("a")))
file:close()

local INK, DIM = "#fdf4ff", "#c4b5fd"
local NEON = { "#f472b6", "#fb923c", "#facc15", "#a78bfa", "#22d3ee" }
local FLOOR_Y, TILES = 520, 16
local BALL_Y = 140 -- the ball hangs above the words; the bars rise to 380

local function kick(f) return score.pulse(f, { part = "kick", note = "kick", decay = 10 }) end
local function hat(f) return score.pulse(f, { part = "hats", decay = 18 }) end

-- the floor: a tile per band of the spectrum, low frequencies in the middle
local function floor(f)
  local levels = audio_spectrum(f, { src = score.name, sample_size = 1024, smooth = 1, window = "hann",
    bands = TILES, log = true, levels = { -20, 26 } })
  local tw = W / TILES
  for i, v in ipairs(spectrum_centered(levels)) do
    local glow = clamp01(v * 0.85 + kick(f) * 0.25)
    rect { x = (i - 1) * tw + 3, y = FLOOR_Y + 3, w = tw - 6, h = H - FLOOR_Y - 6, rx = 6,
      fill = mix_color("#1e1033", NEON[(i - 1) % #NEON + 1], glow) }
    local h = v * 140
    if h >= 1 then
      rect { x = (i - 1) * tw + 10, y = FLOOR_Y - h, w = tw - 20, h = h, rx = 4,
        fill = NEON[(i - 1) % #NEON + 1], opacity = 0.35 + 0.5 * v }
    end
  end
end

-- the mirror ball: it swells on the kick, its facets catch the hats
local function ball(f)
  local s = 1 + 0.08 * kick(f)
  local spin = f.global_seconds * 0.6
  group({ transform = scale(s, s, W / 2, BALL_Y) }, function()
    circle { cx = W / 2, cy = BALL_Y, r = 76, fill = radial_gradient {
      cx = W / 2 - 25, cy = BALL_Y - 25, r = 100, stops = { { 0, "#ffffff" }, { 0.5, "#a78bfa" }, { 1, "#3b0764" } } } }
    for k = 0, 23 do
      local a = spin + k * math.pi / 12
      local lit = 0.25 + 0.75 * hat(f) * ((k % 3 == 0) and 1 or 0.4)
      circle { cx = W / 2 + math.cos(a) * 58, cy = BALL_Y + math.sin(a * 0.5) * 58, r = 4, fill = "#ffffff", opacity = lit }
    end
  end)
  rect { x = W / 2 - 1, y = 0, w = 2, h = BALL_Y - 76, fill = DIM, opacity = 0.6 }
end

-- where the song is: its section, bar and beat
local function hud(f, s)
  local beat = score.beat(f.global_seconds) - score.beat(s.start)
  local bar = math.floor(beat / 4 + 1e-6) + 1 -- a frame on a bar line is that bar
  text { string.upper(s.name), x = 48, y = 72, font = "Bebas Neue", size = 56, fill = INK }
  text { string.format("bar %d · %d bpm · D minor", bar, 122), x = 48, y = 104, font = "JetBrains Mono", size = 18, fill = DIM }
end

video { width = W, height = H, fps = 30, duration = score.duration, background = "#0b0613",
  audio = { { score, fade_out = 1.5 } },
  -- the song mixes near -26 LUFS: lifted to about -14 under the limiter
  master_gain_db = 12,
  limiter = { ceiling_db = -1 },
  render = function(f)
    rect { x = 0, y = 0, w = W, h = H, fill = radial_gradient {
      cx = W / 2, cy = 200, r = 760, stops = { { 0, "#2e1065" }, { 1, "#0b0613" } } } }
    ball(f)
    floor(f)
    render_scenes(f) -- each section's words over the floor
  end,
}

-- what each section says, over the floor
local SAYS = {
  intro = function(f)
    local a = animate(f, { { start = 0.5, stop = 2, from = 0, to = 1 } })
    group({ opacity = a }, function()
      text { "French disco", x = W / 2, y = 310, align = "center", font = "Instrument Serif", size = 88, fill = INK }
      text { "a style of its own · four CC0 libraries · fetched, pinned, verified", x = W / 2, y = 348,
        align = "center", font = "DM Sans", size = 22, fill = DIM }
    end)
  end,
  groove = function(f)
    text { "everything breathes on the kick: the pump bus listens to it", x = W - 48, y = 72,
      align = "right", font = "DM Sans", size = 20, fill = DIM }
  end,
  ["break"] = function(f)
    text { "the chops come through a dark filter of their own", x = W - 48, y = 72,
      align = "right", font = "DM Sans", size = 20, fill = DIM }
  end,
  outro = function(f)
    local lines = {
      "Fashionbass, Emilyguitar · Karoryfer Samples",
      "VS Chamber Orchestra 2 CE, VCSL · Versilian Studios",
      "all CC0 · composed by odawg from media/song.json",
    }
    local a = animate(f, { { start = 0.2, stop = 0.8, from = 0, to = 1 } })
    rect { x = W / 2 - 330, y = 240, w = 660, h = 128, rx = 14, fill = "#0b0613", opacity = 0.82 * a }
    for i, l in ipairs(lines) do
      local li = animate(f, { { start = 0.3 * i, stop = 0.3 * i + 0.8, from = 0, to = 1 } })
      text { l, x = W / 2, y = 250 + i * 32, align = "center", font = "DM Sans", size = 22, fill = INK, opacity = li }
    end
  end,
}

for _, s in ipairs(score.sections) do
  scene { s.name, start = s.start, duration = s.stop - s.start, cue = s.name, render = function(f)
    hud(f, s)
    if SAYS[s.name] then SAYS[s.name](f) end
  end }
end
