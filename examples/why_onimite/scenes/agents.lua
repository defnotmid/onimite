-- Built for agents: an agent can't watch a video, so onimite checks it.
-- The terminal replays a real session on the saga (examples/onimite_saga):
-- `inspect` finds the Bill scene's booms off the beat, the one number that
-- placed them is fixed, and `inspect` runs clean. The text is the command's
-- own output, copied, not written for the film.

local beat = require("beat")
local ui = require("ui")
local T = require("timeline")
local snap = beat.snap

local X, Y, W, H = 120, 290, 1680, 620
local SIZE, LINE = 24, 40

-- What is on screen, in beats into the section: a command typed over
-- [from, to], output popping in on its beat.
local RUN1 = { "$ onimite inspect video.lua Bill", T.AGENT_RUN, T.AGENT_RUN + 1.5 }
local FOUND = {
  "checked 16 frames: 1 findings",
  "Warning 39.77s..39.77s (frames 2386..2386, seen in 1) [Bill]: scenes/bill.lua:60: 6 sounds start off",
  "the music's beat, the loudest \"crash\" -0.043s off at 39.778s (the beat: 0.468s; hits belong on the",
  "beat or half-beat)",
}
local RUN2 = { "$ onimite inspect video.lua Bill", T.AGENT_RERUN, T.AGENT_RERUN + 1.5 }
local CLEAN = "checked 16 frames: no problems found"

local function typed(lb, cmd, y)
  local n = math.floor(#cmd[1] * progress(lb, cmd[2], cmd[3]) + 0.5)
  if n > 0 then
    text { cmd[1]:sub(1, n), x = X + 40, y = y, font = ui.MONO, size = SIZE, fill = ui.TEXT }
  end
end

local function render(f, lb)
  ui.header(lb, "BUILT FOR AGENTS", "an agent can't watch the video: onimite checks it")
  local p = snap(lb - 0.5)
  group({ opacity = clamp01(p * 3), transform = translate(0, (1 - p) * 40) }, function()
    rect { x = X, y = Y, w = W, h = H, rx = 22, fill = ui.PANEL, stroke = ui.LINE, stroke_width = 2 }
    local y = Y + 64
    typed(lb, RUN1, y)
    if lb >= T.AGENT_FOUND then
      for i, s in ipairs(FOUND) do
        text { s, x = X + 40, y = y + i * LINE, font = ui.MONO, size = SIZE, fill = i == 1 and ui.TEXT or ui.F,
          opacity = progress(lb, T.AGENT_FOUND, T.AGENT_FOUND + 0.25) }
      end
    end
    -- The fix: the number that placed the booms, onto the beat.
    y = y + 6 * LINE
    if lb >= T.AGENT_FIX then
      local s = snap(lb - T.AGENT_FIX)
      local before = "scenes/bill.lua:54   sfx.at(C.BILL, cue + "
      local bx = X + 40 + text_width { before, font = ui.MONO, size = SIZE }
      text { before, x = X + 40, y = y, font = ui.MONO, size = SIZE, fill = ui.DIM, opacity = clamp01(s * 3) }
      text { "3.4", x = bx, y = y, font = ui.MONO, size = SIZE, fill = ui.DIM, opacity = clamp01(s * 3) }
      local w = text_width { "3.4", font = ui.MONO, size = SIZE }
      if s > 0.001 then rect { x = bx - 2, y = y - 9, w = (w + 4) * s, h = 3, fill = ui.F } end
      if lb >= T.AGENT_FIX + 1 then
        local s2 = snap(lb - T.AGENT_FIX - 1)
        text { "3", x = bx + w + 14, y = y, font = ui.MONO, size = SIZE, fill = ui.O, opacity = clamp01(s2 * 3) }
        text { ", sfx.impact(), 0.4),", x = bx + w + 14 + text_width { "3", font = ui.MONO, size = SIZE }, y = y,
          font = ui.MONO, size = SIZE, fill = ui.DIM, opacity = clamp01(s2 * 3) }
      end
    end
    y = y + 2 * LINE
    typed(lb, RUN2, y)
    if lb >= T.AGENT_CLEAN then
      local s = snap(lb - T.AGENT_CLEAN)
      ui.check(X + 40, y + LINE - 26, 30, ui.O)
      text { CLEAN, x = X + 90, y = y + LINE, font = ui.MONO, size = SIZE, fill = ui.O, opacity = clamp01(s * 3) }
    end
  end)
  group({ opacity = progress(lb, T.AGENT_CLEAN + 1, T.AGENT_CLEAN + 2) }, function()
    text { "layout, text, sync points, sound on the beat: checked without anyone watching", x = 960, y = 990,
      align = "center", font = ui.MONO, size = 26, fill = ui.DIM }
  end)
end

return { name = "Agents", start = T.AGENTS, stop = T.TRICKS, render = render }
