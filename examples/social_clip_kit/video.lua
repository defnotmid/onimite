-- Social clip kit: one 16 second promo rendered in the three shapes social
-- video comes in, 9:16, 1:1 and 16:9, from the same script. `props.format`
-- picks the canvas, and everything else is laid out from it at load: the
-- stage, the headline fitted to its box with text_width, the format frames,
-- the feature cards, the captions and the progress bar. Pip, the mascot, is
-- a VP9 clip with alpha composited over the picture; the music is an odawg
-- song (track.lua) and every cut lands where it hits (timeline.lua reads
-- its sections, claps, blips and crashes); word-level captions come from a
-- WebVTT script built from the beat timeline.
--
--     onimite render examples/social_clip_kit/video.lua --batch examples/social_clip_kit/rows.json -o out/{name}.mp4
--     onimite render examples/social_clip_kit/video.lua --set format=1x1 -o square.mp4

local T = require("timeline")
local score = require("track")

local FPS = T.FPS
-- seconds from beat b to beat gb (negative before it), as the song counts them
local function since(gb, b) return score.seconds(gb - b) end

-- ---- format and layout (all at load) ----------------------------------------

local FORMATS = {
  ["9x16"] = { 1080, 1920, label = "9:16" },
  ["1x1"] = { 1080, 1080, label = "1:1" },
  ["16x9"] = { 1920, 1080, label = "16:9" },
}
local FORMAT = props.format or "9x16"
local FMT = assert(FORMATS[FORMAT], "props.format is 9x16, 1x1 or 16x9")
local W, H = FMT[1], FMT[2]
local WIDE = W > H

local function box(x, y, w, h) return { x = x, y = y, w = w, h = h, cx = x + w / 2, cy = y + h / 2 } end

-- Where things go in each shape: the progress bar, Pip's stage, the
-- headline, the full-width area (format frames, feature cards), the outro's
-- type, and the captions' centre line, width and size.
local LAYOUTS = {
  ["9x16"] = { bar = box(80, 110, 920, 8), stage = box(90, 250, 900, 780), head = box(80, 1060, 920, 380),
    area = box(80, 300, 920, 1040), mark = box(80, 1040, 920, 400), caption = { y = 1620, w = 920, size = 76 } },
  ["1x1"] = { bar = box(64, 56, 952, 8), stage = box(240, 96, 600, 420), head = box(80, 540, 920, 270),
    area = box(80, 120, 920, 700), mark = box(80, 450, 920, 400), caption = { y = 950, w = 920, size = 58 } },
  ["16x9"] = { bar = box(96, 56, 1728, 8), stage = box(60, 120, 900, 760), head = box(960, 250, 880, 440),
    area = box(160, 140, 1600, 700), mark = box(960, 240, 880, 480), caption = { y = 960, w = 1500, size = 60 } },
}
local L = LAYOUTS[FORMAT]

local DISPLAY, SANS, MONO = "Inter 18pt", "DM Sans", "JetBrains Mono"
local INK, PAPER = "#0d0718", "#fff8ee"

-- The largest size (up to `max`) at which every line fits `w`, and the
-- lines' block `h` (line height `lead`).
local function fit(lines, font, weight, w, h, max, lead, spacing)
  local size = max
  while size > 16 do
    local widest = 0
    for _, l in ipairs(lines) do
      widest = math.max(widest, text_width { l, font = font, size = size, weight = weight, letter_spacing = spacing })
    end
    if widest <= w and #lines * size * lead <= h then break end
    size = size - 2
  end
  return size
end

local HEAD = { "ONE SCRIPT", "EVERY FORMAT" }
local HEAD_SIZE = fit(HEAD, DISPLAY, 800, L.head.w, L.head.h, 180, 1.05, -2)

