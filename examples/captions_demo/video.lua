-- Word-level captions, TikTok style: a 10 s vertical clip over an Afrobeats
-- groove (an odawg song), its captions read from a Whisper-style word-timed JSON file
-- (media/talk.json) and drawn by captions{} in two highlight styles: a box
-- sliding from word to word, then a colour pop with an outline.
--
--     onimite render examples/captions_demo/video.lua -o captions_demo.mp4

-- The skill's library (skills/onimite-video/library: rows to copy into your
-- media folder), from this example's media folder.
local LIB = "../../../skills/onimite-video/library/"

local W, H = 1080, 1920

-- The beat, a section per caption style, two bars (5 s) each. Why: a clip made
-- for the feed wants the feed's warmth, so Afrobeats after Wizkid's "Essence":
-- a clean, palm-muted highlife guitar picking around the chords (Karoryfer's
-- Emily guitar, its own SFZ), a syncopated drum-machine groove with swung
-- shakers and congas, a fingered bass over a synth sub, a soft FM electric
-- piano, and a short flute hook when the captions change style. Eb major,
-- major sevenths, no lo-fi loop.
local score = song { "score", key = "Eb major", bpm = 96, seed = 21, swing = 0.18, swing_subdivision = "16n",
  sources = {
    emily = { url = "https://raw.githubusercontent.com/sfzinstruments/karoryfer.emilyguitar/b4920dc662fd9cad6dcaccdeecffdd91c8725d8c/",
      page = "https://github.com/sfzinstruments/karoryfer.emilyguitar", licence = "CC0-1.0",
      credit = "Emilyguitar by Karoryfer Samples (D. Smolken), CC0", pins = "pins/emily.pins" },
    vsco = { url = "https://raw.githubusercontent.com/sgossner/VSCO-2-CE/6dd651d55dde97fd4028699be9d4481f26917891/",
      page = "https://github.com/sgossner/VSCO-2-CE/tree/SFZ", licence = "CC0-1.0",
      credit = "VS Chamber Orchestra 2: Community Edition by Versilian Studios LLC, CC0 1.0", pins = "pins/vsco.pins" },
  },
  instruments = { LIB .. "instruments/synths.json", {
    -- the bass: a fingered bass over a sine sub
    lowend = { layers = { { instrument = { "Sampler", set = "karoryfer/growlybass", release = 0.15 } },
                          { instrument = { "Synth", oscillator = { type = "sine" }, envelope = { attack = 0.004, decay = 0.2, sustain = 0.7, release = 0.1 } }, gain_db = -6 } } },
  } },
  sections = {
    { "box", duration = "2m", chords = "Ebmaj7 Cm7" },
    { "pop", duration = "2m", chords = "Abmaj7 Bb6" },
  },
  returns = { room = { { "Reverb", decay = 1.2, pre_delay = 0.01 }, { "Filter", type = "highpass", frequency = 300 } } },
  parts = {
    -- the groove: a kick that skips, the rim on the off-beats, shakers swung, congas answering
    drums = { instrument = { LIB .. "machines/808.json", tone = 0.55 }, gain_db = -1, sends = { room = -18 }, play = {
      { "box..pop", velocity = 0.8, humanize = 0.004, steps = {
        kick = { "x..x..x...x..x..", "x..x..x...x....." }, rim = "....x.......x...",
        shaker = "xoxoXoxoxoxoXoxo", conga_high = { "......x.....x.x.", "..x...x.......x." },
        conga_low = { "..........x.....", "..........x..x.." } } },
    } },
    -- the guitar: palm-muted sixteenths around the chord, highlife style
    guitar = { instrument = { "emily/emily_clean.sfz", ampeg_release = 0.05 }, gain_db = 7, sends = { room = -12 }, play = {
      { "box..pop", notes = "Bb4 . G4 Bb4 . Eb5 . Bb4 G4 . Bb4 . D5 . Bb4 . | G4 . Eb4 G4 . C5 . G4 Eb4 . G4 . Bb4 . G4 .", subdivision = "16n",
        velocity = 0.6, humanize = 0.005, vary = { {}, { thin = 0.2 } } },
    } },
    bass = { instrument = { "lowend" }, gain_db = -9, sidechain = { "drums/kick", depth_db = -2.5 }, play = {
      { "box..pop", degrees = "1 - . 1 . . 5 . 6 - . 5 . 3 . 1", subdivision = "16n", octave = 2, velocity = 0.8, humanize = 0.003 },
    } },
    keys = { instrument = { "keys", brightness = 0.5 }, gain_db = -3, sends = { room = -10 }, play = {
      { "box..pop", chords = { voicing = "spread", rhythm = { "x.......x.......", "x...........x..." } }, octave = 3, duration = "2n", velocity = 0.5 },
    } },
    -- the flute's hook when the captions pop
    flute = { instrument = { "vsco/FluteSusVib.sfz", ampeg_attack = 0.03, ampeg_release = 0.3 }, gain_db = 2, sends = { room = -8 }, play = {
      { "pop", notes = ". . Eb6 . F6 . G6 - - - Bb5 . . . . . | . . C6 . Bb5 . G6 - - - F6 . Eb6 . . .", subdivision = "16n", velocity = 0.65, humanize = 0.006 },
    } },
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

video { width = W, height = H, fps = 60, duration = score.duration, background = "#0b0b12",
  audio = { { "score" } },
  master_gain_db = 5.4,   -- the song lifted to about -14 LUFS
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
