-- The reference edit (src/edit.rs), in its original 30000/1001 source-frame
-- timebase. Color hard cuts are individual shots; continuous camera moves
-- stay inside a shot (`clock_start` keeps the shader clock running through
-- the cuts). The integer-fps renderer produces these same 932 frames at 30 fps.

local M = {}

M.SOURCE_FRAMES = 932
M.SOURCE_FPS_NUM = 30000
M.SOURCE_FPS_DEN = 1001

-- `stop` is exclusive (the original's `end`).
M.SHOTS = {
  { name = "BlackLead", start = 0, stop = 6, effect = nil, variant = 0, clock_start = 0 },
  { name = "Boot", start = 6, stop = 26, effect = "Binary", variant = 0, clock_start = 6 },
  { name = "Glass", start = 26, stop = 57, effect = "Glass", variant = 0, clock_start = 26 },
  { name = "GlassAmber", start = 57, stop = 82, effect = "Glass", variant = 1, clock_start = 26 },
  { name = "Chrome", start = 82, stop = 91, effect = "Material", variant = 0, clock_start = 82 },
  { name = "Crystal", start = 91, stop = 97, effect = "Material", variant = 4, clock_start = 82 },
  { name = "Gold", start = 97, stop = 104, effect = "Material", variant = 1, clock_start = 82 },
  { name = "Ceramic", start = 104, stop = 111, effect = "Material", variant = 5, clock_start = 82 },
  { name = "Carbon", start = 111, stop = 119, effect = "Material", variant = 2, clock_start = 82 },
  { name = "ChromeSoft", start = 119, stop = 126, effect = "Material", variant = 0, clock_start = 82 },
  { name = "Pixels", start = 126, stop = 132, effect = "Material", variant = 3, clock_start = 82 },
  { name = "PrismGlass", start = 132, stop = 141, effect = "Material", variant = 6, clock_start = 82 },
  { name = "OpenSource", start = 141, stop = 209, effect = "LiquidChrome", variant = 0, clock_start = 141 },
  { name = "OpenSourceHold", start = 209, stop = 222, effect = "LiquidChrome", variant = 0, clock_start = 141 },
  { name = "Rose", start = 222, stop = 229, effect = "Obsidian", variant = 1, clock_start = 222 },
  { name = "Tunnel", start = 229, stop = 238, effect = "Tunnel", variant = 0, clock_start = 229 },
  { name = "Halftone", start = 238, stop = 256, effect = "Halftone", variant = 0, clock_start = 238 },
  { name = "ShaderLibrary", start = 256, stop = 307, effect = "Catalog", variant = 0, clock_start = 256 },
  { name = "Gradient", start = 307, stop = 344, effect = "Gradient", variant = 0, clock_start = 307 },
  { name = "Ascii", start = 344, stop = 357, effect = "Ascii", variant = 1, clock_start = 344 },
  { name = "Particles", start = 357, stop = 377, effect = "Particles", variant = 0, clock_start = 357 },
  { name = "Obsidian", start = 377, stop = 391, effect = "Obsidian", variant = 0, clock_start = 377 },
  { name = "Silver", start = 391, stop = 397, effect = "Spectral", variant = 2, clock_start = 391 },
  { name = "AuroraGreen", start = 397, stop = 400, effect = "Aurora", variant = 1, clock_start = 391 },
  { name = "AuroraPurple", start = 400, stop = 403, effect = "Aurora", variant = 2, clock_start = 391 },
  { name = "AuroraAqua", start = 403, stop = 407, effect = "Aurora", variant = 3, clock_start = 391 },
  { name = "AuroraOrange", start = 407, stop = 410, effect = "Aurora", variant = 4, clock_start = 391 },
  { name = "BlackBreak", start = 410, stop = 417, effect = nil, variant = 0, clock_start = 410 },
  { name = "Flow", start = 417, stop = 447, effect = "Flow", variant = 0, clock_start = 417 },
  { name = "EmbossBlue", start = 447, stop = 459, effect = "Emboss", variant = 0, clock_start = 447 },
  { name = "EmbossGreen", start = 459, stop = 471, effect = "Emboss", variant = 1, clock_start = 447 },
  { name = "EmbossOrange", start = 471, stop = 483, effect = "Emboss", variant = 2, clock_start = 447 },
  { name = "EmbossPearl", start = 483, stop = 496, effect = "Emboss", variant = 3, clock_start = 447 },
  { name = "NativePreview", start = 496, stop = 567, effect = "Preview", variant = 0, clock_start = 496 },
  { name = "ShaderModeEditor", start = 567, stop = 586, effect = "Spectral", variant = 0, clock_start = 567 },
  { name = "ShaderModeZoom", start = 586, stop = 610, effect = "Spectral", variant = 0, clock_start = 567 },
  { name = "ShaderMode", start = 610, stop = 626, effect = "Spectral", variant = 0, clock_start = 567 },
  { name = "ShaderModeWide", start = 626, stop = 640, effect = "Spectral", variant = 0, clock_start = 567 },
  { name = "BlackPause", start = 640, stop = 654, effect = nil, variant = 0, clock_start = 640 },
  { name = "Eclipse", start = 654, stop = 849, effect = "Eclipse", variant = 0, clock_start = 654 },
  { name = "BlackTail", start = 849, stop = 932, effect = nil, variant = 0, clock_start = 849 },
}

return M
