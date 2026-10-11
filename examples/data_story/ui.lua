-- Palette, type and the parts every section shares.

local M = {}

M.BG, M.BG2, M.LINE = "#0b1018", "#121a26", "#223047"
M.TEXT, M.DIM, M.LOW = "#f4f1ea", "#8592a6", "#2b3a55"

M.DISPLAY, M.SANS, M.MONO = "Inter 18pt", "DM Sans", "JetBrains Mono"

M.SNAP = spring { stiffness = 320, damping = 22 }
M.SOFT = spring { stiffness = 170, damping = 14 }
M.EXPO = cubic_bezier(0.16, 1, 0.3, 1)

-- The chart area every section shares.
M.X0, M.X1, M.BASE, M.TOP = 240, 1760, 800, 340

-- 12,480 style.
function M.thousands(n)
  local s = tostring(math.floor(n + 0.5))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

-- An opaque background (sections slide and wipe over each other): a dark
-- gradient with a slow glow in the accent colour.
function M.backdrop(f, accent, cx, cy)
  rect { x = 0, y = 0, w = 1920, h = 1080, fill = linear_gradient { x1 = 0, y1 = 0, x2 = 0, y2 = 1080,
    stops = { { 0, M.BG2 }, { 1, M.BG } } } }
  local t = f.global_seconds
  local x = cx + 120 * noise(t * 0.15, 1)
  local y = cy + 80 * noise(t * 0.15, 2)
  local glow = mix_color(accent, M.BG, 0.78)
  local clear = { r = glow.r, g = glow.g, b = glow.b, a = 0 }
  circle { cx = x, cy = y, r = 700, fill = radial_gradient { cx = x, cy = y, r = 700,
    stops = { { 0, glow }, { 1, clear } } } }
end

-- A section header that rises in while its section's transition runs (the
-- beat before `lb` = 0).
function M.header(lb, title, sub)
  local s = ease(M.SNAP, (lb + 1) * 0.5)
  group({ transform = translate(0, (1 - s) * 60), opacity = clamp01((lb + 1) * 2) }, function()
    text { title, x = 160, y = 190, font = M.DISPLAY, size = 76, weight = 800, letter_spacing = -2, fill = M.TEXT }
    text { sub, x = 162, y = 244, font = M.MONO, size = 28, fill = M.DIM }
  end)
end

return M
