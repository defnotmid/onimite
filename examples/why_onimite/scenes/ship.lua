-- What you install before the first frame, to scale (area per MB): fframes'
-- Rust toolchain drops into its bin, its 311 crates pour in (one grain
-- each), then the 2.5 GB first build lands on top; onimite is one small
-- block. Simulated once at load (physics{}); each landing has its sound
-- (`HITS`, the scene's audio). Bars 3 and 4: what an edit costs in each.

local beat = require("beat")
local score = require("track")
local ui = require("ui")
local T = require("timeline")
local CRASH = require("library").CRASH
local INSTRUMENTS = require("library").INSTRUMENTS
local facts = require("facts")
local snap, soft = beat.snap, beat.soft

local PX2_PER_MB = 65
local FLOOR, WALL = 960, 10
local FF = { x = 1170, w = 480 }              -- the bins: left edge, inner width
local ON = { x = 1730, w = 120 }
local SOLO_X = 120

local fframes, onimite = facts.setup[1], facts.disk_mb
local TOOLCHAIN, CRATES, BUILD = fframes.parts[1], fframes.parts[2], fframes.parts[3]
local function side(mb) return math.sqrt(mb * PX2_PER_MB) end
local GRAIN = side(CRATES[2] / fframes.deps)
local SLAB_W = FF.w - 20
local SLAB_H = BUILD[2] * PX2_PER_MB / SLAB_W

-- Beats in the scene: the toolchain drops, the crates pour, the build
-- lands, then onimite.
local DROP_TOOLCHAIN, POUR_FROM, POUR_TO, DROP_BUILD, DROP_ONIMITE = 1, 2, 4, 4.5, T.SHIP_TOTAL
local function seconds(lb) return score.seconds(lb, "ship") end

local TOOLCHAIN_AT, BUILD_AT, ONIMITE_AT, GRAINS_AT = 1, 2, 3, 4
-- When crate k (from 0) starts falling, seconds into the scene.
local function poured(k) return seconds(POUR_FROM + (POUR_TO - POUR_FROM) * k / fframes.deps) end
local START = score.time("ship")
local function simulate(shift)
  local function wall(x, y, w, h) return { static = true, box = { w, h }, x = x + w / 2, y = y + h / 2 } end
  local bodies = {
    { box = { side(TOOLCHAIN[2]), side(TOOLCHAIN[2]) }, x = FF.x + FF.w * 0.3, y = -160, angle = 4,
      vy = 900, start = seconds(DROP_TOOLCHAIN) + shift[1], friction = 0.6 },
    { box = { SLAB_W, SLAB_H }, x = FF.x + FF.w / 2, y = -SLAB_H, vy = 1400, start = seconds(DROP_BUILD) + shift[2], density = 2 },
    { box = { side(onimite), side(onimite) }, x = ON.x + ON.w / 2, y = -40, angle = 12, vy = 900, start = seconds(DROP_ONIMITE) + shift[3] },
  }
  -- The crates: spread over the bin's width above the frame, at jittered heights;
  -- consecutive ones far apart so none starts inside another.
  local slots = math.floor((FF.w - 2 * GRAIN) / (GRAIN * 1.6))
  for k = 0, fframes.deps - 1 do
    local slot = (k * 37) % slots
    bodies[#bodies + 1] = { box = { GRAIN, GRAIN }, x = FF.x + GRAIN + slot * GRAIN * 1.6 + GRAIN / 2, y = -20 - 130 * hash(k, 5),
      vy = 1400, angle = hash(k, 3) * 90, spin = (hash(k, 4) - 0.5) * 600, friction = 0.4, bounce = 0.1,
      start = poured(k) }
  end
  -- The bins: floor and walls, open at the top.
  for _, bin in ipairs { FF, ON } do
    bodies[#bodies + 1] = wall(bin.x - WALL, FLOOR, bin.w + 2 * WALL, WALL)
    bodies[#bodies + 1] = wall(bin.x - WALL, 300, WALL, FLOOR - 300)
    bodies[#bodies + 1] = wall(bin.x + bin.w, 300, WALL, FLOOR - 300)
  end
  return physics { duration = score.seconds("4m", "ship"), gravity = 5200, bodies = bodies }
end
-- Body i's first hard contact, seconds into the scene.
local function landing(s, i)
  for _, c in ipairs(s.contacts) do
    if (c.a == i or c.b == i) and c.speed > 300 then return c.t end
  end
end
-- The blocks' drops are moved so each lands on the song's grid (the crates
-- pour as a roll).
local sim = shared("ship.bins", function()
  local first, shift = simulate { 0, 0, 0 }, {}
  for i = 1, 3 do
    local t = START + landing(first, i)
    shift[i] = score.snap(t, "8n") - t
  end
  return simulate(shift)
end)
local GRAINS_END = GRAINS_AT + fframes.deps - 1

-- The landings the soundtrack plays: each body's first hard one, seconds
-- into the scene, and what landed (a grain, a block, the build, onimite).
-- LANDED[i]: when body i landed (the counters count what is in the bin).
local HITS, LANDED = {}, {}
do
  for _, c in ipairs(sim.contacts) do
    for _, i in ipairs { c.a, c.b } do
      if i <= GRAINS_END and not LANDED[i] and c.speed > 300 then
        LANDED[i] = c.t
        HITS[#HITS + 1] = { t = c.t, speed = c.speed,
          kind = i >= GRAINS_AT and "grain" or i == BUILD_AT and "build" or i == ONIMITE_AT and "onimite" or "block" }
      end
    end
  end
end

-- A body drawn about its centre.
local function body(f, i, draw)
  local x, y, angle = physics_at(sim, i, f.seconds)
  group({ transform = { translate = { x, y }, rotate = angle } }, draw)
end

local function bins(f, lb)
  local p = progress(lb, 0.5, 1)
  for _, bin in ipairs { FF, ON } do
    path { d = string.format("M%f %f L%f %f L%f %f L%f %f", bin.x - WALL / 2, 300, bin.x - WALL / 2, FLOOR + WALL / 2,
      bin.x + bin.w + WALL / 2, FLOOR + WALL / 2, bin.x + bin.w + WALL / 2, 300),
      fill = "none", stroke = ui.LINE, stroke_width = WALL, line_join = "round", opacity = p }
  end
  -- What fframes needs, counted as it lands in the bin.
  local function landed(i) return LANDED[i] and f.seconds >= LANDED[i] end
  local mb, crates = 0, 0
  if landed(TOOLCHAIN_AT) then mb = mb + TOOLCHAIN[2] end
  for k = GRAINS_AT, GRAINS_END do
    if landed(k) then crates = crates + 1 end
  end
  mb = mb + CRATES[2] * crates / fframes.deps
  if landed(BUILD_AT) then mb = mb + BUILD[2] end
  group({ opacity = p }, function()
    text { "fframes", x = FF.x - WALL, y = 254, font = ui.DISPLAY, size = 64, fill = ui.F }
    text { string.format("%s · %d crates", facts.size(mb), crates), x = FF.x - WALL, y = 290,
      font = ui.MONO, size = 22, fill = ui.F }
    text { "onimite", x = ON.x + ON.w / 2, y = 254, align = "center", font = ui.DISPLAY, size = 64, fill = ui.O }
  end)
  if lb >= DROP_ONIMITE then
    text { string.format("%.1f MB · that's all", onimite), x = ON.x + ON.w / 2, y = 290, align = "center",
      font = ui.MONO, size = 20, fill = ui.O, opacity = progress(lb, DROP_ONIMITE, DROP_ONIMITE + 0.5) }
  end
  text { "measured: a fresh install, the sum of its files", x = FF.x - WALL, y = 1010, font = ui.MONO, size = 22, fill = ui.DIM }

  for k = GRAINS_AT, GRAINS_END do
    if f.seconds >= poured(k - GRAINS_AT) then
      body(f, k, function()
        rect { x = -GRAIN / 2, y = -GRAIN / 2, w = GRAIN, h = GRAIN, rx = 1.5, fill = k % 3 == 0 and "#ffb08f" or ui.F }
      end)
    end
  end
  local blocks = {
    { TOOLCHAIN_AT, DROP_TOOLCHAIN, side(TOOLCHAIN[2]), side(TOOLCHAIN[2]), "#e2522a", { "Rust toolchain", facts.size(TOOLCHAIN[2]) } },
    { BUILD_AT, DROP_BUILD, SLAB_W, SLAB_H, ui.F, { "first build (target/)", facts.size(BUILD[2]) } },
  }
  for _, b in ipairs(blocks) do
    if lb >= b[2] then
      body(f, b[1], function()
        rect { x = -b[3] / 2, y = -b[4] / 2, w = b[3], h = b[4], rx = 6, fill = b[5] }
        -- Labelled once it is in the bin (it falls past the titles).
        if landed(b[1]) then
          text { b[6][1], x = 0, y = -6, align = "center", font = ui.MONO, size = 22, fill = ui.BG }
          text { b[6][2], x = 0, y = 26, align = "center", font = ui.MONO, size = 22, fill = ui.BG }
        end
      end)
    end
  end
  if lb >= DROP_ONIMITE then
    local s = side(onimite)
    body(f, ONIMITE_AT, function() rect { x = -s / 2, y = -s / 2, w = s, h = s, rx = 3, fill = ui.O } end)
  end
end

-- An editor line and what happens after saving it.
local function edit_card(lb, y, at, who, color, before, after, outcome, reloads)
  local appear = snap(lb - at)
  local typed = lb >= T.RELOAD - 1
  group({ opacity = progress(lb, at, at + 0.1), transform = translate((1 - appear) * -120, 0) }, function()
    rect { x = SOLO_X, y = y, w = 1000, h = 220, rx = 22, fill = ui.PANEL, stroke = ui.LINE, stroke_width = 2 }
    text { who, x = SOLO_X + 36, y = y + 52, font = ui.MONO, size = 24, fill = color }
    text { typed and after or before, x = SOLO_X + 36, y = y + 112, font = ui.MONO, size = 30, fill = ui.TEXT }
    if lb >= T.RELOAD then
      local s = soft(lb - T.RELOAD)
      if reloads then
        ui.chip(SOLO_X + 36, y + 140, outcome, ui.O, ui.BG, 24, s)
      else
        -- a spinner that never gets to say how long
        local a = lb * 360
        group({ transform = { rotate = a, origin = { SOLO_X + 56, y + 172 } } }, function()
          path { d = string.format("M%f %f A20 20 0 1 1 %f %f", SOLO_X + 36, y + 172, SOLO_X + 56, y + 152),
            fill = "none", stroke = ui.F, stroke_width = 5, line_cap = "round" }
        end)
        group({ opacity = progress(lb, T.RELOAD, T.RELOAD + 0.2) }, function()
          text { outcome, x = SOLO_X + 96, y = y + 181, font = ui.MONO, size = 24, fill = ui.F }
        end)
      end
    end
  end)
end

local function render(f, lb)
  ui.header(lb, "SHIPPING", "what you install before the first frame")
  bins(f, lb)
  edit_card(lb, 300, 8, "onimite · video.lua", ui.O, 'text { "Hi", size = 96 }', 'text { "Hi", size = 140 }',
    "saved → the preview hot-reloads", true)
  edit_card(lb, 560, 8.5, "fframes · src/main.rs", ui.F, "font_size: 96.0,", "font_size: 140.0,",
    "saved → cargo rebuilds the video's crate", false)
end

-- A sound per landing, as hard as it hit: a tick per crate (three pitches),
-- a thump for the toolchain, an impact for the build, a blip for onimite;
-- a crash when onimite has landed, a DONE on the reload.
local TICKS = { sound { "tick", instruments = INSTRUMENTS, note = "C#7" }, sound { "tick", instruments = INSTRUMENTS, note = "E7" }, sound { "tick", instruments = INSTRUMENTS, note = "G7" } }
local LANDING = { build = sound { "impact", instruments = INSTRUMENTS, duration = "2n" }, onimite = sound { "blip", instruments = INSTRUMENTS, note = "E6", duration = "16n" },
  block = sound { "thump", instruments = INSTRUMENTS, note = "A1", duration = "4n" } }
local audio = {
  { CRASH, start = T.at.SHIP_TOTAL, gain_db = -4 },
  { sound { "done", instruments = INSTRUMENTS, note = "E6", duration = "16n" }, start = T.at.RELOAD, gain_db = -6 },
}
for _, h in ipairs(HITS) do
  local g = clamp01(h.speed / 2500)
  if h.kind == "grain" then
    audio[#audio + 1] = { TICKS[math.floor(hash(h.t) * 3) + 1], start = START + h.t,
      gain_db = 20 * math.log(0.3 + 0.7 * g, 10) - 14, pan = (hash(h.t, 2) - 0.5) * 0.6 }
  else
    audio[#audio + 1] = { LANDING[h.kind], start = START + h.t, gain_db = h.kind == "build" and -8 or -6 }
  end
end

return { name = "Ship", section = "ship", render = render, audio = audio }
