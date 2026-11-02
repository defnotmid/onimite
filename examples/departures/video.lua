-- A departures board: split-flap rows read from flights.json, a clock on the
-- wall clock (f.now), pages that flip, notices from notices.json (a ticker, a
-- gate banner, an alert over everything). On a screen, for good:
--
--     onimite preview examples/departures/video.lua --live
--
-- Replace flights.json (write the new file beside it, then rename it over
-- the old one) and the board takes it at once: track_changes matches each
-- row with the one that was in its place and stamps it with when it changed
-- and what it was `before`, so only the characters that differ flip, from
-- the old ones. notices.json is matched by id: a new notice comes in, one
-- that ends (its `until`) goes, on time. A file that doesn't read keeps the
-- last good board.
--
-- Rendered, it shows the board the file describes at --now:
--
--     onimite render examples/departures/video.lua --now 2026-11-02T13:58:00Z -o board.mp4
--
-- On a portrait screen (most terminals' newer screens), `--set screen=portrait`:
-- 1080x1920, each flight on two lines (gate and remarks under flight and
-- destination), more flights a page.

local PORTRAIT = props.screen == "portrait"
local W, H, FPS = PORTRAIT and 1080 or 1920, PORTRAIT and 1920 or 1080, 60
video { width = W, height = H, fps = FPS, duration = 30, background = "#07080b" }

-- ---- flights.json --------------------------------------------------------------

local BOARD
do
  local fh = assert(io.open(SCRIPT_DIR .. "/flights.json"))
  BOARD = json_decode(fh:read("a"))
  fh:close()
end

-- The board's local time: the wall clock moved by the file's utc_offset
-- ("+01:00"), so the board shows the airport's time whatever the screen's.
local OFFSET = 0
do
  local sign, hh, mm = (BOARD.utc_offset or "+00:00"):match("^([+-])(%d%d):(%d%d)$")
  assert(sign, "flights.json: utc_offset is like +01:00")
  OFFSET = (sign == "-" and -1 or 1) * (tonumber(hh) * 3600 + tonumber(mm) * 60)
end

-- A flight's lines of tiles: each a list of columns { field, width in
-- characters, heading }, a blank between columns (no field: blanks). A slot
-- shows one string, its lines one after another, each `CHARS` long.
local LINES = PORTRAIT and {
  { { "time", 5, "TIME" }, { "flight", 6, "FLIGHT" }, { "to", 14, "DESTINATION" } },
  { { nil, 5 }, { "gate", 6, "GATE" }, { "remarks", 14, "REMARKS" } },
} or {
  { { "time", 5, "TIME" }, { "flight", 6, "FLIGHT" }, { "to", 14, "DESTINATION" }, { "gate", 3, "GATE" }, { "remarks", 13, "REMARKS" } },
}
local CHARS = -1
for _, c in ipairs(LINES[1]) do CHARS = CHARS + c[2] + 1 end

-- Each character's line and column, and whether it is a remark (they take
-- the status's colour).
local CELLS = {}
for l, line in ipairs(LINES) do
  local col = 1
  for _, c in ipairs(line) do
    for k = 0, c[2] - 1 do
      CELLS[(l - 1) * CHARS + col + k] = { line = l, col = col + k, remark = c[1] == "remarks" }
    end
    col = col + c[2] + 1
  end
  for k = 1, CHARS do
    CELLS[(l - 1) * CHARS + k] = CELLS[(l - 1) * CHARS + k] or { line = l, col = k }
  end
end

