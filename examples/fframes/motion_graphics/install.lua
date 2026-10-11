-- "INSTALL FFF": title, a terminal box with a typed command, and a GitHub link.
--
--     onimite render examples/fframes/motion_graphics/install.lua -o install.mp4

local SNAPPY = spring { mass = 1, stiffness = 300, damping = 26 }
local CMD = "curl -L https://dmtrkovalenko.dev/install-fff-mcp.sh | bash"
local URL = "https://github.com/dmtrKovalenko/fff.nvim"
local MONO = "JetBrains Mono"

-- The command's font size: the largest (42 down to 16, in steps of 2) that
-- fits 1360 px, and the prompt's width at that size.
local CMD_SIZE = 42
while CMD_SIZE > 16 and text_width { CMD, font = MONO, size = CMD_SIZE, weight = 400 } > 1360 do
  CMD_SIZE = CMD_SIZE - 2
end
local PREFIX_W = text_width { "$ ", font = MONO, size = CMD_SIZE, weight = 400 }

video { width = 1920, height = 1080, fps = 60, background = "#000000", duration = 10,
  render = function(f)
    local fs = CMD_SIZE

    local t_scale = animate(f, { { 0, 0.6, 1.5, 1.0, SNAPPY } })
    local t_op = animate(f, { { 0, 0.3, 0, 1, ease_out } })
    local t_y = animate(f, {
      { 0, 0.5, 440, 440, linear },
      { 0.5, 1.0, 440, 260, ease_in_out },
    })
    local box_op = animate(f, { { 0.7, 1.2, 0, 1, ease_out } })
    local box_dy = animate(f, { { 0.7, 1.3, 40, 0, SNAPPY } })

    local box_w, box_h = 1520, 160
    local box_x, box_y, box_r = (1920 - box_w) / 2, 420, 16
    local prompt_x = box_x + 50
    local text_y = box_y + box_h / 2 + 6

    local total = #CMD
    local typed = animate(f, { { 1.0, 2.2, 0, total, linear } })
    local n = math.min(total, math.floor(typed))
    local visible = CMD:sub(1, n)
    local cursor_in = animate(f, { { 1.0, 1.1, 0, 1, linear } })
    local blink = cursor_in
    if typed >= total then blink = (f.index // 30) % 2 == 0 and 1 or 0 end

    local url_op = animate(f, { { 2.5, 3.0, 0, 0.7, ease_out } })
    local url_dy = animate(f, { { 2.5, 3.0, 30, 0, SNAPPY } })
    local accent_w = animate(f, { { 0.4, 1.0, 0.5, 600, ease_in_out } })
    local fade = animate(f, { { 9.2, 9.8, 1, 0, ease_in } })

    local prefix_w = PREFIX_W
    local typed_w = n > 0 and text_width { visible, font = MONO, size = fs, weight = 400 } or 0
    local text_x = prompt_x + prefix_w
    local cursor_x = prompt_x + prefix_w + typed_w + 2

    rect { x = 0, y = 0, w = 1920, h = 1080, fill = "#000000" }
    group({ opacity = fade }, function()
      group({ opacity = t_op,
              transform = { translate = { 960 * (1 - t_scale), t_y * (1 - t_scale) },
                            scale = { t_scale, t_scale } } }, function()
        text { "INSTALL FFF", x = 960, y = t_y, font = "Bebas Neue", size = 200,
          fill = "#ffffff", align = "center", baseline = "central", letter_spacing = 16 }
      end)

      rect { x = 960 - accent_w / 2, y = 380, w = accent_w, h = 2, rx = 1, fill = "#ff8c0099" }

      group({ opacity = box_op, transform = translate(0, box_dy) }, function()
        rect { x = box_x, y = box_y, w = box_w, h = box_h, rx = box_r, fill = "#1a1a2e",
          stroke = "#553300", stroke_width = 1.5 }
        circle { cx = box_x + 32, cy = box_y + 26, r = 9, fill = "#ff5f57" }
        circle { cx = box_x + 58, cy = box_y + 26, r = 9, fill = "#febc2e" }
        circle { cx = box_x + 84, cy = box_y + 26, r = 9, fill = "#28c840" }
        text { "$ ", x = prompt_x, y = text_y, font = MONO, size = fs, fill = "#ff8c00", baseline = "central" }
        if n > 0 then
          text { visible, x = text_x, y = text_y, font = MONO, size = fs, fill = "#e0e0ff", baseline = "central" }
        end
        rect { x = cursor_x, y = text_y - fs * 0.45, w = fs * 0.55, h = fs * 0.9,
          fill = rgba(224, 224, 255, blink) }
      end)

      text { URL, x = 960, y = 680 + url_dy, font = MONO, size = 32,
        fill = rgba(255, 255, 255, url_op), align = "center", letter_spacing = 1 }
    end)
  end,
}
