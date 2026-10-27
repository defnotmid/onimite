-- "ONIMITE vs FFRAMES" drawn into a group that an SkSL shader reads as its
-- `uniform shader` child: glitched slices and colour split in the intro
-- bar, a ripple ring from the slam on bar 2, small kicks on every beat.

local beat = require("beat")
local score = require("track")
local ui = require("ui")
local T = require("timeline")
local facts = require("facts")
local snap, soft = beat.snap, beat.soft

local GLITCH = [[
uniform float3 iResolution;
uniform shader uText;
uniform float uGlitch;  // 0..1: slices pushed sideways, colour split
uniform float uRipple;  // seconds since the slam; negative: no ring
uniform float uSeed;    // changes every 32nd note

float hash(float n) { return fract(sin(n * 127.1 + 311.7) * 43758.547); }

half4 main(float2 coord) {
    float2 p = coord;
    // a ring expanding from the middle bends the text as it passes
    if (uRipple >= 0.0) {
        float2 d = p - iResolution.xy * 0.5;
        float r = length(d);
        float x = (r - uRipple * 1500.0) / 110.0;
        float w = exp(-x * x) * exp(-uRipple * 1.5);
        p -= d / (r + 0.001) * sin(x * 6.0) * 30.0 * w;
    }
    // horizontal slices, some pushed sideways
    float band = floor(coord.y / 16.0);
    if (hash(band + uSeed * 13.0) > 1.0 - uGlitch * 0.6) {
        p.x += (hash(band * 7.0 + uSeed) - 0.5) * 300.0 * uGlitch;
    }
    float split = 3.0 + 26.0 * uGlitch;
    half4 r = uText.eval(p + float2(split, 0.0));
    half4 g = uText.eval(p);
    half4 b = uText.eval(p - float2(split, 0.0));
    half4 c = half4(r.r, g.g, b.b, max(g.a, max(r.a, b.a)));
    c.rgb *= 0.9 + 0.1 * sin(coord.y * 3.14159);
    return c;
}
]]

-- The shader's box and the title inside it, centred with widths measured
-- once at load.
local BOX = { x = 0, y = 230, w = 1920, h = 470 }
local SIZE, VS_SIZE, GAP = 210, 156, 36
local W_O = text_width { "ONIMITE", font = ui.DISPLAY, size = SIZE }
local W_VS = text_width { "vs", font = ui.SERIF, size = VS_SIZE, italic = true }
local W_F = text_width { "FFRAMES", font = ui.DISPLAY, size = SIZE }
local X0 = (BOX.w - (W_O + GAP + W_VS + GAP + W_F)) / 2
local BASE = 330 -- baseline inside the box

local function title_text()
  text { "ONIMITE", x = X0, y = BASE, font = ui.DISPLAY, size = SIZE, fill = ui.O }
  text { "vs", x = X0 + W_O + GAP, y = BASE - 12, font = ui.SERIF, size = VS_SIZE, italic = true, fill = ui.TEXT }
  text { "FFRAMES", x = X0 + W_O + GAP + W_VS + GAP, y = BASE, font = ui.DISPLAY, size = SIZE, fill = ui.F }
end

local function render(f, lb)
  local slam = T.TITLE_SLAM
  local glitch, opacity, s
  if lb < slam then
    -- the intro bar: flickering on sixteenths, solid on the glitch hits
    local on = hash(math.floor(lb * 4)) > 0.4 or pulse(lb, 6) > 0.5
    glitch = 0.55 + 0.45 * pulse(lb, 4)
    opacity = on and 0.85 or 0.15
    s = 0.9
  else
    glitch = math.max(math.exp(-(lb - slam) * 3), 0.1 * pulse(lb, 10), 0.45 * pulse(lb / 4, 12))
    glitch = math.max(glitch, progress(lb, 15.25, 16))
    opacity = 1
    s = 1 + 0.15 * (1 - soft(lb - slam))
  end

  -- the spectrum as a thin bar row under the title
  local bands = ui.spectrum(f, 64)
  group({ opacity = progress(lb, slam, slam + 1) * 0.8 }, function()
    for i, v in ipairs(bands) do
      local h = v * 110 + 3
      rect { x = 96 + (i - 1) * 27, y = 1010 - h, w = 18, h = h, rx = 3,
        fill = i % 2 == 0 and ui.O or ui.F, fill_opacity = 0.75 }
    end
  end)

  group({ opacity = opacity, transform = { scale = s, origin = { 960, BOX.y + BASE - 90 } } }, function()
    shader(f, { sksl = GLITCH, x = BOX.x, y = BOX.y, w = BOX.w, h = BOX.h,
      uniforms = { uText = title_text, uGlitch = glitch, uSeed = math.floor(lb * 8),
                   uRipple = lb >= slam and score.seconds(lb - slam) or -1 } })
  end)

  local sub = snap(lb - 6)
  group({ opacity = progress(lb, 6, 6.1), transform = translate(0, (1 - sub) * 40) }, function()
    text { "same videos · same machine · measured", x = 960, y = 700, align = "center",
      font = ui.MONO, size = 34, fill = ui.TEXT }
  end)
  local note = snap(lb - 8)
  group({ opacity = progress(lb, 8, 8.1), transform = translate(0, (1 - note) * 30) }, function()
    text { string.format("BENCHMARK.md · %s · %s · %s", facts.versions, facts.machine, facts.runs), x = 960, y = 752, align = "center",
      font = ui.MONO, size = 22, fill = ui.DIM }
  end)
  local tag = snap(lb - 10)
  if lb >= 10 then
    local label = "this title: SkSL reading a live text group · fframes binds only images"
    local w = text_width { label, font = ui.MONO, size = 20 } + 28
    ui.chip(960 - w / 2, 150, label, ui.LINE, ui.O, 20, tag)
  end
end

return { name = "Title", section = "title", render = render }
