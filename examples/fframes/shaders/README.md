# shaders

Port of fframes' `shaders` example: an aurora background shader, a Shadertoy raymarcher clipped into a
sliding card, and text on top. 1920x1080 @ 30 fps, 8 s.

    onimite render examples/fframes/shaders/video.lua -o shaders.mp4
    onimite render examples/fframes/shaders/video.lua -o shaders.mp4 --software   # oksl's CPU interpreter

`shaders/aurora.sksl` (SkSL) and `shaders/torus.glsl` (Shadertoy code) are fframes' sources, unmodified. They
sit beside the script and are loaded with `shader(f, { src = "shaders/aurora.sksl", ... })`; a `.glsl` file
goes through fframes' Shadertoy-to-SkSL rewrite.

## Notes

- `iResolution` is the box size in its own units, as in fframes. Each layer still renders at its on-screen
  pixel size.
- The aurora's `fract(sin(x) * 43758.5453)` hash depends on `sin` precision. GPUs evaluate `sin` of large
  arguments approximately, so the GPU noise (ours, and Skia's in fframes) differs from the CPU interpreter's
  exact `sin`. The shapes and colors match. The torus and the card differ only on single silhouette pixels,
  where a ray hit tests against the threshold `h < 0.001`.
