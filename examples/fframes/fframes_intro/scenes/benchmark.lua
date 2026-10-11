-- The drop after the riser. Remotion and fframes render the same 100,000
-- elements; the race runs as a time-lapse of complete MP4 export times.

local beat = require("beat")
local ui = require("ui")
local facts = require("facts")
local prog, expo_out, expo_in, snap = beat.prog, beat.expo_out, beat.expo_in, beat.snap
local ORANGE, BONE, GREY, INK, MONO, DISPLAY = ui.ORANGE, ui.BONE, ui.GREY, ui.INK, ui.MONO, ui.DISPLAY
local Slam, label = ui.Slam, ui.label

local RACE_START = 2
-- The slower renderer crosses the line after this many beats.
local RACE_BEATS = 12
local RESULT_AT = 16
local TABLE_AT = 22

local SLOWEST = math.max(facts.BENCH_REMOTION_S, facts.BENCH_FFRAMES_S, 0.001)

local LANES = {
  { facts.BENCH_REMOTION_LABEL, "CHROME + REACT → H.264 MP4", facts.BENCH_REMOTION_S, GREY, 470 },
  { facts.BENCH_FFRAMES_LABEL, "RUST + SKIA → H.264 MP4", facts.BENCH_FFRAMES_S, ORANGE, 700 },
}

local function race(lb)
  local exit = expo_in(prog(lb, 15.6, 16))
  -- seconds of the real run shown at this beat
  local real = prog(lb, RACE_START, RACE_START + RACE_BEATS) * SLOWEST
  local speedup = SLOWEST / (RACE_BEATS * beat.BEAT)
  group({ opacity = 1 - exit }, function()
    Slam(150, 250, "100,000 TEXT NODES", DISPLAY, 120, BONE):draw(lb, 0, 140)
    label(154, 310, "300 FRAMES · 3840×2160 · H.264 MP4 · SAME LAYOUT, SAME FONT", GREY, 20, "start")
    for idx, lane in ipairs(LANES) do
      local i = idx - 1
      local name, sub, secs, color, y = lane[1], lane[2], lane[3], lane[4], lane[5]
      local appear = snap(lb - 0.6 - i * 0.3)
      local p = math.min(real / math.max(secs, 0.001), 1)
      local done = p >= 1
      local shown = math.min(real, secs)
      local bar_w = math.max(1620 * p, 0.5)
      local done_at = RACE_START + RACE_BEATS * secs / SLOWEST
      local stamp = snap(lb - done_at)
      local flash = done and math.exp(-(lb - done_at) * 6) or 0
      local frames_done = math.floor(300 * p)
      group({ opacity = prog(lb, 0.6 + i * 0.3, 0.7 + i * 0.3), transform = translate((1 - appear) * -120, 0) }, function()
        text { name, x = 150, y = y, font = DISPLAY, size = 58, letter_spacing = -2, fill = i == 1 and ORANGE or BONE }
        text { sub, x = 150, y = y + 34, font = MONO, weight = 500, size = 18, letter_spacing = 2.5, fill = GREY }
        rect { x = 150, y = y + 56, w = 1620, h = 64, fill = "#141312", stroke = "#2f2c29", stroke_width = 1.5 }
        rect { x = 150, y = y + 56, w = bar_w, h = 64, fill = color }
        rect { x = 150, y = y + 56, w = 1620, h = 64, fill = BONE, opacity = flash * 0.6 }
        text { string.format("%.3fs", shown), x = 1770, y = y, align = "end", font = MONO, weight = 600, size = 52,
          fill = done and color or BONE }
        text { frames_done .. " / 300 FRAMES", x = 170, y = y + 100, font = MONO, weight = 600, size = 22,
          letter_spacing = 2, fill = INK, opacity = bar_w > 260 and 1 or 0 }
        group({ opacity = done and 1 or 0, transform = translate(0, (1 - stamp) * 20) }, function()
          text { "DONE", x = 1750, y = y + 100, align = "end", font = MONO, weight = 700, size = 24, letter_spacing = 4,
            fill = INK }
        end)
      end)
    end
    group({ opacity = prog(lb, RACE_START, RACE_START + 0.2) }, function()
      label(1770, 310, string.format("TIME-LAPSE ×%.1f · MEASURED WALL CLOCK", speedup), ORANGE, 20, "end")
    end)
  end)
