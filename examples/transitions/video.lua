-- Every transition of the standard library (script/std.lua), one after the
-- other: each card enters by the transition it names, over its overlap with
-- the card before, which leaves by the same one. Letters pop with stagger,
-- the corner dial loops once a second.
--
--     onimite render examples/transitions/video.lua -o transitions.mp4

local BG, INK = "#0b0d12", "#f3f1ea"
local DISPLAY, MONO = "Bebas Neue", "JetBrains Mono"
local POP = spring { stiffness = 260, damping = 18 }

-- name, options shown and used, card colour
local CARDS = {
  { "transitions", nil, "#1d2433" },
  { "fade", { "fade", duration = 0.6 }, "#0f766e" },
  { "slide", { "slide", from = "right", duration = 0.6, easing = spring { stiffness = 120, damping = 20 } }, "#7c3aed" },
  { "wipe", { "wipe", from = "left", softness = 240, duration = 0.6, easing = ease_in_out }, "#c2410c" },
  { "clock_wipe", { "clock_wipe", duration = 0.6, easing = cubic_bezier(0.65, 0, 0.35, 1) }, "#0369a1" },
  { "zoom", { "zoom", scale = 1.5, duration = 0.6, easing = ease_in_out }, "#be123c" },
  { "glitch", { "glitch", bands = 14, duration = 0.6 }, "#4d7c0f" },
}

-- The options as Lua, for the caption.
local function describe(tr)
  if not tr then return "scene { ..., transition = { kind, options } }" end
  local parts = { string.format("%q", tr[1]) }
  for _, k in ipairs { "from", "softness", "scale", "bands", "duration" } do
    if tr[k] then parts[#parts + 1] = k .. " = " .. (type(tr[k]) == "string" and string.format("%q", tr[k]) or tr[k]) end
  end
  if tr.easing then parts[#parts + 1] = "easing = ..." end
  return "transition = { " .. table.concat(parts, ", ") .. " }"
end

-- The big word laid out letter by letter once, centred.
local SIZE = 300
local function letters(word)
  word = word:upper()
  local out, x = {}, 0
  local total = text_width { word, font = DISPLAY, size = SIZE }
  for i = 1, #word do
    local ch = word:sub(i, i)
    out[i] = { ch, 960 - total / 2 + text_width { word:sub(1, i - 1), font = DISPLAY, size = SIZE } }
  end
  return out
end

-- A dial in the corner: one turn a second (loop), its hand at g.progress.
local function dial(f)
  loop(f, 1, function(g)
    local a = g.progress * 2 * math.pi
    circle { cx = 1800, cy = 120, r = 44, fill = "none", stroke = INK, stroke_width = 3, stroke_opacity = 0.4 }
    line { x1 = 1800, y1 = 120, x2 = 1800 + 40 * math.sin(a), y2 = 120 - 40 * math.cos(a), stroke = INK,
      stroke_width = 5, line_cap = "round" }
  end)
end

local function card(i, c)
  local word = letters(c[1])
  local caption = describe(c[2])
  local color = c[3]
  return function(f)
    rect { x = 0, y = 0, w = 1920, h = 1080, fill = color }
    -- a grid of dots popping from the centre, staggered by distance
    for row = 0, 5 do
      for col = 0, 11 do
        local d = stagger(col + 1, 0.025, { n = 12, from = "center" }) + stagger(row + 1, 0.025, { n = 6, from = "center" })
        local s = ease(POP, f.seconds - 0.2 - d)
        if s > 0.01 then circle { cx = 150 + col * 147, cy = 200 + row * 136, r = 10 * s, fill = INK, fill_opacity = 0.18 } end
      end
    end
    -- letters pop from the middle out, after the transition settles
    for k, l in ipairs(word) do
      local s = ease(POP, f.seconds - 0.4 - stagger(k, 0.05, { n = #word, from = "center" }))
      group({ opacity = math.min(s * 2, 1), transform = translate(0, (1 - s) * 80) }, function()
        text { l[1], x = l[2], y = 640, font = DISPLAY, size = SIZE, fill = INK }
      end)
    end
    text { string.format("%02d / %02d", i, #CARDS), x = 120, y = 136, font = MONO, size = 34, fill = INK }
    -- the caption slides up once the letters are in
    sequence(f, 0.7, nil, function(g)
      local s = ease(POP, g.seconds)
      text { caption, x = 960, y = 860 + (1 - s) * 40, align = "center", font = MONO, size = 32, fill = INK,
        opacity = math.min(s, 1) }
    end)
    dial(f)
  end
end

video { width = 1920, height = 1080, fps = 60, background = BG }

for i, c in ipairs(CARDS) do
  scene { c[1], duration = i == 1 and 1.5 or 1.75, transition = c[2], render = card(i, c) }
end
