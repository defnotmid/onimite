# Shaders in onimite scripts

```lua
local GLOW = [[
uniform float3 iResolution;
uniform float iTime;
uniform half4 uTint;
half4 main(float2 coord) {
  float2 p = coord / iResolution.xy - 0.5;
  float d = length(p) - 0.25 - 0.03 * sin(iTime * 3.0);
  float a = 0.02 / (abs(d) + 0.02);
  return half4(uTint.rgb * a, a) * uTint.a;     // premultiplied
}]]

video { width = 1920, height = 1080, fps = 30, duration = 2, render = function(f)
  shader(f, { sksl = GLOW, x = 460, y = 40, w = 1000, h = 1000,
    uniforms = { uTint = animate(f, { { start = 0, stop = 2, from = "#38bdf8", to = "#f472b6" } }) }, opacity = 0.9 })
end }
```

```lua
-- `uniform shader` children: media images, video clips, or groups of nodes
local RIPPLE = [[
uniform float3 iResolution;
uniform float iTime;
uniform shader uScene;
uniform shader uPhoto;
uniform float uAmount;
half4 main(float2 coord) {
  float2 c = iResolution.xy * 0.5;
  float r = length(coord - c);
  float2 off = normalize(coord - c + 0.001) * sin(r * 0.05 - iTime * 6.0) * uAmount;
  half4 bg = uPhoto.eval((coord + off) / iResolution.xy * 480.0);   // photo.jpg is 480x480
  half4 fg = uScene.eval(coord + off);
  return fg + bg * (1.0 - fg.a);
}]]

video { width = 1920, height = 1080, fps = 30, duration = 2, render = function(f)
  shader(f, { sksl = RIPPLE, x = 0, y = 0, w = 1920, h = 1080,
    uniforms = {
      uAmount = 8,
      uPhoto = "photo.jpg",                    -- sampled in the image's own pixels
      uScene = function()                      -- drawn offscreen in the box's units
        text { "Ripple", x = 960, y = 600, align = "center", font = "DM Sans", size = 220, fill = "#fff" }
      end,
    } })
end }
```

- **Depth of a 3D layer**: `uDepth = { depth_of = "uScene" }` binds the depth of the `view3d`
  drawn in the group input `uScene`, from the same render as its colour (no second 3D render):
  `uDepth.eval(coord)` (same coordinates as `uScene`) gives `r` = distance from the camera along
  its axis in world units, `a` = 1 where something was drawn (`r` = the camera's `far` and
  `a` = 0 where nothing was). For haze, depth of field and edge effects:

```lua
local HAZE = [[
uniform shader uScene;
uniform shader uDepth;
half4 main(float2 c) {
  half4 col = uScene.eval(c);
  half4 d = uDepth.eval(c);
  float fog = d.a > 0.5 ? clamp((d.r - 3.0) / 6.0, 0.0, 1.0) : 1.0;   // 3..9 units fade to haze
  return mix(col, half4(0.75, 0.8, 0.9, 1.0), fog);
}]]
shader(f, { sksl = HAZE, x = 0, y = 0, w = 1920, h = 1080, uniforms = {
  uScene = function() view3d { camera = cam, lights = lights, meshes = meshes } end,
  uDepth = { depth_of = "uScene" } } })
```

  The first `view3d` drawn in that group gives the depth; it covers that 3D layer's box (make
  it fill the group). A `depth_of` naming anything but a group input is `shader_depth_of`.
- `shader(f, {...})` or `shader{...}` (video clock). Source: `sksl = [[...]]`,
  `shadertoy = [[...]]`, `glsl = [[...]]`, or `src = "glow.sksl"` / `"tunnel.glsl"` /
  `"wave.frag"` (in `media/` or relative to the script; `.glsl` means Shadertoy, `.frag` GLSL,
  anything else SkSL).
- SkSL as in fframes' `Shader::sksl`: `half4 main(float2 coord)`, `coord` from the box's
  top-left, premultiplied output. Declared `iResolution` (float3, the box size), `iTime`,
  `iFrame` (from `f`: scene-relative in a scene), `iTimeDelta`, `iFrameRate` are filled for
  you; `time = s` overrides the clock. Use another name (`uClock`) for a clock that continues
  across scenes.
