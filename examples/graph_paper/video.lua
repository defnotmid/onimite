-- Graph paper: the seven letters of "onimite" and the seven marks of its
-- libraries on a drafting sheet. A pen plots their outlines, each letter
-- morphs into its mark as the two rows pass through each other, they lift
-- off the page as solids and spin through one another in two interlocking
-- rings, then fall back and fill the sheet, piling up by their outlines.
--
-- Every shape is one outline (outline{}): drawn as ink (path{}), morphed
-- (morph), extruded (ExtrudeGeometry) and collided (physics bodies'
-- `outline`). The soundtrack is an odawg song (track.lua) the picture
-- reads its timing from: the scenes are its sections, the pen starts on its
-- notes, the burst lands on its impact; the shapes' landings tick.
--
--     onimite preview examples/graph_paper/video.lua
--     onimite render examples/graph_paper/video.lua -o graph_paper.mp4

local W, H = 1080, 1350
local CELL = 27                                   -- a grid cell; every 5th line is major
local PAPER, INK, RED = "#f3eee4", "#1c1b1f", "#e4472d"
local GRID_MINOR, GRID_MAJOR = "#c9d8de", "#9fb9c4"

local score = require("track")
local T = score.time
-- A section's length and where things happen in it, in its scene's seconds.
local function span(name)
  for _, sec in ipairs(score.sections) do
    if sec.name == name then return sec.stop - sec.start end
  end
end
local function local_hits(part, scene) local out = {}
  for i, h in ipairs(score.hits { part = part }) do out[i] = h - T(scene) end
  return out
end

video { width = W, height = H, fps = 60, background = PAPER,
  buses = { music = {}, sfx = {} }, audio = { { "score", bus = "music" } },
  master_gain_db = 7.7 }   -- about -14 LUFS, true peak under -1 dBTP

local WORD = "ONIMITE"
local MARKS = { "onimite", "ovg", "oksl", "odecs", "ottis", "o3d", "odawg" }
local N = #MARKS
local PITCH = CELL * 5                            -- letters sit on the major lines
local function column(i) return W / 2 + (i - (N + 1) / 2) * PITCH end
local TOP, BOTTOM = 470, 880                      -- the two rows

-- The shapes, about (0, 0): in pixels for the page, in units for 3D.
local function letter(i, size) return outline { WORD:sub(i, i), font = "Bebas Neue", size = size, align = "center", baseline = "middle" } end
local function mark(i, w) return outline { svg = MARKS[i] .. ".svg", id = "silhouette", x = -w / 2, y = -w / 2, w = w } end
local LETTER, MARK, LETTER3, MARK3, MORPH = {}, {}, {}, {}, {}
for i = 1, N do
  LETTER[i], MARK[i] = letter(i, 250), mark(i, 150)
  LETTER3[i], MARK3[i] = letter(i, 2.5), mark(i, 1.5)   -- the page sizes at 100 px a unit
  MORPH[i] = morph(LETTER[i], MARK[i])
end

