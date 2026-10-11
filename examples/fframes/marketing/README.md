# marketing

A port of fframes' `marketing` example (`third_party/fframes/examples/marketing`):
a 21.8 s, 1920x1080, 60 fps pitch video.

- A seven-bar audio spectrum of `marketing.mp3` (16-sample FFT smoothed
  over 3 frames, on a square-root scale): white-outlined pills with
  diagonal gradients and coloured glows (an SVG filter graph: blur of the
  alpha, offset, flood, composite, merge).
- Ferris springing in from the bottom right with blinking eyes (gradients
  under SVG matrices).
- A code card and a dashed hand-drawn arrow springing in at 5.8 s.
- At 16 s the bars collapse to the centre, a white circle grows and the
  "fframes" logo appears with a dash-animated wave stroked with a gradient.
- Audio: `marketing.mp3`, `woosh.mp3` at 6 s and `end.mp3` at 16 s.

```sh
onimite render examples/fframes/marketing/video.lua -o marketing.mp4
onimite preview examples/fframes/marketing/video.lua
```

## Deviations

- Springs settle at a residual of 0.001 in the engine, where fframes' spring
  timing runs longer. The difference is under a pixel.
