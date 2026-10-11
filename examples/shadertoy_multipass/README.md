# shadertoy_multipass

A Shadertoy multipass program: Common, two buffers with feedback and the
Image pass, 12 seconds at 1920x1080, 30 fps.

```sh
onimite render examples/shadertoy_multipass/video.lua -o multipass.mp4
onimite frame examples/shadertoy_multipass/video.lua 300 -o frames   # runs frames 0..299's buffers first
```

| file | pass | reads |
| --- | --- | --- |
| `shaders/common.glsl` | Common | the palette, the swirl and the comet paths, `#define`s every pass sees |
| `shaders/ink.glsl` | Buffer A | itself (the previous frame: ink drifting and fading), the emitter group |
| `shaders/glow.glsl` | Buffer B | Buffer A (this frame) |
| `shaders/image.glsl` | Image | Buffer A and Buffer B |

The emitter is a group channel: six dots on a turning ring drawn by the
script each frame, which Buffer A turns into ink. The shader box is
960x540 units drawn with `scale(2, 2)`, so the buffers are 960x540 and the
Image pass runs at 1920x1080.
