-- fframes' `made-of-motion` example: a 489-frame, 1440x1080 analog / pixel
-- collage film with pixel objects, a continuous perspective carousel,
-- thermal performances, paper texture and per-exposure vector ink, ending on
-- seven flying letters assembling into the fframes wordmark.
--
--     onimite render examples/fframes/made_of_motion/video.lua -o made-of-motion.mp4
--
-- Modules mirror the original's files: objects.lua (the wheel, flights and
-- impacts, computed for every frame when the script loads), hero.lua (the
-- three feature cards), flight.lua (the wordmark letters), ink.lua and
-- vector_ink.lua (the decompressed vector ink archives), opening.lua (the
-- opening typography) and the *_capture.lua tables of measured poses.

local ui = require("ui")
local objects = require("objects")
local hero = require("hero")
local flight = require("flight")
local ink_module = require("ink")
local opening = require("opening")
local opening_capture = require("opening_capture")
local restoration_capture = require("restoration_capture")
local label = ui.label

local W, H = 1440, 1080

-- Source frame boundaries, end exclusive. Keep these aligned to the music edit.
local EDIT = {
  { "Question", 48, "question" },
  { "Signal", 93, "signal" },
  { "Portrait", 153, "portrait" },
  { "ThermalCut", 157, "thermal" },
  { "Orbit", 200, "ring" },
  { "Code", 220, "code" },
  { "CarouselA", 237, "carousel" },
  { "Motion", 253, "motion" },
  { "CarouselB", 265, "carousel" },
  { "Feeling", 286, "feeling" },
  { "OrbitReturn", 302, "ring" },
  { "Scatter", 331, "scatter" },
  { "Human", 382, "hand" },
  { "M", 389, "pulse", 0 },
  { "O", 397, "pulse", 1 },
  { "V", 403, "pulse", 2 },
  { "E", 413, "pulse", 3 },
  { "Fframes", 489, "signature" },
}

-- Static data, built once when the script loads (MadeOfMotion::new).
local frames, impacts = objects.choreography()
local letters = flight.new()
local ink = ink_module.new(impacts)
local heroes = hero.new(frames)

local studio = { ink = ink }

local function full(f, src, uniforms)
  shader(f, { src = src, x = 0, y = 0, w = W, h = H, uniforms = uniforms })
end

function studio.background(f, mode, vignette)
  full(f, "shaders/paper.sksl", { uMode = mode, uVignette = vignette })
end

local SIGNAL_POSES = {
  [0] = { 1240, 540, 170, 670, 0, 0.42 },
  [1] = { 550, 540, 680, 660, 0.17, 0.42 },
  [2] = { 350, 540, 740, 950, -0.68, 0.38 },
}

function studio.signal(f)
  local n = f.index
  local pose = SIGNAL_POSES[n] or opening_capture.STAR[math.min(n - 3, 37) + 1]
  full(f, "shaders/signal.sksl", {
    uPose = { pose[1], pose[2], pose[3], pose[4] }, uAngle = pose[5], uPower = pose[6],
  })
end

function studio.print(f, strength)
  full(f, "shaders/print.sksl", { uStrength = strength })
end

function studio.objects(f)
  for _, o in ipairs(frames[math.min(f.global_index, 488)]) do o:draw(f) end
end

function studio.performance(f, file)
  full(f, "shaders/performance.sksl", { uSource = { src = file } })
end

function studio.hand(f)
  local h = restoration_capture.HAND[math.min(f.index, 50) + 1]
  full(f, "shaders/hand.sksl", {
    uField = "hand-field.png", uAtlas = { h[1], h[2] }, uRect = { h[3], h[4], h[5], h[6] },
  })
end

function studio.thermal_cut(f)
  full(f, "shaders/thermal_cut.sksl", {})
  group({ opacity = animate(f, { { 0.0, 0.125, 0, 0.94, ease_out } }) }, function()
    studio.objects(f)
  end)
end

local STACK_LIGHT = radial_gradient { cx = 0.5, cy = 0.5, r = 0.5, units = "bbox",
  stops = { { 0, "#e8e8df" }, { 1, "#e8e8df00" } } }

local function pulse(f, index)
  local mode = 0
  if index == 1 or (index == 3 and f.index < 3) then mode = 1
  elseif index == 2 then mode = 2 end
  local color = index == 0 and "#27221c" or "#ede9df"
  local icons = { 3, 0, 7, 4 }
  studio.background(f, mode, index == 3 and 1.35 or 0.5)
  objects.hero(icons[index + 1], 720, 540, 370, f.global_index * 0.13):draw(f)
  local word = { "M", "O", "V", "E" }
  for i = 0, index do
    label(word[i + 1], 250 + i * 312, 552, 32, color, true)
  end
end

