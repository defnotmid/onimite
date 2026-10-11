# lottie_demo

Lottie animations (Bodymovin JSON exported from After Effects) composed with
onimite text and shapes, 8 s.

    onimite render examples/lottie_demo/video.lua -o lottie_demo.mp4

The `.json` files in `media/` load as Lottie documents (parsed once, shared
by every frame builder) and draw as vectors with `lottie{ src = ... }`:

- `dalek.json` (1920x1080, 30 fps) plays at the scene clock in a card,
  covering its box and clipped by a group path; `lottie_info` gives its
  length for the caption.
- `spiral.json` (a repeater) plays at `speed = 1.5`, two seconds in
  (`offset = 2`), its shape layer recoloured by a per-layer override
  (`overrides = { ["Shape Layer 1"] = { fill = "#0ea5e9" } }`).
- `trim.json` (trim paths) shows a frame the script picks (`frame = ...`),
  swinging back and forth.
- `title.json` is a text layer: a character animator (letters rise in, then
  a wave scales and recolours them) and a drop shadow effect, laid out with
  the media's DM Sans; its string is replaced by an override
  (`overrides = { ["Title"] = { text = "Lottie text" } }`).

| file | source | license |
| --- | --- | --- |
| `media/dalek.json` | lottie-web `test/animations/dalek.json` ([airbnb/lottie-web](https://github.com/airbnb/lottie-web)) | MIT |
| `media/spiral.json` | Skia `resources/skottie/skottie-repeater.json` ([google/skia](https://github.com/google/skia)) | BSD-3-Clause |
| `media/trim.json` | Skia `resources/skottie/skottie-trimpath-fill.json` | BSD-3-Clause |
| `media/title.json` | made for onimite | MIT (this repository) |
| `media/DMSans-Medium.ttf` | DM Sans | OFL-1.1 |
