# tiktok

Port of fframes' `tiktok` example: a vertical 1080x1920 @ 60 fps video as long
as `thought.mp3` (51.17 s). It has four blurred colour blobs (Gaussian blur
100/140, hard-light and lighten blends, one at 50% opacity), a centred 16-bar
audio spectrum, the current `thought.vtt` cue word-wrapped in JetBrains Mono
100, and the goose portrait.

    onimite render examples/fframes/tiktok/video.lua -o tiktok.mp4

Media: `thought.mp3`, `thought.vtt`, `goose2.png`, `JetBrainsMono-Regular.ttf`
(copied from the original `media/files`). How the parts map:
- each `<g mix-blend-mode filter="url(#blur-…)">` becomes
  `group{ blend, filter = { { "blur", std = … }, region = { …, units = "userSpaceOnUse" } }, srgb = true }`
  (the filter's flood + normal blend is the identity);
- `transform="matrix(.00844 .99996 -.99984 .01802 e f)"` stays an SVG matrix string;
- `frame.text_break_lines` over the current cue becomes `captions{}` on
  `thought.vtt` without a highlight: it wraps the cue's words within 1000 px
  and centres each line, line `i`'s baseline at `34% + i * 120` (the frames
  match the earlier `text_lines` + `text_width` layout pixel for pixel);
- `visualize_audio_frame(S32, smooth 4)` + `center_spectrum_low_frequencies`
  become `audio_spectrum` + `spectrum_centered`.

Deviations:
- The original encodes VP9 with alpha into `out.webm` (transparent background).
  onimite writes H.264 MP4. Every frame is fully covered by the black
  background rect, so the pixels are the same.