local function signature(f)
  local poses = letters[math.min(f.index, 75) + 1]
  local chars = { "f", "f", "r", "a", "m", "e", "s" }
  studio.background(f, 0, 0.025)
  ink.draw_signature(f, poses)
  group({ opacity = animate(f, { { 2.625, 2.666667, 1, 0, ease_out } }) }, function()
    for i, ch in ipairs(chars) do
      local p = poses[i]
      group({ transform = string.format("translate(%s %s) rotate(%s) scale(%s)",
        p.position[1], p.position[2], p.angle, p.scale) }, function()
        text { ch, x = 0, y = 0, align = "center", font = "Instrument Serif", italic = true,
          size = 54, fill = "#35221b", stroke = "#35221b", stroke_width = 0.35 }
      end)
    end
  end)
  group({ opacity = animate(f, { { 2.625, 2.666667, 0, 1, ease_out } }) }, function()
    group({ transform = translate(720, 540) }, function()
      group({ transform = animate(f, {
        { 2.666667, 2.833333, scale(2.8), scale(1), cubic_bezier(0.12, 0.92, 0.20, 1) },
      }) }, function()
        text { "fframes", x = 0, y = 39, align = "center", font = "Instrument Serif", italic = true,
          size = 194, letter_spacing = -5, fill = "#24201b" }
      end)
    end)
    group({
      opacity = animate(f, { { 2.833333, 3.083333, 0, 1, ease_out } }),
      transform = animate(f, { { 2.833333, 3.083333, translate(0, 12), translate(0, 0), ease_out } }),
    }, function()
      text { "video, written in code.", x = 720, y = 643, align = "center", font = "JetBrains Mono",
        size = 19, letter_spacing = 1, fill = "#4b4136" }
      circle { cx = 720, cy = 703, r = 4.5, fill = "#eb6c35" }
    end)
  end)
end

local RENDER = {}

function RENDER.question(f)
  studio.background(f, 0, 0)
  if f.index ~= 0 then opening.draw(f) end
  ink.draw_question(f)
end

function RENDER.signal(f)
  local color = f.index == 0 and "#f4eee0" or "#161616"
  studio.signal(f)
  group({ opacity = animate(f, { { 1.25, 1.375, 1, 0, ease_in } }) }, function()
    studio.objects(f)
  end)
  ink.draw(f)
  text { x = 720, y = 554, font = "Inter 24pt", weight = 700, size = 54, letter_spacing = -1.25,
    fill = color, align = "center", spans = {
      { "how do " },
      { "you", fill = f.index >= 39 and "#fff4df" or color },
      { " turn a few lines of code into a feeling?" },
    } }
end

function RENDER.portrait(f)
  local n = f.index
  local copy = n <= 34 and "you don’t." or n <= 38 and "you give" or n <= 42 and "you give it"
    or "you give it fframes."
  local color = n >= 51 and "#181714" or "#f3eee1"
  studio.performance(f, "portrait-clean.mp4")
  ink.draw(f)
  label(copy, 208, 554, 46, color, false)
end

RENDER.thermal = studio.thermal_cut

local function wheel(scatter)
  return function(f)
    studio.background(f, 0, 0.08)
    studio.objects(f)
    ink.impacts_draw(f)
    ink.draw(f)
    if scatter and f.index > 23 then label("from your mind", 720, 552, 32, "#1d1916", true) end
  end
end
RENDER.ring, RENDER.carousel, RENDER.scatter = wheel(false), wheel(false), wheel(true)

function RENDER.code(f) hero.draw(heroes, f, studio, "code") end
function RENDER.motion(f) hero.draw(heroes, f, studio, "motion") end
function RENDER.feeling(f) hero.draw(heroes, f, studio, "feeling") end

function RENDER.hand(f)
  local n = f.index
  if n == 0 then
    studio.background(f, 1, 0)
    ellipse { cx = 720, cy = 535, rx = 76, ry = 184, fill = STACK_LIGHT }
    for i = 0, 11 do
      local x = 720 + math.cos(i * 0.55) * 130
      objects.hero(i, x, 150 + i * 65, 170, i * 0.13):draw(f)
    end
  else
    studio.hand(f)
  end
  local copy = n <= 2 and "from" or n <= 5 and "from your" or "from your mind"
  ink.draw(f)
  label(copy, 208, 554, 42, "#f1ecdf", false)
  group({ opacity = animate(f, { { 0.416667, 0.625, 0, 1, ease_out } }) }, function()
    label("to every frame.", 1050, 554, 42, "#f1ecdf", false)
  end)
end

RENDER.signature = signature

local AUDIO = { { "soundtrack.wav", start = 0 } }

video {
  width = W, height = H, fps = 24, background = "#000000", duration = { frames = 489 },
  audio = AUDIO,
  -- The original mixes without gain changes or limiting.
  limiter = false,
}

local start = 0
for _, shot in ipairs(EDIT) do
  local name, stop, kind, index = shot[1], shot[2], shot[3], shot[4]
  local draw = RENDER[kind]
  local live = kind == "portrait" or kind == "thermal" or kind == "hand"
  local light = kind == "code" or kind == "motion" or kind == "feeling"
  scene { name, duration = { frames = stop - start }, render = function(f)
    if kind == "pulse" then pulse(f, index) else draw(f) end
    if not (live or (kind == "question" and f.index == 0)) then
      ink_module.dust(f, light)
      studio.print(f, 0.045)
    end
  end }
  start = stop
end
