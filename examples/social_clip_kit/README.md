# social_clip_kit

One 17 second promo (60 fps, 113 BPM) rendered in the three shapes social
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
| 0-8 | 0-4.2 | Hook | Pip hops in; "ONE SCRIPT" and "EVERY FORMAT" slam on beats 2 and 4 on their claps, fitted to their box (the slam's overshoot never leaves the canvas) |
| 8-16 | 4.2-8.5 | Formats | the drop: a frame per beat for 9:16, 1:1 and 16:9, then this video's own frame lights up and Pip hops into it |
| 16-24 | 8.5-12.7 | Features | four cuts two beats apart: word chips with a hopping highlight, the track's own `audio_spectrum`, the beats of the bar, Pip over a checkerboard (the alpha showing) |
| 24-32 | 12.7-17 | Outro | the crash: the wordmark at the largest size that fits with the stack under it, the tagline, the `render --batch` pill, the three formats as chips |

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
- **Music with beat-synced cuts**: `track.lua` is an odawg `song{}`,
  amapiano in F minor at 113 BPM after Focalistic and Vigro Deep's "Ke
  Star", a section per part of the promo: its own `logdrum` row (a sine
  falling into its note, a hollow triangle over it, a little drive: the
  genre's tuned bass) carrying the groove from the drop, swung sixteenth
  shakers with accents and rim shots off the beat on the library's 909
  (`machines/909.json`), jazzy stabs on the VCSL upright and a soft electric
  piano bed (minor ninths moving to major ninths for the drop), the format
  frames on a glockenspiel (VS Chamber Orchestra 2's own SFZ through the
  song's `sources`, pinned in `media/pins/vsco.pins`) and a real crash (the
  virtuosity jazz kit) only on the cuts. The picture reads the
  song (`timeline.lua`): the scenes start on its sections, the headline
  lines slam on its claps, the format frames pop on its blips, the feature
  cuts are its crashes (the picture flashes and punches in on them with
  `score.pulse`, and a `cue` lets inspect check the song hits there) and
  the picture pumps on its kicks. Mastered to about -15 LUFS (`onimite
  audio analyze`), the hook quieter than the drop and the cuts.
- **Progress bar**: story-style, a segment per section filling as it plays.

Render with `build/onimite` (Vulkan Video): the three-row batch in 5.4-5.6 s
(1.5-1.9 s of rendering per format).

Files: `video.lua` (formats, layout, sections), `timeline.lua` (every cue
in beats, read from the song, and the voice-over), `track.lua` (the song),
`rows.json` (the three formats).

Media: `mascot.webm` from `tools/gen_media` (this repository, MIT); fonts
copied from other examples (OFL): Inter ExtraBold, DM Sans Medium,
JetBrains Mono. The music is composed by odawg from `track.lua` (CC0,
downloaded on first use: the VCSL upright, the virtuosity kit's crash and
VS Chamber Orchestra 2's glockenspiel).
