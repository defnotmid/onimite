# graph_paper

A 30 second piece on a drafting sheet (1080x1350, 60 fps): the seven letters
of ONIMITE and the seven marks of its libraries (onimite's Pip, ovg, oksl,
oicut, ottis, o3d's Oxa, odawg). Every shape is one outline (`outline{}`):
drawn as ink, morphed, extruded into a solid and collided as a physics body.

```sh
sh examples/graph_paper/fetch.sh                 # the landings' clacks (a CC0 recording), once
onimite preview examples/graph_paper/video.lua
onimite render examples/graph_paper/video.lua -o graph_paper.mp4
```

| bars | seconds | scene (song section) | what |
| --- | --- | --- | --- |
| 0-2 | 0-5 | Plot (`plot`) | the rules fade up; a pen draws each letter on the major lines and each mark below it, each on its note (a piano note, a harp pluck); coordinates noted; the ink fills in |
| 2-4 | 5-10 | Morph (`morph`) | the notes fade; the rows trade places through each other, each letter morphing into its mark on the way down and each mark into its letter on the way up |
| 4-7 | 10-17.5 | Lift (`lift`) | the shapes leave the page as bevelled solids (cream faces and ink walls; the marks red) and spin through each other in two rings at right angles; the strings swell and the timpani roll pull them in, and on the timpani's hit they burst at the camera and past it, an ink shock ring across the paper |
| 7-12 | 17.5-30 | Fill (`fill`) | 84 letters and marks rain onto the empty sheet and pile up by their outlines, a wooden clack per landing; the title block is drawn on the paper above them with a piano chord |

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
  shape, and the marks' bevel stays under half a pixel (deeper closes their
  pixels up). The scene starts on the page: a camera straight on at
  1 unit = 100 px, each solid sunk so its front face is on the paper, the 3D
  layer fading in under the 2D shapes, which then dissolve.
- **Fill**: `physics{}` bodies with `outline = shape` (convex pieces of each
  outline, holes and all), spawned a golden-ratio step apart across the width;
  the contacts place the clacks: single clacks of a real recording (a wooden
  game piece dropped on a table, CC0, fetched by `fetch.sh`), taken with
  `offset` and `stop` and pitched a little by the shape through `speed`.
- **Sound**: `track.lua` is an odawg song in Ab major at 96 BPM after Nils
  Frahm's "Says", its sections the scenes, no library style: one synth
  arpeggio of the song's own (two detuned saws and a square through a
  resonant low-pass) cycling six sixteenths against the bar, its filter
  opening over the piece to its peak at the burst (`automation`) and closing
  as the shapes fall back; a soft grand for the pen (a note per letter) and
  the chords, a harp for the ink (a pluck per mark), quiet cellos and violas
  swelling under the lift, a timpani roll and hit with a real cymbal on the
  burst, a sine sub, the title block's chord with a glockenspiel glint. The
  orchestral sounds are VS Chamber Orchestra 2's own SFZ files through the
  song's `sources`, pinned in `media/pins/vsco.pins`. The picture reads its
  timing from them (`score.hits`, `score.time`). Mastered to about -14
  LUFS (`master_gain_db`; `onimite audio analyze`).

Renders in 3.9 s on Linux (a Radeon RX 9070 XT) and 8.8 s on an M4.

Media: fonts copied from motion_poster (OFL): Bebas Neue, Instrument Serif
Italic, JetBrains Mono. The marks are the libraries' own `assets/logo.svg`
(`art/logo.svg` for ottis and odawg), drawn by their `tools/mascot`. The landings' clacks: "Board Game Pieces" by taure
(freesound.org/s/555190, CC0), fetched by `fetch.sh`, not committed. Samples (CC0,
downloaded on first use): VS Chamber Orchestra 2 and Osiris Piano by Versilian
Studios; the virtuosity kit by Versilian Studios and Karoryfer Samples.
