-- A production line dashboard: a bottling line's stations, the shift's OEE and
-- counts, events and throughput, read from line.json, the file a PLC bridge
-- rewrites every few seconds. On a screen on the floor, for good:
--
--     onimite preview examples/production_line/video.lua --live
--
-- Each write is a reload; track_changes tells it what moved. Stations are
-- matched by id: one whose state changes turns (its colour, a pulse) while
-- the others stay put, and every number counts from its `before` to the new
-- value. A new event slides into the list. The clock, "updated N s ago",
-- the pace marker and the conveyor run on f.now and f.seconds, so the
-- screen keeps moving between writes; a segment stops the moment the
-- station that stops it changed.
--
--     onimite render examples/production_line/video.lua --now 2026-11-02T10:05:20Z -o line.mp4

local W, H, FPS = 1920, 1080, 60
video { width = W, height = H, fps = FPS, duration = 30, background = "#0a0d12" }

local fh = assert(io.open(SCRIPT_DIR .. "/line.json"))
local LINE = json_decode(fh:read("a"))
fh:close()

local OFFSET = 0
do
  local sign, hh, mm = (LINE.utc_offset or "+00:00"):match("^([+-])(%d%d):(%d%d)$")
  assert(sign, "line.json: utc_offset is like +01:00")
  OFFSET = (sign == "-" and -1 or 1) * (tonumber(hh) * 3600 + tonumber(mm) * 60)
end

-- matched by id: what each station, the totals and each event were before
-- their last change, and when that was
local STATIONS = track_changes("stations", LINE.stations, { key = "id" })
local TOTALS = track_changes("totals", { LINE.totals })[1]
local EVENTS = track_changes("events", LINE.events or {}, { key = "id" })

local BG, PANEL, BORDER = "#0a0d12", "#111720", "#1d2531"
local INK, DIM, FAINT = "#e7ecf2", "#7c8798", "#3a4454"
local GREEN, AMBER, RED, BLUE, GREY = "#34d399", "#fbbf24", "#f43f5e", "#60a5fa", "#64748b"
local STATE = {
  running = { "RUNNING", GREEN }, idle = { "IDLE", GREY }, starved = { "STARVED", AMBER },
  blocked = { "BLOCKED", AMBER }, fault = { "FAULT", RED }, changeover = { "CHANGEOVER", BLUE },
}
local function state_of(name) return STATE[name or "idle"] or { (name or "?"):upper(), GREY } end
local LEVEL = { fault = RED, warn = AMBER, info = BLUE }

local MARGIN = 60
local SANS, MONO = "DM Sans", "JetBrains Mono"

-- ---- time ------------------------------------------------------------------------------

local function local_time(f) return f.now + OFFSET end

