-- otfx's terminal text effects (github.com/defnotmid/otfx) full screen: the
-- frame is the terminal, the effect plays its ticks at otfx's 60 fps on the
-- text, then holds. One scene per effect; term.lua is the cell grid they
-- share, effects/NAME.lua builds one effect's timeline at load. The text is
-- the ONIMITE banner, or any text given with --set text=...
--
--     onimite preview examples/otfx/video.lua --fullscreen
--     onimite preview examples/otfx/video.lua --fullscreen --set text="$(fortune)"
--     onimite render examples/otfx/video.lua -o otfx.mp4

local term = require("term")

video { width = 1920, height = 1080, fps = term.FPS, background = "#0b0d12" }

-- ONIMITE in the block letters of otfx's own banner (otfx/docs/banner.txt).
local BANNER = {
  " ▄██████▄    ▄█   █▄    ▄█████▄   ▄██▄     ▄██▄   ▄█████▄   ▄███████▄    ▄███████",
  "███    ███   ███▄  ███   ▀▀███▀▀   ████▄   ▄████   ▀▀███▀▀   ▀▀▀███▀▀▀   ███   █▀ ",
  "███    ███   ████▄ ███     ███     ███▀██▄██▀███     ███        ███      ███      ",
  "███    ███   █████▄███     ███     ███  ▀█▀  ███     ███        ███      ███▄▄▄   ",
  "███    ███   ███▀█████     ███     ███       ███     ███        ███      ███▀▀▀   ",
  "███    ███   ███ ▀████     ███     ███       ███     ███        ███      ███      ",
  "███    ███   ███  ▀███     ███     ███       ███     ███        ███      ███      ",
  "███    ███   ███   ███   ▄▄███▄▄   ███       ███   ▄▄███▄▄      ███      ███   █▄ ",
  " ▀██████▀     ▀█   █▀    ▀█████▀   ▀█▀       ▀█▀   ▀█████▀      ▀█▀       ▀███████",
}
local TAGLINE = "terminal text effects from otfx, drawn by onimite"

local lines = {}
if arg.text then
  for line in (arg.text .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line:gsub("\t", "    ") end
else
  for _, line in ipairs(BANNER) do lines[#lines + 1] = line end
  lines[#lines + 1] = ""
  lines[#lines + 1] = TAGLINE
end
local cells = term.grid(lines)

local HOLD = 1.5                    -- seconds the finished text holds

local function effect_scene(name, fx)
  scene { name, duration = fx.ticks / term.FPS + HOLD, render = function(f)
    fx.draw(math.min(f.index, fx.ticks - 1))
  end }
end

effect_scene("decrypt", require("effects.decrypt").build(cells, 1))
