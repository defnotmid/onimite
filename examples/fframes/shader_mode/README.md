# shader_mode

A port of fframes' `shader-mode` example
(`third_party/fframes/examples/shader-mode`): a 932-frame, 1920x1080, 30 fps
promo of fframes' shaders, cut in the reference's 30000/1001 source frames.
Eighteen shader programs (seventeen SkSL, one Shadertoy), a 3D wall of
shader cards, the native preview footage and the animated fframes wordmark.

| shots | frames | what |
| --- | --- | --- |
| BlackLead, Boot | 0..26 | black, then the binary boot screen (binary-intro.sksl) |
| Glass, GlassAmber | 26..82 | FFRAMES HAS SHADERS over glass, the camera settling from 4x while the boot screen fades out |
| Chrome .. PrismGlass | 82..141 | eight material cuts on one continuous clock, a white flash into |
| OpenSource, OpenSourceHold | 141..222 | "open source" over liquid chrome |
| Rose, Tunnel, Halftone | 222..256 | obsidian, the Shadertoy tunnel, the halftone wordmark zooming in at the cut |
| ShaderLibrary | 256..307 | the card wall: 156 perspective cards (catalog.sksl, one layer each) tilt apart, the camera dives into the hero card's icon, SkSL + SHADERTOY inside it |
| Gradient .. AuroraOrange | 307..410 | gradient, ASCII, particles, obsidian, spectral silver, four aurora cuts |
| BlackBreak, Flow, Emboss* | 410..496 | flowing gradient zooming into a flash, four embossed wordmarks |
| NativePreview | 496..567 | the preview window recording on a turning plane |
| ShaderMode* | 567..640 | "shader mode" over the spectral shader, skewed camera, glitch bars |
| BlackPause, Eclipse, BlackTail | 640..932 | the wordmark with its trail of f's over the eclipse, falling away |

```sh
onimite render examples/fframes/shader_mode/video.lua -o shader-mode.mp4
onimite preview examples/fframes/shader_mode/video.lua
```

Files: `video.lua` (lib.rs: the shader programs, the shot renderer, the
audio), `edit.lua` (the shot table), `titles.lua`, `transitions.lua` (camera
gestures, flashes, glitch bars), `outro.lua` (the wordmark), `catalog.lua` and
`catalog_layout.lua` (the card wall, its 51 frames of geometry computed when
the script loads), `shaders/` (the original's shader files, unmodified),
`media/` (the original's `media/`).

The programs are assembled when the script loads as lib.rs does: `common`,
`source-effects`, `sculpture` (liquid chrome, obsidian) and `gradient-shared`
(gradient, catalog) before each effect, `iTime` renamed to the source clock
`uClock`; the Shadertoy `tunnel.glsl` only gets `uniform float uClock;` and the
rename.

## Media kept outside Git

As in the original, the soundtrack and the recording are not in the
repository. Put the soundtrack at `media/reference-audio.wav` (without it,
`timeline` warns and the video is silent; fframes refuses to run).
`media/native-scrubbing.mp4` (1920x1124, at least 71 frames) is the recorded
scrubbing shown in NativePreview; without it the bundled poster is used, as
in the original.

## Notes on matching the original

- **Clock.** Each shot's shader gets `uClock` (frames since the shot's
  `clock_start` times 1001/30000 s), `uProgress` (local to the shot),
  `uVariant` and `uBeat`, exactly as `Shot::render_frame`. The boot overlay
  over the first Glass frames sets only `uClock`, `uVariant` and `uMask`, as
  in the original, so both onimite and fframes warn that `uProgress` and
  `uBeat` are not set (they are zero on both sides).
- **Easing** is the original's own math (smoothstep, powers, a closed-form
  spring and expo-out in the outro); no named easings are used.
- **Card wall.** The camera, the card poses, their shutter motion and
  near-plane-clipped screen bounds are computed per frame when the script
  loads, in doubles (the original uses f32); the portal title is clipped by
  the 96-point projected icon circle.

## Differences

- **The wordmark's position.** The outro centres "fframes" and spaces its
  echoes by measured widths. onimite' `text_width` measures the shaped,
  kerned string (819.3 px for "fframes", 81.9 for "f"); fframes sums whole-pixel
  character advances without kerning (835). The wordmark sits 7.8 px to the
  right of the original's, which is all of the Eclipse shot's difference.
- **PSNR** against fframes' frames: 47-75 dB on every shot except Eclipse
  (20.7 dB from the wordmark's offset, 22.5 dB while it falls away) and the
  Halftone zoom (40.5 dB at frame 254, anti-aliasing of the 2.3x
  magnified SDF wordmark). The catalog wall is 63-75 dB, the Shadertoy
  tunnel 72 dB. Whole-video PSNR is 29.7 dB, dominated by the 195-frame
  Eclipse shot. `--software` matches as closely (54-63 dB on the same
  frames).
- `inspect` reports the black shots as empty frames (BlackLead, BlackBreak,
  BlackPause, BlackTail), which fframes' check does not, and the boot
  overlay's two unset uniforms, which fframes prints while rendering.
