-- The breakdown: the loop an agent runs while it makes a video, with real
-- output of fframes' command line on the hi-hat hits. Ends on "this video
-- was made by an agent".

local beat = require("beat")
local ui = require("ui")
local prompt = require("scenes.prompt")
local prog, expo_in, cubic_in_out, snap, usize = beat.prog, beat.expo_in, beat.cubic_in_out, beat.snap, beat.usize
local ORANGE, BONE, GREY, BG, DIM, MONO, DISPLAY, SERIF =
  ui.ORANGE, ui.BONE, ui.GREY, ui.BG, ui.DIM, ui.MONO, ui.DISPLAY, ui.SERIF
local Slam = ui.Slam

local M = { name = "AgentsScene", start = 160, stop = 208 }

-- Global beats of the stutter hits that bring in a new card.
M.CARD_BEATS = { 175, 179, 183, 187, 191, 195 }

local NODES = { "WRITE", "TIMELINE", "INSPECT", "STRIP", "FRAME", "RENDER" }

-- Output of the commands, as fframes printed it for this video: `lines`
-- or an image with its aspect ratio. `node` counts from 0.
local CARDS = {
  { node = 1, command = "cargo run -- timeline", lines = {
    { "1920x1080 @ 60 fps, 7650 frames (127.50s)", BONE },
    { "#0   PromptScene      0.00s..2.15s", GREY },
    { "#1   OriginScene      2.15s..16.70s", GREY },
    { "#2   CodeScene       16.70s..23.97s", GREY },
    { "#3   GpuScene        23.97s..27.60s", GREY },
    { "audio music.wav       0.000s..127.500s", ORANGE } } },
  { node = 2, command = "cargo run -- inspect", lines = {
    { "checked 540 frames: 13 findings", BONE },
    { "0 errors · 13 warnings: marquee rows and", GREY },
    { "type that overflows the canvas on purpose", GREY } } },
  { node = 3, command = "cargo run -- strip all -n 30", image = { "strip_self.jpg", 1.887 } },
  { node = 4, command = "cargo run -- frame Shader@2.7s", image = { "frame_self.jpg", 1.778 } },
  { node = 0, command = "cargo run -- audio analyze", lines = {
    { "integrated -14.1 LUFS, range 10.3 LU", BONE },
    { "true peak -1.2 dBTP, clipped samples 0", BONE },
    { "GpuScene        23.97s..27.60s   -13.0 LUFS", GREY },
    { "BenchmarkScene  45.78s..60.33s   -13.0 LUFS", GREY } } },
  { node = 5, command = "cargo run -- render --draft", lines = {
    { "out.mp4 frames 0..7650 (0.00s..127.50s)", GREY },
    { "960x540 in 5.3s", ORANGE } } },
}

local RING_X, RING_Y, RING_R = 1370, 590, 250
local TAU, HALF_PI = 2 * math.pi, math.pi / 2

local function ring(lb, lit)
  local draw = cubic_in_out(prog(lb, 2, 5))
  local circ = TAU * RING_R
  group({ transform = rotate(-90, RING_X, RING_Y) }, function()
    circle { cx = RING_X, cy = RING_Y, r = RING_R, fill = "none", stroke = GREY, stroke_width = 1.5,
      stroke_dasharray = { circ * draw, circ } }
  end)
  circle { cx = RING_X, cy = RING_Y, r = RING_R - 30, fill = "none", stroke = DIM, stroke_width = 1,
    stroke_dasharray = { 4, 8 }, opacity = draw }
  -- comet: one lap per 8 beats, a short trail behind it
  if lb > 5 then
    for k = 0, 9 do
      local t = (lb - 5) / 8 - k * 0.008
      local a = -HALF_PI + t * TAU
      circle { cx = RING_X + math.cos(a) * RING_R, cy = RING_Y + math.sin(a) * RING_R, r = 7 - k * 0.5, fill = ORANGE,
        opacity = 1 - k / 10 }
    end
  end
  for idx, name in ipairs(NODES) do
    local i = idx - 1
    local a = -HALF_PI + i / #NODES * TAU
    local x, y = RING_X + math.cos(a) * RING_R, RING_Y + math.sin(a) * RING_R
    local at = 2.5 + i * 0.4
    local s = snap(lb - at)
    local on = lit == i
    local lx = RING_X + math.cos(a) * (RING_R + 44)
    local ly = RING_Y + math.sin(a) * (RING_R + 44) + 8
    local anchor = math.cos(a) > 0.3 and "start" or (math.cos(a) < -0.3 and "end" or "middle")
    local size = 18 + (on and 8 or 0)
    group({ opacity = prog(lb, at, at + 0.1) }, function()
      rect { x = x - size / 2, y = y - size / 2, w = size * math.max(s, 0.05), h = size * math.max(s, 0.05),
        fill = on and ORANGE or BG, stroke = on and ORANGE or BONE, stroke_width = 2 }
      text { name, x = lx, y = ly, align = anchor, font = MONO, weight = 600, size = 22, letter_spacing = 3,
        fill = on and ORANGE or BONE }
    end)
  end
  group({ opacity = prog(lb, 4, 4.5) }, function()
    text { "the agent", x = RING_X, y = RING_Y - 6, align = "middle", font = SERIF, italic = true, size = 64, fill = BONE }
    text { "NEVER WATCHES A VIDEO", x = RING_X, y = RING_Y + 36, align = "middle", font = MONO, weight = 500, size = 18,
      letter_spacing = 3, fill = GREY }
  end)
