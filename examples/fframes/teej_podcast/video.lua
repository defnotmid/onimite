-- fframes' teej-podcast example as an onimite script: two synced podcast
-- video feeds side by side in clipped, bordered frames, and a chapter list
-- whose orange highlighter springs to the current chapter.
--
--     onimite render examples/fframes/teej_podcast/video.lua -o teej_podcast.mp4
--
-- The original loads `left.mp4` / `right.mp4` from `dynamic_media/` at run
-- time; the copies in media/ are the 5 minute stand-ins that ship with it.

local W, H = 1920, 1080

-- constants.rs
local FRAME_PADDING, FRAME_WIDTH, FRAME_HEIGHT = 40, 640, 1000
local CHAPTERS_START_X = FRAME_WIDTH * 2 + FRAME_PADDING * 3
local CHAPTERS_START_Y = 145
local CHAPTER_HEIGHT, CHAPTER_WIDTH, CHAPTER_PADDING = 60, 490, 15
local CHAPTER_TEXT_PADDING = 10
local CHAPTER_FONT_SIZE, CHAPTER_FONT_WEIGHT = 26, 400
local CHAPTER_FONT_FAMILY = "Sofia Sans Semi Condensed"

-- chapter.rs
local function parse_duration_to_seconds(s)
  local a, b, c = s:match("^(%d+):(%d+):?(%d*)$")
  if c ~= "" then return tonumber(a) * 3600 + tonumber(b) * 60 + tonumber(c) end
  return tonumber(a) * 60 + tonumber(b)
end

local function chapter(title, start)
  return { title = title, start = start, start_seconds = parse_duration_to_seconds(start) }
end

local function chapter_y(index) -- 0-based, as Chapter::get_y_position
  return CHAPTERS_START_Y + index * (CHAPTER_HEIGHT + CHAPTER_PADDING)
end

-- main.rs
local CHAPTERS = {
  chapter("Introduction to Lunch Bites Podcast", "00:00"),
  chapter("Tech Sponsorships and Streaming Quality", "01:51"),
  chapter("Flexing in LA: The Casa Bonita Experience", "02:33"),
  chapter("Viral Moments: The Post-It Note Debate", "03:00"),
  chapter("Zuckerberg's Rebranding and Tech Culture", "04:51"),
  chapter("The Intersection of Geek Culture and Popularity", "14:55"),
  chapter("Psychedelic Fantasy Baseball and AI", "16:48"),
  chapter("The Rise of Meme Coins", "17:52"),
  chapter("Trump Coin and the Crypto Circus", "19:13"),
  chapter("Fart Coin: The AI Millionaire", "21:50"),
  chapter("OpenAI and the Future of AI Models", "25:46"),
  chapter("Influencers and the Coding Landscape", "30:10"),
}

-- create_transition_keyframes_for_chapters: one spring per chapter start
-- from the previous position to this chapter's offset (the spring's own
-- length, at most the 1 s window, decides when it lands).
local CHAPTER_EASING = spring { mass = 0.45, stiffness = 130, damping = 20 }
local CHAPTER_KEYS = {}
do
  local current = 0
  for i, c in ipairs(CHAPTERS) do
    local new_position = chapter_y(i - 1) - CHAPTERS_START_Y
    CHAPTER_KEYS[i] = { start = c.start_seconds, stop = c.start_seconds + 1,
      from = current, to = new_position, easing = CHAPTER_EASING }
    current = new_position
  end
end

-- TeejPodcast::fit_titles: each title fitted (text_fit, "…" marker) to the
-- chapter width after its "mm:ss" and separator, measured at load.
local FITTED_TITLES = {}
do
  local font, size, weight = CHAPTER_FONT_FAMILY, CHAPTER_FONT_SIZE, CHAPTER_FONT_WEIGHT
  local separator_width = text_width { "  ", font = font, size = size, weight = weight }
  local max_width = CHAPTER_WIDTH - CHAPTER_TEXT_PADDING * 2
  for i, c in ipairs(CHAPTERS) do
    local prefix_width = text_width { c.start, font = font, size = size, weight = weight } + separator_width
    FITTED_TITLES[i] = text_fit { c.title, font = font, size = size, weight = weight,
      max_width = math.max(max_width - prefix_width, 0) }
  end
end

local SEPARATOR = "  "

-- The <use href="#left-video-frame" fill="none" stroke="#000" stroke-width="10"/>
-- border and the clipped <image>: the 1280x720 feed at width 1920 (height
-- auto: 1080), xMidYMid meet, inside the frame's clip rect.
local function feed(f, src, frame_x, image_x)
  rect { x = frame_x, y = FRAME_PADDING, w = FRAME_WIDTH, h = FRAME_HEIGHT,
    fill = "none", stroke = "#000000", stroke_width = 10 }
  group({ clip = { x = frame_x, y = FRAME_PADDING, w = FRAME_WIDTH, h = FRAME_HEIGHT } }, function()
    video_frame(f, { src = src, x = image_x, y = 0, w = 1920, h = 1080, fit = "contain",
      start_from = 0, looping = false })
  end)
end

video { width = W, height = H, fps = 24, background = "#ffffff",
  -- Duration::Auto: the end of the audio map, both feeds to their end.
  duration = { video = "left.mp4" },
  audio = {
    { "left.mp4", start = 0 },
    { "right.mp4", start = 0 },
  },
  render = function(f)
    -- The chapter containing the current second; the last stays active.
    local t = math.floor(f.seconds)
    local active_index = #CHAPTERS
    for i = 1, #CHAPTERS - 1 do
      if t >= CHAPTERS[i].start_seconds and t < CHAPTERS[i + 1].start_seconds then
        active_index = i
        break
      end
    end

    rect { x = 0, y = 0, w = 1920, h = 1080, fill = "#1A191B" }

    feed(f, "left.mp4", FRAME_PADDING, -600)
    feed(f, "right.mp4", FRAME_WIDTH + FRAME_PADDING * 2, 8)

    text { "2D: Rust", x = 1400, y = 40, baseline = "hanging", size = 75, fill = "#ffffff",
      font = "JetBrains Mono" }

    -- The chapters rendered as rectangles
    for i = 1, #CHAPTERS do
      rect { x = CHAPTERS_START_X, y = chapter_y(i - 1), w = CHAPTER_WIDTH, h = CHAPTER_HEIGHT,
        fill = "#404040", rx = 5, ry = 5 }
    end

    -- Highlighter renders on top of the rectangles but under the text
    group({ transform = translate(0, animate(f, CHAPTER_KEYS)) }, function()
      rect { x = CHAPTERS_START_X, y = CHAPTERS_START_Y, w = CHAPTER_WIDTH, h = CHAPTER_HEIGHT,
        fill = "#ff6900", rx = 5, ry = 5 }
    end)

    -- The text is rendered on top of either highlighter or rectangle.
    for i, c in ipairs(CHAPTERS) do
      text { x = CHAPTERS_START_X + CHAPTER_TEXT_PADDING,
        y = chapter_y(i - 1) + CHAPTER_HEIGHT // 2 + 5, baseline = "middle",
        fill = i == active_index and "#000000" or "#ffffff",
        font = CHAPTER_FONT_FAMILY, weight = CHAPTER_FONT_WEIGHT, size = CHAPTER_FONT_SIZE,
        spans = { { c.start }, { SEPARATOR }, { FITTED_TITLES[i] } } }
    end
  end,
}
