-- otfx's burn (otfx/src/effects/burn.odin), and the fire a terminal can't
-- draw. The ignition order (a random growth through the text block) and
-- each character's palette, white-hot to crimson, then the final gradient,
-- are otfx's, built once at load. Every frame the burning cells are drawn
-- as a heat map (red: flame, green: smoke) that an SkSL fire reads: flames
-- rise off the letters and sway in turbulent noise, coloured along a
-- blackbody ramp, smoke curls above them, the fire lights the wall behind
-- it, and what is bright blooms.

local term = require("term")

local M = {}

local START = "#837373"
local BURN = { "#ffffff", "#fff75d", "#fe650d", "#8a003c", "#510100" }
local FINAL = { "#00c3ff", "#ffff1c" }  -- bottom row to top row
local CYCLE = 4                         -- ticks per palette entry, as otfx
local COOL_TICKS = 36                   -- the last palette colour to the final one
local SMOKE_CHANCE = 0.5

-- otfx's palette: ten steps between each pair of burn colours.
local PALETTE = {}
for i = 1, #BURN - 1 do
  for s = 0, 9 do PALETTE[#PALETTE + 1] = mix_color(BURN[i], BURN[i + 1], s / 10, "srgb") end
end
PALETTE[#PALETTE + 1] = BURN[#BURN]
local FIRE_TICKS = #PALETTE * CYCLE

local FIRE = [[
uniform float iTime;
uniform shader uHeat;
uniform float2 uCell;

float hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
float noise(float2 p) {
  float2 i = floor(p);
  float2 f = fract(p);
  float2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + float2(1.0, 0.0)), u.x), mix(hash(i + float2(0.0, 1.0)), hash(i + float2(1.0, 1.0)), u.x), u.y);
}
float fbm(float2 p) {
  float v = 0.0;
  float a = 0.5;
  for (int k = 0; k < 4; k++) { v += a * noise(p); p *= 2.03; a *= 0.5; }
  return v;
}

half4 main(float2 c) {
  float2 q = c / uCell.y;                          // in cell heights
  float n1 = fbm(q * float2(1.6, 0.9) + float2(0.0, iTime * 2.4));
  float n2 = fbm(q * float2(3.1, 1.7) + float2(5.2, iTime * 3.7));
  // the heat below a point rises to it: walk down the column, each height
  // in its own turbulence, swaying more the further the heat has risen
  float flame = 0.0;
  float jitter = hash(c);                         // dithers the steps: no bands
  for (int k = 0; k < 12; k++) {
    float fk = float(k) + jitter;
    float up = fk * uCell.y * 0.4;
    float w = noise(q * float2(1.5, 0.7) + float2(fk * 0.61, iTime * 3.1 + fk * 0.23));
    flame += uHeat.eval(c + float2((w - 0.5) * uCell.x * (0.5 + fk * 0.5), up)).r * (1.0 - fk * 0.065);
  }
  float smoke = 0.0;
  for (int k = 0; k < 10; k++) {
    float fk = float(k);
    float up = uCell.y * (0.8 + fk * 1.1);
    float w = noise(q * float2(0.9, 0.5) + float2(fk * 0.83 + 3.0, iTime * 1.3 + fk * 0.31));
    smoke += uHeat.eval(c + float2((w - 0.5) * uCell.x * (2.0 + fk * 1.4), up)).g * (1.0 - fk * 0.08);
  }
  // tongues: the noise carves the rising heat, more the higher it gets
  float f = clamp(flame / 4.2 * (0.25 + 1.2 * smoothstep(0.32, 0.72, n1 * 0.55 + n2 * 0.6)), 0.0, 1.6);
  float3 col = mix(float3(0.5, 0.03, 0.0), float3(1.0, 0.36, 0.03), smoothstep(0.12, 0.45, f));
  col = mix(col, float3(1.0, 0.78, 0.22), smoothstep(0.45, 0.85, f));
  col = mix(col, float3(1.0, 0.97, 0.86), smoothstep(0.85, 1.3, f));
  float a = smoothstep(0.1, 0.38, f);
  float s = clamp(smoke / 3.5, 0.0, 1.0) * smoothstep(0.25, 0.75, n2) * (1.0 - a) * 0.6;
  return half4(half3(col * a + float3(0.3, 0.29, 0.29) * s), half(a + s));
}]]

