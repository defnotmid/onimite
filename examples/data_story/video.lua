-- Data story: a 30 second explainer drawn entirely from data. One garden's
-- year (a name, an emoji, two colours, twelve monthly harvests and the
-- crops) arrives as `props`; the charts, counters, captions' colours and
-- the music's blips all follow it. The numbers in data.json and rows.json
-- are invented sample data.
--
--     onimite render examples/data_story/video.lua --props examples/data_story/data.json -o story.mp4
--     onimite render examples/data_story/video.lua --batch examples/data_story/rows.json -o out/{name}.mp4

local ui = require("ui")

-- ---- data (defaults = data.json, so the script renders on its own) --------

local DEFAULT = {
  name = "Riverside School Garden", emoji = "🌻", accent = "#facc15", accent2 = "#22d3ee", unit = "kg",
  months = { 8, 14, 30, 58, 112, 196, 318, 402, 356, 184, 66, 21 },
  crops = { { label = "🍅 Tomatoes", value = 560 }, { label = "🎃 Squash", value = 420 },
    { label = "🫘 Beans", value = 290 }, { label = "🥬 Greens", value = 345 }, { label = "🌿 Herbs", value = 150 } },
}
local D = {}
for k, v in pairs(DEFAULT) do D[k] = props[k] ~= nil and props[k] or v end