local BLANK = string.rep(" ", CHARS * #LINES)

local function row_text(r)
  if r == nil then return BLANK end
  local parts = {}
  for _, line in ipairs(LINES) do
    for i, c in ipairs(line) do
      local v = c[1] and tostring(r[c[1]] or ""):upper() or ""
      parts[#parts + 1] = (v .. string.rep(" ", c[2])):sub(1, c[2])
      if i < #line then parts[#parts + 1] = " " end
    end
  end
  return table.concat(parts)
end

-- Remarks colour the row's bar and their own characters.
local INK, DIM, TILE_TOP, TILE_BOTTOM, SPLIT = "#f2f2ee", "#6b7280", "#1b1d23", "#16181d", "#07080b"
local STATUS = {
  { "BOARDING", "#facc15" }, { "FINAL CALL", "#fb923c", blink = true }, { "GO TO GATE", "#a3e635" },
  { "GATE CLOSED", "#f87171" }, { "DELAYED", "#fb923c" }, { "CANCELLED", "#ef4444" },
  { "DEPARTED", DIM }, { "ON TIME", INK },
}
local function status_of(remarks)
  remarks = (remarks or ""):upper()
  for _, s in ipairs(STATUS) do
    if remarks:sub(1, #s[1]) == s[1] then return s end
  end
  return { "", INK }
end

-- The board's measures: tiles (pitch, size), slots and lines, the clock.
local M = PORTRAIT and {
  margin = 50, pitch = 36, cw = 32, ch = 50, size = 36, line_h = 56, row_h = 132, rows_y = 340, per_page = 11,
  clock = { 58, 88, 64 },
} or {
  margin = 76, pitch = 39, cw = 35, ch = 56, size = 40, line_h = 66, row_h = 66, rows_y = 290, per_page = 10,
  clock = { 66, 100, 72 },
}

-- The rows, padded to whole pages: a slot that empties flips to blank too.
local PER_PAGE = M.per_page
local list = BOARD.departures or {}
local PAGES = math.max(1, math.ceil(#list / PER_PAGE))
for i = #list + 1, PAGES * PER_PAGE do list[i] = {} end
-- matched by position: what each slot showed before, and since when it shows this
track_changes("departures", list)

-- What a slot shows now and showed before, as strings, with its status.
local SLOTS = {}
for i, r in ipairs(list) do
  SLOTS[i] = {
    text = row_text(r.time and r or nil),
    before = r.before and row_text(r.before.time and r.before or nil) or BLANK,
    changed_at = r.changed_at,
    status = status_of(r.remarks),
    filled = r.time ~= nil,
    before_status = status_of(r.before and r.before.remarks),
    before_filled = r.before ~= nil and r.before.time ~= nil,
  }
end

-- ---- a split-flap tile -----------------------------------------------------------

local ALPHABET = " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:-."
local FLAP = 0.075 -- seconds a flap takes to fall

-- A tile showing `ch` (its whole face), `w` x `h` at (x, y).
local function face(x, y, w, h, ch, color, size)
  rect { x = x, y = y, w = w, h = h / 2, rx = 5, fill = TILE_TOP }
  rect { x = x, y = y + h / 2, w = w, h = h / 2, rx = 5, fill = TILE_BOTTOM }
  if ch ~= " " then
    text { ch, x = x + w / 2, y = y + h / 2 + size * 0.04, align = "center", baseline = "middle",
      font = "JetBrains Mono", weight = 700, size = size, fill = color }
  end
  rect { x = x, y = y + h / 2 - 1, w = w, h = 2, fill = SPLIT }
end

-- One half of a tile showing `ch`, folded toward the split line by `fold`
-- (1 flat, 0 edge-on), darker as it turns away.
local function half(x, y, w, h, ch, color, size, top, fold)
  local mid = y + h / 2
  group({ transform = scale(1, fold, x, mid), clip = { x = x, y = top and y or mid, w = w, h = h / 2 } }, function()
    face(x, y, w, h, ch, color, size)
    if fold < 1 then rect { x = x, y = y, w = w, h = h, fill = "#000", opacity = 0.55 * (1 - fold) } end
  end)
end

-- A tile turning from `from` (in `from_color`) to `to` through a few other
-- characters, `t` seconds after it began (seed: which ones).
local function tile(x, y, w, h, from, to, t, from_color, to_color, size, seed)
  if from == to and from_color == to_color then
    face(x, y, w, h, to, to_color, size)
    return
  end
  if t < 0 then
    face(x, y, w, h, from, from_color, size)
    return
  end
  local flaps = 2 + math.floor(hash(seed, 3) * 4)
  local step = math.floor(t / FLAP)
  if step >= flaps then
    face(x, y, w, h, to, to_color, size)
    return
  end
  local function char_at(k)
    if k <= 0 then return from, from_color end
    if k >= flaps then return to, to_color end
    local i = 1 + math.floor(hash(seed * 7 + k, 11) * #ALPHABET)
    return ALPHABET:sub(i, i), to_color
  end
  local a, ac = char_at(step)
  local b, bc = char_at(step + 1)
  local p = t / FLAP - step
  half(x, y, w, h, b, bc, size, true, 1)  -- the next top, under the falling flap
  half(x, y, w, h, a, ac, size, false, 1) -- the last bottom, until the flap lands on it
  local c = math.cos(p * math.pi)
  if c > 0 then half(x, y, w, h, a, ac, size, true, c) else half(x, y, w, h, b, bc, size, false, -c) end
end

-- ---- the board ---------------------------------------------------------------------

-- CHARS across: x = MARGIN_X + (col - 1) * PITCH ends within the margin
local MARGIN_X, PITCH, CW, CH = M.margin, M.pitch, M.cw, M.ch
local ROWS_Y, ROW_H = M.rows_y, M.row_h
local ROWS_END = ROWS_Y + (PER_PAGE - 1) * ROW_H + (#LINES - 1) * M.line_h + CH
local PAGE = 12 -- seconds a page shows

-- The board's local seconds since 1970 at frame f.
local function local_time(f) return f.now + OFFSET end

local function header(f)
  text { BOARD.title or "Departures", x = MARGIN_X, y = 118, font = "DM Sans", weight = 700, size = 76, fill = INK }
  text { BOARD.terminal or "", x = MARGIN_X + 4, y = 168, font = "DM Sans", weight = 500, size = 28, fill = DIM }
  -- the clock: HH:MM on big flaps that turn when a digit changes
  local now = local_time(f)
  local minute = math.floor(now / 60)
  local shown, last = os.date("!%H:%M", minute * 60), os.date("!%H:%M", (minute - 1) * 60)
  local since = now - minute * 60
  local cw, ch, gap = M.clock[1], M.clock[2], 8
  local x0 = W - MARGIN_X - 5 * (cw + gap) + gap
  for i = 1, 5 do
    local x = x0 + (i - 1) * (cw + gap)
    tile(x, 52, cw, ch, last:sub(i, i), shown:sub(i, i), since - (i - 1) * 0.05, INK, INK, M.clock[3], 900 + i)
  end
  -- the seconds: a hairline filling under the clock
  local into = since / 60
  rect { x = x0, y = 66 + ch, w = 5 * (cw + gap) - gap, h = 3, rx = 1.5, fill = "#22252c" }
  if into > 0 then rect { x = x0, y = 66 + ch, w = (5 * (cw + gap) - gap) * into, h = 3, rx = 1.5, fill = "#facc15" } end
  local day = os.date("!*t", math.floor(now))
  text { (os.date("!%A ", math.floor(now)) .. day.day .. os.date("! %B", math.floor(now))):upper(), x = W - MARGIN_X, y = 106 + ch, align = "right",
    font = "DM Sans", weight = 500, size = 24, letter_spacing = 3, fill = DIM }
end

-- The headings over the columns, the lines' joined where they start at the
-- same column ("FLIGHT / GATE").
local HEADS = {}
for _, line in ipairs(LINES) do
  local col = 0
  for _, c in ipairs(line) do
    if c[3] then
      local h = HEADS[col]
      HEADS[col] = h and h .. " / " .. c[3] or c[3]
    end
    col = col + c[2] + 1
  end
end

local function column_heads()
  for col, label in pairs(HEADS) do
    text { label, x = MARGIN_X + col * PITCH, y = ROWS_Y - 22, font = "DM Sans", weight = 700, size = 20,
      letter_spacing = 3, fill = DIM }
  end
end

-- Which page shows at `seconds`, the one before it, and how long it has shown.
local function page_at(seconds)
  local n = math.floor(seconds / PAGE)
  return n % PAGES, (n - 1) % PAGES, seconds - n * PAGE, n
end

-- the first remark character: where the status bar changes colour
local REMARKS_FROM
for k, c in ipairs(CELLS) do
  if c.remark and not REMARKS_FROM then REMARKS_FROM = k end
end
local EMPTY = { text = BLANK, status = status_of(nil), filled = false }

local function rows(f)
  local page, prev_page, page_age, n = page_at(f.seconds)
  for s = 1, PER_PAGE do
    local slot = SLOTS[page * PER_PAGE + s]
    local y = ROWS_Y + (s - 1) * ROW_H
    -- what this slot turns from, and since when: the page before (blank
    -- before the first), or the row's own last change if that came later
    local was = n == 0 and EMPTY or SLOTS[prev_page * PER_PAGE + s]
    local from, from_status, from_filled, age = was.text, was.status, was.filled, page_age
    local since = f.now - slot.changed_at
    if since < age then
      from, from_status, from_filled, age = slot.before, slot.before_status, slot.before_filled, since
    end
    local delay = function(i) return age - (CELLS[i].col - 1) * 0.012 - (CELLS[i].line - 1) * 0.05 - (s - 1) * 0.035 end
    -- the status bar: the row's colour once its remarks turn, a final call blinking
    local st, filled = slot.status, slot.filled
    if delay(REMARKS_FROM) < 0 then st, filled = from_status, from_filled end
    if filled and st[1] ~= "ON TIME" and st[1] ~= "" then
      local on = not st.blink or (f.seconds % 1) < 0.6
      rect { x = MARGIN_X - 22, y = y + 6, w = 6, h = (#LINES - 1) * M.line_h + CH - 12, rx = 3, fill = st[2], opacity = on and 1 or 0.25 }
    end
    for i, cell in ipairs(CELLS) do
      tile(MARGIN_X + (cell.col - 1) * PITCH, y + (cell.line - 1) * M.line_h, CW, CH, from:sub(i, i), slot.text:sub(i, i), delay(i),
        cell.remark and from_status[2] or INK, cell.remark and slot.status[2] or INK, M.size, s * 97 + i)
    end
  end
  -- the pages: a dot each, the one showing filling as it shows
  if PAGES > 1 then
    for i = 0, PAGES - 1 do
      local x = W - MARGIN_X - (PAGES - i) * 34 + 14
      circle { cx = x, cy = ROWS_END + 30, r = 6, fill = i == page and INK or "#2a2d35" }
    end
    rect { x = MARGIN_X, y = ROWS_END + 28, w = 220, h = 4, rx = 2, fill = "#22252c" }
    if page_age > 0 then
      rect { x = MARGIN_X, y = ROWS_END + 28, w = 220 * page_age / PAGE, h = 4, rx = 2, fill = DIM }
    end
  end
end

-- ---- notices.json ----------------------------------------------------------------

-- Notices, by level: "info" scrolls in the ticker, a "gate" notice takes the
-- ticker's strip as a banner, an "alert" takes the screen. Each may have
-- `from` and `until` (HH:MM, the board's time) and shows between them, so a
-- notice can be put up ahead and ends on its own. Matched by id: one that is
-- new or edited comes in from its change, one that isn't stays put. No
-- notices.json: no notices.
local NOTICES = {}
do
  local fh = io.open(SCRIPT_DIR .. "/notices.json")
  if fh then
    NOTICES = json_decode(fh:read("a")).notices or {}
    fh:close()
  end
end
track_changes("notices", NOTICES, { key = "id" })

local function day_seconds(hhmm)
  local h, m = hhmm:match("^(%d%d?):(%d%d)$")
  assert(h, "notices.json: from and until are like 14:05, not " .. hhmm)
  return tonumber(h) * 3600 + tonumber(m) * 60
end

-- When notice `n` comes in and goes, around the board's time `t` (the
-- board's seconds since 1970; nil: no end): its change or its `from`,
-- whichever is later, and its `until`.
local function window(n, t)
  local day = math.floor(t / 86400) * 86400
  local from = n.from and day + day_seconds(n.from) or -math.huge
  local to = n["until"] and day + day_seconds(n["until"])
  if to and to <= from then -- past midnight
    if t < to then from = from - 86400 else to = to + 86400 end
  end
  return math.max(from, n.changed_at + OFFSET), to
end

-- The notices of `level` showing at `t`, by when they came in, with how far
-- in they are (0..1, easing in after coming and out before going).
local SLIDE = 0.45
local function showing(level, t)
  local out = {}
  for _, n in ipairs(NOTICES) do
    if (n.level or "info") == level then
      local from, to = window(n, t)
      if t >= from and (not to or t < to) then
        local k = math.min(1, (t - from) / SLIDE, to and (to - t) / SLIDE or 1)
        out[#out + 1] = { n = n, from = from, to = to, k = ease(ease_out, k) }
      end
    end
  end
  table.sort(out, function(a, b) return a.from < b.from end)
  return out
end

local STRIP_Y, STRIP_H = H - 74, 74
local SPEED = 90 -- the ticker's pixels a second

-- The ticker: the info notices, one after another, in the strip down to
-- `bottom`; when what it says changes, it starts again from the right edge.
local function ticker(t, bottom)
  local list = showing("info", t)
  if #list == 0 or bottom <= STRIP_Y then return end
  local parts, since = {}, list[1].from
  for i, s in ipairs(list) do
    parts[i] = s.n.text
    since = math.max(since, s.from)
  end
  -- an info notice that ended changed what it says too
  for _, n in ipairs(NOTICES) do
    local _, to = window(n, t)
    if (n.level or "info") == "info" and to and to <= t then since = math.max(since, to) end
  end
  local msg = table.concat(parts, "      ·      ") .. "      ·      "
  local style = { font = "DM Sans", weight = 500, size = 28, letter_spacing = 1 }
  local width = text_width { msg, font = style.font, weight = style.weight, size = style.size, letter_spacing = style.letter_spacing }
  local x = W - (t - since) * SPEED
  if x < 0 then x = x % width - width end
  group({ clip = { x = 0, y = STRIP_Y, w = W, h = bottom - STRIP_Y } }, function()
    while x < W do
      text { msg, x = x, y = H - 28, font = style.font, weight = style.weight, size = style.size,
        letter_spacing = style.letter_spacing, fill = DIM }
      x = x + width
    end
  end)
end

-- The banner: a gate notice in the ticker's strip, rising in and dropping
-- away; several take turns. Returns its top (the strip's bottom: none).
local GATE, TURN = "#facc15", 6
local function banner(t)
  local list = showing("gate", t)
  if #list == 0 then return STRIP_Y + STRIP_H end
  local s = list[1 + math.floor((t - list[1].from) / TURN) % #list]
  local y = STRIP_Y + STRIP_H * (1 - s.k)
  if y >= STRIP_Y + STRIP_H then return y end
  group({ clip = { x = 0, y = y, w = W, h = STRIP_Y + STRIP_H - y } }, function()
    rect { x = 0, y = y, w = W, h = STRIP_H, fill = GATE }
    local pulse = 0.5 + 0.5 * math.cos((t - s.from) * math.pi * 2 / 1.2)
    circle { cx = MARGIN_X + 12, cy = y + STRIP_H / 2, r = 9 + 3 * pulse, fill = "#0b0b0d" }
    text { "GATE", x = MARGIN_X + 40, y = y + 47, font = "DM Sans", weight = 700, size = 22, letter_spacing = 4, fill = "#0b0b0d" }
    local fitted = text_fit { s.n.text, font = "DM Sans", weight = 700, size = 32, max_width = W - MARGIN_X * 2 - 140 }
    text { fitted, x = MARGIN_X + 140, y = y + 48, font = "DM Sans", weight = 700, size = 32, fill = "#0b0b0d" }
  end)
  return y
end

-- An alert: the board dimmed under it, the message as large as it fits.
local ALERT = "#ef4444"
local function alert(t)
  local list = showing("alert", t)
  if #list == 0 then return end
  local s = list[#list]
  local k = s.k
  rect { x = 0, y = 0, w = W, h = H, fill = "#000", opacity = 0.8 * k }
  local pw, ph = math.min(1400, W - 120), PORTRAIT and 720 or 560
  local lines = text_lines { s.n.text, font = "DM Sans", weight = 700, size = 68, max_width = pw - 200 }
  group({ opacity = k, transform = scale(0.94 + 0.06 * k, 0.94 + 0.06 * k, W / 2, H / 2) }, function()
    rect { x = (W - pw) / 2, y = (H - ph) / 2, w = pw, h = ph, rx = 28, fill = "#140809", stroke = ALERT, stroke_width = 3 }
    local pulse = 0.5 + 0.5 * math.cos((t - s.from) * math.pi * 2 / 1.0)
    circle { cx = (W - pw) / 2 + 100, cy = (H - ph) / 2 + 104, r = 12, fill = ALERT, opacity = 0.4 + 0.6 * pulse }
    text { "ATTENTION", x = (W - pw) / 2 + 130, y = (H - ph) / 2 + 114, font = "DM Sans", weight = 700, size = 28,
      letter_spacing = 6, fill = ALERT }
    local y0 = H / 2 + 40 - (#lines - 1) * 68 * 1.2 / 2
    for i, l in ipairs(lines) do
      text { l, x = (W - pw) / 2 + 100, y = y0 + (i - 1) * 68 * 1.2, font = "DM Sans", weight = 700, size = 68, fill = INK }
    end
  end)
end

scene { "Board", duration = 30, render = function(f)
  local t = local_time(f)
  header(f)
  column_heads()
  rows(f)
  rect { x = 0, y = STRIP_Y, w = W, h = STRIP_H, fill = "#0c0d11" }
  ticker(t, banner(t))
  alert(t)
end }
