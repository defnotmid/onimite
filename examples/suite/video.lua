-- The suite as one piece: onimite, ovg, oksl and odecs used together in
-- every frame for 36 seconds. An SkSL world (oksl, media/world.sksl) warps
-- a group of shaped text and vector art (ovg: filters, blend modes,
-- masks, focal gradients) given to it as its `uniform shader` child, with
-- a WebP panorama on its horizon; the ovg rocket (an SVG animated by
-- element id) flies through it; alpha video clips decoded live by odecs
-- glow in portals and fold into the shader's kaleidoscope; the synthesized
-- music's beat and spectrum drive the uniforms. It ends on the suite's
-- structure under the four names.
--
--     onimite render examples/suite/video.lua -o suite.mp4

local beat = require("beat")
local ui = require("ui")
local T = require("timeline")
local track = require("track")
local world = require("world")

local clock, FPS = beat.clock, beat.FPS

local snap, soft = beat.snap, beat.soft
local sin, cos, pi, max, min = math.sin, math.cos, math.pi, math.max, math.min

-- Synthesized once per render, registered as a media clip.
audio_add("track.wav", track.build)

-- canyon.webp's size: the shader samples it in its own pixels.
local PANO_SIZE = { 4800, 928 }

-- Bars where the kick plays: the shader bulges and the picture pumps.
local KICKS = { { 8, T.BREAK }, { T.LOCKUP, T.END + 1 } }
local function kicking(b)
  for _, s in ipairs(KICKS) do if b >= s[1] and b < s[2] then return true end end
  return false
end

local function rgb3(hex)
  return { tonumber(hex:sub(2, 3), 16) / 255, tonumber(hex:sub(4, 5), 16) / 255, tonumber(hex:sub(6, 7), 16) / 255 }
end
local TINT_A, TINT_B = rgb3(ui.OVG), rgb3(ui.OKSL)
local TINT_B2 = rgb3(ui.ODECS)

-- ---- the world (oksl over ovg) -------------------------------------------

local function warp_at(b)
  if b < T.DROP then return 0.15 end
  if b < T.BREAK - 1 then return lerp(0.15, 1, snap(b - T.DROP)) end
  if b < T.LOCKUP then return 1 - progress(b, T.BREAK - 1, T.BREAK + 0.5) end
  return 0.1 * progress(b, T.LOCKUP, T.LOCKUP + 1)
end

local function draw_world(f, b, bands, kick)
  local bass = (bands[1] + bands[2] + bands[3] + bands[4]) / 4
  local k = progress(b, T.KALEIDO - 0.5, T.KALEIDO + 0.5) * (1 - progress(b, T.GLITCH, T.BREAK))
  local tb = clamp01(progress(b, T.KALEIDO, T.KALEIDO + 2) - progress(b, T.BREAK, T.BREAK + 2))
  shader(f, { src = "world.sksl", x = 0, y = 0, w = 1920, h = 1080,
    uniforms = {
      uWorld = function() world.draw(f, b, bands) end,
      uPano = "canyon.webp", uPanoSize = PANO_SIZE,
      uFade = progress(b, 0, 6), uWarp = warp_at(b), uPulse = kick, uBass = bass, uKaleido = k,
      -- the floor runs a row a beat, twice as fast after the drop
      uTravel = b * 0.5 + max(b - T.DROP, 0) * 0.5 - max(b - T.BREAK, 0) * 0.5 + max(b - T.LOCKUP, 0) * 0.5,
      uTintA = TINT_A,
      uTintB = { lerp(TINT_B[1], TINT_B2[1], tb), lerp(TINT_B[2], TINT_B2[2], tb), lerp(TINT_B[3], TINT_B2[3], tb) },
    } })
end

