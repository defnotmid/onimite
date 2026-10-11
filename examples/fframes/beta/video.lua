-- fframes' beta example: the 32 s "Welcome to the beta of fframes" video.
-- Seven scenes: heading, code demo with Ferris, "native / GPU rendering",
-- an iPhone with a Discord invite and a dynamic island visualising the
-- music, the GitHub page, the bundled examples (hello world, marketing,
-- podcast and TikTok videos playing in a rounded preview) and the logo.
--
--     onimite render examples/fframes/beta/video.lua -o beta.mp4
--
-- The embedded example videos live in hello.lua, marketing.lua, podcast.lua
-- and tiktok.lua; Ferris and the SVG helpers in shared.lua.

local shared = dofile("shared.lua")
local render_hello = dofile("hello.lua")
local render_marketing = dofile("marketing.lua")
local render_podcast = dofile("podcast.lua")
local render_tiktok = dofile("tiktok.lua")
local svg_viewport, ferris = shared.svg_viewport, shared.ferris

local W, H, FPS = 1920, 1080, 60

-- Texts without a font-family use fframes' default font, "Inter" in this
-- example (RenderOptions.default_font). It isn't installed where the
-- reference frames were rendered, so fframes skips those texts ("No match
-- for 'Inter' font-family"): the Discord names and messages, the clock, the
-- QR caption and the island's invite. Set a family here (and add its font to
-- media/) to draw them.
local DEFAULT_FONT = nil

local function spring_(m, k, d) return spring { mass = m, stiffness = k, damping = d } end
local SPRING_TEXT = spring_(1.0, 100, 16)

-- ---- HeadingScene -------------------------------------------------------------------------

local HEADING_X1 = { { 0, nil, -400, 260, SPRING_TEXT } }
local HEADING_X2 = { { 0, nil, 1000, 660, SPRING_TEXT } }

scene { "HeadingScene", duration = 3, render = function(f)
  text { "Welcome to the beta", font = "DM Sans", weight = 700, x = animate(f, HEADING_X1), y = 0.4 * H,
    size = 150, fill = "#000000" }
  local spans
  if f.index < 100 then
    spans = { { "of " }, { "fframes" } }
  else
    spans = { { "of " },
      { "ff", dy = 10, size = 190, weight = 400, font = "Bubble Bobble", fill = "#7450d9" },
      { "rames", size = 190, weight = 400, font = "Bubble Bobble" } }
  end
  text { font = "DM Sans", weight = 700, fill = "#000000", x = animate(f, HEADING_X2), y = 0.6 * H,
    size = 150, spans = spans }
end }

-- ---- CodeDemoScene ------------------------------------------------------------------------

local CODE_TILT = { { 0.3, 3.3, -0.4, 1.2, linear } }
local CODE_X = {
  { 0.2, nil, -500, 50, linear },
  { 0.5, nil, 50, 65, linear },
  { 3.8, 4.0, 65, -2000, linear },
}
local CODE_OPACITY = { { 0.3, 0.8, 0, 1, linear } }
local CODE_FERRIS_X = {
  { 0.0, nil, 2444, 1245, spring_(1.45, 130, 20) },
  { 3.8, 4.0, 1245, 3920, linear },
}
local CODE_EYE_R = {
  { 1.4, 1.54, 727, 777, linear },
  { 1.7, 1.84, 777, 727, linear },
  { 1.9, 2.04, 727, 777, linear },
  { 2.1, 2.24, 777, 727, linear },
}
local CODE_EYE_L = {
  { 1.4, nil, 520, 570, linear },
  { 1.7, nil, 570, 520, linear },
  { 1.9, nil, 520, 570, linear },
  { 2.1, 2.3, 570, 520, linear },
}
-- beta_code.png is 790x766: width 1023 gives an automatic height.
local CODE_IMAGE_H = 1023 * 766 / 790

scene { "CodeDemoScene", duration = { frames = 200 }, render = function(f)
  local tilt = animate(f, CODE_TILT)
  -- fframes' Transform order: translate, skewX, skewY (nested groups keep it).
  group({ transform = { translate = { animate(f, CODE_X), 0 }, skew_x = tilt } }, function()
    group({ transform = { skew_y = -tilt + 0.4 } }, function()
      local op = animate(f, CODE_OPACITY)
      if op > 0 then
        image { src = "beta_code.png", x = 0, y = 50, w = 1023, h = CODE_IMAGE_H, opacity = op }
      end
    end)
  end)
  local eye_r, eye_l = animate(f, CODE_EYE_R), animate(f, CODE_EYE_L)
  svg_viewport(animate(f, CODE_FERRIS_X), 250, 500, 500, 1200, 800, function() ferris(eye_r, eye_l) end)
end }

