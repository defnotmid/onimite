# motion_poster

A 20 second generative poster (1080x1350, 60 fps) on a synthesized 120 BPM
ambient techno track. Nothing in it is an image file: every texture is
noise, made with SVG filter primitives, `noise()` and an SkSL shader.

```sh
onimite render examples/motion_poster/video.lua -o motion_poster.mp4
```

| beats | seconds | section | what |
| --- | --- | --- | --- |
| 0-8 | 0-4 | Intro | the field fades up under the pad, the disc swells in, the type grows out of nothing (erode 14 -> 0) |
| 8-24 | 4-12 | Groove | the kick: the outline on NOISE breathes (dilate), a ripple rushes out of the disc on every beat, colour splits on every bar, the field's levels step 5/6 |
| 24-32 | 12-16 | Break | the kick drops out, the type thins (erode), three levels; a riser swirls the poster |
| 32-40 | 16-20 | Finale | the impact: flash, a big colour split, the swirl snaps back, 7/8 levels; fade out |

The layers:

- **The field**: `feTurbulence` (fractal noise) stretched to grey with
  `feColorMatrix` and posterized with `feComponentTransfer` (discrete
  tables) into palette steps mixed in OKLab with `mix_color` (converted to
  linear values: filters work in linear RGB). The group drifts one way while
  its region drifts the other, so the noise slides under a fixed window.
- **The disc**: turbulence as a height map under `feDiffuseLighting` and
  `feSpecularLighting`, combined with the disc's gradient by arithmetic
  composites into embossed metal; the point light wanders by `noise()` and
  dips on the kick.
- **The type** (Bebas Neue): `feMorphology` erode for the entrance and the
  break, dilate minus the letters for outlines (cream on NOISE, breathing
  with the kick; ink on FIELD).
- **Rings and orbs**: five contours around the disc whose radii follow 3D
  `noise()`, and seven orbs on a noise flow, each a content-sized blur
  layer under a sharp core.
- **The shader**: `WARP` (SkSL) takes all of the above as its
  `uniform shader` child: a ripple ring per kick, an RGB split per bar and a
  swirl on the riser.
- **The paper card**: fine turbulence under a distant light, multiplied into
  a cream card; the credits and header sit outside the warp.

Music: `track.lua` synthesizes Am9 Fmaj7 C G at load with why_onimite'
instruments plus a sine sub and dotted-eighth plucks with echoes; the kick,
riser and impact come from `timeline.lua`, which the picture reads too.
`onimite audio analyze`: -13.9 LUFS, -1.5 dBTP.

Render with `build/onimite_speed` (`-o:speed`): 1200 frames in 4.2 s
(16.1 s while turbulence was computed on the CPU every frame).

Media: fonts copied from why_onimite (OFL): Bebas Neue, Instrument Serif
Italic, JetBrains Mono. The music is synthesized.
