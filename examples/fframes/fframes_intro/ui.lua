-- Palette, type and the small pieces of HUD every scene shares (ui.rs).

local beat = require("beat")
local snap, prog = beat.snap, beat.prog

local M = {}

M.BG = "#0b0b0b"
M.BONE = "#ece8e1"
M.ORANGE = "#fb6a22"
M.EMBER = "#8a3712"
M.GREY = "#76726c"
M.DIM = "#2b2926"
M.PAPER = "#e8e4db"
M.INK = "#121110"

M.DISPLAY = "Archivo Black"
M.COND = "Anton"
M.MONO = "IBM Plex Mono"
M.SERIF = "Instrument Serif"

local MONO, EMBER, ORANGE = M.MONO, M.EMBER, M.ORANGE

-- Crop-mark corners around a rectangle.
function M.corners(x, y, w, h, arm, color, width)
  local x1, x2, x3 = x + arm, x + w - arm, x + w
  local y1, y2, y3 = y + arm, y + h - arm, y + h
  path { d = string.format("M%s %s V%s H%s M%s %s H%s V%s M%s %s V%s H%s M%s %s H%s V%s",
      x, y1, y, x1, x2, y, x3, y1, x3, y2, y3, x2, x1, y3, x, y2),
    fill = "none", stroke = color, stroke_width = width }
end

-- A small mono label, uppercase tracking like engineering drawings.
function M.label(x, y, s, color, size, anchor)
  if s == "" then return end
  text { s, x = x, y = y, font = MONO, weight = 500, size = size, letter_spacing = 2.5, fill = color,
    align = anchor or "start" }
end

-- An annotation: a dot on the target, an elbow line and a label.
function M.callout(tx, ty, lx, ly, s, color, progress)
  if progress <= 0 then return end
  local p = math.min(math.max(progress, 0), 1)
  local mx, my = lx, ty
  -- draw-on: first leg then second
  local l1 = math.abs(mx - tx) + 0.01
  local l2 = math.abs(ly - my) + 0.01
  local total = l1 + l2
  local drawn = total * p
  local anchor = lx >= tx and "start" or "end"
  local text_x = lx >= tx and lx + 10 or lx - 10
  local text_opacity = math.min(math.max((p - 0.6) / 0.4, 0), 1)
  circle { cx = tx, cy = ty, r = 5, fill = color, opacity = math.min(p, 1) }
  circle { cx = tx, cy = ty, r = 12, fill = "none", stroke = color, stroke_width = 1.5, opacity = p * 0.6 }
  path { d = string.format("M%s %s H%s V%s", tx, ty, mx, ly), fill = "none", stroke = color, stroke_width = 1.5,
    stroke_dasharray = { drawn, total } }
  text { s, x = text_x, y = ly + 6, font = MONO, weight = 500, size = 20, letter_spacing = 2, fill = color,
    align = anchor, opacity = text_opacity }
end

-- Timecode `00:mm:ss:ff` at 60 fps.
function M.timecode(seconds)
  local total = beat.usize(math.max(seconds * 60, 0))
  local ff = total % 60
  local s = (total // 60) % 60
  local m = total // 3600
  return string.format("00:%02d:%02d:%02d", m, s, ff)
end

function M.thousands(n)
  local s = string.format("%d", n)
  local out = {}
  for i = 1, #s do
    if i > 1 and (#s - i + 1) % 3 == 0 then out[#out + 1] = "," end
    out[#out + 1] = s:sub(i, i)
  end
  return table.concat(out)
end

-- The characters of `s` with each one's left edge (the width of the text
-- before it, plus `tracking` per character) and width, for `letters`.
-- Measured when the script loads.
function M.strip(s, family, size, weight, tracking)
  local st = { family = family, size = size, weight = weight }
  local i = 0
  for pos, c in utf8.codes(s) do
    local ch = utf8.char(c)
    st[#st + 1] = { ch = ch, x = text_width { s:sub(1, pos - 1), font = family, size = size, weight = weight } + tracking * i,
      w = text_width { ch, font = family, size = size, weight = weight } }
    i = i + 1
  end
  return st
end

-- A strip of text (`M.strip`) drawn letter by letter with per-letter
-- offsets: `fn(i) -> dx, dy, opacity, scale` for every character (i from 0).
function M.letters(x, y, st, fill, fn)
  local family, size, weight = st.family, st.size, st.weight
  for i, c in ipairs(st) do
    local dx, dy, o, sc = fn(i - 1)
    if o > 0.001 then
      local cw = c.w
      local cx = x + c.x + cw / 2
      group({ transform = string.format("translate(%s %s) scale(%s) translate(%s 0)",
          cx + dx, y + dy, math.max(sc, 0.001), -cw / 2) }, function()
        text { c.ch, font = family, weight = weight, size = size, fill = fill, opacity = o }
      end)
    end
  end
end

-- A word that slams in with a spring from (dx, dy) and leaves a motion trail
-- of ember copies behind it while it moves (the fframes brand motif).
local Slam = {}
Slam.__index = Slam

function M.Slam(x, y, s, family, size, fill)
  return setmetatable({ x = x, y = y, text = s, family = family, size = size, fill = fill,
    spacing = -size * 0.035, anchor = "start", italic = false }, Slam)
end

function Slam:with_anchor(anchor) self.anchor = anchor return self end
function Slam:with_italic() self.italic = true self.spacing = 0 return self end

local TRAIL = { { 0.16, EMBER, 0.35 }, { 0.10, "#c4531c", 0.5 }, { 0.05, ORANGE, 0.65 } }

-- `since` is beats since the entrance started.
function Slam:draw(since, dx, dy)
  if since < 0 then return end
  local function off(t)
    local s = snap(math.max(t, 0))
    return (1 - s) * dx, (1 - s) * dy
  end
  local function layer(ox, oy, fill, opacity)
    text { self.text, x = self.x + ox, y = self.y + oy, align = self.anchor, font = self.family,
      italic = self.italic, size = self.size, letter_spacing = self.spacing, fill = fill, opacity = opacity }
  end
  for _, tr in ipairs(TRAIL) do
    local lag, color, o = tr[1], tr[2], tr[3]
    local ox, oy = off(since - lag)
    local cx, cy = off(since)
    local moving = math.sqrt((ox - cx) ^ 2 + (oy - cy) ^ 2)
    if moving > 2 and since > lag * 0.5 then
      layer(ox, oy, color, o * math.min(moving / 40, 1))
    end
  end
  local ox, oy = off(since)
  layer(ox, oy, self.fill, prog(since, 0, 0.06))
end

-- A rounded rectangle as path data (SVG <rect rx> geometry, rx clamped to
-- half the sides), for clip paths.
function M.rounded_rect(x, y, w, h, r)
  r = math.min(r, w / 2, h / 2)
  if r <= 0 then
    return string.format("M%s %s H%s V%s H%s Z", x, y, x + w, y + h, x)
  end
  return string.format("M%s %s H%s A%s %s 0 0 1 %s %s V%s A%s %s 0 0 1 %s %s H%s A%s %s 0 0 1 %s %s V%s A%s %s 0 0 1 %s %s Z",
    x + r, y, x + w - r, r, r, x + w, y + r, y + h - r, r, r, x + w - r, y + h,
    x + r, r, r, x, y + h - r, y + r, r, r, x + r, y)
end

return M
