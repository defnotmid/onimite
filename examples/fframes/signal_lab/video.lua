-- fframes' signal-lab example: a 24 s motion study (product UI, data story,
-- technical explainer, closing card) over a synthesized soundtrack.
--
--     onimite render examples/fframes/signal_lab/video.lua -o signal_lab.mp4

local PAPER, INK, MUTED, LIME = "#eeeae2", "#152c2b", "#53645e", "#d2f87a"
local GREEN, GREY = "#709542", "#b4bdb1"
local FONT = "DM Sans"
local SCENE_SECONDS = 6

local EASE_CURVE = cubic_bezier(0.16, 1.0, 0.3, 1.0)
local SPRING = spring { mass = 1, stiffness = 180, damping = 20 }

-- 0 -> 1 over 0.8 s starting at `start`.
local function ramp(f, start)
  return animate(f, { { start, start + 0.8, 0, 1, EASE_CURVE } })
end
-- 56 -> 0 px spring (3 s runtime) starting at `start`.
local function rise(f, start)
  return animate(f, { { start = start, from = 56, to = 0, easing = SPRING } })
end

local function label(number, title)
  circle { cx = 209, cy = 147, r = 17, fill = GREEN }
  text { title, x = 252, y = 158, font = FONT, size = 30, weight = 500, fill = INK }
  text { number, x = 1728, y = 158, font = FONT, size = 30, weight = 500, fill = INK, align = "right" }
end

local function heading(str)
  local fitted = text_fit { str, font = FONT, size = 108, weight = 500, max_width = 1536 }
  text { fitted, x = 192, y = 314, font = FONT, size = 108, weight = 500,
    letter_spacing = -4, fill = INK }
end

local function t(str, x, y, size, fill, align)
  text { str, x = x, y = y, font = FONT, size = size, weight = 500, fill = fill, align = align }
end

video { width = 1920, height = 1080, fps = 30, background = "#ffffff",
  audio = {
    { "pulse.wav", start = 0, gain_db = 6.5, fade_in = 0.08, fade_out = 0.6 },
  },
  render = function(f)
    local progress = math.max(f.global_seconds / 24 * 1536, 0.5)
    rect { x = 0, y = 0, w = 1920, h = 1080, fill = PAPER }
    render_scenes(f)
    path { d = "M192 946 H1728", stroke = GREY, stroke_width = 2, fill = "none" }
    rect { x = 192, y = 945, w = progress, h = 3, fill = GREEN }
    t("FFRAMES / MOTION STUDIES", 192, 1002, 28, MUTED)
    t("24 SECONDS / SVG + RUST", 1728, 1002, 28, MUTED, "right")
  end,
}

scene { "Product", duration = SCENE_SECONDS, render = function(f)
  label("01 / 04", "PRODUCT ANNOUNCEMENT")
  text { "Signal.", x = 183, y = 445, font = FONT, size = 208, weight = 500, letter_spacing = -10, fill = INK }
  t("Your next release,", 192, 543, 52, INK)
  t("in motion.", 192, 610, 52, INK)
  group({ opacity = ramp(f, 0.4) }, function()
    rect { x = 192, y = 703, w = 380, h = 76, rx = 38, fill = INK }
    t("A FICTIONAL PRODUCT", 382, 753, 32, LIME, "center")
  end)
  group({ transform = translate(0, rise(f, 0)) }, function()
    rect { x = 1000, y = 262, w = 728, h = 576, rx = 32, fill = INK }
    circle { cx = 1095, cy = 352, r = 14, fill = LIME }
    t("Release / 01", 1138, 365, 38, PAPER)
    local rows = { { "Build", "Ready" }, { "Review", "Ready" }, { "Publish", "Ready" } }
    for i, row in ipairs(rows) do
      local start = 0.7 + (i - 1) * 0.12
      local y = 470 + (i - 1) * 105
      group({ opacity = ramp(f, start), transform = translate(0, rise(f, start)) }, function()
        rect { x = 1088, y = y - 46, w = 540, h = 82, rx = 14, fill = "#29403d" }
        t(row[1], 1124, y + 8, 38, PAPER)
        t(row[2], 1586, y + 8, 30, LIME, "right")
      end)
    end
    group({ transform = rotate(f.seconds * 8, 1650, 278) }, function()
      circle { cx = 1650, cy = 278, r = 73, fill = LIME }
      path { d = "M1616 278 H1684 M1650 244 V312 M1626 254 L1674 302 M1626 302 L1674 254",
        stroke = INK, stroke_width = 7, fill = "none" }
    end)
  end)
end }

