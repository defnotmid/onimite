# shader_passes

A program of passes in two dialects, 6 seconds at 1280x720, 30 fps.

```sh
onimite render examples/shader_passes/video.lua -o passes.mp4
onimite frame examples/shader_passes/video.lua 150 -o frames   # runs frames 0..149's trail first
```

| file | pass | reads |
| --- | --- | --- |
| `shaders/trail.sksl` | `trail` (SkSL) | itself (`uLast`: its last frame, swirled, spread and faded), the dots group (`uDots`) |
| `shaders/show.frag` | `show` (GLSL, drawn) | `trail` this frame (`uTrail`), through a cosine palette |

Inputs are bound by name: `uLast` and `uDots` are the trail's `uniform
shader` children, `uTrail` the GLSL pass's `sampler2D`. The trail renders
into a half-float buffer at the box's size; `show`, the last pass, runs at
the on-screen size.
