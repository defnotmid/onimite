-- Shared pieces of lib.rs: the opening question and the type style.
local M = {}

M.QUESTION = "how do you turn a few lines of code into a feeling?"

-- Inter 24pt Bold, -1.25 letter spacing; `center` anchors the middle.
function M.label(copy, x, y, size, color, center)
  text { copy, x = x, y = y, font = "Inter 24pt", weight = 700, size = size,
    letter_spacing = -1.25, fill = color, align = center and "center" or "left" }
end

return M