-- cells from term.grid; returns { ticks, draw(tick) }.
function M.build(cells, seed)
  local r = term.rng(seed)
  local n = #cells

  -- The text block, its final colours and each cell's character.
  local c0, c1, r0, r1 = math.huge, -math.huge, math.huge, -math.huge
  for _, c in ipairs(cells) do
    c0, c1, r0, r1 = math.min(c0, c.col), math.max(c1, c.col), math.min(r0, c.row), math.max(r1, c.row)
  end
  local width, height = c1 - c0 + 1, r1 - r0 + 1
  local at, final = {}, {}
  for i, c in ipairs(cells) do
    at[(c.row - r0) * width + (c.col - c0)] = i
    final[i] = mix_color(FINAL[1], FINAL[2], height > 1 and (r1 - c.row) / (height - 1) or 0, "srgb")
  end

  -- otfx's growth: from a random cell, take a random frontier cell and grow
  -- to a random unvisited neighbour; the cells ignite in that order, two to
  -- four a tick (blank cells take their turn too).
  local total = width * height
  local visited, frontier = {}, {}
  local root = r.below(total)
  visited[root] = true
  local order = { root }
  frontier[1] = root
  while #frontier > 0 do
    local pick = r.below(#frontier) + 1
    local current = frontier[pick]
    frontier[pick] = frontier[#frontier]
    frontier[#frontier] = nil
    local col = current % width
    local neighbors = {}
    for d, off in ipairs({ -width, 1, width, -1 }) do
      local nx = current + off
      if nx >= 0 and nx < total and not (d == 2 and col == width - 1) and not (d == 4 and col == 0)
          and not visited[nx] then
        neighbors[#neighbors + 1] = nx
      end
    end
    if #neighbors > 0 then
      local nx = neighbors[r.below(#neighbors) + 1]
      visited[nx] = true
      order[#order + 1] = nx
      if #neighbors > 1 then frontier[#frontier + 1] = current end
      frontier[#frontier + 1] = nx
    end
  end
  local start, smokes = {}, {}
  local tick, remaining, last = 0, r.range(2, 5), 0
  for _, cell in ipairs(order) do
    local i = at[cell]
    if i then
      start[i] = tick
      smokes[i] = r.below(1000) < SMOKE_CHANCE * 1000
      last = math.max(last, tick)
    end
    remaining = remaining - 1
    if remaining == 0 then tick, remaining = tick + 1, r.range(2, 5) end
  end

  local CW, CH = term.CW, term.CH
  -- Flame heat: up in ten ticks, dying as the palette darkens; smoke: after
  -- the flames, a second and a half.
  local function heat(age) return math.min(age / 10, 1) * (1 - math.min(math.max(age - 30, 0) / (FIRE_TICKS - 30), 1)) end
  local function smoke(age)
    local s = math.min(math.max(age - 90, 0) / 40, 1) * (1 - math.min(math.max(age - FIRE_TICKS, 0) / 100, 1))
    return s
  end

  local function draw(t)
    -- the wall behind, lit by the fire: a warm glow under its heat
    local sum, sx, sy = 0, 0, 0
    for i = 1, n do
      local age = t - start[i]
      if age >= 0 and age < FIRE_TICKS then
        local h = heat(age)
        sum, sx, sy = sum + h, sx + h * cells[i].col, sy + h * cells[i].row
      end
    end
    if sum > 0.5 then
      local cx, cy = (sx / sum + 0.5) * CW, (sy / sum + 0.5) * CH
      local glow = math.min(sum / 120, 1)
      rect { x = 0, y = 0, w = 1920, h = 1080, fill = radial_gradient { cx = cx, cy = cy, r = 900,
        stops = { { 0, "#ff6a1a" }, { 0.45, "#5a1404" }, { 1, "#0b0d12" } } }, opacity = 0.55 * glow }
    end
    group({ bloom = { threshold = 0.6, intensity = 0.9, radius = 20 } }, function()
      for i = 1, n do
        local c, age = cells[i], t - start[i]
        local col
        if age < 0 then
          col = START
        elseif age < FIRE_TICKS then
          col = PALETTE[age // CYCLE + 1]
        else
          col = mix_color(PALETTE[#PALETTE], final[i], math.min((age - FIRE_TICKS) / COOL_TICKS, 1), "srgb")
        end
        term.cell(c.ch, c.col, c.row, col)
      end
      shader { sksl = FIRE, x = 0, y = 0, w = 1920, h = 1080, time = t / term.FPS, uniforms = {
        uCell = { CW, CH },
        -- softened, so the flames rise off shapes, not cell edges
        uHeat = function() group({ blur = 6 }, function()
          for i = 1, n do
            local age = t - start[i]
            if age >= 0 then
              local h = age < FIRE_TICKS and heat(age) or 0
              local s = smokes[i] and smoke(age) or 0
              if h > 0.01 or s > 0.01 then
                rect { x = cells[i].col * CW, y = cells[i].row * CH, w = CW, h = CH,
                  fill = string.format("#%02x%02x00", math.floor(h * 255 + 0.5), math.floor(s * 255 + 0.5)) }
              end
            end
          end
        end) end,
      } }
    end)
  end

  return { ticks = last + FIRE_TICKS + 100, draw = draw }
end

return M
