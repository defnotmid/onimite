# made_of_motion

A port of fframes' `made-of-motion` example
(`third_party/fframes/examples/made-of-motion`): a 489-frame, 1440x1080,
24 fps analog / pixel collage film. Pixel objects, a continuous perspective
carousel, thermal performances, paper texture and per-exposure vector ink,
ending on seven flying letters assembling into the fframes wordmark, on the
original soundtrack's cut boundaries.

```sh
onimite render examples/fframes/made_of_motion/video.lua -o made-of-motion.mp4
onimite preview examples/fframes/made_of_motion/video.lua
```

| scene | frames | what |
| --- | --- | --- |
| Question | 0..48 | two colour flashes, the oversized type panning through dashed rulers, the collapse into scanlines and the blinking selection, handwritten ink |
| Signal | 48..93 | the electric star (signal.sksl) on its measured poses, four mosaic objects, the question |
| Portrait | 93..153 | the cleaned portrait clip through performance.sksl (caption cleanup), ink, "you give it fframes." |
| ThermalCut | 153..157 | four-frame thermal sweep (thermal_cut.sksl) revealing the wheel |
| Orbit, CarouselA/B, OrbitReturn | | the twelve-object wheel tilting and turning, pen impacts (impact.sksl) knocking objects |
| Code, Motion, Feeling | | the feature cards: one wheel object flies out, holds next to its title and returns to its moving slot |
| Scatter | 302..331 | the wheel explodes, "from your mind" |
| Human | 331..382 | the stacked objects, then the hand's heat field (hand.sksl) |
| M, O, V, E | 382..413 | one object per letter on paper / dark / red |
| Fframes | 413..489 | seven letters flying on the measured nib tracks, assembling into "fframes" with a camera pullback |

Files, mirroring the original's: `video.lua` (lib.rs: the edit, the
studio's shader layers, the shots, the pulse and signature scenes, the
audio), `objects.lua` (objects.rs: the wheel, the three excursions and the
impacts, computed for all 489 frames when the script loads), `hero.lua`
(hero.rs), `flight.lua` (flight.rs), `ink.lua` (ink.rs: dust, impact
bursts, the opening retarget), `vector_ink.lua` (vector_ink.rs), `opening.lua`
(opening.rs), `ui.lua` (lib.rs' `label` and the question), and the
measured tables `opening_capture.lua`, `restoration_capture.lua`,
`ink_capture.lua`. `shaders/` holds the original's eight SkSL shaders
unmodified, `vector_ink/` its five gzip archives, `opening-type.path` its
frame-13 path, `media/` its `media/` plus `portrait-clean.mp4` and
`soundtrack.wav` from `dynamic_media/`.

## How the original's assets map

- **`*_capture.rs` are data, not recordings.** They hold poses measured on
  the reference film: `opening_capture.rs` the electric star's centre,
  radii, angle and cusp exponent for frames 51..88 (uniforms of
  signal.sksl), `restoration_capture.rs` the hand's atlas cell and canvas
  rectangle per frame (uniforms of hand.sksl) and the camera body's
  stretch/roll used by the motion card, `ink_capture.rs` the four red nib
  tracks the wordmark letters fly on. They are Lua tables here.
- **`opening-type.path`** is SVG path data: the oversized type as pixel
  blocks on frame 13. `opening.lua` reads it when the script loads and
  draws it as a `path`.
- **`vector_ink/*.paths.gz`**: 34,272 traced contours, one per line
  (`frame|pigment|opacity|d`). `vector_ink.lua` decompresses them with
  `gunzip` when the script loads (as the original does with flate2 when the
  video is built), once per render (`shared`, paths parsed once with
  `path_data`), and keeps per-frame lists of path nodes; pigments 6..9
  are the red nib marks the ending moves with the letters.
- **`hand-field.png`** (a 4096x4925 atlas of heat fields) and
  **`objects.png`** (the 4x3 icon atlas) are `uniform shader` children
  (media images); the portrait clip is a video child of performance.sksl,
  synced to the scene's frames as `get_synced_video_frame` is.

## Notes on matching the original

- Named easings use onimite' `ease_in` / `ease_out` / `ease_in_out` (Odin's
  cubic curves); explicit cubic beziers and the impact spring are the
  original's.
- Objects sort back to front with a stable sort, as Rust's `sort_by`.
- The opening selection's width comes from onimite' `text_width` (the
  shaped string with its -1.25 letter spacing), not fframes' sum of
  whole-pixel advances, so its right bracket sits a few pixels further right.
- PSNR against fframes' frames (with fframes' CSS curves swapped in) is
  45-57 dB on 35 of 37 frames checked across all scenes. The portrait clip
  decodes slightly differently (38 dB), the selection frames (18-22) carry
  the bracket offset above (38 dB), and the soft ink, a stack of up to ~30 translucent outlines, is
  composited in 8 bits per layer on both sides, with different rounding:
  the brown pen strokes come out a little redder here and a little more
  olive in fframes (both are within ~10 levels of the exact composite).
- `inspect` gives fframes' two findings: the oversized type crossing the
  canvas edge on purpose during the camera moves.
- Audio: `soundtrack.wav` from the start, no gain changes and no limiter,
  as the original's `AudioMixOptions { limiter: None }` (kept at the file's
  48 kHz; fframes writes 44.1 kHz AAC). The original's
  README describes a separate FFmpeg step restoring the 24000/1001 cadence
  and the AAC packets for delivery; it applies to this output as well.
