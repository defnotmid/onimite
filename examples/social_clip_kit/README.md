# social_clip_kit

One 16 second promo (30 fps, 120 BPM) rendered in the three shapes social
video comes in, 9:16 (1080x1920), 1:1 (1080x1080) and 16:9 (1920x1080),
from one script. `props.format` picks the canvas; the layout follows from it
at load, so one `--batch` renders all three.

```sh
onimite render examples/social_clip_kit/video.lua --batch examples/social_clip_kit/rows.json -o out/{name}.mp4
onimite render examples/social_clip_kit/video.lua --set format=1x1 -o square.mp4
```

Without props it renders 9:16.

| beats | seconds | section | what |
| --- | --- | --- | --- |
| 0-8 | 0-4 | Hook | Pip hops in; "ONE SCRIPT" and "EVERY FORMAT" slam on beats 2 and 4, fitted to their box; a riser |
| 8-16 | 4-8 | Formats | the drop: a frame per beat for 9:16, 1:1 and 16:9, then this video's own frame lights up and Pip hops into it |
| 16-24 | 8-12 | Features | four cuts two beats apart: word chips with a hopping highlight, the track's own `audio_spectrum`, the beats of the bar, Pip over a checkerboard (the alpha showing) |
| 24-32 | 12-16 | Outro | the impact: the wordmark at the largest size that fits with the stack under it, the tagline, the `render --batch` pill, the three formats as chips |

How the formats adapt (`video.lua`, all at load):

- `LAYOUTS` gives each shape its boxes: the progress bar, Pip's stage, the
  headline, the full-width area, the outro's stack and the captions' line.
  In 16:9 the stage and the type sit side by side; in 9:16 and 1:1 they
  stack.
- `fit()` shrinks a size until every line fits its box (`text_width`), for
  the headline, the feature titles and code, and the wordmark; the outro
  stack shrinks the wordmark until the tagline, pill and chips fit under it.
  The pills and word chips are as wide as their measured text.
- The format frames go in a row, or in 9:16 as 9:16 and 1:1 side by side
  over a 16:9 as wide as both.

The pieces the brief asks for:

- **Word-level captions**: `timeline.lua` holds the voice-over as words on
  beats; the script writes it as WebVTT with inline timestamps
  (`<00:00:01.000>word`) and loads it with `captions_load`, then
  `captions{}` draws it with a sliding box (pages of at most three words,
  a page never crossing a cue).
- **The alpha clip**: `media/mascot.webm`, Pip as VP9 with alpha (made by
  `tools/gen_media/gen.sh`), composited by `video_frame` over the
  backgrounds, inside the format frame and over a checkerboard. It loops
  every two seconds (four beats), so it dances on the beat in every
  section.
- **Music with beat-synced cuts**: `track.lua` synthesizes C G Am F with
  the examples' shared instruments (`../common/synth.lua`, `audio_add`); every section and
  feature cut falls on its beat, flashes and punches in, with a crash in the
  music. `onimite audio analyze`: -14.3 LUFS, -1.0 dBTP.
- **Progress bar**: story-style, a segment per section filling as it plays.

Render with `build/onimite` (Vulkan Video): the three-row batch in 5.3 s
(1.1-1.3 s of rendering per format).

Files: `video.lua` (formats, layout, sections), `timeline.lua` (the beat
clock, cues and the voice-over), `track.lua` (the music), `rows.json` (the
three formats).

Media: `mascot.webm` from `tools/gen_media` (this repository, MIT); fonts
copied from other examples (OFL): Inter ExtraBold, DM Sans Medium,
JetBrains Mono. The music is synthesized.
