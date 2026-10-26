-- Rigid-body physics: letter tiles dropped one by one onto a floor, a ball
-- lobbed in to bounce along their tops, a recorded sound per impact (a
-- wooden thud for a tile, a rubber ball's bounce for the ball: fetch.sh
-- downloads them). physics{} runs Box2D once at load (inside shared, so a
-- render's frame builders simulate it once); render samples it with
-- physics_at, and the impacts place the sound.
--
--     examples/physics_demo/fetch.sh
--     onimite strip examples/physics_demo/video.lua Drop -n 12 -o strip.png
--     onimite render examples/physics_demo/video.lua -o physics_demo.mp4

local W, H = 1280, 720
local FLOOR = 560                    -- the floor's top edge
local WORD = "onimite"
local TILE, GAP = 118, 10
local BALL = 46
local COLORS = { "#38bdf8", "#f472b6", "#facc15", "#4ade80", "#a78bfa", "#fb923c", "#f87171" }

video { width = W, height = H, fps = 60, background = "#0f172a",
  master_gain_db = 7 } -- the impacts at about -14 LUFS

local sim = shared("drop", function()
  local bodies = {
    { static = true, box = { W * 2, 40 }, x = W / 2, y = FLOOR + 20 },
  }
  local x0 = (W - #WORD * TILE - (#WORD - 1) * GAP) / 2 + TILE / 2
  for i = 1, #WORD do
    -- Tilted a touch, each its own way: they settle with a wobble.
    local wobble = hash(i, 7) * 2 - 1
    bodies[#bodies + 1] = { box = { TILE, TILE }, x = x0 + (i - 1) * (TILE + GAP) + wobble * 3,
      y = -TILE, angle = wobble * 4, vy = 400, start = 0.25 + stagger(i, 0.16), bounce = 0.15 }
  end
  -- A ball lobbed in from the left once the word stands: it bounces along the tops.
  bodies[#bodies + 1] = { circle = BALL, x = -BALL, y = 260, vx = 520, vy = -700, spin = 360,
    start = 2.4, density = 0.5, bounce = 0.7 }
  return physics { duration = 6, gravity = 2600, bodies = bodies }
end)

-- A sound per impact worth hearing: louder for harder hits, panned to where it
-- lands. The ball (the last body) bounces: one bounce of the recording (it
-- starts 0.84 s in), each tile thuds, pitched a little its own way.
local BALL_ID = #WORD + 2
local pops = {}
for k, c in ipairs(sim.contacts) do
  if c.speed > 300 then
    local pan = clamp((c.x / W) * 2 - 1, -0.8, 0.8)
    local gain = remap(c.speed, 300, 2500, -20, -2)
    if c.a == BALL_ID or c.b == BALL_ID then
      pops[#pops + 1] = { "bounce.mp3", start = c.t, offset = 0.82, stop = c.t + 0.35, gain_db = gain, pan = pan }
    else
      pops[#pops + 1] = { "thud.mp3", start = c.t, gain_db = gain - 4, pan = pan, speed = 0.92 + 0.16 * hash(k, 3) }
    end
  end
end

scene { "Drop", duration = 6, audio = pops, render = function(f)
  rect { x = 0, y = FLOOR, w = W, h = H - FLOOR, fill = "#1e293b" }
  -- the tiles fall in from above the canvas: a clip says the cut is meant
  group({ clip = { x = 0, y = 0, w = W, h = H } }, function()
    for i = 1, #WORD do
      local x, y, angle = physics_at(sim, i + 1, f.seconds)
      group({ transform = { translate = { x, y }, rotate = angle } }, function()
        rect { x = -TILE / 2, y = -TILE / 2, w = TILE, h = TILE, rx = 18, fill = COLORS[i] }
        text { WORD:sub(i, i), x = 0, y = 0, align = "center", baseline = "middle",
          font = "DM Sans", size = 96, fill = "#0f172a" }
      end)
    end
  end)
  local x, y, angle = physics_at(sim, #WORD + 2, f.seconds)
  group({ transform = { translate = { x, y }, rotate = angle } }, function()
    circle { cx = 0, cy = 0, r = BALL, fill = "#f8fafc" }
    rect { x = -6, y = -BALL, w = 12, h = BALL, fill = "#0f172a" } -- shows the spin
  end)
end }