-- ---- the rocket (ovg's svg{} by element id) --------------------------------

-- Where the rocket is at beat b: rising (ignition), a figure of eight
-- (drop), an orbit round the kaleidoscope, a hover in the break, then up
-- and out as the names land. Position, heading (degrees), size.
local function path_at(b)
  if b < T.DROP then
    local r = soft((b - T.ROCKET_IN) * 0.35)
    return 960 + sin(b * 0.8) * 20, lerp(1300, 700, r), sin(b * 1.3) * 4, 300
  elseif b < T.KALEIDO then
    local t = (b - T.DROP) / 16 * 2 * pi
    local x, y = 960 + 720 * sin(t), 700 - 230 * sin(2 * t) - 160 * (1 - snap(b - T.DROP))
    local dx, dy = 720 * cos(t), -460 * cos(2 * t)
    return x, y, math.deg(math.atan(dx, -dy)), 260
  elseif b < T.BREAK then
    local t = (b - T.KALEIDO) / 8 * 2 * pi
    return 960 + 470 * sin(t), 540 - 470 * cos(t), math.deg(t) + 90, 220
  elseif b < T.LOCKUP then
    local h = soft((b - T.BREAK) * 0.5)
    return lerp(960, 1700, h), lerp(70, 330, h) + sin(b * 1.6) * 12, lerp(90, -10, h), lerp(220, 170, h)
  end
  -- out of the top as the names land
  local u = ease(easing.exponential_in, progress(b, T.LOCKUP, T.LOCKUP + 2.5))
  return lerp(1700, 1820, u), lerp(330 + sin(T.LOCKUP * 1.6) * 12, -300, u), lerp(-10, 10, u), lerp(170, 240, u)
end

local function rocket(b, kick)
  if b < T.ROCKET_IN then return end
  local trail = {}
  for i = 0, 18 do
    local x, y = path_at(b - i * 0.04)
    trail[#trail + 1] = x
    trail[#trail + 1] = y
  end
  -- the trail, bright at the rocket and gone 18 steps back
  group({ blend = "screen" }, function()
    for i = 1, 18 do
      line { x1 = trail[2 * i - 1], y1 = trail[2 * i], x2 = trail[2 * i + 1], y2 = trail[2 * i + 2],
        stroke = ui.ODECS, stroke_width = 26 * (1 - i / 19), stroke_opacity = 0.5 * (1 - i / 19),
        line_cap = "round" }
    end
  end)
  local x, y, ang, s = path_at(b)
  local flicker = 0.85 + 0.25 * hash(math.floor(b * 16)) + 0.35 * kick
  group({ transform = { translate = { x, y }, rotate = ang }, shadow = { dx = 0, dy = 0, blur = 30,
    color = ui.ODECS, opacity = 0.35 + 0.4 * kick } }, function()
    svg { src = "rocket.svg", x = -s / 2, y = -s / 2, w = s, h = s, overrides = {
      flame = { transform = scale(1, flicker, 200, 262) },
      flame_core = { opacity = 0.6 + 0.4 * kick },
      fin_l = { transform = rotate(-6 * kick, 150, 190) },
      fin_r = { transform = rotate(6 * kick, 250, 190) },
      window_glass = { fill = ({ ui.OVG, ui.OKSL, ui.ODECS, ui.ONIMITE })[math.floor(b) % 4 + 1] },
      star1 = { visible = false }, star2 = { visible = false }, star3 = { visible = false },
    } }
  end)
end

-- ---- the portals (odecs' alpha clips, composited live) -------------------------

local function glow(color)
  return { filter = {
    { "blur", std = 16, input = "SourceAlpha", result = "b" },
    { "flood", color = color, opacity = 0.95, result = "c" },
    { "composite", op = "in", input = "c", input2 = "b", result = "g" },
    { "merge", "g", "SourceGraphic" },
  } }
end

local PORTALS = {
  { src = "transparent.mov", label = "ProRes 4444 + alpha · .mov", color = ui.OVG, x = 420 },
  { src = "avatar_vp9_alpha.webm", label = "VP9 + alpha · .webm", color = ui.OKSL, x = 1500 },
}
local PR = 230

local function portals(f, b, kick)
  for i, p in ipairs(PORTALS) do
    local at = T.PORTALS[i]
    local open = snap(b - at)
    -- at the kaleidoscope both dive into the centre
    local dive = ease(easing.exponential_in, progress(b, T.KALEIDO - 1, T.KALEIDO))
    if open > 0.001 and dive < 1 then
      local cx = lerp(p.x, 960, dive)
      local cy = 520 + sin((b - at) * pi / 4) * 14
      local s = open * (1 - dive) * (1 + 0.03 * kick)
      group({ transform = { scale = s, origin = { cx, cy } } }, function()
        -- the portal: a lit disc, the clip masked to it, a rim
        group({ mask = function() circle { cx = cx, cy = cy, r = PR, fill = "#ffffff" } end }, function()
          circle { cx = cx, cy = cy, r = PR, fill = radial_gradient { cx = cx, cy = cy, r = PR, fx = cx - 70,
            fy = cy - 90, stops = { { 0, p.color }, { 0.45, "#141826" }, { 1, ui.BG } } }, opacity = 0.9 }
          group(glow(p.color), function()
            video_frame(f, { src = p.src, x = cx - 400, y = cy - 200, w = 800, h = 450, looping = true,
              start_from = clock.time(at) })
          end)
        end)
        circle { cx = cx, cy = cy, r = PR, fill = "none", stroke = p.color, stroke_width = 6 }
        circle { cx = cx, cy = cy, r = PR + 18, fill = "none", stroke = p.color, stroke_width = 2,
          stroke_dasharray = { 10, 14 }, stroke_dashoffset = b * 20 * (i == 1 and 1 or -1), opacity = 0.7 }
        ui.chip(cx - 190, cy + PR + 30, p.label, p.color, ui.BG, 24, snap(b - at - 0.5))
      end)
    end
  end
end

-- ---- captions and the lockup ---------------------------------------------------

-- One line at a time at the bottom left, true of what is on screen.
local CAPTIONS = {
  { 1, "video.lua → onimite: a Lua script, rendered by a native Odin engine" },
  { T.DROP, "oksl compiles world.sksl · ovg draws its child group · svg{} flies the rocket by id" },
  { T.PORTALS[1], "odecs decodes ProRes 4444 and VP9 with alpha, live on the frame clock" },
  { T.KALEIDO, "the VP9 clip, drawn inside the shader's child group, folded six ways" },
  { T.BREAK, "one frame clock, four libraries" },
}

local function caption(b)
  if b >= T.LOCKUP then return end
  local cur
  for _, c in ipairs(CAPTIONS) do if b >= c[1] then cur = c end end
  if not cur then return end
  local a = progress(b, cur[1], cur[1] + 0.5) * (1 - progress(b, T.LOCKUP - 1, T.LOCKUP))
  group({ opacity = a, transform = translate((1 - snap(b - cur[1])) * -40, 0) }, function()
    rect { x = 60, y = 1010, w = 6, h = 34, fill = ui.ONIMITE }
    text { cur[2], x = 82, y = 1036, font = ui.MONO, size = 26, fill = ui.TEXT }
  end)
end

local NAMES = { { "onimite", ui.ONIMITE }, { "ovg", ui.OVG }, { "oksl", ui.OKSL }, { "odecs", ui.ODECS } }
local NAME_SIZE, SEP = 96, "  ·  "
-- The row's layout, measured once at load.
local NAME_X = {}
do
  local widths, sep, total = {}, text_width { SEP, font = ui.SANS, size = NAME_SIZE }, 0
  for i, n in ipairs(NAMES) do
    widths[i] = text_width { n[1], font = ui.SANS, size = NAME_SIZE }
    total = total + widths[i] + (i > 1 and sep or 0)
  end
  local x = 960 - total / 2
  for i = 1, #NAMES do
    NAME_X[i] = x
    x = x + widths[i] + sep
  end
  NAME_X.sep = sep
end

local function lockup(b)
  if b < T.LOCKUP then return end
  group({ filter = { { "blur", std = 14, result = "b" }, { "merge", "b", "SourceGraphic" } } }, function()
    for i, n in ipairs(NAMES) do
      local at = T.NAMES[i]
      local p = snap(b - at)
      if p > 0.001 then
        group({ opacity = clamp01(p * 2), transform = translate(0, (1 - p) * 60) }, function()
          text { n[1], x = NAME_X[i], y = 300, font = ui.SANS, size = NAME_SIZE, fill = n[2] }
          if i > 1 then
            text { SEP, x = NAME_X[i] - NAME_X.sep, y = 300, font = ui.SANS, size = NAME_SIZE, fill = ui.DIM }
          end
        end)
      end
    end
  end)
  local l = snap(b - T.LINE)
  if l > 0.001 then
    group({ opacity = clamp01(l * 2), transform = translate(0, (1 - l) * 30) }, function()
      text { "one binary, all Odin, Lua scripts", x = 960, y = 400, align = "center", font = ui.SANS, size = 52,
        fill = ui.TEXT }
    end)
  end
end

-- ---- the frame -----------------------------------------------------------------

local function picture(f, b)
  local kick = kicking(b) and pulse(b, 6) or 0.25 * pulse(b, 6)
  local bands = ui.spectrum(f, 16)
  draw_world(f, b, bands, kick)
  portals(f, b, kick)
  rocket(b, kick)
  caption(b)
  lockup(b)
end

-- Impacts flash, the beat before the break glitches for three frames.
local FLASHES = { T.DROP, T.LOCKUP }
local GLITCH_FRAME = clock.frame(T.BREAK, FPS)

video {
  width = 1920, height = 1080, fps = FPS, background = ui.BG,
  duration = { frames = clock.frame(T.TOTAL, FPS) },
  audio = { { "track.wav", start = 0, fade_out = 0.5, curve = "equal_power", gain_db = 5 } },
  -- audio analyze: about -14 LUFS, true peaks under -1 dBTP
  master_gain_db = 1.6,
  limiter = { ceiling_db = -3 },
  render = function(f)
    local b = clock.beat(f.global_seconds)
    rect { x = 0, y = 0, w = 1920, h = 1080, fill = ui.BG }
    local pump = 1 + (kicking(b) and pulse(b, 9) or 0) * 0.006
    local since = f.global_index - GLITCH_FRAME
    group({ transform = { scale = pump, origin = { 960, 540 } } }, function()
      if since >= 0 and since < 3 then
        -- the picture splits in bands pushed sideways
        for i = 0, 5 do
          local dx = (hash(i * 13 + since * 7) - 0.5) * 160 * (1 - since / 3)
          group({ transform = translate(dx, 0), clip = { x = 0, y = i * 180, w = 1920, h = 180 } }, function()
            picture(f, b)
          end)
        end
      else
        picture(f, b)
      end
    end)
    local flash = 0
    for _, d in ipairs(FLASHES) do
      if b >= d then flash = max(flash, math.exp(-(b - d) * 5)) end
    end
    if flash > 0.01 then rect { x = 0, y = 0, w = 1920, h = 1080, fill = ui.TEXT, opacity = flash * 0.4 } end
    -- out to black over the last beat
    local out = progress(b, T.TOTAL - 1, T.TOTAL)
    if out > 0 then rect { x = 0, y = 0, w = 1920, h = 1080, fill = "#000000", opacity = out } end
  end,
}
