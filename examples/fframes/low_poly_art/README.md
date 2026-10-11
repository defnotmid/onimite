# low_poly_art

Port of fframes' `low-poly-art` example (the Owl scene, the only one the original binary renders; pelican,
popuga and spektacled owl are `dead_code` there): 2394 low-poly triangles, a title filled with a jittering
noise texture, and 30 audio-reactive bars. 1920x1080 @ 60 fps, 10 s, with `owl.mp3`.

    onimite render examples/fframes/low_poly_art/video.lua -o low_poly_art.mp4

Rendering takes about 6 s for 600 frames (~100 fps).

The polygon table in `video.lua` is fframes' `owl.rs`.

## Mapping

- Per-frame noise: a sine hash of the frame index (the original hashes it with a u64 splitmix; any per-frame jitter
  in -30..29 will do).
- "EAGLE OWL" `clipPath` of text: a group `mask` with the text drawn in white; the noise is a `pattern` fill (230x177 tile).
- Spectrum: `audio_spectrum(sample_size = 64, smooth = 4, window = "hamming")` + `spectrum_centered`, skipping 2 like the Rust;
  bar heights are `sqrt(magnitude) * 60` clamped to 20..100.
- Nested `<svg height=1080 x=-300 viewBox="0 0 2560 3840">`: translate + uniform scale 0.28125, centred (meet).

## Deviations

- `shape-rendering="crispEdges"` (no anti-aliasing on polygons) is not available; polygons are anti-aliased.
- The original clamps the raw magnitudes, which its ramp-shaped "Hamming" window inflates; with a real Hamming window they
  are small (< 5), hence the square-root scale. Bar heights are not compared against the original's frames.