-- ---- RenderingScene -----------------------------------------------------------------------

local GPU_SECOND = 1.1
local RENDER_X1 = { { 0, nil, -400, 260, spring_(0.6, 300, 26) }, { 0.3, 2.2, 260, 310, linear } }
local RENDER_X2 = { { 0, nil, 1900, 460, spring_(0.6, 300, 26) }, { 0.3, 2.2, 460, 410, linear } }
local BASE_FPS = { { GPU_SECOND, GPU_SECOND + 0.8, 60, 100, linear } }
local PROGRESS_W = { { 0, 0.8, 900, 1000, linear }, { GPU_SECOND, GPU_SECOND + 1, 1000, 1350, linear } }
local PROGRESS = linear_gradient { units = "bbox", x1 = 0, y1 = 0, x2 = 1, y2 = 0,
  stops = { { 0, "#aa83de" }, { 1, "#00d4ff" } } }

-- The original adds `rand::random() * 4` to the fps counter, a different
-- number on every render; this is a deterministic stand-in (an LCG on the
-- frame number) with the same range.
local function random01(n)
  return ((n * 1103515245 + 12345) % 2147483648) / 2147483648
end

scene { "RenderingScene", duration = { frames = 140 }, render = function(f)
  local gpu = f.seconds > GPU_SECOND
  local fps_counter = math.floor(animate(f, BASE_FPS) + random01(f.global_index) * 4) % 256

  text { "With the power of", font = "DM Sans", weight = 700, x = animate(f, RENDER_X1), y = 0.3 * H,
    size = 150, fill = "#000000" }
  text { font = "DM Sans", weight = 700, x = animate(f, RENDER_X2), y = 0.5 * H, size = 150, fill = "#000000",
    spans = {
      gpu and { "  GPU    ", weight = 400, size = 170, font = "Bubble Bobble", fill = "#7450d9" }
        or { "native ", weight = 900, size = 150, font = "DM Sans", fill = "#7450d9" },
      { "     rendering" },
    } }
  text { "Rendering fps: " .. fps_counter, y = 0.7 * H, x = 0.11 * W, fill = "#4b5563",
    font = "JetBrains Mono", size = 45, weight = 600 }
  rect { fill = PROGRESS, x = 0.1 * W, y = 0.72 * H, rx = 12, ry = 12, h = 30, w = animate(f, PROGRESS_W) }
end }

-- ---- IphoneScene --------------------------------------------------------------------------

local HOURS, MINUTES = 12, 4
local SEND_MESSAGE_TS, EXPAND_ISLAND_TS = 4.8, 6.2
local ISLAND_W = {
  { 0.0, nil, 120, 180, spring_(1.6, 400, 26) },
  { EXPAND_ISLAND_TS, nil, 180, 348, spring_(1.6, 300, 26) },
}
local ISLAND_H = { { EXPAND_ISLAND_TS, nil, 40, 80, spring_(1.6, 300, 26) } }
local QR_OPACITY = { { 1.1, 1.4, 0, 1, linear } }
local INVITE_SCALE = { { 2.5, 2.7, 1, 1.04, linear } }
local DISCORD_Y = { { 3.0, nil, 1800, 0, spring_(0.4, 70, 16) } }
local SEND_Y = { { SEND_MESSAGE_TS, nil, 200, 0, spring_(1.0, 240, 26) } }
local SEND_SCALE = { { SEND_MESSAGE_TS, nil, 0.4, 1, spring_(1.0, 220, 26) } }
local SEND_OPACITY = { { SEND_MESSAGE_TS, SEND_MESSAGE_TS + 0.2, 0, 1, linear } }

