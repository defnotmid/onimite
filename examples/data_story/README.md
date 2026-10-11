# data_story

A 30 second data-driven explainer (1920x1080, 60 fps, 120 BPM) drawn
entirely from one table of `props`: a garden's name, an emoji, two accent
colours, twelve monthly harvests and its crops. Charts, counters, colours,
the captions' highlight and the music's blips all follow the data, so one
script makes a video per row.

```sh
onimite render examples/data_story/video.lua --props examples/data_story/data.json -o story.mp4
onimite render examples/data_story/video.lua --batch examples/data_story/rows.json -o out/{name}.mp4
```

Without `--props` the script uses data.json's values as defaults. The
gardens and every number in `data.json` and `rows.json` are invented
sample data (the title card says so).

| beats | seconds | section | what |
| --- | --- | --- | --- |
| 0-8 | 0-4 | Title | the emoji pops (colour COLR glyph), the name slams in at a fitted size, subtitle |
| 8-24 | 4-12 | Bars | `wipe` in; twelve bars rise on springs, a sixteenth apart (`stagger`), counters on top, coloured low to high with `mix_color` (OKLab); the best month lights up with a content-sized blur glow and a callout |
| 24-36 | 12-18 | Line | `slide` in; the running total draws on (`path_length` dashes) with a gradient area, a dot rides the line by arc length carrying a counter, and pops on the total |
| 36-48 | 18-24 | Donut | `clock_wipe` in; a segment a beat (crop colours mixed from accent to accent2), legend rows with emoji labels, percentage counters, the biggest share in the middle |
| 48-60 | 24-30 | Outro | `zoom` in; the year's total counts up over three beats and lands on a hit, a sparkline of the months |

Captions: `media/story.json` is a hand-written, Whisper-style word-timed
file whose words sit on the music's grid; `captions{}` draws it on top of
every section (`highlight = "fill"` in the row's accent colour, pages of at
most five words).

Music: `track.lua` synthesizes a C major bed at load with the
examples' shared instruments (`../common/synth.lua`, `audio_add`). Its hits come from `timeline.lua`
and the data: a blip per month pitched by the month's value, a blip per
donut segment, crashes on the section downbeats, ticks under the count.
`onimite audio analyze`: -13.9 LUFS, -1.2 dBTP.

Render with `build/onimite_speed` (`-o:speed`): 1800 frames in 4.1 s; the
three-row batch in 14.6 s.

Files: `video.lua` (props, chart geometry at load, the sections),
`timeline.lua` (the beat clock and every cue), `ui.lua` (palette, fonts,
backdrop, header), `track.lua` (the music), `data.json`, `rows.json`.

Media: fonts copied from other examples (OFL): Inter ExtraBold
(captions_demo), DM Sans Medium (batch), JetBrains Mono. Emoji come from the
bundled Noto Color Emoji. `story.json` is written for this example; the
music is synthesized.