-- The sheet: minor and major rules as two paths, built once.
local RULES = shared("rules", function()
  local minor, major = {}, {}
  for k = 0, math.ceil(W / CELL) do
    local list = k % 5 == 0 and major or minor
    list[#list + 1] = string.format("M%d 0V%d", k * CELL, H)
  end
  for k = 0, math.ceil(H / CELL) do
    local list = k % 5 == 0 and major or minor
    list[#list + 1] = string.format("M0 %dH%d", k * CELL, W)
  end
  return { minor = path_data(table.concat(minor)), major = path_data(table.concat(major)) }
end)

local function sheet(reveal)
  path { d = RULES.minor, stroke = GRID_MINOR, stroke_width = 1, opacity = reveal }
  path { d = RULES.major, stroke = GRID_MAJOR, stroke_width = 1.5, opacity = reveal }
end

local function at(x, y, angle, s, draw)
  group({ transform = { translate = { x, y }, rotate = angle or 0, scale = s or 1 } }, draw)
end

local MONO = { font = "JetBrains Mono", size = 17, fill = INK }
local function label(str, x, y, opacity)
  text { str, x = x, y = y, font = MONO.font, size = MONO.size, fill = MONO.fill, align = "center", opacity = opacity }
end

-- 1. Plot: the rules fade up, then a pen draws each outline in turn, letters
-- above, marks below, with their coordinates noted under them.
local PEN_L, PEN_M = local_hits("pen", "plot"), local_hits("ink", "plot")
scene { "Plot", duration = span("plot"), render = function(f)
  local t = f.seconds
  sheet(clamp(t / 0.8, 0, 1))
  for i = 1, N do
    -- the pen starts each outline on its note: a bell for a letter, a pluck for a mark
    local p = ease(ease_in_out, clamp((t - PEN_L[i]) / 1.6, 0, 1))
    local q = ease(ease_in_out, clamp((t - PEN_M[i]) / 1.6, 0, 1))
    -- the ink fills in and the pen line goes into it (Morph draws fills only)
    local fill = ease(ease_out, clamp((t - 3.2 - stagger(i, 0.06)) / 0.8, 0, 1))
    at(column(i), TOP, 0, 1, function()
      path { d = LETTER[i], fill = INK, fill_opacity = fill, stroke = INK, stroke_width = 2, stroke_opacity = 1 - fill,
        path_length = 1, stroke_dasharray = { 1, 1 }, stroke_dashoffset = 1 - p }
    end)
    at(column(i), BOTTOM, 0, 1, function()
      path { d = MARK[i], fill = RED, fill_opacity = fill, stroke = INK, stroke_width = 2, stroke_opacity = 1 - fill,
        path_length = 1, stroke_dasharray = { 1, 1 }, stroke_dashoffset = 1 - q }
    end)
    label(string.format("%s  %d,%d", WORD:sub(i, i), column(i), TOP), column(i), TOP + 170, p)
    label(MARKS[i], column(i), BOTTOM + 120, q)
  end
end }

-- 2. Morph: the rows trade places through each other, each letter turning
-- into its mark on the way down and each mark into its letter on the way up.
scene { "Morph", duration = span("morph"), render = function(f)
  local t = f.seconds
  sheet(1)
  -- The plot's notes fade before the shapes move.
  local notes = 1 - ease(ease_out, clamp(t / 0.4, 0, 1))
  for i = 1, N do
    if notes > 0 then
      label(string.format("%s  %d,%d", WORD:sub(i, i), column(i), TOP), column(i), TOP + 170, notes)
      label(MARKS[i], column(i), BOTTOM + 120, notes)
    end
    local k = ease(ease_in_out, clamp((t - 0.4 - stagger(i, 0.28)) / 2.2, 0, 1))
    local sway = math.sin(k * math.pi) * (i % 2 == 0 and 1 or -1)
    at(column(i) + sway * 60, TOP + (BOTTOM - TOP) * k, sway * 25, 1, function()
      path { d = morph_at(MORPH[i], k), fill = mix_color(INK, RED, k) }
    end)
    at(column(i) - sway * 60, BOTTOM + (TOP - BOTTOM) * k, -sway * 25, 1, function()
      path { d = morph_at(MORPH[i], 1 - k), fill = mix_color(INK, RED, 1 - k) }
    end)
  end
end }

-- 3. Lift: the shapes leave the page as solids (cream faces, ink walls; the
-- marks red) and spin through each other in two rings at right angles.
-- One 3D unit is 100 px on the page at depth 0, so they start where the
-- Morph scene left them.
local FOV = 30
local DIST = (H / 200) / math.tan(math.rad(FOV / 2))
local function page3(x, y) return { (x - W / 2) / 100, -(y - H / 2) / 100, 0 } end
-- bevel_offset = -bevel_size: the bevel ends on the outline itself, as big
-- as the page shape. An inward bevel must stay under half the thinnest
-- feature or the outline folds over itself: the marks' pixels are 0.047
-- units, so theirs is 0.012; the letters' strokes take 0.03.
local SOLID = { depth = 0.32, bevel_thickness = 0.05, bevel_size = 0.03, bevel_offset = -0.03, bevel_segments = 3, crease_angle = math.pi / 4 }
local PIXEL_SOLID = { depth = 0.32, bevel_thickness = 0.03, bevel_size = 0.012, bevel_offset = -0.012, bevel_segments = 2, crease_angle = math.pi / 4 }
local function extrude(shape, solid)
  local g = { type = "ExtrudeGeometry", shape = shape }
  for k, v in pairs(solid or SOLID) do g[k] = v end
  return g
end
local function mix3(a, b, k) return { a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k, a[3] + (b[3] - a[3]) * k } end

-- The burst that ends the scene: the rings pull in for a beat, then every
-- solid flies at the screen and past it on all sides, leaving the sheet
-- empty for the Fill scene to rain onto.
local BURST = local_hits("impact", "lift")[1]          -- on the impact, after the riser
local PULL, LIFT_END = BURST - score.seconds("4n", "lift"), span("lift")
local function norm3(v)
  local l = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
  return l > 1e-6 and { v[1] / l, v[2] / l, v[3] / l } or nil
end

scene { "Lift", duration = LIFT_END, render = function(f)
  local t = f.seconds
  sheet(1)
  local rise = ease(ease_in_out, clamp(t / 2.2, 0, 1))
  local spin = t * 0.55
  local R = 3.4
  local orbit = rise * (0.5 + t * 0.06)
  local cam = { DIST * math.sin(orbit) * 0.9, DIST * 0.35 * rise, DIST * math.cos(orbit) * (1 - 0.25 * rise) }
  local view = norm3(cam)
  local pull = ease(ease_in_out, clamp((t - PULL) / (BURST - PULL), 0, 1))
  local fly = clamp((t - BURST) / 1.3, 0, 1) ^ 1.7
  -- A shape at `p`, n-th of 14, through the burst: in toward the middle,
  -- then out along its own direction across the view and at the camera,
  -- tumbling faster as it goes.
  local function burst(p, n)
    local q = { p[1] * (1 - 0.18 * pull), p[2] * (1 - 0.18 * pull), p[3] * (1 - 0.18 * pull) }
    if fly <= 0 then return q, 0 end
    local along = q[1] * view[1] + q[2] * view[2] + q[3] * view[3]
    local out = norm3 { q[1] - view[1] * along, q[2] - view[2] * along, q[3] - view[3] * along }
      or { math.cos(n), math.sin(n), 0 }
    local reach = DIST * 1.15
    return { q[1] + (out[1] * 6 + view[1] * reach) * fly, q[2] + (out[2] * 6 + view[2] * reach) * fly,
      q[3] + (out[3] * 6 + view[3] * reach) * fly }, fly * (5 + hash(n, 4) * 4)
  end
  local meshes = {}
  for i = 1, N do
    local a = (i - 1) / N * math.pi * 2 + spin
    -- Letters: a ring lying flat (about Y), facing out; marks: a ring
    -- standing up (about X): the two cross where the shapes pass through
    -- each other.
    local ring_l = { R * math.sin(a), 0, R * math.cos(a) }
    local ring_m = { 0, R * math.sin(a + math.pi / N), R * math.cos(a + math.pi / N) }
    local flat_l, flat_m = page3(column(i), TOP), page3(column(i), BOTTOM)
    local self = t * (1.2 + 0.1 * i)
    -- Sunk into the page at first, only the front face at the paper (where
    -- the 2D shapes were); out of it as they rise.
    local pos_l, pos_m = mix3(flat_l, ring_l, rise), mix3(flat_m, ring_m, rise)
    pos_l[3] = pos_l[3] - (SOLID.depth + SOLID.bevel_thickness) * (1 - rise)
    pos_m[3] = pos_m[3] - (PIXEL_SOLID.depth + PIXEL_SOLID.bevel_thickness) * (1 - rise)
    local tumble_l, tumble_m
    pos_l, tumble_l = burst(pos_l, i)
    pos_m, tumble_m = burst(pos_m, i + N)
    meshes[#meshes + 1] = { geometry = extrude(LETTER3[i]), position = pos_l,
      rotation = { tumble_l, (a + self * 0.3) * rise, tumble_l * 0.5 }, cast_shadow = true,
      material = { color = mix_color(INK, "#fffaf0", clamp(rise * 1.6, 0, 1)), roughness = 0.6 },
      side_material = { color = INK, roughness = 0.45 } }
    meshes[#meshes + 1] = { geometry = extrude(MARK3[i], PIXEL_SOLID), position = pos_m,
      rotation = { (a + math.pi / N) * rise + tumble_m, self * 0.4 * rise, tumble_m * 0.7 }, cast_shadow = true,
      material = { color = RED, roughness = 0.5 }, side_material = { color = INK, roughness = 0.45 } }
  end
  -- The shock of the burst on the paper: an ink ring and a red one just
  -- behind it, out from the middle (the view's centre) and fading.
  for k, ring in ipairs { { 0, INK, 26 }, { 0.09, RED, 12 } } do
    local u = clamp((t - BURST - ring[1]) / 0.9, 0, 1)
    if u > 0 and u < 1 then
      local e = ease(ease_out, u)
      circle { cx = W / 2, cy = H / 2, r = 40 + e * 900, fill = "none", stroke = ring[2],
        stroke_width = ring[3] * (1 - e) + 1, opacity = 1 - u }
    end
  end
  view3d {
    opacity = clamp(t / 0.25, 0, 1),         -- under the page's shapes, which then dissolve
    camera = { position = cam, target = { 0, 0, 0 }, fov = FOV },
    lights = {
      { type = "HemisphereLight", color = "#ffffff", ground_color = "#8a7f70", intensity = 1.6 },
      { type = "DirectionalLight", color = "#fff6e8", intensity = 1.8, position = { 4, 7, 9 } },
    },
    meshes = meshes,
  }
  -- The page's flat shapes over the solids at first (the cut from Morph
  -- shows nothing new), dissolving as the solids come out of the paper.
  local cover = 1 - ease(ease_in_out, clamp((t - 0.2) / 0.6, 0, 1))
  if cover > 0 then
    for i = 1, N do
      group({ opacity = cover }, function()
        at(column(i), TOP, 0, 1, function() path { d = LETTER[i], fill = INK } end)
        at(column(i), BOTTOM, 0, 1, function() path { d = MARK[i], fill = RED } end)
      end)
    end
  end
end }

-- 4. Fill: the shapes rain onto the sheet, big and small, and pile up by
-- their outlines until the page is full.
local SMALL_L, SMALL_M = {}, {}
for i = 1, N do SMALL_L[i], SMALL_M[i] = letter(i, 150), mark(i, 95) end
local DROPS = 84
local FILL_END = span("fill")
local function drop_shape(k)
  local i = (k - 1) % N + 1
  local kind = math.floor((k - 1) / N) % 4                -- big letter, mark, small letter, small mark
  local shape = ({ LETTER, MARK, SMALL_L, SMALL_M })[kind + 1][i]
  return shape, kind % 2 == 1
end
local pile = shared("pile", function()
  local bodies = {
    { static = true, box = { W * 2, 60 }, x = W / 2, y = H + 30 },
    { static = true, box = { 60, H * 4 }, x = -30, y = 0 },
    { static = true, box = { 60, H * 4 }, x = W + 30, y = 0 },
  }
  for k = 1, DROPS do
    local shape = drop_shape(k)
    -- Each spawn a golden-ratio step across from the last: neighbours in
    -- time land far apart.
    local lane = (k * 0.6180339887) % 1
    bodies[#bodies + 1] = { name = "drop" .. k, outline = shape, x = 140 + lane * (W - 280), y = -160, vy = 900,
      angle = hash(k, 2) * 360, spin = (hash(k, 3) - 0.5) * 240, start = stagger(k, 0.07), bounce = 0.15, friction = 0.5 }
  end
  return physics { duration = FILL_END, gravity = 2600, bodies = bodies }
end)

-- 5. The title block, drawn on in the paper left above the pile as the last
-- shapes settle: the drafting sheet's box of fields.
local BLOCK = { x = 81, y = 81, w = 918, h = 216 }
local FIELDS = {
  { "DRAWN BY", "Claude, through onimite" },
  { "LIBRARIES", "ovg oksl odecs ottis o3d odawg" },
  { "SHEET", "1 / 1      SCALE 1:1" },
}
local TITLE_SIZE = text_size { "onimite", font = "Instrument Serif", italic = true, max_width = 320, size = 132 }
local function title_block(t)
  if t <= 0 then return end
  local draw = ease(ease_in_out, clamp(t / 1.2, 0, 1))
  local b = BLOCK
  local split = b.x + 378                         -- the title's cell | the fields
  local rules = string.format("M%d %dH%dV%dH%dZ M%d %dV%d", b.x, b.y, b.x + b.w, b.y + b.h, b.x, split, b.y, b.y + b.h)
  for k = 1, #FIELDS - 1 do
    rules = rules .. string.format(" M%d %dH%d", split, b.y + k * b.h / #FIELDS, b.x + b.w)
  end
  rect { x = b.x, y = b.y, w = b.w, h = b.h, fill = PAPER, opacity = draw }
  path { d = rules, fill = "none", stroke = INK, stroke_width = 2.5, path_length = 1,
    stroke_dasharray = { 1, 1 }, stroke_dashoffset = 1 - draw }
  local words = ease(ease_out, clamp((t - 0.9) / 0.8, 0, 1))
  text { "onimite", x = b.x + 189, y = b.y + b.h / 2 + 6, font = "Instrument Serif", italic = true, size = TITLE_SIZE,
    fill = INK, align = "center", baseline = "middle", opacity = words }
  for k, fld in ipairs(FIELDS) do
    local y = b.y + (k - 0.5) * b.h / #FIELDS
    local shown = clamp((t - 1.1 - k * 0.25) / 0.5, 0, 1)
    text { fld[1], x = split + 24, y = y, font = MONO.font, size = 14, fill = RED, baseline = "middle", opacity = shown }
    text { fld[2], x = split + 150, y = y, font = MONO.font, size = 20, fill = INK, baseline = "middle", opacity = shown }
  end
end

-- A clack per hard landing: a wooden game piece dropped on a table (a real
-- recording: media/pieces.mp3, CC0, fetched by fetch.sh), one of its single
-- clacks in turn, pitched a little by the shape (a mark a fifth below its
-- letter) through the clip's speed, louder for harder landings; each shape's
-- at most every 0.25 s and all of them at most every 30 ms (a pile touches
-- thousands of times).
local TITLE = T("fill@3m") - T("fill")
local CLACKS = { 9.30, 10.56, 11.24 }                  -- single clacks' onsets in pieces.mp3
local SHAPE_STEP = { 0, 2, 4, 5, 7, 9, 11 }            -- semitones, the shapes up the scale
local ticks, last, last_any = {}, {}, -1
for _, c in ipairs(pile.contacts) do
  for _, b in ipairs { c.a, c.b } do
    local k = tonumber((pile.bodies[b].name or ""):match("^drop(%d+)$"))
    if k and c.speed > 500 and (last[k] or -1) < c.t - 0.25 and c.t - last_any >= 0.03 then
      last[k], last_any = c.t, c.t
      local _, is_mark = drop_shape(k)
      local semis = SHAPE_STEP[(k - 1) % N + 1] / 2 - 3 - (is_mark and 7 or 0)
      ticks[#ticks + 1] = { "pieces.mp3", start = c.t, offset = CLACKS[#ticks % 3 + 1], stop = c.t + 0.22,
        speed = 2 ^ (semis / 12), gain_db = remap(c.speed, 500, 3000, -6, 6), pan = clamp(c.x / W * 1.6 - 0.8, -0.8, 0.8),
        fade_out = 0.05, bus = "sfx" }
      break
    end
  end
end

scene { "Fill", duration = FILL_END, audio = ticks, render = function(f)
  sheet(1)
  for k = 1, DROPS do
    local shape, is_mark = drop_shape(k)
    local x, y, a = physics_at(pile, "drop" .. k, f.seconds)
    at(x, y, a, 1, function()
      if k % 9 == 0 then
        path { d = shape, fill = "none", stroke = INK, stroke_width = 2.5 }
      else
        path { d = shape, fill = is_mark and RED or INK }
      end
    end)
  end
  title_block(f.seconds - TITLE)
end }
