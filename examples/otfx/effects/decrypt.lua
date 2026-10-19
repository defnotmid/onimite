-- otfx's decrypt (otfx/src/effects/decrypt.odin): characters are typed in
-- as block shades settling on a cipher symbol, every character cycles fast
-- through the cipher alphabet, then slowly, each on its own run of symbols
-- (some held long), until it lands on its own character and fades from white
-- to the final colour. Built once at load as columns per character; draw(tick)
-- reads the tick straight off them.

local term = require("term")

local M = {}

local CIPHER = { "#008000", "#00cb00", "#00ff00" }
local FINAL = "#eda000"
local TYPING_SPEED = 2              -- characters per typing tick
local TYPING_SAMPLES = { 0, 0, 1, 1, 2, 2, 3, 3, 4 }
local SHADES = { "▉", "▓", "▒", "░" }
local FAST_FRAMES, SLOW_MAX = 80, 15
local FAST_TICKS = FAST_FRAMES * 2  -- a fast symbol holds two ticks
local DISCOVERED_TICKS = 11 * 5     -- ten fade steps plus the exact final colour

-- The cipher alphabet: printable ASCII, block elements, box drawing, Latin-1 and Latin
-- Extended-A (otfx goes on to U+01C3, Latin Extended-B, which JetBrains Mono does not draw).
local SYMBOLS = {}
for _, r in ipairs({ { 33, 127 }, { 9608, 9632 }, { 9472, 9599 }, { 174, 384 } }) do
  for c = r[1], r[2] - 1 do SYMBOLS[#SYMBOLS + 1] = utf8.char(c) end
end

-- White to FINAL in ten steps, as otfx's appearance ramp.
local FADE = {}
for s = 0, 10 do FADE[s + 1] = mix_color("#ffffff", FINAL, s / 10, "srgb") end

-- cells from term.grid; returns { ticks, draw(tick) }.
function M.build(cells, seed)
  local r = term.rng(seed)
  local n = #cells

  -- Typing: four shade colours and a cipher symbol per character, and when it's typed.
  local typed_color, typed_symbol, start = {}, {}, {}
  for i = 1, n do
    for k = 1, 5 do typed_color[(i - 1) * 5 + k] = r.pick(CIPHER) end
    typed_symbol[i] = r.pick(SYMBOLS)
  end
  local tick, head, typing_end = 0, 0, 0
  while head < n or tick < typing_end do
    if head < n and r.range(0, 101) <= 75 then
      for _ = 1, TYPING_SPEED do
        if head == n then break end
        head = head + 1
        start[head] = tick
        typing_end = math.max(typing_end, tick + 9)
      end
    end
    tick = tick + 1
  end
  local t0 = tick

  -- Decrypting: a colour, 80 fast symbols, and 1..15 slow symbols with cumulative ends.
  local color, fast, slow_count, slow_symbol, slow_end, slow_total = {}, {}, {}, {}, {}, {}
  local decrypt_end = 0
  for i = 1, n do
    color[i] = r.pick(CIPHER)
    for k = 1, FAST_FRAMES do fast[(i - 1) * FAST_FRAMES + k] = r.pick(SYMBOLS) end
    local count, total = r.range(1, SLOW_MAX + 1), 0
    for k = 1, count do
      slow_symbol[(i - 1) * SLOW_MAX + k] = r.pick(SYMBOLS)
      local hold = r.range(3, 6)
      if r.range(0, 101) <= 30 then hold = r.range(35, 60) end
      total = total + hold
      slow_end[(i - 1) * SLOW_MAX + k] = total
    end
    slow_count[i], slow_total[i] = count, total
    decrypt_end = math.max(decrypt_end, FAST_TICKS + total + DISCOVERED_TICKS)
  end

  local function draw(t)
    local d = t - t0
    for i = 1, n do
      local c = cells[i]
      local ch, col
      if d < 0 then
        local s = start[i]
        if s and s <= t then
          local k = TYPING_SAMPLES[math.min(t - s, 8) + 1]
          ch = k < 4 and SHADES[k + 1] or typed_symbol[i]
          col = typed_color[(i - 1) * 5 + k + 1]
        end
      elseif d < FAST_TICKS then
        ch, col = fast[(i - 1) * FAST_FRAMES + d // 2 + 1], color[i]
      else
        local s, base, k = d - FAST_TICKS, (i - 1) * SLOW_MAX, 0
        while k < slow_count[i] and s >= slow_end[base + k + 1] do k = k + 1 end
        if k < slow_count[i] then
          ch, col = slow_symbol[base + k + 1], color[i]
        else
          ch, col = c.ch, FADE[math.min((s - slow_total[i]) // 5, 10) + 1]
        end
      end
      if ch then term.cell(ch, c.col, c.row, col) end
    end
  end

  return { ticks = t0 + decrypt_end, draw = draw }
end

return M