-- <clipPath id="iphoneUi"><rect width=380 height=820 rx=60 x=780 y=150/>
local IPHONE_UI = { clip_path = "M840 150 H1100 A60 60 0 0 1 1160 210 V910 A60 60 0 0 1 1100 970 H840 A60 60 0 0 1 780 910 V210 A60 60 0 0 1 840 150 Z" }
local CLOCK = string.format("%02d:%02d", HOURS, MINUTES)
local QR_CORNERS = {
  "M832 439V415C832 402.297 842.297 392 855 392H882",
  "M1086 392H1110C1122.7 392 1133 402.297 1133 415V442",
  "M1133 650V674C1133 686.703 1122.7 697 1110 697H1083",
  "M879 697H855C842.297 697 832 686.703 832 674V647",
}
local GITHUB_ICON = "M12 2C6.477 2 2 6.477 2 12c0 4.419 2.865 8.166 6.839 9.489.5.09.682-.218.682-.484 0-.236-.009-.866-.014-1.699-2.782.602-3.369-1.34-3.369-1.34-.455-1.157-1.11-1.465-1.11-1.465-.909-.62.069-.608.069-.608 1.004.071 1.532 1.03 1.532 1.03.891 1.529 2.341 1.089 2.91.833.091-.647.349-1.086.635-1.337-2.22-.251-4.555-1.111-4.555-4.943 0-1.091.39-1.984 1.03-2.682-.103-.254-.447-1.27.097-2.646 0 0 .84-.269 2.75 1.025A9.548 9.548 0 0112 6.836c.85.004 1.705.114 2.504.336 1.909-1.294 2.748-1.025 2.748-1.025.546 1.376.202 2.394.1 2.646.64.699 1.026 1.591 1.026 2.682 0 3.841-2.337 4.687-4.565 4.935.359.307.679.917.679 1.852 0 1.335-.012 2.415-.012 2.741 0 .269.18.579.688.481A9.997 9.997 0 0022 12c0-5.523-4.477-10-10-10z"

-- `transform-origin` percentages resolve against the 1920x1080 viewport.
local CENTER = { 960, 540 }
local BOTTOM_CENTER = { 960, 1080 }

local function discord_message(x, y, name, content, image_src)
  image { src = image_src, x = x, y = y, w = 80, h = 80 }
  if DEFAULT_FONT then
    text { name, x = x + 80, y = y + 34, font = DEFAULT_FONT, weight = 500, size = 18, fill = "#ffffff" }
    text { content, x = x + 80, y = y + 60, font = DEFAULT_FONT, weight = 500, size = 15, fill = "#cbd5e1" }
  end
end

