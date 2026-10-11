-- The script that types itself in "Spark", as coloured tokens. The scene
-- draws it and its key clicks (sfx.typing) follow the same text.

local look = require("look")

local M = {}

local K, P, S, N, I = look.PINK, look.CYAN, look.O, look.LEMON, look.INK

M.LINES = {
  { { "video", K }, { " { ", I }, { "width", P }, { " = ", I }, { "1920", N }, { ", ", I }, { "height", P },
    { " = ", I }, { "1080", N }, { ", ", I }, { "fps", P }, { " = ", I }, { "60", N }, { " }", I } },
  { { "scene", K }, { " { ", I }, { "\"Hello\"", S }, { ", ", I }, { "duration", P }, { " = ", I }, { "3", N },
    { ", ", I }, { "render", P }, { " = ", I }, { "function", K }, { "(f)", I } },
  { { "  text", K }, { " { ", I }, { "\"Hello\"", S }, { ", ", I }, { "x", P }, { " = ", I }, { "960", N },
    { ", ", I }, { "y", P }, { " = ", I }, { "540", N }, { ", ", I }, { "size", P }, { " = ", I }, { "140", N },
    { " }", I } },
  { { "end", K }, { " }", I } },
}
M.COMMAND = { { "$ ", S }, { "onimite render video.lua", I } }

-- The characters as typed, one after another (the scene reveals them in
-- this order; sfx.typing clicks on each visible one).
local function text(lines)
  local out = {}
  for _, tokens in ipairs(lines) do
    for _, t in ipairs(tokens) do out[#out + 1] = t[1] end
  end
  return table.concat(out)
end

M.CODE_TEXT = text(M.LINES)
M.COMMAND_TEXT = text { M.COMMAND }
M.CODE_CHARS, M.COMMAND_CHARS = #M.CODE_TEXT, #M.COMMAND_TEXT

return M
