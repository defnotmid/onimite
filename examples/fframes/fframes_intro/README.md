# fframes_intro

A port of fframes' `fframes-intro` example
(`third_party/fframes/examples/fframes-intro`): the 127.5 s, 1920x1080,
60 fps introduction to fframes, made with fframes. Everything sits on the
132 BPM beat grid of the soundtrack (`beat.lua`); every scene starts on a
downbeat.

| scene | beats | what |
| --- | --- | --- |
| PromptScene | ..0 | the prompt typed into a coding agent over a contour shader |
| OriginScene | 0..32 | the first commit's year digit by digit, the git history scrolling past, the numbers, "video = f(frame)" |
| CodeScene | 32..48 | the code typed out next to its output, EVERY FRAME., "RENDERED ON THE" |
| GpuScene | 48..56 | the GPU slam, then the render pipeline with packets on the beat |
| TextScene | 56..62 | marquee rows of outlined Anton, one lit per beat |
| ImageScene | 62..66 | the beta poster developing from an orange dither (develop.sksl) |
| VideoScene | 66..72 | two podcast feeds; the right one chroma-keyed (key.sksl) over the tunnel |
| ShaderScene | 72..80 | the tunnel (tunnel.sksl) opens to full frame, its source scrolls, the guest prints as halftone |
| ScaleScene | 80..96 | HOW FAST?, a wall of 3,334 text nodes, REMOTION vs FFRAMES |
| BenchmarkScene | 96..128 | the export race, N× FASTER, the numbers (grid.sksl) |
| PreviewScene | 128..160 | the preview window capture; NO BROWSER AT ALL ANYWHERE |
| AgentsScene | 160..208 | the agentic loop ring with command output cards; THIS VIDEO WAS MADE BY AN AGENT |
| RenderScene | 208..224 | frames of this video flying out of the grid, frame count and render time |
| RecapScene | 224..236 | one word per beat on alternating colours, ALL OF IT. in Rust. |
| DoneScene | 236..240 | `cargo fframes new my-video` typed in silence |
| OutroScene | 240.. | the fframes wordmark with its trail of f's and the install commands |

A video-level pass (as the original's `render_frame`) draws the scenes with
the beat pump, flashes on the drops, three-frame glitch cuts (the scenes
drawn six times in clipped, shifted bands), film grain (grain.sksl) and a
difference-blended HUD (bars, beats, timecode, section).

Audio: `music.wav` (1.5 s fade out) and sound effects on the beats (typing,
enter, impacts, shutter, glitch, whooshes, blips, braam), master gain
+3.5 dB into a -1.3 dBFS limiter as in the original's `AudioMixOptions`.

```sh
onimite render examples/fframes/fframes_intro/video.lua -o intro.mp4
onimite preview examples/fframes/fframes_intro/video.lua
```

Files: `video.lua` (scenes list, audio, the video-level pass), `beat.lua`
(clock and easing), `ui.lua` (palette, type, HUD pieces, the Slam text),
`facts.lua` (numbers shown on screen), `scenes/*.lua` (one per scene, as in
the original), `shaders/*.sksl` (the original's six shaders, unmodified),
`media/` (the original's `media/` and `dynamic_media/`).

## Notes on matching the original

- **Numbers.** The original computes in f32; this port uses Lua's doubles,
  so the hash noise (`fract(sin(n * 127.1 + 311.7) * 43758.547)`, used for
  the glitch bands, the GPU shake, the text wall and the flying thumbnails)
  gives different values from the same formula. `fract` and `as usize`
  follow Rust (truncation, negatives saturating to 0).
- **Easing** is the original's own math (expo, cubic, quart, a closed-form
  spring in `beat.rs`), ported as is; it uses none of fframes' named easings.
- **Git history.** OriginScene reads `git log --reverse
  --format=%h|%ad|%s --date=short` of `third_party/fframes` when the script
  loads (the original's build.rs runs it at build time on its repository).
  Without git the scene shows no commits, as in the original.
- **Glitch bands** clip in the band's shifted space (SVG: the clip path is in
  the user space of the element that carries the transform).

## Differences

- Text widths come from onimite' `text_width` (the shaped, kerned string,
  measured when the script loads), not fframes' sum of whole-pixel character
  advances. What is placed by a width (the wordmark's centring, the stats'
  unit, the marquee rows' period, the year's digits) can sit a few pixels
  from the original.
- PSNR against fframes' frames is 39-44 dB on most frames. The rest is
  grain and anti-aliasing, the raymarched tunnel's fine lines (35 dB at
  Shader@2.7s), and the dither/threshold shaders: the poster's develop pass
  switches pixels on hard thresholds, so the first frames of ImageScene
  differ pixel by pixel (down to 22-25 dB) while looking the same.
- `inspect` matches fframes' 13 findings (canvas overflow on purpose) plus
  one: "HOW" on the first frame of ScaleScene, faint (opacity 0.2) and left
  of the canvas, which fframes' check does not report.