scene { "IphoneScene", duration = 8, render = function(f)
  local island_w = animate(f, ISLAND_W)
  local island_h = animate(f, ISLAND_H)
  -- The scene frame, as in the original (scene-relative audio position).
  local vis = audio_spectrum(f, { src = "beta.mp3", sample_size = 16, smooth = 3 }) or {}

  group(IPHONE_UI, function()
    -- The iPhone background rect fills with "url(#pattern1)", which is not
    -- defined: SVG renders nothing for it.
    image { src = "camera_ui.png", w = 370, h = 819, x = 790, y = 154 }
    image { src = "qr.png", w = 300, h = 300, x = 830, y = H // 2 - 150 }
    local op = animate(f, QR_OPACITY)
    if op > 0 then
      group({ opacity = op }, function()
        for _, d in ipairs(QR_CORNERS) do
          path { d = d, stroke = "#ebbd1d", stroke_width = 2, fill = "none" }
        end
        local s = animate(f, INVITE_SCALE)
        group({ transform = { scale = s, origin = CENTER } }, function()
          rect { x = 884, y = 715, fill = "#ebbd1d", w = 200, h = 34, rx = 16 }
          if DEFAULT_FONT then
            text { "fframes discord invite", font = DEFAULT_FONT, size = 16, weight = 500, x = 905, y = 737, fill = "#000000" }
          end
        end)
      end)
    end
  end)

  group(IPHONE_UI, function()
    group({ transform = translate(0, animate(f, DISCORD_Y)) }, function()
      rect { x = 790, y = 154, w = 370, h = 819, fill = "#292841" }
      image { src = "discord_ui.png", w = 370, h = 819, x = 791, y = 152 }
      if DEFAULT_FONT then
        text { CLOCK, font = DEFAULT_FONT, weight = 500, x = 830, y = 196, fill = "#9ca3af", size = 16 }
      end
      discord_message(800, 370, "John Doe", "Hey, How I can export the .webm video?", "john.png")
      discord_message(800, 450, "Dmitriy Kovalenko", "Just change out file extension to .webm", "dmitriy.png")
      discord_message(800, 530, "Linus Torvalds", "https://github.com/torvalds", "torvalds.png")
      local op = animate(f, SEND_OPACITY)
      if op > 0 then
        group({ opacity = op, transform = { translate = { 0, animate(f, SEND_Y) }, scale = animate(f, SEND_SCALE),
          origin = BOTTOM_CENTER } }, function()
          discord_message(800, 620, "Me", "https://github.com/theawesome", "me.png")
        end)
      end
    end)
  end)

  -- iphone_frame.png is 480x544: width 800 at x=30%, y=10%.
  image { src = "iphone_frame.png", x = 0.3 * W, y = 0.1 * H, w = 800, h = 800 * 544 / 480 }

  rect { x = 916 - (island_w - 120) / 2, y = 170, w = island_w, h = island_h, ry = island_h / 2, fill = "#000000" }

  if f.index > 8 and f.seconds < EXPAND_ISLAND_TS then
    text { "ff", font = "Bubble Bobble", fill = "#6366f1", size = 23, x = 895, y = 197 }
    -- .skip(1).take(6)
    for i = 1, 6 do
      local v = vis[i + 1] or 0
      local db = math.max(4, math.min(18, 10 * math.log(v * 500, 10)))
      rect { x = 1025 + i * 3.5 + i, y = 190 - db / 2, w = 3, h = db, ry = 1, fill = "#6366f1" }
    end
  elseif f.seconds > EXPAND_ISLAND_TS + 0.2 then
    svg_viewport(816, 182, 56, 56, 24, 24, function()
      path { d = GITHUB_ICON, fill = "#ffffff" }
    end)
    if DEFAULT_FONT then
      text { "New collaboration invite", font = DEFAULT_FONT, weight = 500, size = 18, x = 880, y = 208, fill = "#ffffff" }
      text { "dmtrKovalenko invites you to fframes", font = DEFAULT_FONT, weight = 500, size = 14, x = 880, y = 230, fill = "#cbd5e1" }
    end
  end
end }

-- ---- GithubScene --------------------------------------------------------------------------

local GITHUB_X = { { 0.0, nil, 1920, 0, spring_(0.3, 90, 26) } }
local GITHUB_Y = { { 0.8, 6.3, 0, -1700, linear } }
-- github_screenshot.png is 2560x5166, shown 1920 wide.
local GITHUB_H = 1920 * 5166 / 2560

scene { "GithubScene", duration = 5, overlap = { previous = 0.3 }, render = function(f)
  group({ transform = translate(animate(f, GITHUB_X), animate(f, GITHUB_Y)) }, function()
    image { src = "github_screenshot.png", x = 0, y = 0, w = 1920, h = GITHUB_H }
  end)
end }

-- ---- BetaExamples -------------------------------------------------------------------------

local VIDEO_SCALE = 0.62
local VIDEO_OFFSET_Y = 320
local VIDEO_OFFSET_X = (1920 - 1920 * VIDEO_SCALE) / 2
local VIDEO_W, VIDEO_H = 1920 * VIDEO_SCALE, 1080 * VIDEO_SCALE
local MARKETING_TS, PODCAST_TS, TIKTOK_TS = 2.6, 4.8, 6.8

local TEXT_GRADIENT = linear_gradient { units = "bbox", x1 = 0, y1 = 0, x2 = 1, y2 = 0,
  stops = { { 0, "#4338ca" }, { 1, "#a21caf" } } }
local SUBTITLE_X = { { 0, nil, 200, 960, SPRING_TEXT } }
local HELLO_X = { { 0, nil, 1700, 960, SPRING_TEXT } }
local TITLES_SPRING = spring_(1.0, 140, 16)
local TITLES_Y = {
  { MARKETING_TS, nil, 0, -180, TITLES_SPRING },
  { PODCAST_TS, nil, -180, -380, TITLES_SPRING },
  { TIKTOK_TS, nil, -380, -580, TITLES_SPRING },
}
-- <clipPath id="text-clip"><rect width="100%" height="135" y="115"/>
local TEXT_CLIP = { clip = { x = 0, y = 115, w = 1920, h = 135 } }
-- filter="url(#shadow)": feDropShadow stdDeviation 40, flood-opacity 0.3
-- (dx = dy = 2), in sRGB, over the region x/y -10%, width/height 200% of
-- the rect (which cuts the top of the shadow).
local SHADOW = {
  filter = { { "drop_shadow", std = 40, dx = 2, dy = 2, color = "#000000", opacity = 0.3 },
    region = { x = -0.1, y = -0.1, w = 2, h = 2 } },
  srgb = true,
}
local PREVIEW_CLIP = { clip_path = string.format(
  "M%g %g H%g A50 50 0 0 1 %g %g V%g A50 50 0 0 1 %g %g H%g A50 50 0 0 1 %g %g V%g A50 50 0 0 1 %g %g Z",
  VIDEO_OFFSET_X + 50, VIDEO_OFFSET_Y, VIDEO_OFFSET_X + VIDEO_W - 50,
  VIDEO_OFFSET_X + VIDEO_W, VIDEO_OFFSET_Y + 50, VIDEO_OFFSET_Y + VIDEO_H - 50,
  VIDEO_OFFSET_X + VIDEO_W - 50, VIDEO_OFFSET_Y + VIDEO_H, VIDEO_OFFSET_X + 50,
  VIDEO_OFFSET_X, VIDEO_OFFSET_Y + VIDEO_H - 50, VIDEO_OFFSET_Y + 50,
  VIDEO_OFFSET_X + 50, VIDEO_OFFSET_Y) }
local PREVIEW_LANDSCAPE = { transform = { translate = { VIDEO_OFFSET_X, VIDEO_OFFSET_Y }, scale = VIDEO_SCALE } }
local PREVIEW_PORTRAIT = { transform = { translate = { VIDEO_OFFSET_X + 1188, VIDEO_OFFSET_Y }, rotate = 90,
  scale = VIDEO_SCALE } }

-- The podcast and TikTok videos get `frame.into_global()`.
local global_frame = { fps = FPS }

scene { "BetaExamples", duration = { frames = 500 }, render = function(f)
  text { "to help you get started", font = "DM Sans", weight = 700, align = "center",
    x = animate(f, SUBTITLE_X), y = 0.08 * H, size = 60, fill = TEXT_GRADIENT }

  group(TEXT_CLIP, function()
    group({ transform = translate(0, animate(f, TITLES_Y)) }, function()
      text { "\"Hello world\" video", x = animate(f, HELLO_X), y = 220, font = "DM Sans", weight = 700,
        fill = "#000000", align = "center", size = 120 }
      text { "Marketing Pitch Video", x = 960, y = 394, font = "DM Sans", weight = 700, fill = "#000000",
        align = "center", size = 120 }
      text { "Podcast Visualization", x = 960, y = 594, font = "DM Sans", weight = 700, fill = "#000000",
        align = "center", size = 120 }
      text { "TikTok-like video", x = 960, y = 794, font = "DM Sans", weight = 700, fill = "#000000",
        align = "center", size = 120 }
    end)
  end)

  group(SHADOW, function()
    rect { w = VIDEO_W, h = VIDEO_H, x = VIDEO_OFFSET_X, y = VIDEO_OFFSET_Y, rx = 50, ry = 50,
      fill = "#000000", stroke = "#4338ca", stroke_width = 8 }
  end)

  local s = f.seconds
  group(PREVIEW_CLIP, function()
    group(s >= TIKTOK_TS and PREVIEW_PORTRAIT or PREVIEW_LANDSCAPE, function()
      if s < MARKETING_TS then
        render_hello(f)
      elseif s < PODCAST_TS then
        render_marketing(f)
      else
        global_frame.index = f.global_index
        global_frame.seconds = f.global_seconds
        global_frame.global_index = f.global_index
        global_frame.global_seconds = f.global_seconds
        if s < TIKTOK_TS then render_podcast(global_frame) else render_tiktok(global_frame) end
      end
    end)
  end)
end }

-- ---- EndScene -----------------------------------------------------------------------------

local END_OPACITY = { { 0.1, 0.2, 0, 1, linear } }
local BETA_OPACITY = { { 0.6, 0.8, 0, 1, linear } }
local BETA_ROTATE = { { 0.6, 0.8, rotate(-60, 1300, 590), rotate(-25, 1300, 590), linear } }
local END_TEXT = linear_gradient { units = "bbox", x1 = 0, y1 = 0, x2 = 1, y2 = 0,
  stops = { { 0, "#4338ca" }, { 1, "#a21caf" } } }

scene { "EndScene", duration = 2, render = function(f)
  local op = animate(f, END_OPACITY)
  if op > 0 then
    text { font = "Bubble Bobble", size = 190, x = 0.5 * W, y = 0.5 * H, align = "center", opacity = op,
      fill = "#000000", spans = { { "ff", fill = "#7450d9" }, { "rames" } } }
  end
  local bop = animate(f, BETA_OPACITY)
  if bop > 0 then
    group({ transform = animate(f, BETA_ROTATE) }, function()
      text { "beta", size = 80, x = 1220, y = 605, fill = END_TEXT, font = "Fredoka One", opacity = bop }
    end)
  end
end }

video { width = W, height = H, fps = FPS, background = "#ffffff",
  audio = {
    { "beta.mp3", start = 0 },
    { "pop.mp3", start = { frame = 95 } },
    { "pop.mp3", start = { frame = 440 } },
  },
  render = function(f)
    image { src = "background.png", x = 0, y = 0, w = W, h = H }
    render_scenes(f)
  end,
}