scene { "Data", duration = SCENE_SECONDS, render = function(f)
  label("02 / 04", "DATA STORY")
  heading("Give numbers a rhythm.")
  local count = 76 * ramp(f, 0.55)
  text { string.format("%.0f", count), x = 180, y = 646, font = FONT, size = 248, weight = 500,
    letter_spacing = -12, fill = INK }
  t("Weekly activations", 192, 734, 46, INK)
  t("ILLUSTRATIVE DATA / WEEKS 01–04", 192, 802, 30, MUTED)
  local bars = { { "01", 24 }, { "02", 41 }, { "03", 58 }, { "04", 76 } }
  for i, b in ipairs(bars) do
    local p = ramp(f, 0.25 + (i - 1) * 0.1)
    local h = math.max(b[2] * 4.3 * p, 0.5)
    local x = 982 + (i - 1) * 188
    rect { x = x, y = 798 - h, w = 126, h = h, rx = 8, fill = i == 4 and GREEN or GREY }
    t(string.format("%.0f", b[2] * p), x + 63, 775 - h, 36, INK, "center")
    t(b[1], x + 63, 851, 30, MUTED, "center")
  end
end }

scene { "System", duration = SCENE_SECONDS, render = function(f)
  label("03 / 04", "TECHNICAL EXPLAINER")
  heading("Make the process visible.")
  group({ opacity = ramp(f, 0.4) }, function()
    path { d = "M632 591 H740 M1180 591 H1288", stroke = GREEN, stroke_width = 5, fill = "none" }
    path { d = "M718 577 L740 591 L718 605 M1266 577 L1288 591 L1266 605",
      stroke = GREEN, stroke_width = 5, fill = "none" }
  end)
  local cards = { { "01", "Describe", "Rust + SVG" }, { "02", "Inspect", "Frames + sound" },
                  { "03", "Render", "Video file" } }
  for i, c in ipairs(cards) do
    local x = 192 + (i - 1) * 548
    local start = 0.12 + (i - 1) * 0.1
    group({ opacity = ramp(f, start), transform = translate(0, rise(f, start)) }, function()
      rect { x = x, y = 440, w = 440, h = 302, rx = 24, fill = INK }
      t(c[1], x + 36, 505, 30, LIME)
      t(c[2], x + 36, 612, 64, PAPER)
      t(c[3], x + 36, 684, 32, GREY)
    end)
  end
  local travel = math.min(math.max(f.seconds - 1.2, 0) / 2.8, 1)
  local x = 1508 - 1096 * travel
  group({ opacity = ramp(f, 0.65) }, function()
    path { d = "M412 780 V824 H1508 V780", stroke = GREY, stroke_width = 3, fill = "none" }
    circle { cx = x, cy = 824, r = 12, fill = GREEN }
    t("REVISE AND REPEAT", 960, 894, 30, MUTED, "center")
  end)
end }

scene { "Final", duration = SCENE_SECONDS, render = function(f)
  local p, shift = ramp(f, 0.2), rise(f, 0.2)
  label("04 / 04", "CREATED WITH FFRAMES")
  group({ transform = translate(0, shift) }, function()
    text { "Built from code.", x = 183, y = 457, font = FONT, size = 146, weight = 500, letter_spacing = -6, fill = INK }
    text { "Ready to revise.", x = 183, y = 631, font = FONT, size = 146, weight = 500, letter_spacing = -6, fill = INK }
  end)
  group({ opacity = p }, function()
    rect { x = 192, y = 750, w = 1536, h = 90, rx = 16, fill = INK }
    t("PRODUCT DEMOS", 240, 809, 34, PAPER)
    circle { cx = 664, cy = 797, r = 7, fill = LIME }
    t("DATA STORIES", 716, 809, 34, PAPER)
    circle { cx = 1100, cy = 797, r = 7, fill = LIME }
    t("VISUAL EXPLAINERS", 1152, 809, 34, PAPER)
  end)
end }
