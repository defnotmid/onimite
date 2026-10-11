-- fframes' `shader-mode` example: a 932-frame, 1920x1080 promo of fframes'
-- shader support with 18 shaders (SkSL and one Shadertoy program), a 3D
-- wall of shader cards, native preview footage and the animated fframes
-- wordmark. The edit is the reference's 30000/1001 source frames, rendered
-- at 30 fps.
--
--     onimite render examples/fframes/shader_mode/video.lua -o shader-mode.mp4
--
-- Modules mirror the original's files: edit.lua (the shots), titles.lua,
-- transitions.lua (camera gestures, flashes and glitch bars), outro.lua (the
-- wordmark), catalog.lua and catalog_layout.lua (the card wall). The shader
-- files in shaders/ are the original's, assembled here as lib.rs does.

local edit = require("edit")
local titles = require("titles")
local transitions = require("transitions")
local outro = require("outro")
local catalog = require("catalog")

local function read(name)
  local file = assert(io.open(SCRIPT_DIR .. "/shaders/" .. name, "rb"))
  local source = file:read("a")
  file:close()
  return source
end

local COMMON = read("common.sksl")
local SOURCE_EFFECTS = read("source-effects.sksl")
local SCULPTURE = read("sculpture.sksl")
local GRADIENT_SHARED = read("gradient-shared.sksl")

local EFFECT_FILES = {
  Ascii = "ascii.sksl", Glass = "glass.sksl", Material = "material.sksl", LiquidChrome = "liquid-chrome.sksl",
  Tunnel = "tunnel.glsl", Halftone = "halftone.sksl", Gradient = "gradient.sksl", Particles = "particles.sksl",
  Obsidian = "obsidian.sksl", Aurora = "aurora.sksl", Flow = "flow.sksl", Emboss = "emboss.sksl",
  Rays = "rays.sksl", Spectral = "spectral.sksl", Eclipse = "eclipse.sksl", Catalog = "catalog.sksl",
  Preview = "preview.sksl", Binary = "binary-intro.sksl",
}

local MASKS = {
  Ascii = "glyph-atlas.png", Binary = "binary-atlas.png", Halftone = "fframes-sdf.png",
  Emboss = "fframes-sdf.png", Catalog = "catalog.png",
}

-- Each effect's program, assembled once as the original's Effect::shader:
-- the shared fragments before the effect, `iTime` renamed to the source
-- clock `uClock`. The Shadertoy tunnel only gets the renamed clock.
local SHADERS = {}
for effect, file in pairs(EFFECT_FILES) do
  local source = read(file)
  if effect == "Tunnel" then
    SHADERS[effect] = { shadertoy = "uniform float uClock;\n" .. source:gsub("iTime", "uClock") }
  else
    local sculpture = (effect == "LiquidChrome" or effect == "Obsidian") and SCULPTURE or ""
    local gradient = (effect == "Gradient" or effect == "Catalog") and GRADIENT_SHARED or ""
    local sksl = table.concat({ COMMON, SOURCE_EFFECTS, sculpture, gradient, source }, "\n")
    SHADERS[effect] = { sksl = (sksl:gsub("iTime", "uClock")) }
  end
end

local TITLE_NAMES = {
  GlassAmber = "Glass", OpenSourceHold = "OpenSource",
  ShaderModeEditor = "ShaderMode", ShaderModeZoom = "ShaderMode", ShaderModeWide = "ShaderMode",
}

local SOURCE_SECONDS = edit.SOURCE_FPS_DEN / edit.SOURCE_FPS_NUM

-- A full-frame layer of an effect.
local function layer(f, effect, uniforms)
  local program = SHADERS[effect]
  shader(f, { sksl = program.sksl, shadertoy = program.shadertoy, x = 0, y = 0, w = 1920, h = 1080,
    uniforms = uniforms })
end

local function render_shot(spec, f)
  local effect = spec.effect
  if not effect then return end
  local frames = spec.stop - spec.start
  local progress = f.index / frames
  local source_index = f.global_index
  -- Geometry stays continuous through color/material cuts, while progress
  -- is local to the edit segment; uClock is the source's rational clock.
  local index = source_index - spec.clock_start
  if effect == "Catalog" then
    transitions.apply(source_index, spec.name, function() catalog.render(f, index, SHADERS.Catalog.sksl) end)
    return
  end
  local seconds = index * SOURCE_SECONDS
  local uniforms = {
    uClock = seconds,
    uProgress = progress,
    uVariant = spec.variant,
    uBeat = math.exp(-(seconds % 0.5) * 12),
  }
  if MASKS[effect] then uniforms.uMask = MASKS[effect] end
  if effect == "Preview" then
    -- The recorded scrubbing when media/ has it (from the shot's start),
    -- else the bundled poster.
    local file = "native-scrubbing.mp4"
    local info = video_info(file)
    if info then
      uniforms.uRecording = { src = file, looping = false }
      uniforms.uRecordingSize = { info.width, info.height }
    else
      uniforms.uRecording = "native-preview-poster.jpg"
      uniforms.uRecordingSize = { 1920, 1124 }
    end
  end
  transitions.apply(source_index, spec.name, function()
    layer(f, effect, uniforms)
    local opacity = 1
    if spec.name == "Glass" and source_index < 35 then
      opacity = math.max(0, math.min(1, (source_index - 31) / 4))
    end
    group({ opacity = opacity }, function()
      if spec.name == "Eclipse" then
        outro.render(index / f.fps)
      else
        titles.render(TITLE_NAMES[spec.name] or spec.name, index / f.fps)
      end
    end)
  end)
  -- The binary boot screen fades out over the start of the Glass shot.
  if spec.name == "Glass" and source_index < 33 then
    layer(f, "Binary", {
      uClock = (source_index - 6) * 1001 / 30000,
      uVariant = 1,
      uMask = "binary-atlas.png",
    })
  end
end

video {
  width = 1920, height = 1080, fps = 30, background = "#000000",
  duration = { frames = edit.SOURCE_FRAMES },
  -- The source soundtrack in stereo, without gain or limiting.
  audio = { { "reference-audio.wav", start = 0 } },
  limiter = false,
}

for _, spec in ipairs(edit.SHOTS) do
  scene { spec.name, duration = { frames = spec.stop - spec.start }, render = function(f) render_shot(spec, f) end }
end
