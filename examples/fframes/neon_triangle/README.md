# neon_triangle

Port of fframes' `neon-triangle` example: one neon triangle rotating at a constant speed on black, a shader
test clip. The title has a magenta bloom (an SVG filter chain), and a monospace readout shows the angles.
1920x1080 @ 60 fps, 6 s.

    onimite render examples/fframes/neon_triangle/video.lua -o neon.mp4

`shaders/triangle.sksl` is fframes' SkSL source, unmodified.

## Notes

- The text filter (`feGaussianBlur` x2, `feMerge`, `feFlood`, `feComposite in`) maps one-to-one to the
  `filter` primitives. fframes' filter region (`x=-20% y=-50% width=140% height=200%`) is omitted because the
  glow stays inside it.
- GPU and `--software` renders differ by at most 10/255, on a few hundred anti-aliased edge pixels.