end

-- N× FASTER on an orange field.
local function result(l)
  local ratio = facts.BENCH_REMOTION_S / math.max(facts.BENCH_FFRAMES_S, 0.001)
  local n = 1 + (ratio - 1) * expo_out(prog(l, 0, 1.2))
  local s = 1 + (1 - expo_out(l / 0.35)) * 0.15
  local word = snap(l - 1)
  local exit = expo_in(prog(l, 5.7, 6))
  group({ opacity = 1 - exit }, function()
    rect { x = 0, y = 0, w = 1920, h = 1080, fill = ORANGE }
    group({ transform = string.format("translate(150 760) scale(%s) translate(-150 -760)", s) }, function()
      text { string.format("%.2f×", n), x = 130, y = 760, font = DISPLAY, size = 480, letter_spacing = -30, fill = INK }
    end)
    text { "FASTER THAN REMOTION", x = 150, y = 900 + (1 - word) * 60, font = DISPLAY, size = 120, letter_spacing = -4,
      fill = INK, opacity = prog(l, 1, 1.08) }
    text { "SAME 100,000 TEXT NODES", x = 150, y = 170, font = MONO, weight = 600, size = 22, letter_spacing = 4, fill = INK }
    text { "COMPLETE MP4 · MEDIAN WALL CLOCK", x = 1770, y = 170, align = "end", font = MONO, weight = 600, size = 22,
      letter_spacing = 4, fill = INK }
    rect { x = 150, y = 196, w = 1620, h = 3, fill = INK }
  end)
end

local TABLE = {
  { facts.BENCH_REMOTION_LABEL, facts.BENCH_REMOTION_S, GREY },
  { "FFRAMES · CPU", facts.BENCH_FFRAMES_CPU_S, BONE },
  { facts.BENCH_FFRAMES_LABEL, facts.BENCH_FFRAMES_S, ORANGE },
}

local function table_(l)
  local exit = expo_in(prog(l, 9.6, 10))
  group({ opacity = 1 - exit }, function()
    Slam(150, 300, "THE NUMBERS", DISPLAY, 110, BONE):draw(l, 0, 120)
    label(1740, 400, "WALL CLOCK", GREY, 18, "end")
    for idx, row in ipairs(TABLE) do
      local i = idx - 1
      local name, secs, color = row[1], row[2], row[3]
      local at = 0.3 + i * 0.5
      local s = snap(l - at)
      local y = 520 + i * 130
      group({ opacity = prog(l, at, at + 0.08), transform = translate((1 - s) * 80, 0) }, function()
        rect { x = 150, y = y - 70, w = 1620, h = 110, fill = "#0f0e0d", fill_opacity = 0.85, stroke = "#2f2c29",
          stroke_width = 1.5 }
        rect { x = 150, y = y - 70, w = 6, h = 110, fill = color }
        text { name, x = 190, y = y, font = DISPLAY, size = 48, letter_spacing = -1, fill = BONE }
        text { string.format("%.3f s", secs), x = 1740, y = y, align = "end", font = MONO, weight = 600, size = 48,
          fill = color }
      end)
    end
    label(154, 860, "RENDER + ENCODE + MP4", BONE, 18, "start")
    label(154, 900, facts.BENCH_NOTE, GREY, 18, "start")
    label(154, 940, "REPRODUCE: RENDER-BENCH/VS-REMOTION IN THE FFRAMES REPO", ORANGE, 18, "start")
  end)
end

local function render(f, lb)
  if lb >= RESULT_AT and lb < TABLE_AT then return result(lb - RESULT_AT) end
  shader(f, { src = "shaders/grid.sksl", x = 0, y = 0, w = 1920, h = 1080, uniforms = {
    uSpeed = 2, uHorizon = 0.62, uBright = 0.35, uInk = "#6f6a63", uHot = ORANGE } })
  if lb < RESULT_AT then race(lb) else table_(lb - TABLE_AT) end
end

return { name = "BenchmarkScene", start = 96, stop = 128, render = render }
