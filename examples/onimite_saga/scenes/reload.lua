local look = require("look")
local fx = require("fx")
local score = require("music.score")
local sfx = require("sfx")
local facts = require("facts")
local snap = look.snap

-- ---- live reload ---------------------------------------------------------------

local SAVES = { 1.5, 3.5, 5.5 }          -- scene-local beats of the three saves

local NAMES = { "tiktok", "audio", "beta", "intro", "shader", "motion" }

local PANEL = { x = 90, y = 190, w = 820, h = 700 }

local CHART = { x = 960, y = 190, w = 870, h = 700 }

local CODE_Y = 300

local function reload(f, lb, gb)
  fx.pop(f, 4, "#15072d", "#241047", "#8a5cff", look.kick(gb) * 0.5)
  look.title(lb, 0, "SAVE. IT'S ALREADY THERE.", 100, 140, 96)

  local saves = 0
  for _, s in ipairs(SAVES) do if lb >= s then saves = saves + 1 end end
  local since = lb - (SAVES[saves] or -10)
  local accent = saves >= 1 and look.CYAN or look.PINK
  local radius = saves >= 2 and 40 or 6
  local glow = saves >= 3

  -- the editor
  group({ opacity = progress(lb, 0.2, 0.8) }, function()
    rect { x = PANEL.x, y = PANEL.y, w = PANEL.w, h = PANEL.h, rx = 26, fill = "#0a0c14", stroke = look.LINE, stroke_width = 2 }
    text { "chart.lua", x = PANEL.x + 40, y = PANEL.y + 56, font = look.MONO, size = 24, fill = look.DIM }
    local lines = {
      { "-- edit. save. the picture follows.", look.DIM },
      { "local accent = ", look.INK, saves >= 1 and "\"#19e3ff\"" or "\"#ff2d95\"", saves >= 1 and look.CYAN or look.PINK, 1 },
      { "local radius = ", look.INK, saves >= 2 and "40" or "6", look.LEMON, 2 },
      { "local glow   = ", look.INK, saves >= 3 and "true" or "false", look.O, 3 },
      { "", look.INK },
      { "for i, r in ipairs(speedups) do", look.PINK },
      { "  rect { h = r * 96, rx = radius,", look.INK },
      { "         fill = accent }", look.INK },
      { "end", look.PINK },
    }
    for i, l in ipairs(lines) do
      local y = CODE_Y + (i - 1) * 56
      if l[5] and saves == l[5] and since < 0.8 then
        rect { x = PANEL.x + 14, y = y - 38, w = PANEL.w - 28, h = 52, rx = 10, fill = accent, opacity = 0.35 * (1 - since / 0.8) }
      end
      text { l[1], x = PANEL.x + 40, y = y, font = look.MONO, size = 28, fill = l[2] }
      if l[3] then
        text { l[3], x = PANEL.x + 40 + #l[1] * text_width { "M", font = look.MONO, size = 28 }, y = y, font = look.MONO,
          size = 28, fill = l[4] }
      end
    end
    -- the save key
    if saves > 0 and since < 1.1 then
      local p = snap(since * 3)
      group({ opacity = clamp01(1.5 - since * 1.4), transform = { scale = 0.8 + 0.2 * p, origin = { PANEL.x + 140, PANEL.y + PANEL.h - 70 } } },
        function()
          look.chip(PANEL.x + 40, PANEL.y + PANEL.h - 110, "Ctrl + S", look.INK, look.NIGHT, 28, 1)
        end)
    end
  end)

  -- the chart
  group({ opacity = progress(lb, 0.4, 1) }, function()
    rect { x = CHART.x, y = CHART.y, w = CHART.w, h = CHART.h, rx = 26, fill = "#0a0c14", opacity = 0.88, stroke = accent,
      stroke_width = 3 }
    text { "speed-up over fframes", x = CHART.x + 40, y = CHART.y + 56, font = look.MONO, size = 24, fill = look.DIM }
    -- the reloaded badge
    if saves > 0 then
      local p = snap(since * 2)
      group({ opacity = clamp01(p * 3) * (since < 1.6 and 1 or 0.7) }, function()
        circle { cx = CHART.x + CHART.w - 190, cy = CHART.y + 50, r = 8, fill = look.O }
        text { "reloaded", x = CHART.x + CHART.w - 170, y = CHART.y + 58, font = look.MONO, size = 24, fill = look.O }
      end)
    end
    local base, bw, gap = CHART.y + CHART.h - 90, 90, 36
    local x0 = CHART.x + 50
    local drawn = function()
      for i, r in ipairs(facts.RACE) do
        local p = snap(since * 1.6 - (i - 1) * 0.12 + (saves == 0 and lb * 1.6 - 0.5 or 0))
        local h = math.max(r[4] * 96 * clamp01(p), 4)
        local x = x0 + (i - 1) * (bw + gap)
        rect { x = x, y = base - h, w = bw, h = h, rx = radius, fill = accent }
        if p > 0.3 then
          text { string.format("%.1f×", r[4]), x = x + bw / 2, y = base - h - 14, align = "center", font = look.DISPLAY,
            size = 54, fill = look.INK, opacity = clamp01((p - 0.3) * 2) }
        end
        text { NAMES[i], x = x + bw / 2, y = base + 40, align = "center", font = look.MONO, size = 20, fill = look.DIM }
      end
    end
    if glow then
      group({ blur = 22, opacity = 0.9 }, drawn)
    end
    drawn()
  end)
end

-- Its sounds (sfx.lua), in beats into the scene.
local SOUNDS = {}
for _, save in ipairs(SAVES) do -- a key click and a DONE at each save
  SOUNDS[#SOUNDS + 1] = sfx.at("reload", save - 0.05, sfx.tick(3000), 0.25)
  SOUNDS[#SOUNDS + 1] = sfx.at("reload", save, sfx.done(), 0.15)
end

local AT = score.time("reload")
scene { "Reload", cue = "reload", start = AT, audio = SOUNDS, render = function(f)
  local gb = score.beat(f)
  reload(f, gb - score.beat(AT), gb)
end }
