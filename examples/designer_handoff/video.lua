-- Designer handoff: a designer's files driven straight into an animated
-- product card, 15 s at 1920x1080. Nothing is redrawn or re-typed by hand:
--
--   * tokens.json (W3C design tokens) is read at load with json_decode:
--     its colours, type styles, spacing, radii, shadow and copy lay out and
--     paint everything, and the Tokens scene lists them as a spec sheet;
--   * media/illustration.svg is drawn on as line art first (its <path> data
--     parsed once per render with shared() + path_data()), then shown as
--     the document itself with svg{}, parts recoloured by id from the tokens;
--   * media/badge.json, a Lottie animation, plays when the button is
--     pressed, its layers recoloured from the tokens.
--
-- Layout is measured, not guessed: the title and tagline wrap with
-- text_lines inside the card's padding, the button fits its label with
-- text_width, and the card's height follows its content.
--
--     onimite render examples/designer_handoff/video.lua -o designer_handoff.mp4

local W, H, FPS = 1920, 1080, 30

-- ---- tokens.json -------------------------------------------------------------

local TOKENS
do
  local fh = assert(io.open(SCRIPT_DIR .. "/tokens.json"))
  TOKENS = json_decode(fh:read("a"))
  fh:close()
end

-- A token's $value by its dotted path ("color.brand").
local function tok(path)
  local v = TOKENS
  for key in path:gmatch("[^.]+") do v = assert(v[key], "tokens.json has no " .. path) end
  return v["$value"]
end

