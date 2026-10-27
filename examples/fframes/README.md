# fframes examples, ported

All 20 examples of [fframes](https://github.com/dmtrKovalenko/fframes)
(MIT, `LICENSES/fframes-MIT.txt`), ported to onimite: each makes the same
video (its size, frame rate, frame count, shots and timing). They are the
material for the parity checks and the benchmark (BENCHMARK.md,
`tools/bench.sh`). Each folder's README lists what it covers and where it
deviates.

The Lua is ours. The media, fonts, shaders and data the ports use are
fframes' own (photos, music, recordings, SkSL), so they are not committed
here. `fetch.sh` fetches fframes at the commit pinned in
`third_party/fetch.sh` and copies them into place:

    examples/fframes/fetch.sh
    onimite render examples/fframes/hello_world/video.lua -o hello.mp4

`assets.tsv` lists every copied file and where it comes from in fframes'
repository. Run `fetch.sh` again after the pin moves. shader-mode's
soundtrack is not in fframes' repository either, so `fetch.sh` writes the
same 31 s 220 Hz stand-in for both sides.

| fframes | port |
| --- | --- |
| `arm` | `arm` |
| `audio-announce` | `audio_announce` |
| `beta` | `beta` |
| `conference-splash-screen` | `conference_splash_screen` |
| `fframes-intro` | `fframes_intro` |
| `hello-world` | `hello_world` |
| `lottie-launch` | `lottie_launch` |
| `low-poly-art` | `low_poly_art` |
| `made-of-motion` | `made_of_motion` |
| `marketing` | `marketing` |
| `motion-graphics` | `motion_graphics` (three scripts) |
| `neon-triangle` | `neon_triangle` |
| `pixel-memory` | `pixel_memory` |
| `podcast` | `podcast` |
| `shader-mode` | `shader_mode` |
| `shaders` | `shaders` |
| `signal-lab` | `signal_lab` |
| `svg-in-3d` | `svg_in_3d` |
| `teej-podcast` | `teej_podcast` |
| `tiktok` | `tiktok` |
