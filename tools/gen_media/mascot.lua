-- Pip, the mascot (examples/common/pip.lua), dancing at 120 BPM on a
-- transparent background: a seamless 2 second loop (640x360, 30 fps). gen.sh
-- renders it to PNGs and encodes them as ProRes 4444 (.mov) and VP9 with
-- alpha (.webm), the alpha clips the examples composite.
--
--     onimite render tools/gen_media/mascot.lua -o frames/
--
-- Every motion repeats in the loop: a hop on each beat with squash and
-- stretch, a sway every two beats, a blink once a loop, the fuse sparking,
-- and pixel sparkles popping around.

local pip = dofile("../../examples/common/pip.lua")

local W, H, FPS, LOOP, BEAT = 640, 360, 30, 2, 0.5
local SIZE = 280
local CX, FLOOR = W / 2, 340 -- where Pip's feet land
local TAU, sin, abs = 2 * math.pi, math.sin, math.abs

-- Pixel sparkles: where and when they pop (beats into the loop), their colour.
local SPARKLES = {
  { 140, 120, 0.25, "#ffe14d" }, { 500, 90, 1.25, "#ff9db4" }, { 110, 230, 2.25, "#ffa38f" },
  { 530, 210, 3.25, "#ffe14d" }, { 190, 60, 0.75, "#ffffff" }, { 450, 150, 2.75, "#ffffff" },
}

local function sparkle(x, y, u, color)
  -- a four-point pixel star that grows and fades over half a beat
  local px = 8
  local a = 1 - u
  local r = math.floor(u * 3 + 1)
  for i = -r, r do
    rect { x = x + i * px, y = y, w = px, h = px, fill = color, opacity = a, shape_rendering = "crispEdges" }
    if i ~= 0 then rect { x = x, y = y + i * px, w = px, h = px, fill = color, opacity = a, shape_rendering = "crispEdges" } end
  end
end

video { width = W, height = H, fps = FPS, duration = LOOP, background = "transparent", render = function(f)
  local t = f.seconds
  local ph = t / BEAT -- beats
  local hop = abs(sin(math.pi * ph)) -- 0 on each beat, 1 between
  local lift = 34 * hop ^ 1.4
  local sway = 6 * sin(TAU * t / (2 * BEAT)) -- degrees, a sway every two beats

  -- the shadow shrinks as Pip lifts
  group({ opacity = 0.35 - 0.15 * hop }, function()
    ellipse { cx = CX, cy = FLOOR + 4, rx = SIZE * 0.32 * (1 - 0.25 * hop), ry = 10, fill = "#1b1220" }
  end)
  group({ transform = { translate = { 0, -lift }, rotate = sway, origin = { CX, FLOOR } } }, function()
    pip.draw(t, { x = CX - SIZE / 2, y = FLOOR - SIZE * 0.86, size = SIZE, beat = ph,
      blink = (t % LOOP) > 1.3 and (t % LOOP) < 1.43 })
  end)
  for _, s in ipairs(SPARKLES) do
    local u = ((ph - s[3]) % (LOOP / BEAT)) / 0.5
    if u >= 0 and u < 1 then sparkle(s[1], s[2], u, s[4]) end
  end
end }