-- The most the whole frame grows on a crash and a kick together (around its
-- centre; the render function's punch).
local PUNCH = 1 + 0.06 + 0.006
-- How much larger than its box (centre cx, width w) a slam may start, at most
-- `want`, so that under the punch it stays on the canvas: in the wide format
-- the boxes sit off centre and get less.
local function slam_from(want, cx, w)
  return math.min(want, 2 * (W / 2 / PUNCH - math.abs(cx - W / 2)) / w)
end
local HEAD_SLAM = slam_from(1.35, L.head.cx, L.head.w)

-- The three format frames: in a row across the area, or, in the tall
-- format, 9:16 and 1:1 side by side over 16:9 as wide as both; labels
-- under each.
local FRAMES = {}
do
  local a, label_h = L.area, 90
  local keys = { "9x16", "1x1", "16x9" }
  local function add(k, x, y, w, h)
    FRAMES[k] = { key = keys[k], label = FORMATS[keys[k]].label, box = box(x, y, w, h) }
  end
  if H > W then
    local gap, rows = 50, 30
    local h1 = (a.h - 2 * label_h - rows - gap * 9 / 16) / (1 + 1.5625 * 9 / 16)
    local w1 = 1.5625 * h1 + gap
    local h2 = w1 * 9 / 16
    local x, y = a.cx - w1 / 2, a.cy - (h1 + h2 + 2 * label_h + rows) / 2
    add(1, x, y, h1 * 9 / 16, h1)
    add(2, x + h1 * 9 / 16 + gap, y, h1, h1)
    add(3, x, y + h1 + label_h + rows, w1, h2)
  else
    local ratios, gap = { 9 / 16, 1, 16 / 9 }, WIDE and 70 or 40
    local sum = ratios[1] + ratios[2] + ratios[3]
    local fh = math.min((a.w - 2 * gap) / sum, a.h - label_h)
    local x = a.cx - (sum * fh + 2 * gap) / 2
    for k = 1, 3 do
      add(k, x, a.cy - (fh + label_h) / 2, ratios[k] * fh, fh)
      x = x + ratios[k] * fh + gap
    end
  end
end

-- Feature cards: the visual and its title, side by side when wide.
local FEATURES = {
  { title = "Word-level captions", code = 'captions{ highlight = "box" }' },
  { title = "Music made in Lua", code = 'song { "score", style = "styles/chicago_house.json" }' },
  { title = "Cuts on the beat", code = 'score.hits { part = "crash" }' },
  { title = "Alpha video", code = 'video_frame{ src = "mascot.webm" }' },
}
local CARD = {}
do
  local a = L.area
  if WIDE then
    CARD.vis = box(a.x, a.y + 40, a.w * 0.5, a.h - 80)
    CARD.tx, CARD.ty, CARD.tw, CARD.align = a.x + a.w * 0.56, a.cy, a.w * 0.44, "left"
  else
    local vh = a.h * (FORMAT == "1x1" and 0.62 or 0.66)
    CARD.vis = box(a.x + 40, a.y, a.w - 80, vh)
    CARD.tx, CARD.ty, CARD.tw, CARD.align = a.cx, a.y + vh + (a.h - vh) * 0.45, a.w, "center"
  end
  local titles = {}
  for k, ft in ipairs(FEATURES) do titles[k] = ft.title end
  CARD.size = fit(titles, DISPLAY, 800, CARD.tw, 1e9, WIDE and 92 or 88, 1, -1)
  CARD.code = fit({ FEATURES[2].code }, MONO, 400, CARD.tw, 60, 32, 1, 0)
end

-- The outro, stacked in L.mark: the wordmark as large as fits (with the
-- stack below it), the tagline, the command pill and the format chips.
local PILL = { "render --batch rows.json", font = MONO, size = WIDE and 40 or 36 }
local OUT = {}
do
  local m = L.mark
  local size = fit({ "onimite" }, DISPLAY, 800, m.w, m.h, 240, 1, -6)
  local function stack(ms)
    local tag = math.max(34, math.floor(ms * 0.2))
    return ms * 0.8 + tag * 1.7 + PILL.size * 2.3 + PILL.size * 2.4 + 30, tag
  end
  while stack(size) > m.h do size = size - 2 end
  local total, tag = stack(size)
  OUT.size, OUT.tag = size, tag
  -- the wordmark's slam starts 1.25 times larger, or as much as stays on the canvas
  OUT.slam = slam_from(1.25, m.cx, m.w)
  OUT.mark = m.y + (m.h - total) / 2 + size * 0.8
  OUT.tagline = OUT.mark + tag * 1.7
  OUT.pill = OUT.tagline + PILL.size * 2.3
  OUT.chips = OUT.pill + PILL.size * 2.4
end

-- ---- captions: the voice-over as WebVTT with inline word timestamps --------

local function stamp(s)
  return string.format("%02d:%02d:%06.3f", math.floor(s / 3600), math.floor(s % 3600 / 60), s % 60)
end
do
  local vtt = { "WEBVTT", "" }
  for _, c in ipairs(T.CAPTIONS) do
    local words = {}
    for i = 1, #c, 2 do
      words[#words + 1] = (i > 1 and "<" .. stamp(score.time(c[i])) .. ">" or "") .. c[i + 1]
    end
    vtt[#vtt + 1] = stamp(score.time(c[1])) .. " --> " .. stamp(score.time(c.stop))
    vtt[#vtt + 1] = table.concat(words, " ")
    vtt[#vtt + 1] = ""
  end
  captions_load("voiceover", table.concat(vtt, "\n"))
end

local CAPTIONS = { src = "voiceover", x = W / 2 - L.caption.w / 2, y = L.caption.y, w = L.caption.w,
  valign = "middle", font = DISPLAY, weight = 800, size = L.caption.size, line_height = 1.2, uppercase = true,
  fill = PAPER, highlight = "box", highlight_fill = "#ffd23f", active_fill = INK, active_scale = 1.1,
  max_words = 3, hold = 0.3 }

-- ---- shared pieces ---------------------------------------------------------

local SNAP = spring { stiffness = 320, damping = 22 }
local SOFT = spring { stiffness = 170, damping = 14 }

-- Each section's background and accent.
local THEMES = {
  { top = "#3a1270", bottom = "#120628", blob = "#ff4f8b", accent = "#ffd23f" },
  { top = "#06455a", bottom = "#03141d", blob = "#3ee0ff", accent = "#3ee0ff" },
  { top = "#5a0f45", bottom = "#16041a", blob = "#ffd23f", accent = "#ff4f8b" },
  { top = "#3a1270", bottom = "#120628", blob = "#3ee0ff", accent = "#ffd23f" },
}
local function section_of(gb)
  local k = 1
  for i, s in ipairs(T.SECTIONS) do if gb >= s[1] then k = i end end
  return k
end

local function backdrop(f, gb)
  local th = THEMES[section_of(gb)]
  rect { x = 0, y = 0, w = W, h = H, fill = linear_gradient { x1 = 0, y1 = 0, x2 = W * 0.3, y2 = H,
    stops = { { 0, th.top }, { 1, th.bottom } } } }
  local t = f.global_seconds
  local r = math.max(W, H) * 0.32
  group({ blur = r * 0.35, opacity = 0.5 }, function()
    circle { cx = W * (0.25 + 0.1 * noise(t * 0.2, 1)), cy = H * (0.3 + 0.08 * noise(t * 0.2, 2)), r = r, fill = th.blob }
    circle { cx = W * (0.8 + 0.08 * noise(t * 0.2, 3)), cy = H * (0.78 + 0.06 * noise(t * 0.2, 4)), r = r * 0.8,
      fill = th.accent }
  end)
end

-- Pip: the alpha clip, `w` wide around (cx, cy), with a soft glow behind.
-- The clip loops every two seconds (four beats), so it stays on the beat
-- in every section (sections start on bars).
local function bo(f, cx, cy, w, opacity)
  local h = w * 9 / 16
  circle { cx = cx, cy = cy + h * 0.05, r = h * 0.48, fill = radial_gradient { cx = cx, cy = cy + h * 0.05,
    r = h * 0.48, stops = { { 0, "#ffffff30" }, { 1, "#ffffff00" } } }, opacity = opacity }
  video_frame(f, { src = "mascot.webm", x = cx - w / 2, y = cy - h / 2, w = w, h = h, looping = true,
    opacity = opacity })
end

-- A rounded pill with centred text, `q` a text query (measured).
local function pill(cx, cy, q, fill, ink, stroke)
  local w = text_width(q) + q.size * 1.6
  local h = q.size * 1.9
  rect { x = cx - w / 2, y = cy - h / 2, w = w, h = h, rx = h / 2, fill = fill, stroke = stroke,
    stroke_width = stroke and 3 or nil }
  text { q[1], x = cx, y = cy, align = "center", baseline = "middle", font = q.font, size = q.size,
    weight = q.weight, fill = ink }
end

-- ---- sections (gb: beats on the video clock, lb: beats into the section) ----

local function hook(f, gb, lb)
  local th = THEMES[1]
  -- already a little way in on the first frame (the thumbnail)
  local s = ease(SOFT, since(gb, T.BO_IN) + 0.12)
  if s > 0 then
    local st = L.stage
    group({ transform = { translate = { 0, (1 - s) * 120 }, scale = 0.6 + 0.4 * s, origin = { st.cx, st.y + st.h } },
      opacity = clamp01(s * 2) }, function()
      bo(f, st.cx, st.cy, st.w * 1.15, 1)
    end)
  end
  local hd = L.head
  local lead = HEAD_SIZE * 1.05
  local y0 = hd.cy - lead + HEAD_SIZE * 0.72
  for k, line in ipairs(HEAD) do
    local at = k == 1 and T.LINE1 or T.LINE2
    local p = ease(SNAP, since(gb, at))
    if p > 0 then
      local y = y0 + (k - 1) * lead
      group({ transform = { scale = HEAD_SLAM - (HEAD_SLAM - 1) * p, origin = { hd.cx, y - HEAD_SIZE * 0.35 } }, opacity = clamp01(p * 3) },
        function()
          text { line, x = hd.cx, y = y, align = "center", font = DISPLAY, size = HEAD_SIZE, weight = 800,
            letter_spacing = -2, fill = k == 1 and PAPER or th.accent }
        end)
    end
  end
end

local function formats(f, gb, lb)
  local th = THEMES[2]
  local here = ease(SNAP, since(gb, T.HERE))
  for k, fr in ipairs(FRAMES) do
    local p = ease(SNAP, since(gb, T.FRAMES[k]))
    if p > 0 then
      local b = fr.box
      local mine = fr.key == FORMAT
      local dim = mine and 1 or 1 - 0.55 * here
      group({ transform = { scale = 0.7 + 0.3 * p, origin = { b.cx, b.cy } }, opacity = clamp01(p * 2) * dim }, function()
        rect { x = b.x, y = b.y, w = b.w, h = b.h, rx = 24, fill = mine and here > 0 and th.accent .. "26" or "#ffffff0d",
          stroke = mine and here > 0 and th.accent or "#ffffffb0", stroke_width = 5 }
        -- a sketch of the layout inside, a disc for Pip and two lines of type
        -- (this video's own frame shows Pip instead)
        local r = math.min(b.w, b.h) * 0.16
        local cy = b.cy - b.h * 0.12
        if not (mine and here > 0) then
          circle { cx = b.cx, cy = cy, r = r, fill = "#ffffff30" }
          rect { x = b.cx - b.w * 0.3, y = cy + r * 1.6, w = b.w * 0.6, h = r * 0.34, rx = r * 0.17, fill = "#ffffff40" }
          rect { x = b.cx - b.w * 0.2, y = cy + r * 2.2, w = b.w * 0.4, h = r * 0.34, rx = r * 0.17, fill = "#ffffff28" }
        end
        text { fr.label, x = b.cx, y = b.y + b.h + 64, align = "center", font = MONO, size = 44,
          fill = mine and here > 0 and th.accent or PAPER }
      end)
      -- this video's own frame: Pip hops into it
      if mine and here > 0 then
        local bw = math.min(b.w * 1.3, b.h * 1.5)
        group({ transform = { scale = here, origin = { b.cx, b.cy - b.h * 0.12 } } }, function()
          bo(f, b.cx, b.cy - b.h * 0.08, bw, 1)
        end)
        local q = { "this one", font = MONO, size = 30 }
        local y = b.y - 46 - 10 * (1 - here)
        group({ opacity = clamp01(here * 2) }, function() pill(b.cx, y, q, th.accent, INK) end)
      end
    end
  end
end

-- The feature visuals, drawn into CARD.vis (v); g: the cut's local frame.
local VISUALS = {
  -- captions: three word chips, the highlight hopping every half beat
  function(f, gb, v, th)
    local words = { "WORD", "BY", "WORD" }
    local size = math.min(v.h * 0.22, v.w * 0.09)
    local q = { font = DISPLAY, size = size, weight = 800 }
    local ws, total = {}, 0
    for k, wd in ipairs(words) do
      q[1] = wd
      ws[k] = text_width(q) + size * 0.7
      total = total + ws[k] + (k > 1 and size * 0.3 or 0)
    end
    local active = math.floor(gb * 2) % 3 + 1
    local pop = 1 + 0.12 * pulse(gb * 2, 6)
    local x = v.cx - total / 2
    for k, wd in ipairs(words) do
      local on = k == active
      local cx = x + ws[k] / 2
      group({ transform = { scale = on and pop or 1, origin = { cx, v.cy } } }, function()
        rect { x = x, y = v.cy - size * 0.75, w = ws[k], h = size * 1.5, rx = size * 0.3,
          fill = on and "#ffd23f" or "#ffffff1a" }
        text { wd, x = cx, y = v.cy, align = "center", baseline = "middle", font = DISPLAY, size = size, weight = 800,
          fill = on and INK or PAPER }
      end)
      x = x + ws[k] + size * 0.3
    end
  end,
  -- music: the song's spectrum, mirrored about the middle
  function(f, gb, v, th)
    local bins = audio_spectrum(f, { src = "score", sample_size = 1024, smooth = 1, bands = 24 })
    if not bins then return end
    local n = #bins
    local bw = v.w / (2 * n)
    for i, m in ipairs(bins) do
      local db = 20 * math.log(m + 1e-3, 10)
      local level = clamp01((db + 18) / 44)
      local h = math.max(level * v.h * 0.9, 8)
      local c = mix_color(th.accent, "#ffd23f", i / n)
      for side = -1, 1, 2 do
        local x = v.cx + side * (i - 0.5) * bw
        rect { x = x - bw * 0.35, y = v.cy - h / 2, w = bw * 0.7, h = h, rx = bw * 0.35, fill = c }
      end
    end
  end,
  -- cuts on the beat: four beats of the bar, the playing one lit
  function(f, gb, v, th)
    local r = math.min(v.w / 12, v.h * 0.18)
    local beat = math.floor(gb) % 4
    local kick = pulse(gb, 7)
    for i = 0, 3 do
      local cx = v.cx + (i - 1.5) * r * 2.8
      local on = i == beat
      if on then
        group({ blur = r * 0.5, opacity = 0.7 * kick + 0.3 }, function() circle { cx = cx, cy = v.cy, r = r * 1.2, fill = th.accent } end)
      end
      circle { cx = cx, cy = v.cy, r = on and r * (1 + 0.15 * kick) or r * 0.8, fill = on and th.accent or "#ffffff26" }
    end
    -- the playhead sweeps the bar
    local x = v.cx + (fract(gb / 4) * 4 - 1.5) * r * 2.8
    rect { x = x - 3, y = v.cy + r * 1.7, w = 6, h = r * 0.5, rx = 3, fill = PAPER }
    text { string.format("%d BPM", score.sections[1].bpm), x = v.cx, y = v.cy - r * 1.7, align = "center", font = MONO, size = r * 0.5, fill = PAPER,
      opacity = 0.8 }
  end,
  -- alpha video: Pip over a checkerboard, the transparency showing
  function(f, gb, v, th)
    local s = math.min(v.w, v.h * 1.4)
    local b = box(v.cx - s / 2, v.cy - s * 0.36, s, s * 0.72)
    local cell = s / 16
    rect { x = b.x, y = b.y, w = b.w, h = b.h, rx = 28, fill = pattern { x = b.x, y = b.y, w = cell * 2, h = cell * 2,
      content = function()
        rect { x = 0, y = 0, w = cell * 2, h = cell * 2, fill = "#d9d4e4" }
        rect { x = 0, y = 0, w = cell, h = cell, fill = "#ffffff" }
        rect { x = cell, y = cell, w = cell, h = cell, fill = "#ffffff" }
      end } }
    video_frame(f, { src = "mascot.webm", x = b.x, y = b.y, w = b.w, h = b.h, looping = true })
    rect { x = b.x, y = b.y, w = b.w, h = b.h, rx = 28, fill = "none", stroke = th.accent, stroke_width = 5 }
  end,
}

local function features(f, gb, lb)
  local th = THEMES[3]
  local k = 1
  for i, c in ipairs(T.FEATURE_CUTS) do if gb >= c then k = math.min(i, #FEATURES) end end
  local cut = T.FEATURE_CUTS[k]
  local p = ease(SNAP, since(gb, cut))
  local v = CARD.vis
  group({ transform = { scale = 0.88 + 0.12 * p, origin = { v.cx, v.cy } }, opacity = clamp01(p * 3) }, function()
    VISUALS[k](f, gb, v, th)
  end)
  local ft = FEATURES[k]
  local tp = ease(SNAP, since(gb, cut + 0.25))
  if tp > 0 then
    group({ transform = translate(0, (1 - tp) * 50), opacity = clamp01(tp * 2) }, function()
      local y = CARD.ty
      text { string.format("%02d", k), x = CARD.tx, y = y - CARD.size * 0.95, align = CARD.align, font = MONO,
        size = 34, fill = th.accent }
      text { ft.title, x = CARD.tx, y = y, align = CARD.align, font = DISPLAY, size = CARD.size, weight = 800,
        letter_spacing = -1, fill = PAPER }
      text { ft.code, x = CARD.tx, y = y + CARD.code * 2, align = CARD.align, font = MONO, size = CARD.code,
        fill = "#ffffffb0" }
    end)
  end
end

local function outro(f, gb, lb)
  local th = THEMES[4]
  local st = L.stage
  local s = ease(SOFT, since(gb, T.MARK) + 0.15)
  bo(f, st.cx, st.cy, st.w * 1.1 * (0.85 + 0.15 * s), clamp01(s * 2))
  local m = L.mark
  local mp = ease(SNAP, since(gb, T.MARK))
  group({ transform = { scale = OUT.slam - (OUT.slam - 1) * mp, origin = { m.cx, OUT.mark - OUT.size * 0.35 } },
    opacity = clamp01(mp * 3) }, function()
    text { "onimite", x = m.cx, y = OUT.mark, align = "center", font = DISPLAY, size = OUT.size, weight = 800,
      letter_spacing = -6, fill = PAPER }
  end)
  text { "one Lua script · every format", x = m.cx, y = OUT.tagline, align = "center", font = SANS,
    size = OUT.tag, fill = PAPER, opacity = clamp01((gb - T.MARK - 0.5) * 2) * 0.85 }
  local pp = ease(SNAP, since(gb, T.PILL))
  if pp > 0 then
    group({ transform = { scale = 0.8 + 0.2 * pp, origin = { m.cx, OUT.pill } }, opacity = clamp01(pp * 2) }, function()
      pill(m.cx, OUT.pill, PILL, "#ffffff12", th.accent, th.accent)
    end)
  end
  -- the three formats as chips, this one lit
  local cq = { font = MONO, size = 30 }
  local cy = OUT.chips
  for k, fr in ipairs(FRAMES) do
    local cp = ease(SNAP, since(gb, T.CHIPS + (k - 1) * 0.25))
    if cp > 0 then
      cq[1] = fr.label
      local mine = fr.key == FORMAT
      group({ opacity = clamp01(cp * 2), transform = translate(0, (1 - cp) * 20) }, function()
        pill(m.cx + (k - 2) * 170, cy, cq, mine and th.accent or "#ffffff1a", mine and INK or PAPER)
      end)
    end
  end
end

local RENDERERS = { hook, formats, features, outro }

-- ---- video -------------------------------------------------------------------

-- Story-style progress: a segment per section, each filling as it plays.
local function progress_bar(gb)
  local b, gap = L.bar, 12
  local n = #T.SECTIONS
  local sw = (b.w - gap * (n - 1)) / n
  for k, s in ipairs(T.SECTIONS) do
    local stop = k < n and T.SECTIONS[k + 1][1] or T.TOTAL
    local x = b.x + (k - 1) * (sw + gap)
    local p = clamp01((gb - s[1]) / (stop - s[1]))
    rect { x = x, y = b.y, w = sw, h = b.h, rx = b.h / 2, fill = "#ffffff38" }
    if p > 0 then rect { x = x, y = b.y, w = math.max(sw * p, b.h), h = b.h, rx = b.h / 2, fill = PAPER } end
  end
end

-- Cuts: every section start and every feature cut has its crash in the
-- song; the picture flashes and punches in on it (inspect checks it hits).
local CUT, FLASH = { part = "crash", decay = 6 }, { part = "crash", decay = 8 }
local KICK = { part = "drums", note = "kick", decay = 9 }
cue("cut", score.hits { part = "crash" }, { hit = "score" })

video {
  width = W, height = H, fps = FPS, background = THEMES[1].bottom,
  duration = score.duration,
  buses = { music = {} },
  audio = { { "score", bus = "music", fade_out = 0.6 } },
  -- the song mixes near -17.5 LUFS: lifted to about -14 under the limiter
  -- (audio analyze: -14.1 LUFS, -1.5 dBTP)
  master_gain_db = 4.9,
  render = function(f)
    local gb = score.beat(f)
    backdrop(f, gb)
    local punch = 0.06 * score.pulse(f, CUT) + 0.006 * score.pulse(f, KICK)   -- at most PUNCH - 1
    group({ transform = { scale = 1 + punch, origin = { W / 2, H / 2 } } }, function() render_scenes(f) end)
    captions(f.global_seconds, CAPTIONS)
    progress_bar(gb)
    local flash = score.pulse(f, FLASH)
    if flash > 0.02 then rect { x = 0, y = 0, w = W, h = H, fill = PAPER, opacity = flash * 0.35 } end
    local out = progress(gb, T.TOTAL - 0.75, T.TOTAL)
    if out > 0 then rect { x = 0, y = 0, w = W, h = H, fill = THEMES[4].bottom, opacity = out } end
  end,
}

-- A scene per section, from its first beat to the next scene's (the
-- outro through the song's tail).
for k, s in ipairs(T.SECTIONS) do
  local start, render = s[1], RENDERERS[k]
  scene { s[2], start = score.time(s[3]), cue = s[3], render = function(f)
    local gb = score.beat(f)
    render(f, gb, gb - start)
  end }
end
