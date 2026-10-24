-- otfx's thunderstorm (otfx/src/effects/thunderstorm.odin), lit as a real
-- storm is. otfx's storm, built once at load: the text dims, rain falls,
-- bolts of \ / | grow from the top row branching to the ground, sparks fly
-- from where they land, struck letters glow, and the text brightens to its
-- final gradient. What a terminal can't draw: each flash flickers as a
-- bolt's return strokes do and lights the clouds around it; every glyph is
-- lit by its distance to the bolt's channel, the near ones white-blue, the
-- far ones barely; struck letters glow white-hot and cool through orange to
-- red; rain and sparks move smoothly between cells; and the bolt, the sparks
-- and whatever is lit bloom.

local term = require("term")

local M = {}

local BG = "#0b0d12"
local LIGHTNING = "#68a3e8"
local LIGHT = "#eaf2ff"                  -- what the flash lights things with
local RAIN = "#5d6094"
local SPARK = "#ff4d00"
local RAIN_SYMBOLS = { "\\", ".", "," }
local SPARK_SYMBOLS = { "*", ".", "'" }
local BOLT_SYMBOLS = { "\\", "/", "|" }
local FINAL = { "#8a008a", "#00d1ff", "#ffffff" } -- bottom row to top row
local FADE = 96                          -- the pre- and post-storm fades (otfx's eight colours of twelve ticks)
local STORM = 12 * term.FPS              -- otfx's storm_time, 12 s
local FLASH, BOLT_GONE = 42, 54          -- ticks after a bolt lands: its flash, then it fades
local GLOW = 90                          -- ticks a struck letter takes to cool
local REACH = 170                        -- px from the channel where its light is half

-- A return stroke's flash: the strokes' pulses, each decaying (ages in ticks).
local STROKES = { { 0, 1.0 }, { 9, 0.55 }, { 16, 0.85 }, { 31, 0.4 } }
local function flash(age)
  if age < 0 or age >= BOLT_GONE then return 0 end
  local s = 0
  for _, p in ipairs(STROKES) do
    if age >= p[1] then s = s + p[2] * math.exp(-(age - p[1]) / 5) end
  end
  return math.min(s, 1.2)
end

-- White-hot to orange to red to `cold` as u goes 0 to 1.
local function cooling(u, cold)
  if u < 0.2 then return mix_color("#fff4dc", "#ffc35a", u / 0.2) end
  if u < 0.5 then return mix_color("#ffc35a", "#ef5411", (u - 0.2) / 0.3) end
  if u < 0.8 then return mix_color("#ef5411", "#6e1604", (u - 0.5) / 0.3) end
  return mix_color("#6e1604", cold, math.min((u - 0.8) / 0.2, 1))
end

local function lerp(a, b, t) return a + (b - a) * t end

-- cells from term.grid; returns { ticks, draw(tick) }.
function M.build(cells, seed)
  local r = term.rng(seed)
  local COLS, ROWS, CW, CH = term.COLS, term.ROWS, term.CW, term.CH
  local function float(a, b) return a + (b - a) * r.below(1000000) / 1000000 end
  local n = #cells

  -- Colours: the final gradient (bottom to top), the storm's (half as
  -- bright), and which text cell is where.
  local r0, r1 = math.huge, -math.huge
  for _, c in ipairs(cells) do r0, r1 = math.min(r0, c.row), math.max(r1, c.row) end
  local final, storm, at = {}, {}, {}
  for i, c in ipairs(cells) do
    local u = r1 > r0 and (r1 - c.row) / (r1 - r0) or 0
    final[i] = u < 0.5 and mix_color(FINAL[1], FINAL[2], u * 2) or mix_color(FINAL[2], FINAL[3], u * 2 - 1)
    storm[i] = mix_color(final[i], "#000000", 0.5)
    at[c.row * COLS + c.col] = i
  end

  -- A bolt from the top row at `col`: the trunk steps down a row a tick
  -- (\ right, / left, | straight), forking 5% of rows into a branch that
  -- runs diagonally to the ground; each branch's segments come right after
  -- the segment it forks from (otfx's order).
  local function bolt(col)
    local segs = {}
    local function branch(c, row, side)
      while row <= ROWS - 1 do
        local sym, nextc
        if side then
          sym = r.below(2)
          c = c + 1 - 2 * sym
          nextc = c
        else
          sym = r.below(3)
          nextc = c + (sym == 0 and 1 or 0) - (sym == 1 and 1 or 0)
        end
        local fork = not side and r.below(100) < 5
        segs[#segs + 1] = { col = c, row = row, sym = BOLT_SYMBOLS[sym + 1] }
        if fork then branch(c, row, true) end
        c, row = nextc, row + 1
      end
    end
    branch(col, 0, false)
    return segs
  end

  -- The storm, tick by tick: rain every few ticks, a strike now and then
  -- (0.8% a tick while none is live), until 12 s have passed and the last
  -- bolt has gone.
  local rain, strikes = {}, {}
  local rain_delay, live_until, t = 0, -1, 0
  while true do
    if rain_delay > 0 then
      rain_delay = rain_delay - 1
    else
      for _ = 1, r.range(1, 7) do
        local c0 = r.range(-ROWS, COLS + 1)
        local c1 = c0 + ROWS
        local len = math.sqrt(ROWS * ROWS + (2 * ROWS) ^ 2)
        rain[#rain + 1] = { start = t, c0 = c0, c1 = c1, steps = math.max(math.floor(len / float(0.5, 1.5) + 0.5), 1),
          sym = r.pick(RAIN_SYMBOLS) }
      end
      rain_delay = r.range(1, 8)
    end
    if t > live_until and float(0, 1) < 0.008 then
      local segs = bolt(r.range(0, COLS))
      -- revealed one to three segments every other tick
      local k, tick = 1, t
      while k <= #segs do
        for _ = 1, r.range(1, 4) do
          if k > #segs then break end
          segs[k].at = tick
          k = k + 1
        end
        tick = tick + 2
      end
      local land = segs[#segs].at + 1
      local s = { start = t, segs = segs, land = land, top = segs[1].col }
      -- the light each text cell gets: half at REACH px from the channel
      s.light, s.struck = {}, {}
      for i, c in ipairs(cells) do
        local best = math.huge
        for _, g in ipairs(segs) do
          local dx, dy = (c.col - g.col) * CW, (c.row - g.row) * CH
          best = math.min(best, dx * dx + dy * dy)
        end
        s.light[i] = 1 / (1 + best / (REACH * REACH))
      end
      for _, g in ipairs(segs) do
        local i = at[g.row * COLS + g.col]
        if i then s.struck[#s.struck + 1] = i end
      end
      -- sparks from where it landed, out along curves to the ground
      local impact = segs[#segs]
      s.sparks = {}
      for _ = 1, r.range(12, 19) do
        local off = r.range(4, 21) * (r.below(2) == 0 and -1 or 1)
        local tc = impact.col + off
        local cc, cr = impact.col - math.floor((impact.col - tc) / 2 + 0.5), r.range(0, ROWS)
        local len = 0
        local px, py = impact.col, impact.row
        for j = 1, 10 do
          local u = j / 10
          local x = (1 - u) ^ 2 * impact.col + 2 * (1 - u) * u * cc + u * u * tc
          local y = (1 - u) ^ 2 * impact.row + 2 * (1 - u) * u * cr + u * u * (ROWS - 1)
          len = len + math.sqrt((x - px) ^ 2 + (2 * (y - py)) ^ 2)
          px, py = x, y
        end
        s.sparks[#s.sparks + 1] = { c0 = impact.col, r0 = impact.row, cc = cc, cr = cr, c1 = tc,
          steps = math.max(math.floor(len / float(0.1, 0.25) + 0.5), 1), sym = r.pick(SPARK_SYMBOLS) }
      end
      strikes[#strikes + 1] = s
      live_until = land + BOLT_GONE
    end
    t = t + 1
    if t >= STORM and t > live_until then break end
  end
  local storm_ticks = t

  local function draw(tick)
    local st = tick - FADE
    -- the flash now (the strongest of the strikes), and the strike it's from
    local light, lit = 0, nil
    for _, s in ipairs(strikes) do
      local f = flash(st - s.land)
      if f > light then light, lit = f, s end
    end
    -- the clouds over the bolt light up
    if lit then
      rect { x = 0, y = 0, w = 1920, h = 1080, fill = radial_gradient { cx = (lit.top + 0.5) * CW, cy = -60, r = 1500,
        stops = { { 0, "#9cbcff" }, { 0.35, "#36466e" }, { 1, BG } } }, opacity = math.min(light, 1) * 0.55 }
    end
    group({ bloom = { threshold = 0.5, intensity = 1.1, radius = 24 } }, function()
      -- the text: faded to the storm's colours and back, lit by the flash,
      -- struck letters glowing
      for i = 1, n do
        local c = cells[i]
        local col
        if st < 0 then
          col = mix_color(final[i], storm[i], tick / FADE)
        elseif st >= storm_ticks then
          col = mix_color(storm[i], final[i], math.min((st - storm_ticks) / FADE, 1))
        else
          col = storm[i]
          if lit then
            col = mix_color(col, final[i], math.min(light, 1) * 0.6)
            col = mix_color(col, LIGHT, math.min(light * lit.light[i] * 1.25, 1))
          end
        end
        term.cell(c.ch, c.col, c.row, col)
      end
      if st < 0 or st >= storm_ticks then return end
      for _, s in ipairs(strikes) do
        local age = st - s.land
        if age >= 0 and age < GLOW then
          local hot = cooling(age / GLOW, BG)
          for _, i in ipairs(s.struck) do
            local c = cells[i]
            term.cell(c.ch, c.col, c.row, mix_color(hot, storm[i], math.max((age / GLOW - 0.8) / 0.2, 0)))
          end
        end
      end
      -- the weather starts and ends past the frame's edges, as otfx's does
      -- past the terminal's: clipped to the frame
      group({ clip = { x = 0, y = 0, w = 1920, h = 1080 } }, function()
      -- rain, lit by the flash
      local rain_col = mix_color(RAIN, LIGHT, math.min(light, 1) * 0.7)
      for _, d in ipairs(rain) do
        local age = st - d.start
        if age >= 0 and age < d.steps then
          local u = (age + 1) / d.steps
          term.cell(d.sym, lerp(d.c0, d.c1, u), u * (ROWS - 1), rain_col)
        end
      end
      for _, s in ipairs(strikes) do
        -- the bolt: its leader growing, then white-hot with each stroke, then gone
        local age = st - s.land
        if st >= s.start and age < BOLT_GONE then
          local col = LIGHTNING
          if age >= FLASH then
            col = mix_color(LIGHTNING, BG, (age - FLASH) / (BOLT_GONE - FLASH))
          elseif age >= 0 then
            col = mix_color(LIGHTNING, "#ffffff", math.min(flash(age), 1))
          end
          -- the channel's own light: a soft column along it, pulsing with
          -- each stroke (faint while the leader grows)
          local halo = age < 0 and 0.18 or math.min(flash(age), 1)
          if halo > 0.01 then
            group({ blur = 14, blend = "screen", opacity = halo }, function()
              for _, g in ipairs(s.segs) do
                if g.at <= st then
                  rect { x = (g.col + 0.2) * CW, y = g.row * CH, w = CW * 0.6, h = CH, fill = "#a9c8ff" }
                end
              end
            end)
          end
          for _, g in ipairs(s.segs) do
            if g.at <= st then term.cell(g.sym, g.col, g.row, col) end
          end
        end
        -- sparks: out along their curves, then cooling where they fell
        if age >= -1 then
          for _, p in ipairs(s.sparks) do
            local a = age + 1
            local u = math.min(a / p.steps, 1)
            u = math.sqrt(1 - (1 - u) ^ 2)              -- circular out, as otfx's
            local x = (1 - u) ^ 2 * p.c0 + 2 * (1 - u) * u * p.cc + u * u * p.c1
            local y = (1 - u) ^ 2 * p.r0 + 2 * (1 - u) * u * p.cr + u * u * (ROWS - 1)
            local cool = math.max(a - p.steps, 0) / (18 * 8)
            if cool < 1 then
              local col = a < p.steps and mix_color("#fff1c4", SPARK, a / p.steps) or mix_color(SPARK, BG, cool)
              term.cell(p.sym, x, y, col)
            end
          end
        end
      end
      end)
    end)
  end

  return { ticks = FADE + storm_ticks + FADE, draw = draw }
end

return M
