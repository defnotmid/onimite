-- Since 2021: the first commit, five years of history scrolling past, and
-- the numbers behind it.

local beat = require("beat")
local ui = require("ui")
local facts = require("facts")
local prog, expo_out, expo_in, quart_out, cubic_in_out, snap, usize, round =
  beat.prog, beat.expo_out, beat.expo_in, beat.quart_out, beat.cubic_in_out, beat.snap, beat.usize, beat.round
local ORANGE, BONE, GREY, MONO, DISPLAY, SERIF = ui.ORANGE, ui.BONE, ui.GREY, ui.MONO, ui.DISPLAY, ui.SERIF
local callout, letters, thousands, Slam = ui.callout, ui.letters, ui.thousands, ui.Slam

-- `git log` of the fframes repository, read when the script loads (the
-- original's build.rs runs the same command when the video is built). The
-- repository is third_party/fframes of onimite; without git the scene has
-- no commits, as in the original.
local function read_commits()
  local commits = {}
  local repo = SCRIPT_DIR .. "/../../../third_party/fframes"
  local p = io.popen("git -C '" .. repo .. "' log --reverse '--format=%h|%ad|%s' --date=short 2>/dev/null")
  if not p then return commits end
  for line in p:lines() do
    local hash, date, message = line:match("^([^|]*)|([^|]*)|(.*)$")
    if hash then commits[#commits + 1] = { hash = hash, date = date, message = message } end
  end
  p:close()
  return commits
end
local COMMITS = read_commits()

-- Days since 1970-01-01 of a `YYYY-MM-DD` date (Howard Hinnant's algorithm).
local function day_number(date)
  local y, m, d = date:match("^(%d+)-(%d+)-(%d+)")
  y, m, d = tonumber(y) or 1970, tonumber(m) or 1, tonumber(d) or 1
  if m <= 2 then y = y - 1 end
  local era = y // 400
  local yoe = y - era * 400
  local doy = (153 * (m + (m > 2 and -3 or 9)) + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  return era * 146097 + doe - 719468
end

local MONTHS = { "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC" }
-- `2021-09-19` as `SEP 2021`.
local function month_label(date)
  local month = tonumber(date:sub(6, 7)) or 1
  return MONTHS[math.min(math.max(month, 1), 12)] .. " " .. date:sub(1, 4)
end

-- Numbers derived from the history: commit count and the span from the
-- first commit to the latest one.
local HISTORY = (function()
  local first = COMMITS[1] and COMMITS[1].date or "2021-09-19"
  local last = COMMITS[#COMMITS] and COMMITS[#COMMITS].date or first
  return { count = #COMMITS, days = day_number(last) - day_number(first),
    since = month_label(first), ["until"] = month_label(last) }
end)()

-- Commit messages as the history shows them: ASCII only, 48 characters.
for _, c in ipairs(COMMITS) do c.short = c.message:gsub("[\128-\255]", ""):sub(1, 48) end

-- Engineering-drawing title block, bottom right.
local function title_block(date, o)
  if o <= 0 then return end
  local function t(s, x, y, fill)
    text { s, x = x, y = y, font = MONO, size = 18, letter_spacing = 1.5, fill = fill or BONE }
  end
  group({ opacity = o }, function()
    rect { x = 1290, y = 800, w = 470, h = 150, fill = "#0b0b0b", fill_opacity = 0.7, stroke = GREY, stroke_width = 1.5 }
    path { d = "M1290 850 H1760 M1290 900 H1760 M1400 800 V950 M1600 850 V950", fill = "none", stroke = GREY, stroke_width = 1.5 }
    t("TITLE", 1306, 832, GREY)
    t("FFRAMES — PROOF OF CONCEPT", 1416, 832)
    t("DRAWN", 1306, 882, GREY)
    t("dmtrKovalenko", 1416, 882)
    t("REV 1", 1616, 882, GREY)
    t("SHEET", 1306, 932, GREY)
    t("1 OF " .. HISTORY.count, 1416, 932)
    t(date, 1616, 932, ORANGE)
  end)
end

local COMMAND = "$ git log --reverse | head -1"
local HASH_W = 7 * 36 * 0.6
-- The first commit's year, laid out letter by letter.
local FIRST_YEAR = COMMITS[1] and ui.strip(COMMITS[1].date:sub(1, 4), DISPLAY, 440, 400, -8)

-- Beats 0-8: the year of the first commit, one digit per beat, then the
-- commit itself.
local function first_commit(lb)
  local first = COMMITS[1]
  if not first then return end
  local exit = expo_in(prog(lb, 7.6, 8))
  local typed = usize((lb / 0.8) * #COMMAND)
  local command = COMMAND:sub(1, math.min(typed, #COMMAND))
  local underline = quart_out(prog(lb, 3, 4)) * 1120
  local meta = prog(lb, 4, 4.4)
  group({ opacity = 1 - exit, transform = translate(0, -exit * 120) }, function()
    if command ~= "" then
      text { command, x = 160, y = 220, font = MONO, weight = 500, size = 30, fill = GREY }
    end
    letters(150, 690, FIRST_YEAR, BONE, function(i)
      local s = snap(lb - i)
      return 0, (1 - s) * 160, prog(lb, i, i + 0.15), 0.85 + 0.15 * s
    end)
    rect { x = 160, y = 740, w = math.max(underline, 0.5), h = 10, fill = ORANGE }
    group({ opacity = meta }, function()
      text { first.hash, x = 160, y = 826, font = MONO, weight = 600, size = 36, fill = ORANGE }
      text { first.date .. "   Dmitriy Kovalenko", x = 160 + HASH_W + 30, y = 826, font = MONO, weight = 500,
        size = 36, fill = BONE }
      text { "“" .. first.message .. "”", x = 1030, y = 832, font = SERIF, italic = true, size = 64, fill = ORANGE }
    end)
    callout(160 + HASH_W / 2, 842, 160 + HASH_W / 2, 980, "FIRST COMMIT", ORANGE, prog(lb, 5, 5.8))
    callout(1270, 520, 1420, 360, (HISTORY.days // 365) .. " YEARS AGO", BONE, prog(lb, 5.5, 6.3))
    title_block(first.date, prog(lb, 6, 6.4))
  end)
end

-- Beats 8-16: every commit scrolls past, accelerating, the year flips.
local function history(lb)
  local n = #COMMITS
  if n == 0 then return end
  local enter = expo_out(prog(lb, 0, 0.5))
  local exit = expo_in(prog(lb, 7.6, 8))
  -- position in the list (float), ease in-out across the 8 beats
  local pos = cubic_in_out(prog(lb, 0.3, 7.4)) * (n - 1)
  local current = round(pos)
  local line_h, center_y = 44, 560
  local first = math.floor(pos) - 11
  local c = COMMITS[math.min(current, n - 1) + 1]
  group({ opacity = enter * (1 - exit), transform = translate(0, (1 - enter) * 80 - exit * 80) }, function()
    rect { x = 140, y = center_y - 34, w = 1060, h = 48, fill = ORANGE, fill_opacity = 0.12 }
    rect { x = 140, y = center_y - 34, w = 4, h = 48, fill = ORANGE }
    for i = math.max(first, 0), math.min(first + 23, n - 1) do
      local row = COMMITS[i + 1]
      local y = center_y + (i - pos) * line_h
      local dist = math.abs((y - center_y) / 480)
      local o = math.min(math.max(1 - dist, 0), 1) ^ 1.5
      local is_current = i == current
      group({ opacity = o }, function()
        text { row.hash, x = 160, y = y, font = MONO, weight = 600, size = 26, fill = is_current and ORANGE or "#6d4a36" }
        text { row.date, x = 310, y = y, font = MONO, weight = 500, size = 26, fill = GREY }
        if row.short ~= "" then
          text { row.short, x = 510, y = y, font = MONO, weight = 500, size = 26, fill = is_current and BONE or "#8f8a82" }
        end
      end)
    end
    text { c.date:sub(1, 4), x = 1770, y = 600, align = "end", font = DISPLAY, size = 300, letter_spacing = -10, fill = ORANGE }
    text { string.format("#%03d / %d", current + 1, n), x = 1770, y = 680, align = "end", font = MONO, weight = 500,
      size = 36, fill = BONE }
    text { c.date, x = 1770, y = 730, align = "end", font = MONO, weight = 500, size = 26, fill = GREY }
  end)
end

-- (value, unit, caption); values count up as they enter
local ITEMS = {
  { HISTORY.days // 365, "YEARS", HISTORY.since .. " → " .. HISTORY["until"] .. "  ·  " .. thousands(HISTORY.days) .. " DAYS" },
  { HISTORY.count, "COMMITS", "FROM THE FIRST “POC” TO TODAY" },
  { facts.LINES_OF_RUST, "LINES OF RUST", "FFMPEG · SVG · SKIA · EDITOR · CLI" },
}
-- The final number's and the unit's widths (with their letter spacing).
for _, item in ipairs(ITEMS) do
  item.num_w = text_width { thousands(item[1]), font = DISPLAY, size = 400, letter_spacing = -10 }
  item.unit_w = text_width { item[2], font = DISPLAY, size = 110, letter_spacing = -3 }
end

-- Beats 16-32: the numbers, one per bar, then "video = f(frame)".
local function stats(lb)
  local bar = usize(math.floor(lb / 4))
  local l = lb - bar * 4
  if bar < 3 then
    local item = ITEMS[bar + 1]
    local value, unit, caption = item[1], item[2], item[3]
    local enter = expo_out(prog(l, 0, 0.7))
    local exit = expo_in(prog(l, 3.65, 4))
    local x = 150 + (1 - enter) * 260 - exit * 300
    local num_w = item.num_w
    local unit_s = snap(l - 0.5)
    local unit_w = item.unit_w
    -- the unit goes next to the number when it fits, below it otherwise
    local ux, uy, cap_y
    if 150 + num_w + 40 + unit_w < 1770 then ux, uy, cap_y = num_w + 40, 0, 0 else ux, uy, cap_y = 8, 130, 130 end
    local cap = prog(l, 1, 1.4)
    local shown = thousands(round(value * expo_out(prog(l, 0, 1.3))))
    group({ opacity = 1 - exit }, function()
      group({ transform = translate(x, 0) }, function()
        text { shown, x = 0, y = 640, font = DISPLAY, size = 400, letter_spacing = -10, fill = BONE }
        group({ transform = translate(ux, uy + (1 - unit_s) * 60), opacity = math.min(unit_s, 1) }, function()
          text { unit, x = 0, y = 640, font = DISPLAY, size = 110, letter_spacing = -3, fill = ORANGE }
        end)
        rect { x = 4, y = 700 + cap_y, w = math.max(cap * 60, 0.5), h = 4, fill = ORANGE }
        text { caption, x = 4, y = 760 + cap_y, font = MONO, weight = 500, size = 30, letter_spacing = 3, fill = BONE,
          opacity = cap }
      end)
    end)
    return
  end
  -- bar 4: ONE IDEA, then video = f(frame)
  local a = snap(l)
  local exit = expo_in(prog(l, 3.7, 4))
  group({ opacity = 1 - exit }, function()
    text { "ONE IDEA", x = 160, y = 330, font = MONO, weight = 600, size = 34, letter_spacing = 6, fill = ORANGE,
      opacity = math.min(a, 1) }
    Slam(150, 620, "video =", DISPLAY, 190, BONE):draw(l - 1, 0, 150)
    Slam(905, 628, "f(frame)", SERIF, 270, ORANGE):with_italic():draw(l - 2, 260, 0)
  end)
end

local function render(f, lb)
  local well_x = 0.7 - prog(lb, 0, 32) * 0.25
  shader(f, { src = "shaders/contour.sksl", x = 0, y = 0, w = 1920, h = 1080, uniforms = {
    uWell = { well_x, 0.58 }, uDepth = 0.8, uDensity = 18, uBright = 0.42, uInk = "#8a857c", uHot = ORANGE } })
  if lb < 8 then
    first_commit(lb)
  elseif lb < 16 then
    history(lb - 8)
  else
    stats(lb - 16)
  end
end

return { name = "OriginScene", start = 0, stop = 32, render = render }