assert(type(D.months) == "table" and #D.months == 12, "props.months needs 12 numbers")
assert(type(D.crops) == "table" and #D.crops >= 2 and #D.crops <= 6, "props.crops needs 2 to 6 entries")

local MONTH_NAMES = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local ACCENT, ACCENT2 = D.accent, D.accent2
local LOW = mix_color(ACCENT, ui.LOW, 0.7) -- small values: a dark, muted accent

local MAXV, PEAK, TOTAL, CUM = 0, 1, 0, {}
for m, v in ipairs(D.months) do
  if v > MAXV then MAXV, PEAK = v, m end
  TOTAL = TOTAL + v
  CUM[m] = TOTAL
end

local CROPS, CROP_SUM, TOP = {}, 0, 1
for _, c in ipairs(D.crops) do CROP_SUM = CROP_SUM + c.value end
for k, c in ipairs(D.crops) do
  CROPS[k] = { label = c.label, value = c.value, share = c.value / CROP_SUM,
    color = mix_color(ACCENT, ACCENT2, (k - 1) / (#D.crops - 1)) }
  if c.value > D.crops[TOP].value then TOP = k end
end

-- The name as large as fits in 1600 px.
local NAME_SIZE = 150
while NAME_SIZE > 72 and text_width { D.name, font = ui.DISPLAY, size = NAME_SIZE, weight = 800, letter_spacing = -3 } > 1600 do
  NAME_SIZE = NAME_SIZE - 4
end

-- ---- chart geometry, at load ----------------------------------------------

local SLOT = (ui.X1 - ui.X0) / 12
local BAR_W = 84
local function month_x(m) return ui.X0 + (m - 0.5) * SLOT end
local function value_y(v, hi) return ui.BASE - v / hi * (ui.BASE - ui.TOP) end

-- The running total's polyline, with arc lengths for the dot riding it.
local LINE_PTS, LINE_LEN, LINE_D = {}, { 0 }, {}
for m = 1, 12 do
  LINE_PTS[m] = { month_x(m), value_y(CUM[m], TOTAL) }
  LINE_D[#LINE_D + 1] = string.format("%s%.1f %.1f", m == 1 and "M" or "L", LINE_PTS[m][1], LINE_PTS[m][2])
  if m > 1 then
    local a, b = LINE_PTS[m - 1], LINE_PTS[m]
    LINE_LEN[m] = LINE_LEN[m - 1] + math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
  end
end
LINE_D = table.concat(LINE_D, " ")
local AREA = {}
for m = 1, 12 do AREA[#AREA + 1] = LINE_PTS[m] end
AREA[#AREA + 1] = { month_x(12), ui.BASE }
AREA[#AREA + 1] = { month_x(1), ui.BASE }

-- The point at fraction p of the line's length, and the months passed.
local function along(p)
  local d = p * LINE_LEN[12]
  for m = 2, 12 do
    if d <= LINE_LEN[m] then
      local a, b = LINE_PTS[m - 1], LINE_PTS[m]
      local u = (d - LINE_LEN[m - 1]) / (LINE_LEN[m] - LINE_LEN[m - 1])
      return lerp(a[1], b[1], u), lerp(a[2], b[2], u), lerp(CUM[m - 1], CUM[m], u), m - 1 + u
    end
  end
  return LINE_PTS[12][1], LINE_PTS[12][2], TOTAL, 12
end

-- Donut segments: arcs from 12 o'clock, a small gap between them.
local DONUT_X, DONUT_Y, DONUT_R, DONUT_W = 600, 600, 220, 84
local function arc(a0, a1)
  local r0, r1 = math.rad(a0 - 90), math.rad(a1 - 90)
  return path_data(string.format("M%.2f %.2f A%d %d 0 %d 1 %.2f %.2f",
    DONUT_X + DONUT_R * math.cos(r0), DONUT_Y + DONUT_R * math.sin(r0), DONUT_R, DONUT_R,
    a1 - a0 > 180 and 1 or 0, DONUT_X + DONUT_R * math.cos(r1), DONUT_Y + DONUT_R * math.sin(r1)))
end
do
  local a = 0
  for _, c in ipairs(CROPS) do
    c.arc = arc(a + 1.2, a + c.share * 360 - 1.2)
    a = a + c.share * 360
  end
end

-- ---- music and captions ------------------------------------------------------

-- The score (track.lua) is composed from the data; every cue the picture
-- uses is read back from it (timeline.lua).
local score = require("track")(D.months, #CROPS)
local T = require("timeline")(score)

local CAPTIONS = { src = "story.json", x = 160, y = 985, w = 1600, valign = "middle",
  font = ui.DISPLAY, weight = 800, size = 46, fill = ui.TEXT, upcoming_fill = "#f4f1ea66",
  active_fill = ACCENT, highlight = "fill", active_scale = 1.1, max_words = 5, hold = 0.4 }

-- ---- sections (t: video seconds, at: seconds into the section) -------------

local function title(f, t, at)
  ui.backdrop(f, ACCENT, 960, 480)
  local e = ease(ui.SOFT, t - T.EMOJI)
  if e > 0 then
    group({ transform = { scale = 0.6 + 0.4 * e, rotate = (1 - e) * -12, origin = { 960, 380 } }, opacity = clamp01(e * 2) }, function()
      text { D.emoji, x = 960, y = 380, align = "center", baseline = "middle", size = 200 }
    end)
  end
  local n = ease(ui.SNAP, t - T.NAME)
  if n > 0 then
    group({ transform = { translate = { 0, (1 - n) * 80 }, scale = 1.06 - 0.06 * n, origin = { 960, 600 } }, opacity = clamp01(n * 3) }, function()
      text { D.name, x = 960, y = 640, align = "center", font = ui.DISPLAY, size = NAME_SIZE, weight = 800,
        letter_spacing = -3, fill = ui.TEXT }
    end)
  end
  local s = ease(ui.SNAP, t - T.SUB)
  if s > 0 then
    local w = 520 * s
    rect { x = 960 - w / 2, y = 690, w = w, h = 6, rx = 3, fill = ACCENT }
    text { "12 months of harvest  ·  sample data", x = 960, y = 770 + (1 - s) * 30, align = "center",
      font = ui.SANS, size = 48, fill = ui.DIM, opacity = s }
  end
end

local function bars(f, t, at)
  ui.backdrop(f, ACCENT, 1300, 500)
  ui.header(at + T.BEAT, "Harvest per month", D.unit .. " · January to December")
  local focus = ease(ease_in_out, t - T.PEAK, 0.4)
  rect { x = ui.X0 - 20, y = ui.BASE, w = ui.X1 - ui.X0 + 40, h = 2, fill = ui.LINE }
  for m, v in ipairs(D.months) do
    local x = month_x(m)
    local s = ease(ui.SOFT, t - T.MONTHS[m])
    local is_peak = m == PEAK
    local dim = is_peak and 1 or 1 - 0.6 * focus
    if s > 0 then
      local h = math.max(v / MAXV * (ui.BASE - ui.TOP) * s, 2)
      local fill = mix_color(LOW, ACCENT, v / MAXV)
      if is_peak and focus > 0 then
        group({ blur = 26, opacity = focus * 0.8 }, function()
          rect { x = x - BAR_W / 2, y = ui.BASE - h, w = BAR_W, h = h, rx = 10, fill = ACCENT }
        end)
      end
      rect { x = x - BAR_W / 2, y = ui.BASE - h, w = BAR_W, h = h, rx = 10, fill = fill, opacity = dim }
      text { ui.thousands(v * clamp01(s)), x = x, y = ui.BASE - h - 18, align = "center", font = ui.MONO, size = 28,
        fill = is_peak and focus > 0 and ACCENT or ui.TEXT, opacity = clamp01(s * 3) * dim }
    end
    text { MONTH_NAMES[m], x = x, y = ui.BASE + 46, align = "center", font = ui.MONO, size = 28,
      fill = is_peak and focus > 0.5 and ACCENT or ui.DIM, opacity = clamp01(at * 4) }
  end
  -- the callout over the best month
  local c = ease(ui.SNAP, t - T.PEAK)
  if c > 0 then
    local label = "Best month " .. D.emoji
    local w = text_width { label, font = ui.SANS, size = 40 } + 48
    local x, y = month_x(PEAK), ui.TOP - 124
    x = math.max(ui.X0 + w / 2, math.min(ui.X1 - w / 2, x))
    group({ transform = { scale = 0.8 + 0.2 * c, origin = { x, y + 30 } }, opacity = clamp01(c * 3) }, function()
      rect { x = x - w / 2, y = y, w = w, h = 64, rx = 32, fill = ACCENT }
      text { label, x = x, y = y + 32, align = "center", baseline = "middle", font = ui.SANS, size = 40, fill = ui.BG }
    end)
  end
end

local function line_chart(f, t, at)
  ui.backdrop(f, ACCENT2, 700, 600)
  ui.header(at + T.BEAT, "Running total", D.unit .. ", each month added to the last")
  -- grid: quarters of the year's total
  for q = 1, 4 do
    local y = value_y(TOTAL * q / 4, TOTAL)
    local a = clamp01((at + 0.3 - q * 0.1) * 4)
    rect { x = ui.X0, y = y, w = ui.X1 - ui.X0, h = 1, fill = ui.LINE, opacity = a }
    text { ui.thousands(TOTAL * q / 4), x = ui.X0 - 24, y = y + 10, align = "right", font = ui.MONO, size = 28,
      fill = ui.DIM, opacity = a }
  end
  rect { x = ui.X0, y = ui.BASE, w = ui.X1 - ui.X0, h = 2, fill = ui.LINE }
  for m = 1, 12 do
    text { MONTH_NAMES[m], x = month_x(m), y = ui.BASE + 46, align = "center", font = ui.MONO, size = 28, fill = ui.DIM }
  end
  local p = ease(cubic_bezier(0.65, 0, 0.35, 1), t - T.LINE_GO, T.LINE_END - T.LINE_GO)
  if p <= 0 then return end
  local x, y, value, months = along(p)
  group({ clip = { x = ui.X0 - 10, y = ui.TOP - 40, w = x - ui.X0 + 10, h = ui.BASE - ui.TOP + 40 } }, function()
    polygon { points = AREA, fill = linear_gradient { x1 = 0, y1 = ui.TOP, x2 = 0, y2 = ui.BASE,
      stops = { { 0, mix_color(ACCENT2, ui.BG, 0.55) }, { 1, mix_color(ACCENT2, ui.BG, 0.95) } } } }
  end)
  path { d = LINE_D, fill = "none", stroke = ACCENT2, stroke_width = 8, line_cap = "round", line_join = "round",
    path_length = 1, stroke_dasharray = { 1, 1 }, stroke_dashoffset = 1 - p }
  for m = 1, math.floor(months + 1e-6) do
    circle { cx = LINE_PTS[m][1], cy = LINE_PTS[m][2], r = 7, fill = ui.BG, stroke = ACCENT2, stroke_width = 4 }
  end
  -- the dot and its counter; it pops when the line lands on the total
  local pop = 1 + 0.35 * score.pulse(f, { part = "chimes", decay = 3 })
  group({ blur = 14 }, function() circle { cx = x, cy = y, r = 18 * pop, fill = ACCENT2 } end)
  circle { cx = x, cy = y, r = 12 * pop, fill = ui.TEXT }
  local label = ui.thousands(value) .. " " .. D.unit
  text { label, x = math.min(x, ui.X1 - 140), y = y - 36, align = "center", font = ui.MONO, size = 36, fill = ui.TEXT }
end

local function donut(f, t, at)
  ui.backdrop(f, ACCENT, 600, 600)
  ui.header(at + T.BEAT, "What grew", "share of the year's harvest, by crop")
  circle { cx = DONUT_X, cy = DONUT_Y, r = DONUT_R, fill = "none", stroke = ui.BG2, stroke_width = DONUT_W }
  for k, c in ipairs(CROPS) do
    local p = ease(ui.EXPO, t - T.SEGMENTS[k], 0.9)
    if p > 0 then
      path { d = c.arc, fill = "none", stroke = c.color, stroke_width = DONUT_W, path_length = 1,
        stroke_dasharray = { 1, 1 }, stroke_dashoffset = 1 - p }
    end
    -- its legend row
    local s = ease(ui.SNAP, t - T.SEGMENTS[k])
    if s > 0 then
      local y = 400 + (k - 1) * (480 / #CROPS)
      group({ transform = translate((1 - s) * 60, 0), opacity = clamp01(s * 2) }, function()
        rect { x = 1000, y = y - 18, w = 36, h = 36, rx = 10, fill = c.color }
        text { c.label, x = 1066, y = y, baseline = "middle", font = ui.SANS, size = 46, fill = ui.TEXT }
        text { string.format("%d%%", math.floor(c.share * 100 * clamp01(p) + 0.5)), x = 1760, y = y, align = "right",
          baseline = "middle", font = ui.MONO, size = 44, fill = c.color }
      end)
    end
  end
  -- the biggest share in the middle, once its segment is in
  local top = CROPS[TOP]
  local s = ease(ui.SNAP, t - T.SEGMENTS[TOP] - T.BEAT / 2)
  if s > 0 then
    group({ transform = { scale = 0.85 + 0.15 * s, origin = { DONUT_X, DONUT_Y } }, opacity = clamp01(s * 2) }, function()
      text { string.format("%d%%", math.floor(top.share * 100 + 0.5)), x = DONUT_X, y = DONUT_Y + 14, align = "center",
        font = ui.DISPLAY, size = 104, weight = 800, letter_spacing = -2, fill = ui.TEXT }
      text { "the biggest share", x = DONUT_X, y = DONUT_Y + 70, align = "center", font = ui.SANS, size = 32, fill = ui.DIM }
    end)
  end
end

local function outro(f, t, at)
  ui.backdrop(f, ACCENT, 960, 560)
  local n = ease(ui.SNAP, at + T.BEAT)
  text { D.emoji .. "  " .. D.name, x = 960, y = 300 + (1 - n) * 40, align = "center", font = ui.DISPLAY, size = 64,
    weight = 800, letter_spacing = -1, fill = ui.TEXT, opacity = clamp01(n * 2) }
  local c = ease(ui.EXPO, t - T.COUNT_GO, T.COUNT_END - T.COUNT_GO)
  local land = 1 + 0.06 * score.pulse(f, { part = "chimes", decay = 4 })
  if t >= T.COUNT_GO then
    group({ transform = { scale = land, origin = { 960, 540 } } }, function()
      text { ui.thousands(TOTAL * c), x = 960, y = 590, align = "center", font = ui.DISPLAY, size = 220, weight = 800,
        letter_spacing = -6, fill = mix_color(ui.TEXT, ACCENT, c) }
    end)
    text { D.unit .. " harvested in 12 months", x = 960, y = 680, align = "center", font = ui.SANS, size = 52,
      fill = ui.DIM, opacity = c }
  end
  -- the year as a sparkline, coloured low to high
  local sp = ease(ui.EXPO, t - T.COUNT_END, 1.2)
  if sp > 0 then
    for m, v in ipairs(D.months) do
      local h = math.max(v / MAXV * 90 * sp, 2)
      local x = 960 + (m - 6.5) * 40
      rect { x = x - 14, y = 840 - h, w = 28, h = h, rx = 6, fill = mix_color(LOW, ACCENT, v / MAXV) }
    end
  end
end

local RENDERERS = { title, bars, line_chart, donut, outro }
local TRANSITIONS = {
  nil,
  { "wipe", from = "left", softness = 240 },
  { "slide", from = "right" },
  { "clock_wipe" },
  { "zoom" },
}
local NAMES = { "TITLE", "MONTHS", "RUNNING TOTAL", "CROPS", "TOTAL" }

-- ---- video ---------------------------------------------------------------

local function hud(f, t)
  local section = 1
  for k, s in ipairs(T.SCENES) do if t >= score.time(s[1]) then section = k end end
  group({ opacity = 0.85 }, function()
    text { D.emoji .. " " .. D.name, x = 160, y = 84, font = ui.MONO, size = 28, fill = ui.DIM }
    text { string.format("%02d / %02d  %s", section, #T.SCENES, NAMES[section]), x = 1760, y = 84, align = "right",
      font = ui.MONO, size = 28, fill = ui.DIM }
    rect { x = 160, y = 1046, w = 1600, h = 2, fill = ui.LINE }
    rect { x = 160, y = 1045, w = math.max(1600 * t / score.duration, 1), h = 4, fill = ACCENT }
  end)
end

video {
  width = 1920, height = 1080, fps = T.FPS, duration = score.duration, background = ui.BG,
  audio = { { "score", fade_out = 0.8 } },
  -- the song lifted to about -14 LUFS under the limiter
  master_gain_db = 7.9,
  limiter = { ceiling_db = -1.2 },
  render = function(f)
    local t = f.global_seconds
    local kick = score.pulse(f, { part = "drums", note = "kick", decay = 9 })   -- the kicks really played
    group({ transform = { scale = 1 + 0.004 * kick, origin = { 960, 540 } } }, function() render_scenes(f) end)
    hud(f, t)
    captions(t, CAPTIONS)
    local out = progress(t, score.duration - 0.6, score.duration)
    if out > 0 then rect { x = 0, y = 0, w = 1920, h = 1080, fill = ui.BG, opacity = out } end
  end,
}

-- A scene per section, starting on it; its transition takes the beat before.
for k, s in ipairs(T.SCENES) do
  local start = score.time(s[1])
  local tr = TRANSITIONS[k]
  if tr then tr.duration, tr.easing = T.BEAT, ease_in_out end
  local render = RENDERERS[k]
  scene { s[2], start = start, transition = tr,
    render = function(f) render(f, f.global_seconds, f.global_seconds - start) end }
end
