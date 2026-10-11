-- opening.rs: opening typography, source-timed rulers, lateral camera moves
-- and selection collapse.
local ui = require("ui")
local label, QUESTION = ui.label, ui.QUESTION

local M = {}

-- The pixel-block capture of the oversized type on frame 13 (SVG path data).
local TYPE_PATH = (function()
  local file = assert(io.open(SCRIPT_DIR .. "/opening-type.path", "rb"))
  local d = file:read("a")
  file:close()
  return d
end)()

-- The question up to its `count`-th space.
local function prefix(count)
  local stop, spaces = #QUESTION, 0
  for i = 1, #QUESTION do
    if QUESTION:sub(i, i) == " " then
      spaces = spaces + 1
      if spaces == math.max(count, 1) then
        stop = i - 1
        break
      end
    end
  end
  return QUESTION:sub(1, stop)
end

local COLLAPSE = {
  [14] = {
    "M220 548 L223 516 L240 526 L230 536 L250 550 M281 528 L301 543 M330 526 L344 516 L335 541 M374 523 L365 541 M409 528 L427 544 M465 526 L454 544 M501 529 L511 545 M538 529 L551 543 M578 537 H777 M830 542 L853 530 M881 540 L899 523",
    "M0 0",
    5,
  },
  [15] = {
    "M144 517 V540 H175 M212 540 H257 M286 540 H302 M329 540 H342 M377 540 H389 M408 540 H430 M500 540 H507 M549 540 H647 M709 540 L723 520 L739 540 H759",
    "M1100 448 H1115 M1107 490 V519 M1107 563 V586",
    4,
  },
  [16] = {
    "M178 539 H218 M292 539 H303 M325 539 H394 M513 539 H557 M577 539 H587 M628 539 H638 M681 539 H691 M710 539 H733",
    "M905 470 V508 M905 551 V581",
    2.5,
  },
  [17] = {
    "M114 539 H122 M143 539 H161 M221 539 H250 M276 539 H292 M320 539 H350 M377 539 H419 M454 539 H472 M491 539 H528 M571 539 H593 M641 539 H659 M686 539 H704",
    "M793 431 H825 M809 472 V494 M809 550 V590",
    4,
  },
}

local function collapse(f)
  -- Four source exposures collapse the large lettering into broken
  -- scanlines before the small selection resolves. This is geometry, not
  -- source footage.
  local c = COLLAPSE[math.min(f.index, 17)]
  group({
    filter = { { "blur", std = c[3] }, region = { x = -0.2, y = -1, w = 1.4, h = 3 } },
    opacity = 0.82,
  }, function()
    path { d = c[1], fill = "none", stroke = "#211914", stroke_width = 13, line_cap = "round" }
    path { d = c[2], fill = "none", stroke = "#38241b", stroke_width = 12 }
  end)
end

local PAN = {
  { 0.208333, 0.25, translate(421, 0), translate(366, 0), linear },
  { 0.25, 0.291667, translate(366, 0), translate(-125, 0), linear },
  { 0.291667, 0.375, translate(-125, 0), translate(-176, 0), ease_out },
  { 0.375, 0.416667, translate(-176, 0), translate(-500, 0), linear },
  { 0.416667, 0.458333, translate(-500, 0), translate(-705, 0), ease_out },
  { 0.458333, 0.5, translate(-705, 0), translate(-722, 0), ease_out },
}

local CURSORS = {
  [8] = { x = 506, y = 369, w = 934, h = 257, fill = "#191716" },
  [9] = { x = 890, y = 369, w = 456, h = 257, fill = "#191716" },
  [10] = { x = 1252, y = 369, w = 9, h = 257, fill = "#38241b" },
}

function M.draw(f)
  local n = f.index
  if n >= 18 then
    local count = math.min(4 + (n - 13) * 8 // 32, 12)
    local copy = prefix(count)
    if n == 18 or n == 19 or n == 20 or n == 22 then
      local width = text_width { copy, font = "Inter 24pt", size = 54, weight = 700, letter_spacing = -1.25 }
      local right = 106.25 + width + 24
      -- The reference briefly resolves into a typesetting selection, then
      -- blinks it off/on once. Keep both end caps outside our adapted copy.
      group({ opacity = n == 18 and 0.40 or n == 22 and 0.78 or 0.58 }, function()
        path { d = string.format("M82 444 H%s M82 628 H%s", right, right),
          stroke = "#553424", stroke_width = 2.3, stroke_dasharray = { 6, 7 }, fill = "none" }
        path { d = string.format("M72 444 H92 M82 444 V628 M72 628 H92 M%s 444 H%s M%s 444 V628 M%s 628 H%s",
          right - 10, right + 10, right, right - 10, right + 10),
          stroke = "#38241b", stroke_width = 6, fill = "none" }
      end)
    end
    label(copy, 106.25, 554, 54, "#171611", false)
    return
  end

  if n >= 14 then return collapse(f) end

  local count = n <= 4 and 1 or n <= 7 and 2 or n <= 12 and 3 or 4
  local copy = prefix(count)
  local function rulers()
    if n == 2 then
      path { d = "M0 108 H1440 M0 957 H1440", fill = "none",
        stroke = "#654020", stroke_width = 8, stroke_dasharray = { 44, 44 } }
    elseif n >= 3 then
      -- These are x-height/baseline rulers, not padding above and below the
      -- word. They stay full-width while the oversized type pans through them.
      path { d = "M0 444 H1440 M0 620 H1440", fill = "none",
        stroke = "#633b25", stroke_width = 4, stroke_dasharray = { 44, 44 },
        stroke_dashoffset = n * 3.0, opacity = 0.86 }
    end
  end
  if n == 13 then
    rulers()
    path { d = TYPE_PATH, fill = "#211914" }
    return
  end
  if n == 1 then
    rect { x = 0, y = 0, w = 1440, h = 1080, fill = "#ce101c" }
  elseif n == 2 then
    rect { x = 0, y = 0, w = 1440, h = 1080, fill = "#e8b900" }
  end
  rulers()
  group({ transform = animate(f, PAN) }, function()
    group({ transform = { translate = { 0, n == 1 and 1130 or 620 }, scale = { 6, n == 1 and 30 or 6.5 } } }, function()
      label(copy, 0, 0, 54, "#211914", false)
    end)
  end)
  if CURSORS[n] then rect(CURSORS[n]) end
end

return M
