# graph_paper

A 30 second piece on a drafting sheet (1080x1350, 60 fps): the seven letters
of ONIMITE and the seven marks of its libraries (onimite's Pip, ovg, oksl,
odecs, ottis, o3d's Oxa, odawg). Every shape is one outline (`outline{}`):
drawn as ink, morphed, extruded into a solid and collided as a physics body.

```sh
onimite preview examples/graph_paper/video.lua
onimite render examples/graph_paper/video.lua -o graph_paper.mp4
```

| bars | seconds | scene (song section) | what |
| --- | --- | --- | --- |
| 0-2 | 0-5 | Plot (`plot`) | the rules fade up; a pen draws each letter on the major lines and each mark below it, each on its note (a bell, a pluck); coordinates noted; the ink fills in |
| 2-4 | 5-10 | Morph (`morph`) | the notes fade; the rows trade places through each other, each letter morphing into its mark on the way down and each mark into its letter on the way up |
| 4-7 | 10-17.5 | Lift (`lift`) | the shapes leave the page as bevelled solids (cream faces and ink walls; the marks red) and spin through each other in two rings at right angles; a riser pulls them in, and on the impact they burst at the camera and past it, an ink shock ring across the paper |
| 7-12 | 17.5-30 | Fill (`fill`) | 84 letters and marks rain onto the empty sheet and pile up by their outlines, a tick per landing; the title block is drawn on the paper above them with a bell chord |

How it's made:

- **Outlines**: `outline { "O", font = "Bebas Neue", size = 250, align =
  "center", baseline = "middle" }` for a letter about (0, 0), `outline { svg =
  "ovg.svg", id = "silhouette", ... }` for a mark (each library's logo has a
  hidden `silhouette`, its pixels traced into one outline). The same handles at
  page size and at 3D size (1.5 units).
- **Plot**: `path{ d = h }` with `path_length = 1` and a dash offset for the
  pen; the stroke fades into the fill, so the cut to Morph shows nothing new.
- **Morph**: `morph(letter, mark)` once per pair at load, `morph_at(m, k)`
  every frame; letters with counters morph into solid marks (the counters
  shrink away).
- **Lift**: `ExtrudeGeometry` of the 3D outlines with `side_material` for the
  walls; `bevel_offset = -bevel_size` keeps each solid as big as its page
  shape, and the marks' bevel stays under half a pixel (deeper folds them:
  `extrude_folded`). The scene starts on the page: a camera straight on at
  1 unit = 100 px, each solid sunk so its front face is on the paper, the 3D
  layer fading in under the 2D shapes, which then dissolve.
- **Fill**: `physics{}` bodies with `outline = shape` (convex pieces of each
  outline, holes and all), spawned a golden-ratio step apart across the width;
  the contacts place the ticks (`sound { "tick" }`, pitched by the shape).
- **Sound**: `track.lua` is an odawg song in D minor at 96 BPM, its sections
  the scenes. The ambient style plays the pad, bells, strings and sub; the
  example's parts are the pen (a bell per letter), the ink (a pluck per mark),
  the riser, the impact with a crash and a whoosh, and the title chord. The
  picture reads its timing from them (`score.hits`, `score.time`). Mastered to
  -14.8 LUFS, -1.5 dBTP (`master_gain_db`, `limiter`).

Renders in 3.9 s on Linux (a Radeon RX 9070 XT) and 8.8 s on an M4.

Media: fonts copied from motion_poster (OFL): Bebas Neue, Instrument Serif
Italic, JetBrains Mono. The marks are the libraries' own `assets/logo.svg`
(`art/logo.svg` for ottis and odawg), drawn by their `tools/mascot`.
