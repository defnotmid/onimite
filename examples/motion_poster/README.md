# motion_poster

A 20 second generative poster (1080x1350, 60 fps) on a 118 BPM dub
techno track composed by odawg (`song{}`). Nothing in it is an image file: every texture is
noise, made with SVG filter primitives, `noise()` and an SkSL shader.

```sh
onimite render examples/motion_poster/video.lua -o motion_poster.mp4
```

| bars | seconds | scene (song section) | what |
| --- | --- | --- | --- |
| 0-2 | 0-4.1 | Intro (`intro`) | the field fades up under the pad, the disc swells in, the type grows out of nothing (erode 14 -> 0) |
| 2-6 | 4.1-12.2 | Groove (`groove`) | the kick: the outline on NOISE breathes (dilate), a ripple rushes out of the disc on every beat, colour splits on every bar, the field's levels step 5/6 |
| 6-8 | 12.2-16.3 | Break (`break`) | the kick drops out, the type thins (erode), three levels; the hiss swell (the `riser` part) swirls the poster |
| 8-10 | 16.3-20.3 | Finale (`finale`) | the impact (an 808 boom): flash, a big colour split, the swirl snaps back, 7/8 levels; fade out |

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

Music: `track.lua` is an odawg `song{}` of dub techno after Basic Channel's
"Phylyps Trak", in C minor, its four sections named after the scenes and no
library style: every part is written for the poster. Its own `stab` row (three
detuned saws and a square snapped open by a filter envelope) plays an off-beat
Cm9 into a `dub` return (a dotted-eighth `PingPongDelay` feeding back through a
high- and a low-pass, so each repeat darkens), its filter opening across the
groove by `automation`; the harmony lifts once, to Abmaj9, for the break, whose
echoes are thrown up. Under it: the library's 909 (`machines/909.json`) tuned
down and darkened, its kick on every beat and shuffled closed hats with accents
and ghosts; a sine sub on a dotted push ducking under the kick (`sidechain`); the
chord held low as a bed (`pad`); its own `hiss` row (pink noise through a
rising band-pass) as the break's swell; one 808 boom on the root for the impact
(`instruments/808_bass.json`).

The picture reads its cues from the song (`timeline.lua`): the scenes start
on its sections, the outline breathes and the shader ripples on the kicks
really played (`score.pulse(f, { part = "drums", note = "kick" })`, and
the time since the last of `score.hits { part = "drums", note = "kick" }`),
the colour splits on each bar's chord (`score.pulse` on the pad), the swirl
follows the riser's span (`score.events { part = "riser" }`) and the flash
decays from the impact. Drop a kick pattern or move the riser in
`track.lua` and the picture follows. `onimite audio analyze`: -14.7 LUFS,
-1.2 dBTP; the scenes -22, -13, -20 and -13 LUFS.

Render with `build/onimite_speed` (`-o:speed`): 1200 frames in 4.6 s
(16.1 s while turbulence was computed on the CPU every frame).

Media: fonts copied from why_onimite (OFL): Bebas Neue, Instrument Serif
Italic, JetBrains Mono. The music is composed by odawg.
