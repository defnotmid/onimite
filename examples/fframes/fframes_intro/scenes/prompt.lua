-- Cold open: the prompt that asked for this video, typed into a coding agent.

local beat = require("beat")
local ui = require("ui")
local facts = require("facts")
local prog, expo_out, gsec, usize, fract = beat.prog, beat.expo_out, beat.gsec, beat.usize, beat.fract
local ORANGE, BONE, GREY, MONO = ui.ORANGE, ui.BONE, ui.GREY, ui.MONO

local PROMPT = "make an intro video for fframes. make it stunning."

-- Agent output after the prompt: (is a tool call, text).
local OUTPUT = {
  { true, "Explored skills/fframes-video" },
  { false, "Read SKILL.md, design.md, audio.md" },
  { true, "Edited src/lib.rs" },
  { true, "Ran cargo run --release -- timeline" },
  { true, "Ran cargo run --release -- strip all -n 24" },
}

local CHARS = #PROMPT
-- two lines: the first sentence, then "make it stunning."
local SPLIT = (PROMPT:find(". ", 1, true) or CHARS - 1) + 1
local ENTER_AT = beat.beat_time(-1)

local function render(f)
  local t = gsec(f)
  local typed = math.min(usize(8 + (t - 0.02) * 44), CHARS)
  local shown = PROMPT:sub(1, typed)
  local done = typed >= CHARS
  -- caret blinks once typing is done
  local caret_on = not done or fract(t * 3) < 0.55
  local line1, line2 = shown:sub(1, SPLIT), shown:sub(SPLIT + 1)
  local adv = 64 * 0.6
  local on_second = typed > SPLIT
  local caret_x = 240 + (on_second and typed - SPLIT or typed) * adv
  local caret_y = on_second and 612 or 522

  local after = t - ENTER_AT
  local lift = after > 0 and -expo_out(after / 0.25) * 200 or 0
  local enter_flash = after > 0 and math.exp(-after * 9) or 0

  shader(f, { src = "shaders/contour.sksl", x = 0, y = 0, w = 1920, h = 1080, uniforms = {
    uWell = { 0.74, 0.62 }, uDepth = 0.6, uDensity = 16, uBright = 0.35 + enter_flash * 0.4,
    uInk = "#8a857c", uHot = ORANGE } })
  group({ transform = translate(0, lift) }, function()
    text { "CODEX  ·  ~/dev/fframes", x = 160, y = 366, font = MONO, weight = 500, size = 22, letter_spacing = 2, fill = GREY }
    text { facts.RELEASE_LABEL, x = 1760, y = 366, align = "end", font = MONO, weight = 500, size = 28,
      letter_spacing = 2, fill = GREY }
    rect { x = 140, y = 400, w = 1640, h = 270, rx = 18, fill = "#0f0e0d", fill_opacity = 0.85,
      stroke = after > 0 and ORANGE or "#4a4640", stroke_width = 2 }
    text { "›", x = 180, y = 522, font = MONO, weight = 600, size = 64, fill = ORANGE }
    if line1 ~= "" then text { line1, x = 240, y = 522, font = MONO, weight = 500, size = 64, fill = BONE } end
    if line2 ~= "" then text { line2, x = 240, y = 612, font = MONO, weight = 500, size = 64, fill = ORANGE } end
    rect { x = caret_x + 4, y = caret_y - 50, w = 32, h = 64, fill = ORANGE,
      opacity = (caret_on and after <= 0) and 1 or 0 }
  end)
  group({ transform = translate(0, -40) }, function()
    for i, line in ipairs(OUTPUT) do
      local call, s = line[1], line[2]
      local at = ENTER_AT + 0.05 + (i - 1) * 0.07
      local y = 560 + (i - 1) * 44
      group({ opacity = prog(t, at, at + 0.06) }, function()
        if call then
          circle { cx = 172, cy = y - 9, r = 7, fill = ORANGE }
        else
          path { d = string.format("M204 %s V%s H222", y - 26, y - 9), fill = "none", stroke = GREY, stroke_width = 2 }
        end
        text { s, x = call and 200 or 236, y = y, font = MONO, size = 28, fill = "#b9b4ab" }
      end)
    end
  end)
end

return { name = "PromptScene", start = nil, stop = 0, render = render, PROMPT = PROMPT }
