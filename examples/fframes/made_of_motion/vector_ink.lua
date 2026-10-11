-- vector_ink.rs: per-exposure vector contours, measured at the reference's
-- native cadence. Soft ink is a stack of translucent outlines, not an image
-- or video sample.
local M = {}

local PIGMENTS = {
  [0] = "#0a0907", "#40220f", "#c91c14", "#fffbea", "#ff2414", "#ffd155", "#c91c14", "#c91c14",
  "#c91c14", "#c91c14", "#b91613",
}

-- Decompress the vector text once per render; no source pixels are
-- embedded. Each line is `frame|pigment|opacity|SVG path`. Pigments 6..9
-- are the four red nib tracks the wordmark ending retargets. The paths are
-- parsed once (`path_data`) and every frame builder shares the result.
function M.new()
  return shared("vector_ink", function()
    local frames, marks = {}, {}
    for i = 0, 488 do
      frames[i] = {}
      marks[i] = { {}, {}, {}, {} }
    end
    for _, chunk in ipairs { "000", "100", "200", "300", "400" } do
      local source = gunzip("vector_ink/" .. chunk .. ".paths.gz")
      for index, pigment, opacity, d in source:gmatch("([^|\n]*)|([^|\n]*)|([^|\n]*)|([^\n]*)") do
        index, pigment, opacity = tonumber(index), tonumber(pigment), tonumber(opacity)
        local color = pigment and PIGMENTS[pigment]
        if index and frames[index] and color and opacity then
          local node = { d = path_data(d), fill = color, fill_rule = "evenodd", opacity = opacity }
          if pigment >= 6 and pigment < 10 then
            local list = marks[index][pigment - 5]
            list[#list + 1] = node
          else
            local list = frames[index]
            list[#list + 1] = node
          end
        end
      end
    end
    return { frames = frames, letter_marks = marks }
  end)
end

local function paths(list)
  for i = 1, #list do path(list[i]) end
end

-- The unmodified trace of the frame's global exposure.
function M.draw(v, f)
  local n = f.global_index
  if not v.frames[n] then return end
  paths(v.frames[n])
  for k = 1, 4 do paths(v.letter_marks[n][k]) end
end

local LETTERS = require("ink_capture").LETTERS

-- Preserve source nib shapes and exposure timing through the seven brand
-- flights and final camera pullback. `draw` remains the unmodified trace.
function M.draw_signature(v, f, letters)
  local n = math.min(f.global_index, 488)
  local source = LETTERS[math.min(math.max(n - 413, 0), #LETTERS - 1) + 1]
  -- The reference's longest, strongest red gestures are its last twelve
  -- frames. Keep them after assembly, attached to the same camera as the
  -- wordmark; only the independent black gestures leave the composition.
  group({ opacity = animate(f, { { 2.541667, 2.708333, 1, 0, ease_out } }) }, function()
    paths(v.frames[n])
  end)
  local zoom = animate(f, { { 2.541667, 2.666667, scale(1), scale(2.8), ease_in } })
  group({ transform = translate(720, 540) }, function()
    group({ transform = animate(f, {
      { 2.666667, 2.833333, scale(1), scale(1 / 2.8), cubic_bezier(0.12, 0.92, 0.20, 1) },
    }) }, function()
      group({ transform = translate(-720, -540) }, function()
        for i = 0, 6 do
          local s = source[i % 4 + 1]
          local p = letters[i + 1].position
          group({ transform = translate(p[1], p[2]) }, function()
            group({ transform = zoom }, function()
              group({ transform = translate(-s[1], -s[2]) }, function()
                paths(v.letter_marks[n][i % 4 + 1])
              end)
            end)
          end)
        end
      end)
    end)
  end)
end

return M
