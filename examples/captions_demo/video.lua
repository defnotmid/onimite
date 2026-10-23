-- Word-level captions, TikTok style: a 10 s vertical clip over a lo-fi beat
-- (an odawg song), its captions read from a Whisper-style word-timed JSON file
-- (media/talk.json) and drawn by captions{} in two highlight styles: a box
-- sliding from word to word, then a colour pop with an outline.
--
--     onimite render examples/captions_demo/video.lua -o captions_demo.mp4

-- The skill's library (skills/onimite-video/library: rows and styles to
-- copy into your media folder), from this example's media folder.
local LIB = "../../../skills/onimite-video/library/"
local INSTRUMENTS = { LIB .. "instruments/synths.json", LIB .. "instruments/classic.json", LIB .. "instruments/sfx.json" }

local W, H = 1080, 1920

-- The beat: lo-fi hip hop in A minor, a section per style, two bars (5 s) each. The
-- style's swung boom-bap, round bass and filtered keys, the keys a real FM electric
-- piano (sampled); in "pop" a soft grand arpeggiates on top.
local score = song { "score", instruments = INSTRUMENTS, key = "A minor", bpm = 96, seed = 120,
  sections = {
    { "box", duration = "2m", style = LIB .. "styles/lofi.json", energy = 0.5, chords = "Am9 Fmaj7" },
    { "pop", duration = "2m", energy = 0.6, chords = "Cmaj7 G" },
  },
  parts = {
    drums = { gain_db = 1 },
    keys = { instrument = { "Sampler", set = "vcsl/fm_piano" }, gain_db = -12.3 },
    piano = { instrument = { "Sampler", set = "osiris/soft_piano" }, gain_db = -12.4, pan = 0.25, sends = { room = -6 },
      play = { { "pop", arpeggio = { pattern = "upDown", interval = "8n", octaves = 2 }, octave = 4, velocity = 0.55 } } },
  },
}

-- The look both styles share: Inter ExtraBold, wrapped within 920 px around y = 1080.
local function style(t)
  t.src, t.x, t.y, t.w, t.valign = "talk.json", 80, 1080, 920, "middle"
  t.font, t.weight, t.size, t.line_height = "Inter 18pt", 800, 104, 1.25
  t.hold = 0.35 -- keep a page up through short pauses
  return t
end

local BOX = style { highlight = "box", highlight_fill = "#facc15", active_fill = "#111827", uppercase = true,
  max_duration = 1.2 }
local POP = style { highlight = "fill", active_fill = "#4ade80", active_scale = 1.22, stroke = "#0b0b12",
  stroke_width = 16, upcoming_fill = "#ffffffa0", combine_ms = 1000 }

-- The style's name in a pill at the top.
local function label(s)
  local q = { s, font = "JetBrains Mono", size = 38 }
  local w = text_width(q) + 64
  rect { x = (W - w) / 2, y = 250, w = w, h = 76, rx = 38, fill = "#ffffff14", stroke = "#ffffff33", stroke_width = 2 }
  q.x, q.y, q.align, q.baseline, q.fill = W / 2, 288, "center", "middle", "#e5e7eb"
  text(q)
end

video { width = W, height = H, fps = 30, duration = score.duration, background = "#0b0b12",
  audio = { { "score" } },
  master_gain_db = 6.6, limiter = { ceiling_db = -1.2 },   -- the song lifted to about -14 LUFS
  render = function(f)
    local t = f.global_seconds
    local kick = score.pulse(f, { part = "drums", note = "kick", decay = 6 })
    rect { x = 0, y = 0, w = W, h = H, fill = linear_gradient { x1 = 0, y1 = 0, x2 = 0, y2 = H,
      stops = { { 0, "#1e1b4b" }, { 0.55, "#0b0b12" }, { 1, "#111827" } } } }
    -- two slow blobs and a glow that breathes with the kick
    group({ blur = 120 }, function()
      circle { cx = 280 + 120 * math.sin(t * 0.7), cy = 640, r = 300, fill = "#7c3aed", opacity = 0.55 }
      circle { cx = 820 - 120 * math.sin(t * 0.5), cy = 1500, r = 340, fill = "#0ea5e9", opacity = 0.45 }
    end)
    circle { cx = W / 2, cy = 1080, r = 520 + 40 * kick, fill = radial_gradient { cx = W / 2, cy = 1080,
      r = 520 + 40 * kick, stops = { { 0, "#ffffff10" }, { 1, "#ffffff00" } } } }
    -- the beat in the bar
    local b = math.floor(score.beat(f)) % 4
    for i = 0, 3 do
      local on = i == b
      circle { cx = W / 2 + (i - 1.5) * 56, cy = 1640, r = on and 12 + 6 * kick or 10,
        fill = on and "#facc15" or "#ffffff40" }
    end
    render_scenes(f)
    -- progress
    rect { x = 0, y = H - 12, w = W, h = 12, fill = "#ffffff20" }
    if t > 0 then rect { x = 0, y = H - 12, w = W * t / score.duration, h = 12, fill = "#facc15" } end
  end,
}

scene { "Box", start = score.time("box"), render = function(f)
  label('highlight = "box"')
  captions(f.global_seconds, BOX)
end }

scene { "Pop", start = score.time("pop"), transition = { "slide", from = "right", duration = 0.4, easing = ease_in_out },
  render = function(f)
    label('highlight = "fill"')
    -- the first half's last page is still held while this scene slides in
    if f.global_seconds >= score.time("pop@0.2s") then captions(f.global_seconds, POP) end
  end }