- Shadertoy (`void mainImage(out vec4 c, in vec2 p)`) compiles as GLSL ES 3 (oksl's GLSL
  dialect): `#define` with and without arguments, `#if`/`#ifdef`, `switch`, `discard`,
  bottom-left origin, opaque output. Every Shadertoy input is declared: `iResolution`,
  `iTime`, `iTimeDelta`, `iFrame`, `iFrameRate`, `iSampleRate` (48000), `iChannelTime` (a
  video channel's clip time), `iChannelResolution`, `iMouse`/`iDate` (zero). Bind
  `iChannel0..3` in `uniforms` like children (`iChannel0 = "photo.jpg"`, a clip table or a
  group) and sample with `texture(iChannelN, uv)`, uv 0..1 (also `textureLod`, `texelFetch`,
  `textureSize`). `uniform shader` and `.eval` are SkSL only.
- GLSL (`glsl = [[...]]`, `.frag`) is a GLSL ES 3.0 fragment shader: `void main()` reading
  the layer's uv, `layout(location = 0) in vec2 uv` (0..1 from the box's top-left), and
  writing premultiplied colour to `layout(location = 0) out vec4 color`. Nothing is declared
  for you: declare `uniform float iTime;` (also `iResolution`, `iTimeDelta`, `iFrame`,
  `iFrameRate`) to get the clock, and `uniform sampler2D`s for inputs, sampled with
  `texture(s, uv)`; `texelFetch` and `textureSize` take the image's own size
  (`iChannelResolution` is Shadertoy's only).
- Multipass (feedback, blurs, simulations) in any dialect: `passes` in place of the source
  (see below). Shadertoy's own layout is one spelling of it, a table in place of the
  `shadertoy` source: `shadertoy = { common = "common.glsl", buffer_a = { src = "a.glsl",
  channels = { "buffer_a", "photo.jpg" } }, image = { source = [[...]], channels = {
  "buffer_a" } } }`. A pass there is `{ source = [[...]] | src = "x.glsl", channels }` or just
  its source; channel n (`iChannelN`) is `"buffer_a".."buffer_d"` or an input. It runs as the
  passes "Buffer A".."Buffer D" (those present) and "Image", the output. See
  `examples/shadertoy_multipass`.
- Uniform values: numbers, booleans, lists (vectors, matrices column by column, arrays),
  colours (`"#rrggbb"`, `rgb()`, animated). Up to four `uniform shader` children (a `depth_of` input counts as one): a media
  image name, a clip `{ src = "clip.mp4", looping = true, start_from = 0, clip_start = 0 }`,
  a function (a group drawn in the box's units), or `{ group = fn, w = 400, h = 300 }`.
  Children sample with `child.eval(p)` in their own pixels (bilinear, clamped, premultiplied).
- oksl accepts `for`, `while`, `do`, `switch` and dynamic array indexing in both dialects, with
  no iteration cap: a loop that never ends hangs the render. Compile errors are diagnostics `shader glow.sksl:12:7: ...` (the layer is skipped);
  undeclared or unset uniforms warn. Always look at a `frame` PNG of a shader: a clean
  inspect does not prove it looks right.
- A shader layer composes like an image (transforms, clips, masks, filters, opacity) and runs
  at its on-screen pixel size; `--software` runs oksl's CPU interpreter.

## Passes: multipass in any dialect

```lua
-- examples/shader_passes: an SkSL trail reading its own last frame, coloured by a GLSL pass
shader(f, { x = 0, y = 0, w = 1280, h = 720,
  passes = {
    { name = "trail", src = "shaders/trail.sksl",              -- SkSL: `uniform shader` children
      inputs = { uLast = "trail",                              -- itself: its last frame (feedback)
                 uDots = function() dots(t) end } },           -- a group, drawn every frame
    { name = "show", src = "shaders/show.frag",                -- GLSL: `uniform sampler2D uTrail`
      inputs = { uTrail = "trail" } },                         -- runs earlier: this frame's output
  },
  uniforms = { uFade = 0.965 } })                              -- set in every pass declaring it
```

- A pass is `{ name, sksl | shadertoy | glsl = [[...]] | src = "file", inputs }`; passes mix
  dialects freely. `name` defaults to `"pass N"`. Up to 8 passes; they run in list order.
- `inputs` binds the pass's channels: by name (`uLast = ...` for `uniform shader uLast`,
  `iChannel0 = ...`, a `sampler2D`'s name) or in channel order (`inputs = { "trail", "photo.jpg" }`:
  declaration order for children and samplers, `iChannelN` for Shadertoy). Bind by name in
  SkSL and GLSL so reordering declarations changes nothing.
- An input is another pass's name (its output this frame when that pass runs earlier, else
  its last frame: feedback), `{ previous = "name" }` (always the last frame, also of an
  earlier pass), or anything a uniform child takes (media image, clip table, group
  function). On iFrame 0 a last frame reads transparent black.
- The last pass is drawn, or the one named by `output = "name"`. `common = [[...]]` or
  `common = "common.glsl"` starts every pass's source (Shadertoy's Common; one dialect).
- Passes read as feedback, and every pass but the output, render into RGBA16F buffers at the
  box's size in its own units (a 960x540 box drawn with `scale(2, 2)` halves the cost);
  Shadertoy passes other than the output return their colour unclamped. The output pass runs
  at the box's on-screen pixel size, unless a pass reads it: then its buffer is drawn.
- Seeking is exact in every dialect (`frame 300` runs the feedback passes for frames 0..299
  first; the preview keeps checkpoints), so keep effects a function of iFrame/iTime, not of
  wall time. Only a program where some pass reads a last frame pays that: passes that only
  read earlier passes' output of this frame draw each frame alone.
- Uniform values go to every pass that declares them; inputs go in the passes (`uniforms`
  naming an input warns `shader_pass_input`). Errors name the pass: `shader trail.sksl:
  blur:3:9: ...`, `Common:2:1` for the common source; an input naming a pass the program
  lacks is an error at the channel's first use (`uLast reads trial, which the program does
  not have`), an unknown `output` is `invalid_value`.