end

-- A terminal card: the command, then its output lines or image.
local function card(c, l)
  local x, y, w = 150, 440, 800
  local enter = snap(l)
  local typed = math.min(usize((l / 0.5) * #c.command), #c.command)
  local command = c.command:sub(1, typed)
  local h
  if c.lines then
    h = 90 + #c.lines * 36 + 20
  else
    h = 84 + (w - 56) / c.image[2] + 28
  end
  group({ opacity = prog(l, 0, 0.08), transform = translate((1 - enter) * -80, 0) }, function()
    rect { x = x, y = y, w = w, h = h, fill = "#0e0d0c", fill_opacity = 0.92, stroke = "#3d3a35", stroke_width = 1.5 }
    rect { x = x, y = y, w = 4, h = h, fill = ORANGE }
    text { "$", x = x + 28, y = y + 52, font = MONO, weight = 600, size = 25, fill = ORANGE }
    if command ~= "" then
      text { command, x = x + 58, y = y + 52, font = MONO, weight = 500, size = 25, fill = BONE }
    end
    rect { x = x + 28, y = y + 70, w = w - 56, h = 1, fill = "#3d3a35" }
    if c.lines then
      for i, line in ipairs(c.lines) do
        local o = prog(l, 0.5 + (i - 1) * 0.08, 0.55 + (i - 1) * 0.08)
        text { line[1], x = x + 28, y = y + 110 + (i - 1) * 36, font = MONO, weight = 500, size = 23, fill = line[2],
          opacity = o }
      end
    else
      local iw = w - 56
      group({ opacity = prog(l, 0.45, 0.6) }, function()
        image { src = c.image[1], x = x + 28, y = y + 84, w = iw, h = iw / c.image[2] }
      end)
    end
  end)
end

-- THIS VIDEO WAS / MADE BY AN AGENT.
local function confession(l)
  local c = prog(l, 3, 3.4)
  local collapse = expo_in(prog(l, 7.3, 8))
  local s = 1 - collapse * 0.15
  group({ opacity = 1 - collapse, transform = string.format("translate(960 540) scale(%s) translate(-960 -540)", s) },
    function()
      Slam(150, 470, "THIS VIDEO WAS", DISPLAY, 138, BONE):draw(l, 0, 160)
      Slam(150, 630, "MADE BY AN AGENT.", DISPLAY, 138, ORANGE):draw(l - 1, 0, 160)
      text { "in Rust, with fframes. No timeline editor was opened.", x = 156, y = 712, font = SERIF, italic = true,
        size = 54, fill = BONE, opacity = c }
    end)
end

-- Before the first command: the prompt from the cold open, again.
local function prompt_card(l)
  if l < 0 then return end
  local s = prompt.PROMPT
  local typed = math.min(usize((l / 3) * #s), #s)
  local shown = s:sub(1, typed)
  local first, second = shown, ""
  if #shown > 33 then first, second = shown:sub(1, 33), shown:sub(34) end
  local enter = snap(l)
  group({ opacity = prog(l, 0, 0.1), transform = translate((1 - enter) * -80, 0) }, function()
    text { "IT STARTS WITH A PROMPT", x = 150, y = 480, font = MONO, weight = 500, size = 20, letter_spacing = 3, fill = GREY }
    rect { x = 150, y = 510, w = 800, h = 150, fill = "#0e0d0c", fill_opacity = 0.92, stroke = ORANGE, stroke_width = 2 }
    text { "›", x = 180, y = 572, font = MONO, weight = 600, size = 32, fill = ORANGE }
    if first ~= "" then text { first, x = 220, y = 572, font = MONO, weight = 500, size = 32, fill = BONE } end
    if second ~= "" then text { second, x = 220, y = 620, font = MONO, weight = 500, size = 32, fill = BONE } end
  end)
end

function M.render(f, lb)
  shader(f, { src = "shaders/contour.sksl", x = 0, y = 0, w = 1920, h = 1080, uniforms = {
    uWell = { RING_X / 1920, RING_Y / 1080 }, uDepth = 0.9, uDensity = 20, uBright = 0.3 * prog(lb, 0, 2),
    uInk = "#8a857c", uHot = ORANGE } })
  if lb >= 40 then return confession(lb - 40) end
  local title_a = snap(lb)
  local title_b = snap(lb - 1.5)
  local exit = expo_in(prog(lb, 39.6, 40))
  -- which card is on screen
  local active
  for i, b in ipairs(M.CARD_BEATS) do if lb >= b - 160 then active = i end end
  group({ opacity = 1 - exit }, function()
    group({ transform = translate(0, (1 - title_a) * 60), opacity = prog(lb, 0, 0.1) }, function()
      text { "BUILT FOR THE", x = 150, y = 235, font = DISPLAY, size = 110, letter_spacing = -4, fill = BONE }
    end)
    group({ transform = translate(0, (1 - title_b) * 60), opacity = prog(lb, 1.5, 1.6) }, function()
      text { "AGENTIC LOOP.", x = 150, y = 345, font = DISPLAY, size = 110, letter_spacing = -4, fill = ORANGE }
    end)
    ring(lb, active and CARDS[active].node)
    if active then
      card(CARDS[active], lb - (M.CARD_BEATS[active] - 160))
    else
      prompt_card(lb - 6)
    end
  end)
end

return M
