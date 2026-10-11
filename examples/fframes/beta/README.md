# beta

A port of fframes' `beta` example (`third_party/fframes/examples/beta`): the
32 s, 1920x1080, 60 fps "Welcome to the beta of fframes" video, in seven scenes:

| scene | what |
| --- | --- |
| HeadingScene (3 s) | springing title; "fframes" switches to the Bubble Bobble logo at frame 100 |
| CodeDemoScene (200 f) | skewed code screenshot and Ferris with dancing eyes, in a nested `<svg>` viewport |
| RenderingScene (140 f) | "native / GPU rendering", an fps counter and a gradient progress bar |
| IphoneScene (8 s) | iPhone with QR code and Discord screens in a rounded clip path; dynamic island with an audio spectrum of `beta.mp3`, then a GitHub invite |
| GithubScene (5 s, overlaps 0.3 s) | GitHub page sliding in and scrolling |
| BetaExamples (500 f) | the hello-world, marketing, podcast and TikTok videos playing in a rounded preview with a drop shadow; the TikTok video is rotated 90° |
| EndScene (2 s) | the logo fades in |

Audio: `beta.mp3` plus `pop.mp3` at frames 95 and 440.

```sh
onimite render examples/fframes/beta/video.lua -o beta.mp4
onimite preview examples/fframes/beta/video.lua
```

Files: `video.lua` holds the scenes. `hello.lua`, `marketing.lua`, `podcast.lua`
and `tiktok.lua` are the embedded videos, each a frame function. `shared.lua`
holds the nested-`<svg>` viewport and Ferris.

## Notes on matching the original

- The embedded videos get the same frames as in the original. Hello world and
  marketing get the scene frame. Podcast and TikTok get the global frame
  (`frame.into_global()`). The iPhone spectrum uses the scene frame.
- SVG details reproduced by hand:
  - `transform-origin` percentages resolve against the viewport.
  - fframes' Transform order is translate, rotate, scale, skewX, skewY. The
    script nests groups where the engine's order differs.
  - Nested `<svg>`s use meet scaling and clip to their viewport.
  - The filter regions of the TikTok blobs and of the preview shadow are
    group clips. The mask and clip paths of the podcast are rects.
  - The pattern avatars are circle-clipped images.
- The iPhone background fills with `url(#pattern1)`, which is not defined, so
  SVG draws nothing. The port leaves it out.

## Deviations

- **Missing fonts.** fframes skips text whose font it cannot find. The
  original renders with `default_font: "Inter"`, which is not installed here,
  so it drops every text without a font family: the Discord names and
  messages, the clock, the QR caption and the island invite. The port draws
  none of them, matching the reference. Set `DEFAULT_FONT` in `video.lua`
  (and add the font) to draw them.
- **The fps counter** in RenderingScene adds `rand::random() * 4` in the
  original, a different value on every render. The port uses a deterministic
  hash of the frame number with the same range.
- **Reference frames.** fframes' CPU backend can reuse a cached group across
  frames when several frames are rendered in one run. For example, in a batch
  `frame` call the QR corners at 10.5 s keep the opacity 0 of an earlier
  frame. Compare against frames rendered one per run.
