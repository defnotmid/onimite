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

- `shader(f, {...})` or `shader{...}` (video clock). Source: `sksl = [[...]]`,
  `shadertoy = [[...]]`, or `src = "glow.sksl"` / `"tunnel.glsl"` (in `media/` or relative to
  the script; `.glsl` means Shadertoy).
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
- Shadertoy multipass (Common + Buffer A-D + Image) is a table in place of the source:
  `shadertoy = { common = "common.glsl", buffer_a = { src = "a.glsl", channels = { "buffer_a",
  "photo.jpg" } }, image = { source = [[...]], channels = { "buffer_a" } } }`. A pass is
  `{ source = [[...]] | src = "x.glsl", channels }` or just its source; Common's `#define`s and
  functions are visible in every pass. Channel n (`iChannelN`) is `"buffer_a".."buffer_d"`
  (this frame's output of an earlier buffer; itself or a later buffer gives the previous
  frame: feedback) or an input like a uniform child (image, clip table, group function).
  Buffers run A..D then Image; they are RGBA16F (unclamped) at the box's size in its own
  units (a 960x540 box drawn with `scale(2, 2)` halves the cost) and start black at iFrame 0.
  Seeking is exact (`frame 300` runs the buffers for frames 0..299 first), so keep effects a
  function of iFrame/iTime, not of wall time. Uniforms go to every pass that declares them.
  Errors read `shader image.glsl: Buffer A:3:9: ...`. See `examples/shadertoy_multipass`.
- Uniform values: numbers, booleans, lists (vectors, matrices column by column, arrays),
  colours (`"#rrggbb"`, `rgb()`, animated). Up to four `uniform shader` children: a media
  image name, a clip `{ src = "clip.mp4", looping = true, start_from = 0, clip_start = 0 }`,
  a function (a group drawn in the box's units), or `{ group = fn, w = 400, h = 300 }`.
  Children sample with `child.eval(p)` in their own pixels (bilinear, clamped, premultiplied).
- oksl accepts `for`, `while`, `do`, `switch` and dynamic array indexing in both dialects, with
  no iteration cap: a loop that never ends hangs the render. Compile errors are diagnostics `shader glow.sksl:12:7: ...` (the layer is skipped);
  undeclared or unset uniforms warn. Always look at a `frame` PNG of a shader: a clean
  inspect does not prove it looks right.
- A shader layer composes like an image (transforms, clips, masks, filters, opacity) and runs
  at its on-screen pixel size; `--software` runs oksl's CPU interpreter.
