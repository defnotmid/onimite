-- A talk: each scene is a slide, played and then held at its end until the
-- presenter clicks on (Right, Space, Page Down or a clicker; Left goes back,
-- B blacks the screen, P pauses):
--
--     onimite preview examples/talk/video.lua --present
--
-- A held slide keeps moving (hold = "alive", the default): the title's
-- backdrop drifts, the 3D slide keeps turning. Builds are scenes too: each
-- draws the bullets before it where they settled and brings in the next. The
-- bounce slide plays again while held (hold = "loop"); the "One more thing"
-- card plays straight on into the last slide (hold = false). Rendered, the
-- same script is the recorded talk, with a chapter per slide.

video { width = 1280, height = 720, fps = 60, background = "#0b1020", motion_blur = { shutter = 180 } }

local INK, DIM, ACCENT = "#f1f5f9", "#94a3b8", "#38bdf8"
local FADE = { "fade", duration = 0.4 }

-- what arrives: up from below, settling on a spring
local function arrive(f, delay)
  local s = { start = delay, stop = delay + 0.6, from = 0, to = 1, easing = spring { stiffness = 170, damping = 17 } }
  return animate(f, { s })
end

local function heading(f, label, delay)
  local k = arrive(f, delay or 0)
  text { label, x = 120, y = 170 + 30 * (1 - k), font = "DM Sans", size = 64, fill = INK, opacity = k }
end

-- a drifting backdrop: soft discs on slow orbits (the motion that shows a
-- held slide is alive)
local function backdrop(f)
  for i = 1, 5 do
    local a = f.global_seconds * (0.12 + 0.05 * i) + i * 1.7
    circle { cx = 640 + math.cos(a) * (180 + 60 * i), cy = 360 + math.sin(a * 1.3) * (90 + 20 * i), r = 140 + 25 * i,
      fill = i % 2 == 0 and ACCENT or "#6366f1", opacity = 0.07 }
  end
end

scene { "Motion as data", duration = 2.5, render = function(f)
  backdrop(f)
  local k = arrive(f, 0.2)
  text { "Motion as data", x = 640, y = 330 + 30 * (1 - k), font = "DM Sans", size = 96, align = "center", fill = INK, opacity = k }
  local k2 = arrive(f, 0.6)
  text { "a talk in one script", x = 640, y = 410, font = "DM Sans", size = 36, align = "center", fill = DIM, opacity = k2 }
end }

-- the build: three scenes, one bullet each, the earlier ones in place
local BULLETS = { "Every frame is a function of time", "Scenes are the slides", "The script is the talk and the recording" }
local function bullets(f, shown)
  heading(f, "Three ideas", shown == 1 and 0 or -1)
  for i = 1, shown do
    local k = i == shown and arrive(f, 0.1) or 1
    local y = 290 + (i - 1) * 90
    if k > 0 then circle { cx = 140, cy = y - 14, r = 9 * k, fill = ACCENT } end
    text { BULLETS[i], x = 175 - 20 * (1 - k), y = y, font = "DM Sans", size = 40, fill = INK, opacity = k }
  end
end
scene { "Three ideas", duration = 1.2, transition = FADE, render = function(f) bullets(f, 1) end }
scene { "Three ideas 2", duration = 1, render = function(f) bullets(f, 2) end }
scene { "Three ideas 3", duration = 1, render = function(f) bullets(f, 3) end }

-- 3D: the knot keeps turning while the slide is held
scene { "Turning", duration = 2, transition = FADE, render = function(f)
  heading(f, "Held, it keeps turning")
  view3d {
    x = 640, y = 220, w = 560, h = 440,
    camera = { fov = 35, position = { 0, 0.6, 6 }, target = { 0, 0, 0 } },
    lights = {
      { type = "HemisphereLight", color = "#dbe6ff", ground_color = "#1e1b4b", intensity = 1.2 },
      { type = "DirectionalLight", color = "#ffffff", intensity = 2.5, position = { 3, 5, 4 } },
    },
    meshes = {
      { geometry = { type = "TorusGeometry", radius = 1.3, tube = 0.42, radial_segments = 48, tubular_segments = 128 },
        rotation = { f.seconds * 0.7, f.seconds * 1.1, 0 },
        material = { type = "MeshStandardMaterial", color = ACCENT, metalness = 0.3, roughness = 0.35 } },
    },
  }
end }

-- a loop: the bounce plays again while the slide is held
scene { "Bounce", duration = 1.6, hold = "loop", transition = FADE, render = function(f)
  heading(f, "Held, it plays again")
  local u = f.seconds / 1.6
  local h = math.abs(math.sin(u * math.pi * 2)) * (1 - u * 0.5)
  circle { cx = 340 + 600 * u, cy = 600 - 300 * h, r = 34, fill = ACCENT }
  rect { x = 120, y = 634, w = 1040, h = 4, fill = DIM, opacity = 0.4 }
end }

-- a card that doesn't wait: it plays straight on into the last slide
scene { "One more thing", duration = 1, hold = false, transition = FADE, render = function(f)
  local k = arrive(f, 0)
  text { "One more thing", x = 640, y = 380, font = "DM Sans", size = 56, align = "center", fill = DIM, opacity = k }
end }

scene { "Thanks", duration = 2, transition = FADE, render = function(f)
  backdrop(f)
  local k = arrive(f, 0.1)
  text { "Thanks", x = 640, y = 360 + 30 * (1 - k), font = "DM Sans", size = 110, align = "center", fill = INK, opacity = k }
  text { "onimite render video.lua: the recorded talk, a chapter per slide", x = 640, y = 440, font = "DM Sans", size = 28,
    align = "center", fill = DIM, opacity = arrive(f, 0.5) }
end }
