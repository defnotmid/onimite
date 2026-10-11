-- The code of a video is typed out while its output renders next to it.
-- The lift ends in a bar of near silence reading "rendered on the".

local beat = require("beat")
local ui = require("ui")
local prog, expo_out, expo_in, snap, spring, usize, fract =
  beat.prog, beat.expo_out, beat.expo_in, beat.snap, beat.spring, beat.usize, beat.fract
local ORANGE, BONE, GREY, BG, MONO, DISPLAY = ui.ORANGE, ui.BONE, ui.GREY, ui.BG, ui.MONO, ui.DISPLAY
local callout, corners, label, Slam = ui.callout, ui.corners, ui.label, ui.Slam

local KW, TY, PL, PU, ST = ORANGE, "#d9c7a8", BONE, "#8f8a82", "#f3a676"

-- The code, as colored tokens per line.
local CODE = {
  { { "impl ", KW }, { "Video ", TY }, { "for ", KW }, { "Intro ", TY }, { "{", PU } },
  { { "    const ", KW }, { "FPS", PL }, { ": ", PU }, { "usize ", TY }, { "= ", PU }, { "60", ST }, { ";", PU } },
  {},
  { { "    fn ", KW }, { "render_frame", PL }, { "(", PU }, { "&self", KW }, { ", ", PU }, { "frame", PL },
    { ": ", PU }, { "Frame", TY }, { ") -> ", PU }, { "Svgr ", TY }, { "{", PU } },
  { { "        let ", KW }, { "y ", PL }, { "= ", PU }, { "spring", PL }, { "(frame.", PU }, { "seconds", PL },
    { "());", PU } },
  { { "        svgr!", KW }, { "(<", PU }, { "text ", PL }, { "y", TY }, { "={y}>", PU }, { "\"EVERY FRAME\"", ST },
    { "</", PU }, { "text", PL }, { ">)", PU } },
  { { "    }", PU } },
  { { "}", PU } },
}

local CODE_X, CODE_Y, CODE_SIZE, LINE_H = 150, 300, 34, 56
local ADV = CODE_SIZE * 0.6

local TOTAL = 0
for _, line in ipairs(CODE) do for _, tok in ipairs(line) do TOTAL = TOTAL + #tok[1] end end

-- The frame the code draws: EVERY FRAME, bouncing on every beat.
local function output(f, lb)
  local appear = expo_out(prog(lb, 3, 4))
  if appear <= 0 then return end
  local exit = expo_in(prog(lb, 11.7, 12))
  local x, y, w, h = 1190, 320, 600, 338
  local bounce = spring(fract(lb) * beat.BEAT, 260, 14)
  local ty = (1 - bounce) * -60
  group({ opacity = appear * (1 - exit), transform = translate((1 - appear) * 120, 0) }, function()
    rect { x = x, y = y, w = w, h = h, fill = "#141312", stroke = "#3a3733", stroke_width = 1.5 }
    corners(x - 14, y - 14, w + 28, h + 28, 18, ORANGE, 2)
    group({ clip = { x = x, y = y, w = w, h = h } }, function()
      text { "EVERY FRAME", x = x + w / 2, y = y + h / 2 + 30 + ty, align = "middle", font = DISPLAY, size = 76,
        letter_spacing = -2, fill = BONE }
    end)
    label(x, y + h + 44, "OUTPUT", GREY, 18, "start")
    label(x + w, y + h + 44, string.format("FRAME %05d", f.global_index), ORANGE, 18, "end")
    callout(x + w / 2, y + h + 14, x + w / 2 - 40, 820, "DRAWN BY SKIA ON THE GPU", ORANGE, prog(lb, 10, 10.8))
  end)
end

-- Beats 12-14: EVERY / FRAME. over the dimmed code.
local function big_words(lb)
  local l = lb - 12
  if l < 0 then return end
  Slam(150, 560, "EVERY", DISPLAY, 250, BONE):draw(l, 0, 190)
  Slam(150, 800, "FRAME.", DISPLAY, 250, ORANGE):draw(l - 1, 0, 190)
end

-- The bar that goes (nearly) silent before the drop.
local function silence(l)
  local o = prog(l, 0, 0.2)
  local w = snap(l - 0.9)
  rect { x = 0, y = 0, w = 1920, h = 1080, fill = BG }
  text { "RENDERED ON THE", x = 960, y = 560, align = "middle", font = MONO, weight = 500, size = 40,
    letter_spacing = 12, fill = GREY, opacity = o }
  rect { x = 960 - 30 * w, y = 600, w = math.max(60 * w, 0.5), h = 4, fill = ORANGE }
end

local function render(f, lb)
  if lb >= 46 - 32 then return silence(lb - 14) end
  local typed = usize(expo_out(prog(lb, 0, 7)) ^ 0.7 * TOTAL)
  local dim = 1 - 0.75 * prog(lb, 12, 12.3)
  local caret_on = fract(lb * 2) < 0.6
  group({ opacity = dim }, function()
    text { "SRC/LIB.RS", x = CODE_X, y = 220, font = MONO, weight = 500, size = 22, letter_spacing = 3, fill = GREY }
    rect { x = CODE_X, y = 236, w = 1000, h = 1, fill = GREY, opacity = 0.5 }
    local left = typed
    local cx, cy = CODE_X, CODE_Y
    for li, line in ipairs(CODE) do
      local y = CODE_Y + (li - 1) * LINE_H
      local col = 0
      for _, tok in ipairs(line) do
        local s, color = tok[1], tok[2]
        local n = #s
        local take = math.min(n, left)
        if take > 0 then
          local part = s:sub(1, take)
          local lead = #part:match("^ *")
          part = part:gsub("^%s+", "")
          if part ~= "" then
            text { part, x = CODE_X + (col + lead) * ADV, y = y, font = MONO, weight = 500, size = CODE_SIZE, fill = color }
          end
        end
        left = left - take
        col = col + take
        if take < n then break end
      end
      if left > 0 or col > 0 then cx, cy = CODE_X + col * ADV, y end
      if left == 0 then break end
    end
    rect { x = cx + 2, y = cy - 28, w = 16, h = 36, fill = ORANGE, opacity = caret_on and 1 or 0 }
    callout(CODE_X + 13 * ADV, CODE_Y + 3 * LINE_H - 40, CODE_X + 13 * ADV, 190, "CALLED FOR EVERY FRAME", ORANGE,
      prog(lb, 8, 8.8))
    callout(CODE_X + 13 * ADV, CODE_Y + 5 * LINE_H + 12, 520, 790, "RETURNS AN SVG TREE", BONE, prog(lb, 9, 9.8))
  end)
  output(f, lb)
  big_words(lb)
end

return { name = "CodeScene", start = 32, stop = 48, render = render }
