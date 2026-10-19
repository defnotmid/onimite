# suite

onimite, ovg, oksl, odecs, o3d, odawg and ottis used together in one 36
second piece: 1920x1080, 60 fps, 120 BPM. The seven aren't shown one after
another; the picture is one composition through all of it:

- **oksl** compiles `media/world.sksl`, the world everything sits in: a sky
  over a moving grid floor, with `canyon.webp` (decoded by odecs) as a
  duotone skyline. Its `uniform shader uWorld` child is a group of nodes
  that it warps, splits into colour fringes, blooms and, in the second
  half, folds into a six-way kaleidoscope.
- **ovg** draws that group (`world.lua`): the lines of this script typing
  themselves (glow filter), planets lit by focal radial gradients, a
  spectrum ring, "LUA SCRIPT IN · MP4 OUT" seen through a sliding stripe
  mask, and in the break the suite's structure. It also draws the rocket,
  an SVG (`rocket.svg`, from ovg's demo) animated by element id: flame
  flicker, fins kicking on the beat, the window's colour, the stars hidden.
- **o3d** draws the gyroscope in the middle of the spectrum ring
  (`view3d{}` in `world.lua`): four lit tori in the libraries' colours
  turning round onimite's green core, swelling with the kick and the bass.
  It is part of the shader's child group, so the warp bends it, the
  fringes split it and the kaleidoscope folds it into rings.
- **odecs** decodes Pip, the dancing mascot, live on the frame clock: the ProRes
  4444 `.mov` and the VP9-alpha `.webm` glow in masked portals over the
  shader world. In the kaleidoscope the VP9 clip is drawn *inside* the
  shader's child group, so the fold multiplies it.
- **odawg** composes and mixes the soundtrack (`track.lua`, a `song{}`:
  synthwave on the library's 909 machine, octave saw bass, wide pads, a
  dotted-eighth arp, a lead in the kaleidoscope), and the picture reads it:
  its sections and blips place every moment, its kicks (`score.pulse`)
  bulge the shader and pump the picture, its mix is the spectrum ring
  (labelled "odawg's mix") and the shader's fringes and floor glow, and a
  readout shows its section and bar (`score.section`).
- **ottis** says the break's line ("Seven libraries. One frame clock. One
  binary.", `say()`, the default voice alba), timed word by word: the
  captions highlight each word as it is said, and the music ducks under it.
- **onimite** runs the Lua script and puts it all on one frame clock.

```sh
onimite render examples/suite/video.lua -o suite.mp4
```

| beats | seconds | section | what |
| --- | --- | --- | --- |
| 0-16 | 0-8 | `ignition`, `liftoff` | the world fades up, the script's lines type in, the rocket rises on its blip; the kick, a riser |
| 16-32 | 8-16 | `drop` | full warp, the 3D gyroscope springs up inside the spectrum ring, the rocket flies a figure of eight, the portals open on their blips (beats 20 and 24) |
| 32-48 | 16-24 | `kaleido` | the portals dive into the centre, the kaleidoscope folds the VP9 dancer, the gyroscope and the spectrum ring; the rocket orbits; a stutter before the break |
| 48-56 | 24-28 | `break` | the warp settles and the structure draws itself, a box a blip (o3d's lands with the SDL_GPU row on 52, then odawg's and ottis's); ottis says the line, its words lit as they are said |
| 56-72 | 28-36 | `lockup`, `tail` | "onimite · ovg · oksl · odecs · o3d · odawg · ottis" (a name an eighth, ottis's with the line on its crash, 60), "one binary, all Odin, Lua scripts", the structure under it; the last hit on 68 |

The text on screen comes from the seven READMEs. Files: `track.lua` (the
song, D minor: its sections are the piece's parts, its transitions the
risers and the impacts on the drop and the lockup, its own parts the blips,
crashes and stutters the picture lands on), `timeline.lua` (every moment in
beats, read from the song: section starts and those parts' hits, so the
picture moves when the song does), `beat.lua` (easing on the song's beat),
`ui.lua` (palette, spectrum), `world.lua` (the shader's child group, the
gyroscope),
`video.lua` (the shader layer, portals, rocket, captions, lockup).

## Media

- `rocket.svg`: drawn for ovg's demo (CC0).
- `transparent.mov`, `avatar_vp9_alpha.webm`: Pip, the examples' mascot,
  dancing on a transparent background (a two second loop at 120 BPM), as
  ProRes 4444 and as VP9 with an alpha stream. Rendered by onimite from
  `tools/gen_media/mascot.lua` and encoded by `tools/gen_media/gen.sh`.
- `canyon.webp`: a photo-like canyon panorama (4800x928, lossy WebP),
  rendered by onimite from `tools/gen_media/canyon.lua` (turbulence-lit
  rock strata, noise ridges) and encoded by `gen.sh`.
- Fonts (OFL): Bebas Neue, Space Grotesk, JetBrains Mono.
- The soundtrack is composed by odawg from `track.lua`. The spoken line is
  Pocket TTS by Kyutai (CC-BY-4.0), voice alba, through ottis. All of the media above is part of this
  repository (MIT); `tools/gen_media/gen.sh` regenerates the clips and the
  panorama.