-- A group's tokens as a list of { name, value, description }, sorted by
-- `order(value)` (then by name).
local function tokens_of(group, order)
  local out = {}
  for name, t in pairs(TOKENS[group]) do
    if name:sub(1, 1) ~= "$" then out[#out + 1] = { name = name, value = t["$value"], description = t["$description"] } end
  end
  table.sort(out, function(a, b)
    local x, y = order(a.value), order(b.value)
    if x ~= y then return x < y end
    return a.name < b.name
  end)
  return out
end

local function luminance(hex)
  local r, g, b = tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
end

local C = {}
for _, t in ipairs(tokens_of("color", luminance)) do C[t.name] = t.value end
local S = {}
for _, t in ipairs(tokens_of("space", function(v) return v end)) do S[t.name] = t.value end
local R = {}
for _, t in ipairs(tokens_of("radius", function(v) return v end)) do R[t.name] = t.value end

-- A type style as text fields: font, weight, size, letter spacing.
local function style(name, size)
  local v = tok("font." .. name)
  return { font = v.fontFamily, weight = v.fontWeight, size = size or v.fontSize, letter_spacing = v.letterSpacing }
end
local DISPLAY, BODY, LABEL = style("display"), style("body"), style("label")

-- text{} with a style, a string and extra fields.
local function styled(st, str, fields)
  local t = { str, font = st.font, weight = st.weight, size = st.size, letter_spacing = st.letter_spacing }
  for k, v in pairs(fields) do t[k] = v end
  text(t)
end
local function measure(st, str)
  return text_width { str, font = st.font, weight = st.weight, size = st.size, letter_spacing = st.letter_spacing }
end

-- ---- the illustration's paths, parsed once per render -------------------------

-- Every <path id=".." d=".."> of the SVG in document order (back to front),
-- as path handles for the line-art draw-on.
local LINES = shared("illustration_lines", function()
  local fh = assert(io.open(SCRIPT_DIR .. "/media/illustration.svg"))
  local svg = fh:read("a")
  fh:close()
  local list = {}
  for id, d in svg:gmatch('<path id="([^"]+)" d="([^"]+)"') do list[#list + 1] = { id = id, d = path_data(d) } end
  return list
end)
local ART_W, ART_H = 600, 480 -- the SVG's viewBox

-- ---- the card, laid out from the tokens at load ---------------------------------

local CARD = { w = 720 }
do
  local pad = S.xl
  local inner = CARD.w - 2 * pad
  CARD.pad, CARD.inner = pad, inner
  CARD.well_h = math.floor(inner * ART_H / ART_W)
  CARD.title = text_lines { tok("content.name"), font = DISPLAY.font, weight = DISPLAY.weight, size = DISPLAY.size,
    letter_spacing = DISPLAY.letter_spacing, max_width = inner }
  CARD.tagline = text_lines { tok("content.tagline"), font = BODY.font, weight = BODY.weight, size = BODY.size,
    max_width = inner }
  CARD.title_lead, CARD.body_lead = DISPLAY.size * 1.05, BODY.size * 1.4
  -- the button fits the longer of its two labels, lg padding each side
  CARD.button_w = math.max(measure(BODY, tok("content.cta")), measure(BODY, tok("content.done")) + BODY.size * 1.2)
    + 2 * S.lg
  CARD.button_h = BODY.size + 2 * S.md
  CARD.h = pad + CARD.well_h + S.lg + #CARD.title * CARD.title_lead + S.sm + #CARD.tagline * CARD.body_lead + S.lg
    + CARD.button_h + pad
  CARD.x, CARD.y = (W - CARD.w) / 2, (H - CARD.h) / 2
  -- rows, top to bottom
  CARD.well_y = CARD.y + pad
  CARD.title_y = CARD.well_y + CARD.well_h + S.lg + DISPLAY.size * 0.8
  CARD.tag_y = CARD.title_y + (#CARD.title - 1) * CARD.title_lead + S.sm + BODY.size * 1.15
  CARD.row_y = CARD.y + CARD.h - pad - CARD.button_h
  CARD.button_x = CARD.x + CARD.w - pad - CARD.button_w
end

local SHADOW = tok("shadow.card")
local SNAP = spring { stiffness = 300, damping = 24 }
local SOFT = spring { stiffness = 160, damping = 18 }

-- ---- drawing ---------------------------------------------------------------------

-- The designer's canvas: the canvas colour under a dot grid on the sm step.
local function canvas()
  rect { x = 0, y = 0, w = W, h = H, fill = C.canvas }
  rect { x = 0, y = 0, w = W, h = H, fill = pattern { x = 0, y = 0, w = S.lg, h = S.lg,
    content = function() circle { cx = S.lg / 2, cy = S.lg / 2, r = 1.6, fill = C.muted, opacity = 0.35 } end } }
end

-- The illustration in the well: `draw` 0..1 strokes it on path by path,
-- `fill` 0..1 fades the document in over it; `glow` pulses the ring.
local function art(draw, fill, glow)
  local s = CARD.inner / ART_W
  local x, y = CARD.x + CARD.pad, CARD.well_y
  if draw > 0 and fill < 1 then
    group({ transform = { translate = { x, y }, scale = s }, opacity = 1 - fill }, function()
      for i, l in ipairs(LINES) do
        local p = clamp01(draw * (#LINES + 3) / 4 - (i - 1) / 4)
        if p > 0 then
          path { d = l.d, fill = "none", stroke = C.ink, stroke_width = 3 / s, line_join = "round",
            line_cap = "round", path_length = 1, stroke_dasharray = { 1, 1 }, stroke_dashoffset = 1 - ease(ease_in_out, p, 1) }
        end
      end
    end)
  end
  if fill > 0 then
    svg { src = "illustration.svg", x = x, y = y, w = CARD.inner, h = CARD.well_h, opacity = fill, overrides = {
      ring = { stroke = C.glow, opacity = 0.65 + 0.35 * glow },
      light = { fill = C.glow, opacity = 0.5 + 0.5 * glow },
      spark = { fill = C.accent },
    } }
  end
end

-- The button: `press` 0..1 dips it, `done` 0..1 swaps the label.
local function button(press, done)
  local x, y, w, h = CARD.button_x, CARD.row_y, CARD.button_w, CARD.button_h
  local s = 1 - 0.06 * press
  group({ transform = { scale = s, origin = { x + w / 2, y + h / 2 } } }, function()
    rect { x = x, y = y, w = w, h = h, rx = math.min(R.pill, h / 2), fill = mix_color(C.brand, C.ink, 0.25 * press) }
    if done < 1 then
      styled(BODY, tok("content.cta"), { x = x + w / 2, y = y + h / 2, align = "center", baseline = "middle",
        fill = C.surface, opacity = 1 - done })
    end
    if done > 0 then
      local label = tok("content.done")
      local lw = measure(BODY, label) + BODY.size * 1.2
      local lx = x + (w - lw) / 2
      group({ opacity = done }, function()
        path { d = string.format("M%.1f %.1f l%.1f %.1f l%.1f %.1f", lx + 4, y + h / 2, BODY.size * 0.25, BODY.size * 0.25,
          BODY.size * 0.45, -BODY.size * 0.5), fill = "none", stroke = C.glow, stroke_width = 4, line_cap = "round",
          line_join = "round" }
        styled(BODY, label, { x = lx + BODY.size * 1.2, y = y + h / 2, baseline = "middle", fill = C.surface })
      end)
    end
  end)
end

-- The card; `parts` says how far each part is in (0..1).
local function card(p)
  local c = p.card
  if c <= 0 then return end
  group({ transform = { translate = { 0, (1 - c) * 40 }, scale = 0.96 + 0.04 * c, origin = { W / 2, H / 2 } },
    opacity = clamp01(c * 2) }, function()
    group({ shadow = { dx = SHADOW.offsetX, dy = SHADOW.offsetY, blur = SHADOW.blur, color = SHADOW.color,
      opacity = SHADOW.opacity } }, function()
      rect { x = CARD.x, y = CARD.y, w = CARD.w, h = CARD.h, rx = R.lg, fill = C.surface }
    end)
    rect { x = CARD.x + CARD.pad, y = CARD.well_y, w = CARD.inner, h = CARD.well_h, rx = R.md, fill = C.well }
    art(p.draw, p.fill, p.glow)
    if p.text > 0 then
      local t = p.text
      group({ transform = translate(0, (1 - t) * 24), opacity = clamp01(t * 1.5) }, function()
        for i, line in ipairs(CARD.title) do
          styled(DISPLAY, line, { x = CARD.x + CARD.pad, y = CARD.title_y + (i - 1) * CARD.title_lead, fill = C.ink })
        end
        for i, line in ipairs(CARD.tagline) do
          styled(BODY, line, { x = CARD.x + CARD.pad, y = CARD.tag_y + (i - 1) * CARD.body_lead, fill = C.muted })
        end
        styled(DISPLAY, tok("content.price"), { x = CARD.x + CARD.pad, y = CARD.row_y + CARD.button_h / 2,
          baseline = "middle", size = DISPLAY.size * 0.75, fill = C.ink })
        button(p.press or 0, p.done or 0)
      end)
    end
  end)
end

-- A redline: a dimension between two points with its token's name and value.
local function redline(x1, y1, x2, y2, label, a, below)
  if a <= 0 then return end
  group({ opacity = a }, function()
    line { x1 = x1, y1 = y1, x2 = x2, y2 = y2, stroke = C.accent, stroke_width = 2 }
    local vertical = x1 == x2
    for _, e in ipairs { { x1, y1 }, { x2, y2 } } do
      if vertical then line { x1 = e[1] - 8, y1 = e[2], x2 = e[1] + 8, y2 = e[2], stroke = C.accent, stroke_width = 2 }
      else line { x1 = e[1], y1 = e[2] - 8, x2 = e[1], y2 = e[2] + 8, stroke = C.accent, stroke_width = 2 } end
    end
    local w = measure(LABEL, label) + 20
    local cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
    if vertical then cx = cx + w / 2 + 14 else cy = cy + (below and 26 or -24) end
    rect { x = cx - w / 2, y = cy - 16, w = w, h = 32, rx = R.sm * 0.5, fill = C.accent }
    styled(LABEL, label, { x = cx, y = cy, align = "center", baseline = "middle", fill = C.surface })
  end)
end

local function spec(name) return string.format("space.%s · %d", name, S[name]) end

-- ---- scenes ---------------------------------------------------------------------

-- The three files, each with a live thumbnail of itself.
local FILES = {
  { "illustration.svg", "SVG · vector illustration" },
  { "badge.json", "Lottie · button animation" },
  { "tokens.json", "Design tokens · colour, type, space" },
}
local FILE_W, FILE_H, THUMB_H = 520, 440, 290

local function file_thumb(k, x, y, w, h, f)
  if k == 1 then
    svg { src = "illustration.svg", x = x, y = y, w = w, h = h }
  elseif k == 2 then
    lottie(f, { src = "badge.json", x = x, y = y, w = w, h = h, overrides = {
      Disc = { fill = C.brand }, Burst = { stroke = C.accent }, Ring = { stroke = C.accent } } })
  else
    local list = tokens_of("color", luminance)
    local r = math.min(w / (#list * 2.4), h / 5)
    for i, t in ipairs(list) do
      local cx = x + w / 2 + (i - (#list + 1) / 2) * r * 2.3
      circle { cx = cx, cy = y + h / 2, r = r, fill = t.value, stroke = C.ink, stroke_width = 1.5, stroke_opacity = 0.15 }
    end
  end
end

local function files(f)
  local t = f.seconds
  local hp = ease(SNAP, t - 0.1)
  group({ transform = translate(0, (1 - hp) * 30), opacity = clamp01(hp * 2) }, function()
    styled(DISPLAY, "Designer handoff", { x = W / 2, y = 250, align = "center", size = 104, fill = C.ink })
    styled(BODY, "three files from the designer, straight into a video", { x = W / 2, y = 320, align = "center",
      fill = C.muted })
  end)
  local gap = S.xl
  local x0 = W / 2 - (3 * FILE_W + 2 * gap) / 2
  for k, fl in ipairs(FILES) do
    local p = ease(SOFT, t - 0.45 - stagger(k, 0.15))
    if p > 0 then
      local x, y = x0 + (k - 1) * (FILE_W + gap), 430
      group({ transform = { translate = { 0, (1 - p) * 60 }, rotate = (1 - p) * (k - 2) * 4,
        origin = { x + FILE_W / 2, y + FILE_H } }, opacity = clamp01(p * 2) }, function()
        group({ shadow = { dx = 0, dy = 18, blur = 30, color = SHADOW.color, opacity = SHADOW.opacity } }, function()
          rect { x = x, y = y, w = FILE_W, h = FILE_H, rx = R.md, fill = C.surface }
        end)
        rect { x = x + S.md, y = y + S.md, w = FILE_W - 2 * S.md, h = THUMB_H, rx = R.sm, fill = C.well }
        file_thumb(k, x + S.md + S.sm, y + S.md + S.sm, FILE_W - 2 * S.md - 2 * S.sm, THUMB_H - 2 * S.sm, f)
        styled(LABEL, fl[1], { x = x + S.md, y = y + THUMB_H + 76, size = 30, fill = C.ink })
        styled(BODY, fl[2], { x = x + S.md, y = y + THUMB_H + 118, size = 26, fill = C.muted })
      end)
    end
  end
end

-- The tokens as a spec sheet: colours, type, spacing and radii, in the
-- order and with the values tokens.json gives.
local function sheet(f)
  local t = f.seconds
  local function pop(i) return ease(SNAP, t - 0.2 - i * 0.06) end
  styled(LABEL, "tokens.json", { x = 160, y = 210, size = 28, fill = C.accent, opacity = clamp01(t * 3) })
  -- colours, dark to light
  styled(DISPLAY, "Colour", { x = 160, y = 290, size = 48, fill = C.ink, opacity = clamp01(t * 3) })
  for i, c in ipairs(tokens_of("color", luminance)) do
    local p = pop(i)
    if p > 0 then
      local col, row = (i - 1) % 2, (i - 1) // 2
      local x, y = 160 + col * 300, 360 + row * 150
      group({ transform = { scale = 0.8 + 0.2 * p, origin = { x + 40, y + 40 } }, opacity = clamp01(p * 2) }, function()
        rect { x = x, y = y, w = 80, h = 80, rx = R.sm, fill = c.value, stroke = C.ink, stroke_width = 1.5,
          stroke_opacity = 0.12 }
        styled(BODY, c.name, { x = x + 100, y = y + 34, size = 28, fill = C.ink })
        styled(LABEL, c.value, { x = x + 100, y = y + 68, fill = C.muted })
      end)
    end
  end
  -- type, each style in itself
  styled(DISPLAY, "Type", { x = 820, y = 290, size = 48, fill = C.ink, opacity = clamp01((t - 0.3) * 3) })
  for i, name in ipairs { "display", "body", "label" } do
    local p = pop(8 + i)
    if p > 0 then
      local st, y = style(name), 360 + (i - 1) * 150
      group({ transform = translate((1 - p) * 40, 0), opacity = clamp01(p * 2) }, function()
        styled(st, st.font, { x = 820, y = y + st.size * 0.8, fill = C.ink })
        styled(LABEL, string.format("font.%s · %d / %d", name, st.size, st.weight), { x = 820, y = y + st.size + 40,
          fill = C.muted })
      end)
    end
  end
  -- spacing as bars, radii as corners
  styled(DISPLAY, "Space", { x = 1400, y = 290, size = 48, fill = C.ink, opacity = clamp01((t - 0.6) * 3) })
  for i, sp in ipairs(tokens_of("space", function(v) return v end)) do
    local p = pop(12 + i)
    if p > 0 then
      local y = 350 + (i - 1) * 58
      rect { x = 1400, y = y, w = math.max(sp.value * 5 * p, 1), h = 28, rx = 6, fill = C.brand, opacity = 0.85 }
      styled(LABEL, string.format("%s · %d", sp.name, sp.value), { x = 1400 + sp.value * 5 + 16, y = y + 22,
        fill = C.muted, opacity = clamp01(p * 2) })
    end
  end
  styled(DISPLAY, "Radius", { x = 1400, y = 700, size = 48, fill = C.ink, opacity = clamp01((t - 0.9) * 3) })
  for i, r in ipairs(tokens_of("radius", function(v) return v end)) do
    local p = pop(18 + i)
    if p > 0 then
      local x = 1400 + (i - 1) * 100
      rect { x = x, y = 750, w = 76, h = 76, rx = math.min(r.value, 38), fill = "none", stroke = C.accent,
        stroke_width = 4, opacity = clamp01(p * 2) }
      styled(LABEL, r.name, { x = x + 38, y = 860, align = "center", fill = C.muted, opacity = clamp01(p * 2) })
    end
  end
end

-- The card assembling from the tokens, with the designer's redlines.
local function build(f)
  local t = f.seconds
  card { card = ease(SOFT, t - 0.2), draw = clamp01((t - 0.5) / 1.8), fill = ease(ease_in_out, t - 2.0, 0.6),
    glow = 0.5 + 0.5 * math.sin(t * 4), text = ease(SNAP, t - 2.3) }
  local a = clamp01((t - 2.9) * 3) * (1 - clamp01((t - 4.1) * 3))
  local x0, y0 = CARD.x, CARD.y
  redline(x0, y0 + CARD.h * 0.3, x0 + CARD.pad, y0 + CARD.h * 0.3, spec("xl"), a)
  redline(x0 + CARD.w - 120, y0, x0 + CARD.w - 120, CARD.well_y, spec("xl"), a)
  redline(x0 + CARD.w - 120, CARD.well_y + CARD.well_h, x0 + CARD.w - 120, CARD.well_y + CARD.well_h + S.lg, spec("lg"),
    clamp01(a * 1.5 - 0.2))
  redline(CARD.button_x, CARD.row_y + CARD.button_h + 14, CARD.button_x + S.lg, CARD.row_y + CARD.button_h + 14, spec("lg"),
    clamp01(a * 1.5 - 0.4), true)
end

-- The card done: a cursor clicks the button, the Lottie badge bursts.
local CLICK = 1.1
local function ship(f)
  local t = f.seconds
  local press = math.exp(-((t - CLICK) / 0.08) ^ 2)
  local done = ease(ease_out, t - CLICK - 0.1, 0.3)
  card { card = 1, draw = 1, fill = 1, glow = 0.5 + 0.5 * math.sin((t + 5) * 4), text = 1, press = press, done = done }
  -- the badge over the well's top right corner
  if t >= CLICK then
    local s = 260
    lottie { src = "badge.json", x = CARD.x + CARD.w - s * 0.62, y = CARD.y - s * 0.38, w = s, h = s, time = t - CLICK,
      loop = false, overrides = { Disc = { fill = C.brand }, Burst = { stroke = C.accent }, Ring = { stroke = C.accent } } }
  end
  -- the cursor glides in, clicks, and leaves
  local bx, by = CARD.button_x + CARD.button_w * 0.6, CARD.row_y + CARD.button_h * 0.6
  local into = ease(ease_in_out, t - 0.2, CLICK - 0.25)
  local away = ease(easing.cubic_in, t - CLICK - 0.6, 0.6)
  local cx = lerp(lerp(W + 40, bx, into), W + 80, away)
  local cy = lerp(lerp(H - 60, by, into), H + 80, away)
  group({ transform = { translate = { cx, cy }, scale = 1 - 0.15 * press },
    shadow = { dx = 0, dy = 4, blur = 6, color = "#000000", opacity = 0.3 } }, function()
    path { d = "M0 0 L0 34 L9 26 L15 40 L21 37 L15 24 L27 24 Z", fill = C.ink, stroke = C.surface, stroke_width = 2.5,
      line_join = "round" }
  end)
  -- what went in, along the bottom
  local tp = ease(SNAP, t - 2.0)
  if tp > 0 then
    group({ opacity = clamp01(tp * 2), transform = translate(0, (1 - tp) * 20) }, function()
      styled(LABEL, "illustration.svg  +  badge.json  +  tokens.json  →  MP4", { x = W / 2, y = H - 28,
        align = "center", size = 24, fill = C.muted })
    end)
  end
end

-- ---- video -----------------------------------------------------------------------

local FADE = { "fade", duration = 0.5, easing = ease_in_out }

video { width = W, height = H, fps = FPS, background = C.canvas,
  render = function(f)
    canvas()
    render_scenes(f)
    local out = progress(f.global_seconds, 14.5, 15)
    if out > 0 then rect { x = 0, y = 0, w = W, h = H, fill = C.canvas, opacity = out } end
  end,
}

scene { "Files", duration = 3, render = files }
scene { "Tokens", duration = 4, transition = FADE, render = sheet }
scene { "Build", duration = 4.5, transition = FADE, render = build }
scene { "Ship", duration = 3.5, render = ship }