-- How far a change has come, 0..1, `dur` seconds from `at` (f.now's clock).
local function progress_since(f, at, dur) return ease(ease_out, (f.now - at) / dur) end

-- A value counting from its `before` to now after the row's change.
local function counted(f, row, key, dur)
  local now = row[key] or 0
  local was = row.before and row.before[key]
  if type(was) ~= "number" then return now end
  return was + (now - was) * progress_since(f, row.changed_at, dur or 0.9)
end

local function thousands(n)
  local s = string.format("%d", math.floor(n + 0.5))
  return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

-- ---- the header ----------------------------------------------------------------------------

-- the newest change of anything in the file: what "updated N s ago" counts from
local LAST_CHANGE = TOTALS.changed_at
for _, s in ipairs(STATIONS) do LAST_CHANGE = math.max(LAST_CHANGE, s.changed_at) end
for _, e in ipairs(EVENTS) do LAST_CHANGE = math.max(LAST_CHANGE, e.changed_at) end

local function header(f)
  text { (LINE.line or "Line"):upper(), x = MARGIN, y = 78, font = SANS, weight = 700, size = 44, letter_spacing = 2, fill = INK }
  local lw = text_width { (LINE.line or "Line"):upper(), font = SANS, weight = 700, size = 44, letter_spacing = 2 }
  text { LINE.product or "", x = MARGIN + lw + 24, y = 78, font = SANS, weight = 500, size = 26, fill = DIM }
  local shift = LINE.shift or {}
  text { string.format("%s  ·  %s–%s", shift.name or "", shift.from or "", shift.to or ""), x = MARGIN, y = 112,
    font = SANS, weight = 500, size = 20, letter_spacing = 1, fill = DIM }
  local now = local_time(f)
  text { os.date("!%H:%M:%S", math.floor(now)), x = W - MARGIN, y = 80, align = "right", font = MONO, weight = 700, size = 44, fill = INK }
  local ago = math.max(0, math.floor(f.now - LAST_CHANGE))
  local fresh = progress_since(f, LAST_CHANGE, 1.2)
  circle { cx = W - MARGIN - 196, cy = 105, r = 5 + 4 * (1 - fresh), fill = GREEN, opacity = 0.5 + 0.5 * (1 - fresh) }
  text { ago == 0 and "updated just now" or string.format("updated %d s ago", ago), x = W - MARGIN, y = 112, align = "right",
    font = SANS, weight = 500, size = 20, fill = DIM }
end

-- ---- the KPI tiles -------------------------------------------------------------------------

local TILE_Y, TILE_H, TILE_GAP = 140, 230, 24
local TILE_W = (W - 2 * MARGIN - 3 * TILE_GAP) / 4

local function tile(i, label)
  local x = MARGIN + (i - 1) * (TILE_W + TILE_GAP)
  rect { x = x, y = TILE_Y, w = TILE_W, h = TILE_H, rx = 18, fill = PANEL, stroke = BORDER, stroke_width = 1.5 }
  text { label, x = x + 28, y = TILE_Y + 42, font = SANS, weight = 700, size = 17, letter_spacing = 3, fill = DIM }
  return x
end

-- an arc of the circle at (cx, cy), radius r, from angle a to b (degrees, 0 at the top, clockwise)
local function arc(cx, cy, r, a, b)
  local function at(deg)
    local t = math.rad(deg - 90)
    return cx + r * math.cos(t), cy + r * math.sin(t)
  end
  local x1, y1 = at(a)
  local x2, y2 = at(b)
  return string.format("M %.2f %.2f A %.2f %.2f 0 %d 1 %.2f %.2f", x1, y1, r, r, (b - a) > 180 and 1 or 0, x2, y2)
end

local function bar(x, y, w, k, color)
  rect { x = x, y = y, w = w, h = 8, rx = 4, fill = FAINT }
  if k > 0 then rect { x = x, y = y, w = w * math.min(1, k), h = 8, rx = 4, fill = color } end
end

local function oee_tile(f)
  local x = tile(1, "OEE")
  local a, p, q = counted(f, TOTALS, "availability"), counted(f, TOTALS, "performance"), counted(f, TOTALS, "quality")
  local oee = a * p * q
  local cx, cy, r = x + 110, TILE_Y + 136, 62
  circle { cx = cx, cy = cy, r = r, fill = "none", stroke = FAINT, stroke_width = 14 }
  local color = oee >= 0.85 and GREEN or oee >= 0.7 and AMBER or RED
  if oee > 0.001 then
    path { d = arc(cx, cy, r, 0, 359.9 * oee), fill = "none", stroke = color, stroke_width = 14, line_cap = "round" }
  end
  text { string.format("%d%%", math.floor(oee * 100 + 0.5)), x = cx, y = cy + 14, align = "center", font = SANS, weight = 700, size = 40, fill = INK }
  for k, part in ipairs { { "Availability", a }, { "Performance", p }, { "Quality", q } } do
    local y = TILE_Y + 88 + (k - 1) * 44
    text { part[1], x = x + 210, y = y, font = SANS, weight = 500, size = 18, fill = DIM }
    text { string.format("%.1f%%", part[2] * 100), x = x + TILE_W - 28, y = y, align = "right", font = MONO, size = 18, fill = INK }
    bar(x + 210, y + 10, TILE_W - 238, part[2], GREEN)
  end
end

-- the share of the shift gone at the board's time
local function shift_share(f)
  local shift = LINE.shift or {}
  local function sec(hhmm) local h, m = (hhmm or "00:00"):match("(%d+):(%d+)") return tonumber(h) * 3600 + tonumber(m) * 60 end
  local day = local_time(f) % 86400
  local from, to = sec(shift.from), sec(shift.to)
  return clamp01((day - from) / math.max(1, to - from))
end

local function good_tile(f)
  local x = tile(2, "GOOD UNITS")
  local good = counted(f, TOTALS, "good")
  text { thousands(good), x = x + 28, y = TILE_Y + 124, font = SANS, weight = 700, size = 62, fill = INK }
  local target = (LINE.shift or {}).target or 1
  local bw = TILE_W - 56
  bar(x + 28, TILE_Y + 160, bw, good / target, BLUE)
  -- where the shift's pace says it should be by now
  local pace = shift_share(f)
  rect { x = x + 28 + bw * pace - 1.5, y = TILE_Y + 152, w = 3, h = 24, rx = 1.5, fill = INK, opacity = 0.8 }
  local ahead = good - target * pace
  text { string.format("of %s  ·  %s%s on pace", thousands(target), ahead >= 0 and "+" or "−", thousands(math.abs(ahead))),
    x = x + 28, y = TILE_Y + 204, font = SANS, weight = 500, size = 18, fill = ahead >= 0 and GREEN or AMBER }
end

local function rate_tile(f)
  local x = tile(3, "LINE RATE")
  local last = STATIONS[#STATIONS]
  local rate = last and counted(f, last, "rate") or 0
  local target = LINE.target_rate or 1
  local cx, cy, r = x + TILE_W / 2, TILE_Y + 192, 112
  path { d = arc(cx, cy, r, -90, 90), fill = "none", stroke = FAINT, stroke_width = 12, line_cap = "round" }
  local k = clamp01(rate / (target * 1.1))
  local color = rate >= target * 0.95 and GREEN or rate > 0 and AMBER or RED
  if k > 0.002 then
    path { d = arc(cx, cy, r, -90, -90 + 180 * k), fill = "none", stroke = color, stroke_width = 12, line_cap = "round" }
  end
  -- the target, a tick on the gauge
  local t = math.rad(-90 + 180 * (1 / 1.1) - 90)
  line { x1 = cx + (r - 14) * math.cos(t), y1 = cy + (r - 14) * math.sin(t), x2 = cx + (r + 14) * math.cos(t), y2 = cy + (r + 14) * math.sin(t),
    stroke = INK, stroke_width = 3 }
  text { thousands(rate), x = cx, y = cy - 22, align = "center", font = SANS, weight = 700, size = 40, fill = INK }
  text { string.format("per hour  ·  target %s", thousands(target)), x = cx, y = cy + 4, align = "center", font = SANS, weight = 500, size = 16, fill = DIM }
end

local function scrap_tile(f)
  local x = tile(4, "SCRAP")
  local scrap, good = counted(f, TOTALS, "scrap"), counted(f, TOTALS, "good")
  text { thousands(scrap), x = x + 28, y = TILE_Y + 124, font = SANS, weight = 700, size = 62, fill = INK }
  local share = scrap / math.max(1, scrap + good)
  text { string.format("%.2f%% of output", share * 100), x = x + 28, y = TILE_Y + 164, font = SANS, weight = 500, size = 20,
    fill = share < 0.015 and GREEN or AMBER }
  text { "goal under 1.50%", x = x + 28, y = TILE_Y + 200, font = SANS, weight = 500, size = 17, fill = DIM }
end

-- ---- the line ------------------------------------------------------------------------------

local CARD_Y, CARD_W, CARD_H = 420, 186, 176
local CARD_GAP = (W - 2 * MARGIN - #STATIONS * CARD_W) / math.max(1, #STATIONS - 1)
local BELT_Y = CARD_Y + CARD_H + 46
local function card_x(i) return MARGIN + (i - 1) * (CARD_W + CARD_GAP) end

local function station(f, i, s)
  local x, y = card_x(i), CARD_Y
  local st, was = state_of(s.state), state_of(s.before and s.before.state)
  local k = progress_since(f, s.changed_at, 0.6)
  local changed_state = s.before and s.before.state ~= s.state
  local color = changed_state and mix_color(was[2], st[2], k) or st[2]
  local fault = s.state == "fault"
  local pulse = fault and (0.55 + 0.45 * math.cos(f.seconds * math.pi * 2 / 1.1)) or 1
  rect { x = x, y = y, w = CARD_W, h = CARD_H, rx = 16, fill = PANEL, stroke = fault and RED or BORDER,
    stroke_width = fault and 2.5 or 1.5, stroke_opacity = fault and pulse or 1 }
  rect { x = x + 16, y = y, w = CARD_W - 32, h = 4, rx = 2, fill = color }
  -- a state that just changed rings out once
  if changed_state and k < 1 then
    rect { x = x - 10 * k, y = y - 10 * k, w = CARD_W + 20 * k, h = CARD_H + 20 * k, rx = 16 + 10 * k, fill = "none",
      stroke = st[2], stroke_width = 3, opacity = 1 - k }
  end
  text { text_fit { s.name or s.id, font = SANS, weight = 700, size = 21, max_width = CARD_W - 32 }, x = x + 16, y = y + 42,
    font = SANS, weight = 700, size = 21, fill = INK }
  local label = changed_state and k < 0.5 and was[1] or st[1]
  local lw = text_width { label, font = SANS, weight = 700, size = 14, letter_spacing = 2 }
  rect { x = x + 16, y = y + 58, w = lw + 22, h = 26, rx = 13, fill = color, opacity = 0.16 }
  text { label, x = x + 27, y = y + 76, font = SANS, weight = 700, size = 14, letter_spacing = 2, fill = color }
  local rate = counted(f, s, "rate")
  text { rate > 0.5 and thousands(rate) or "—", x = x + 16, y = y + 126, font = MONO, weight = 700, size = 28, fill = rate > 0.5 and INK or DIM }
  text { "/h", x = x + 16 + text_width { rate > 0.5 and thousands(rate) or "—", font = MONO, weight = 700, size = 28 } + 6, y = y + 126,
    font = SANS, size = 16, fill = DIM }
  if fault and s.fault then
    text { text_fit { s.fault, font = SANS, weight = 600, size = 16, max_width = CARD_W - 32 }, x = x + 16, y = y + 158,
      font = SANS, weight = 600, size = 16, fill = RED, opacity = pulse }
  else
    text { thousands(counted(f, s, "count")) .. " made", x = x + 16, y = y + 158, font = SANS, size = 16, fill = DIM }
  end
end

-- The conveyor: units flowing from each station to the next while both run,
-- standing still (since the change that stopped them) when they don't.
local SPACING = 34
local function belt(f)
  rect { x = MARGIN, y = BELT_Y - 15, w = W - 2 * MARGIN, h = 30, rx = 15, fill = "#0f141b", stroke = BORDER, stroke_width = 1.5 }
  for i = 1, #STATIONS do
    local cx = card_x(i) + CARD_W / 2
    line { x1 = cx, y1 = CARD_Y + CARD_H, x2 = cx, y2 = BELT_Y - 15, stroke = FAINT, stroke_width = 2 }
    circle { cx = cx, cy = BELT_Y, r = 7, fill = state_of(STATIONS[i].state)[2] }
  end
  for i = 1, #STATIONS - 1 do
    local a, b = STATIONS[i], STATIONS[i + 1]
    local x0, x1 = card_x(i) + CARD_W / 2 + 14, card_x(i + 1) + CARD_W / 2 - 14
    local moving = a.state == "running" and b.state ~= "fault" and b.state ~= "blocked"
    local speed = 46 * (a.rate or 0) / (LINE.target_rate or 24000)
    -- a stopped segment stands where it was when the later of the two changed
    local t = f.seconds
    local stopped_at = math.max(a.changed_at, b.changed_at)
    if not moving and f.now >= stopped_at then t = f.seconds - (f.now - stopped_at) end
    local shift = t * speed
    group({ clip = { x = x0, y = BELT_Y - 12, w = x1 - x0, h = 24 } }, function()
      local off = shift % SPACING
      local queued = (not moving) and math.min(a.buffer or 0, math.floor((x1 - x0) / SPACING)) or 0
      for k = 0, math.floor((x1 - x0) / SPACING) + 1 do
        local ux = x0 - SPACING + off + k * SPACING
        rect { x = ux, y = BELT_Y - 8, w = 22, h = 16, rx = 6, fill = BLUE, opacity = moving and 0.9 or 0.45 }
      end
      -- a stopped segment shows what waits in it, packed at its end
      for k = 1, queued do
        rect { x = x1 - k * 26, y = BELT_Y - 8, w = 22, h = 16, rx = 6, fill = AMBER, opacity = 0.85 }
      end
    end)
  end
end

-- ---- events and throughput -------------------------------------------------------------------

local LOW_Y, LOW_H = BELT_Y + 40, H - BELT_Y - 40 - 40
local EVENTS_W = 860

local function events(f)
  rect { x = MARGIN, y = LOW_Y, w = EVENTS_W, h = LOW_H, rx = 18, fill = PANEL, stroke = BORDER, stroke_width = 1.5 }
  text { "EVENTS", x = MARGIN + 28, y = LOW_Y + 40, font = SANS, weight = 700, size = 17, letter_spacing = 3, fill = DIM }
  local row_h = 46
  for i = 1, math.min(#EVENTS, math.floor((LOW_H - 60) / row_h)) do
    local e = EVENTS[i]
    local k = e.before == nil and progress_since(f, e.changed_at, 0.6) or 1
    local fresh = e.before == nil and 1 - progress_since(f, e.changed_at, 3) or 0
    local y = LOW_Y + 60 + (i - 1) * row_h
    group({ opacity = k, transform = translate(0, -14 * (1 - k)) }, function()
      if fresh > 0 then rect { x = MARGIN + 14, y = y, w = EVENTS_W - 28, h = row_h - 6, rx = 10, fill = LEVEL[e.level] or BLUE, opacity = 0.14 * fresh } end
      circle { cx = MARGIN + 36, cy = y + 20, r = 6, fill = LEVEL[e.level] or BLUE }
      text { e.at or "", x = MARGIN + 56, y = y + 27, font = MONO, size = 19, fill = DIM }
      text { text_fit { e.text or "", font = SANS, weight = 500, size = 20, max_width = EVENTS_W - 180 }, x = MARGIN + 132, y = y + 27,
        font = SANS, weight = 500, size = 20, fill = INK }
    end)
  end
end

local function throughput(f)
  local x, w = MARGIN + EVENTS_W + 24, W - 2 * MARGIN - EVENTS_W - 24
  rect { x = x, y = LOW_Y, w = w, h = LOW_H, rx = 18, fill = PANEL, stroke = BORDER, stroke_width = 1.5 }
  text { "THROUGHPUT  ·  LAST 30 MIN", x = x + 28, y = LOW_Y + 40, font = SANS, weight = 700, size = 17, letter_spacing = 3, fill = DIM }
  local hist = LINE.history or {}
  if #hist < 2 then return end
  local target = LINE.target_rate or 1
  local top = target * 1.15
  local cx, cy, cw, ch = x + 28, LOW_Y + 64, w - 56, LOW_H - 92
  local function px(i) return cx + (i - 1) / (#hist - 1) * cw end
  local function py(v) return cy + ch - clamp01(v / top) * ch end
  local d = { string.format("M %.1f %.1f", px(1), cy + ch) }
  for i, v in ipairs(hist) do d[#d + 1] = string.format("L %.1f %.1f", px(i), py(v)) end
  d[#d + 1] = string.format("L %.1f %.1f Z", px(#hist), cy + ch)
  path { d = table.concat(d, " "), fill = linear_gradient { x1 = 0, y1 = cy, x2 = 0, y2 = cy + ch,
    stops = { { 0, BLUE }, { 1, "#60a5fa00" } } }, opacity = 0.35 }
  local l = {}
  for i, v in ipairs(hist) do l[#l + 1] = string.format("%s %.1f %.1f", i == 1 and "M" or "L", px(i), py(v)) end
  path { d = table.concat(l, " "), fill = "none", stroke = BLUE, stroke_width = 3, line_join = "round" }
  line { x1 = cx, y1 = py(target), x2 = cx + cw, y2 = py(target), stroke = INK, stroke_width = 1.5, opacity = 0.5, stroke_dasharray = { 8, 8 } }
  text { "target", x = cx + cw, y = py(target) - 8, align = "right", font = SANS, size = 15, fill = DIM }
  circle { cx = px(#hist), cy = py(hist[#hist]), r = 6, fill = BLUE }
end

scene { "Line", duration = 30, render = function(f)
  header(f)
  oee_tile(f)
  good_tile(f)
  rate_tile(f)
  scrap_tile(f)
  belt(f)
  for i, s in ipairs(STATIONS) do station(f, i, s) end
  events(f)
  throughput(f)
end }
