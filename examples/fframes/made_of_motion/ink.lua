-- ink.rs: frame-exact vector ink plus procedural collision illumination.
local vector_ink = require("vector_ink")

local M = {}

function M.dust(f, light)
  local t = f.global_index / 24
  local fill = light and "#ded7c9" or "#2c2825"
  for i = 0, 9 do
    local x = 135 + (i * 431 + t * (11 + i)) % 1170
    local y = 110 + (i * 197 - t * (5 + i * 2)) % 860
    local r = i % 3 == 0 and 1.7 or 0.8
    circle { cx = x, cy = y, r = r, fill = fill, opacity = 0.32 }
  end
end

function M.new(impacts)
  local ink = { impacts = impacts, vectors = vector_ink.new() }

  function ink.impacts_draw(f)
    for _, hit in ipairs(ink.impacts) do
      local age = f.global_index - hit.at
      if age >= 0 and age < 7 then
        shader(f, { src = "shaders/impact.sksl", x = hit.position[1] - 170, y = hit.position[2] - 170,
          w = 340, h = 340, uniforms = { uAge = age, uSeed = hit.at, uDirection = hit.direction } })
      end
    end
  end

  function ink.draw(f)
    vector_ink.draw(ink.vectors, f)
  end

  -- Retarget the reference's "you're" loop to "code" in the opening copy.
  -- The fixed font places their word centres at x=793 and x=900
  -- respectively; code is 7/8 as wide. Ease into that mapping before the
  -- loop closes, then release it with the original pen's exit. Ink
  -- inspection keeps source positions.
  local IDENTITY = { translate = { 0, 0 }, scale = { 1, 1 } }
  local RETARGET = { translate = { 206.125, -3 }, scale = { 0.875, 1 } }
  function ink.draw_question(f)
    group({ transform = animate(f, {
      { 1.125, 1.291667, IDENTITY, RETARGET, ease_in_out },
      { 1.458333, 1.541667, RETARGET, IDENTITY, ease_in },
    }) }, function()
      vector_ink.draw(ink.vectors, f)
    end)
  end

  function ink.draw_signature(f, letters)
    vector_ink.draw_signature(ink.vectors, f, letters)
  end

  return ink
end

return M
