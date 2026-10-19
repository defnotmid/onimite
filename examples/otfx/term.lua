-- The cell grid otfx's effects play on, filling the frame as a terminal
-- fills its screen: block elements drawn as rects, as terminals draw them
-- (so a banner's halves meet without seams), everything else a JetBrains
-- Mono glyph centred in its cell. Effects build their timelines at load from
-- term.grid's cells and draw a tick with term.cell.

local M = {}

-- 96×27 cells of 20×40 px, or the grid of a terminal: --set cols=213 --set rows=60.
M.COLS, M.ROWS = tonumber(arg.cols) or 96, tonumber(arg.rows) or 27
M.CW, M.CH = 1920 / M.COLS, 1080 / M.ROWS
M.FONT, M.SIZE = "JetBrains Mono", math.min(M.CW / 0.6, M.CH / 1.2)  -- the advance is 0.6 em
M.FPS = 60                          -- otfx's frame rate: one effect tick per frame

-- { x, y, w, h, opacity } in cell units per block element.
local BLOCKS = {
  ["█"] = { 0, 0, 1, 1, 1 },     ["▀"] = { 0, 0, 1, 0.5, 1 },  ["▄"] = { 0, 0.5, 1, 0.5, 1 },
  ["▉"] = { 0, 0, 7 / 8, 1, 1 }, ["▌"] = { 0, 0, 0.5, 1, 1 },  ["▐"] = { 0.5, 0, 0.5, 1, 1 },
  ["▓"] = { 0, 0, 1, 1, 0.75 },  ["▒"] = { 0, 0, 1, 1, 0.5 },  ["░"] = { 0, 0, 1, 1, 0.25 },
}

-- A seeded stream of draws (otfx's engine RNG, through hash so every frame
-- builder agrees). below(n): 0..n-1; range(a, b): a..b-1, as otfx's random_range.
function M.rng(seed)
  local n = 0
  local r = {}
  function r.below(k) n = n + 1; return math.floor(hash(n, seed) * k) end
  function r.range(a, b) return a + r.below(b - a) end
  function r.pick(list) return list[r.below(#list) + 1] end
  return r
end

-- The non-space characters of `lines`, the block centred on the grid, top
-- to bottom, left to right (otfx's .Top_Bottom_Left_Right).
function M.grid(lines)
  local width = 0
  for _, line in ipairs(lines) do width = math.max(width, utf8.len(line)) end
  local col0, row0 = (M.COLS - width) // 2, (M.ROWS - #lines) // 2
  local cells = {}
  for r, line in ipairs(lines) do
    local c = col0
    for _, cp in utf8.codes(line) do
      if cp ~= 32 then cells[#cells + 1] = { ch = utf8.char(cp), col = c, row = row0 + r - 1 } end
      c = c + 1
    end
  end
  return cells
end

function M.cell(ch, col, row, color)
  local x, y = col * M.CW, row * M.CH
  local b = BLOCKS[ch]
  if b then
    rect { x = x + b[1] * M.CW, y = y + b[2] * M.CH, w = b[3] * M.CW, h = b[4] * M.CH,
      fill = color, fill_opacity = b[5] }
  else
    text { ch, x = x + M.CW / 2, y = y + M.CH / 2, align = "center", baseline = "middle",
      font = M.FONT, size = M.SIZE, fill = color }
  end
end

return M
