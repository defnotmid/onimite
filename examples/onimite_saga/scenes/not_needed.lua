local look = require("look")
local fx = require("fx")
local score = require("music.score")
local sfx = require("sfx")
local snap = look.snap

-- ---- what you don't need ----------------------------------------------------------------

-- Widest first: they land on each other, so the stack stands.
local NOT = { "hundreds of packages", "a GPU (--software)", "node_modules", "a compiler", "a browser", "ffmpeg" }

-- Each thing you don't need drops onto a stack on its beat and is struck
-- through; then a wrecking ball swings in from the left and scatters the lot.
-- physics{} simulates it once at load; the thuds and the smash are its
-- impacts.
local SIZE, PAD, PLATE_H = 96, 24, 92
local STACK_X = 700
local W, H = look.W, look.H
local GROUND = look.H - 56                       -- the floor the stack stands on
local PIVOT, ROPE, BALL = { 260, -480 }, 1250, 115
-- On the beat grid (inspect's off_beat): item i lands on the stack on an
-- eighth note, the ball smashes it on beat SMASH_AT.
local function landing(i) return 0.5 + 0.5 * i end
local SMASH_AT = 5
local function seconds(lb) return score.seconds(lb, "not_needed") end

local ITEMS = {}
for i, s in ipairs(NOT) do ITEMS[i] = { text = s, w = look.width(s, look.DISPLAY, SIZE) } end

local WALLS = 3
local BALL_AT = WALLS + #NOT + 1
-- The world with item i let go at starts[i] and the ball at `release`
-- (seconds into the scene).
local function world(starts, release)
  local bodies = {
    { static = true, layer = "walls", box = { W * 2, 80 }, x = W / 2, y = GROUND + 40 },  -- the ground
    { static = true, layer = "walls", box = { 80, H * 2 }, x = -40, y = H / 2 },     -- and its sides
    { static = true, layer = "walls", box = { 80, H * 2 }, x = W + 40, y = H / 2 },
  }
  for i, it in ipairs(ITEMS) do
    bodies[WALLS + i] = { box = { it.w + 2 * PAD, PLATE_H }, x = STACK_X + (hash(i, 3) - 0.5) * 30, y = -PLATE_H,
      angle = (hash(i, 9) - 0.5) * 6, vy = 2200, start = starts[i], friction = 0.5 }
  end
  -- The ball hangs from above the frame on a rope, held out to the left
  -- (off-screen) until it is let go: it is at the bottom of its swing, and
  -- fastest, as it meets the middle of the stack. It passes the frame's
  -- sides (it swings off and back).
  local a = math.rad(-65)
  bodies[BALL_AT] = { name = "ball", circle = BALL, x = PIVOT[1] + ROPE * math.sin(a), y = PIVOT[2] + ROPE * math.cos(a),
    density = 30, bounce = 0.2, ignores = { "walls" }, leaves = true, bullet = true, start = release }
  -- Pip is solid: what flies at him bounces off.
  bodies[BALL_AT + 1] = { static = true, name = "pip", circle = 165, x = 1660, y = 500 }
  return physics { duration = seconds(8) + 0.5, gravity = 5200, bodies = bodies,
    joints = { { "rope", b = "ball", from = PIVOT } } }
end

-- When each body first lands or hits something (seconds into the scene).
local function first_hits(sim)
  local first = {}
  for _, c in ipairs(sim.contacts) do
    for _, b in ipairs { c.a, c.b } do
      if not first[b] and c.speed > 300 then first[b] = c.t end
    end
  end
  return first
end

-- Timed to the music: a guess, then each drop and the release moved by how
-- far its landing (or the smash) missed its beat, until they meet.
local pile = shared("not_needed.pile", function()
  local starts, release = {}, seconds(SMASH_AT - 2)
  for i = 1, #ITEMS do starts[i] = seconds(landing(i)) - 0.3 end
  for _ = 1, 3 do
    local first = first_hits(world(starts, release))
    for i = 1, #ITEMS do
      if first[WALLS + i] then starts[i] = starts[i] + seconds(landing(i)) - first[WALLS + i] end
    end
    if first[BALL_AT] then release = release + seconds(SMASH_AT) - first[BALL_AT] end
  end
  return world(starts, release)
end)
local LANDED = first_hits(pile)

local function not_needed(f, lb, gb)
  fx.pop(f, 4, "#0a3a6e", "#0ea5e9", "#2ef2a0", look.kick(gb))
  group({ shadow = look.SHADOW }, function()
    look.pop_word("YOU DON'T NEED", 100, 190, 150, lb, look.INK, look.DISPLAY, { each = 0.08 })
  end)
  look.pip(f, 1440, 230, 440, 440, gb)
  rect { x = 0, y = GROUND, w = W, h = H - GROUND, fill = look.NIGHT, opacity = 0.85 }
  for i, it in ipairs(ITEMS) do
    do -- (above the frame until it drops)
      local x, y, angle = physics_at(pile, WALLS + i, f.seconds)
      local strike = progress(lb, landing(i) + 0.25, landing(i) + 0.5)
      group({ transform = { translate = { x, y }, rotate = angle }, shadow = look.SHADOW }, function()
        rect { x = -it.w / 2 - PAD, y = -PLATE_H / 2, w = it.w + 2 * PAD, h = PLATE_H, rx = 14, fill = look.NIGHT }
        text { it.text, x = -it.w / 2, y = 4, baseline = "middle", font = look.DISPLAY, size = SIZE, fill = look.INK }
        if strike > 0.01 then
          rect { x = -it.w / 2 - 10, y = -2, w = (it.w + 20) * strike, h = 12, rx = 6, fill = look.PINK }
        end
      end)
    end
  end
  local x, y = physics_at(pile, "ball", f.seconds)
  line { x1 = PIVOT[1], y1 = PIVOT[2], x2 = x, y2 = y, stroke = look.INK, stroke_width = 8 }
  circle { cx = x, cy = y, r = BALL, fill = look.NIGHT, stroke = look.INK, stroke_width = 6 }
  circle { cx = x - BALL * 0.35, cy = y - BALL * 0.35, r = BALL * 0.18, fill = look.INK, opacity = 0.5 }
end

-- Its sounds (sfx.lua): a tom as each thing lands on the stack, the ball's
-- whoosh into the smash, the smash (its tail covers the debris). Placed at
-- the impacts the simulation measured, which it timed to the beat.
local SOUNDS = {}
for i = 1, #NOT do
  local t = LANDED[WALLS + i]
  if t then SOUNDS[#SOUNDS + 1] = { sfx.tom(120 - (i - 1) * 8), start = t, gain_db = 20 * math.log(0.4, 10), bus = "sfx" } end
end
local SMASH = LANDED[BALL_AT]
if SMASH then
  SOUNDS[#SOUNDS + 1] = sfx.at("not_needed", SMASH_AT - 1, sfx.whoosh(sfx.seconds("not_needed", SMASH_AT - 1, 1)), 0.2)
  SOUNDS[#SOUNDS + 1] = { sfx.impact(), start = SMASH, gain_db = 20 * math.log(0.5, 10), pan = -0.2, bus = "sfx" }
end

local AT = score.time("not_needed")
scene { "NotNeeded", cue = "not_needed", start = AT, audio = SOUNDS, render = function(f)
  local gb = score.beat(f)
  not_needed(f, gb - score.beat(AT), gb)
end }
