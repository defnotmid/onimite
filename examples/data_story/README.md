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

| bars | seconds | scene (song section) | what |
| --- | --- | --- | --- |
| 0-2 | 0-4 | Title (`title`) | the emoji pops (colour COLR glyph), the name slams in at a fitted size, subtitle |
| 2-6 | 4-12 | Bars (`bars`) | `wipe` in; twelve bars rise on springs, each on its month's blip (a sixteenth apart), counters on top, coloured low to high with `mix_color` (OKLab); the best month lights up with a content-sized blur glow and a callout |
| 6-9 | 12-18 | Line (`line`) | `slide` in; the running total draws on (`path_length` dashes) with a gradient area, a dot rides the line by arc length carrying a counter, and pops on the total |
| 9-12 | 18-24 | Donut (`donut`) | `clock_wipe` in; a segment on each crop's blip, a beat apart (crop colours mixed from accent to accent2), legend rows with emoji labels, percentage counters, the biggest share in the middle |
| 12-15 | 24-30 | Outro (`outro`, `tail`) | `zoom` in; the year's total counts up over the ticks and lands on the chime, a sparkline of the months |

Captions: `media/story.json` is a hand-written, Whisper-style word-timed
file whose words sit on the music's grid; `captions{}` draws it on top of
every section (`highlight = "fill"` in the row's accent colour, pages of at
most five words).

Music: `track.lua` composes an odawg `song{}` from the data: house at 120
BPM in C major (C Am F G, a chord a bar), a section per scene (`title`,
`bars`, `line`, `donut`, `outro`, then an ambient `tail` bar). The `house`
style plays the bed on 909 drums (`DrumKit`), its energy rising section by
section (the stabs come in on the chart, the pluck arpeggio on the donut);
odawg adds the riser into the first drop and the snare fills. The parts the
picture answers to are placed in the sections and pitched from the data: a
blip per month (a sixteenth apart, higher for a bigger month), a chime on
the best month, a riser while the line draws and a chime as it lands, a
blip per crop, twelve ticks up the scale under the count, crashes on the
scenes' downbeats (a `DrumMachine` 909).

The picture reads them back (`timeline.lua`): the bars rise on
`score.hits { part = "months" }`, the callout on the chime in `bars`, the
line draws over `score.events { part = "riser" }`, the segments on
`score.hits { part = "segments" }`; the scenes start on the sections
(`start = score.time("bars")`) and the picture pumps with the kicks the
drums play (`score.pulse(f, { part = "drums", note = "kick" })`). Nothing
is computed in beats: a changed pattern or section moves the picture with
it. The moments are cues (`month[0]`..`month[11]`, `peak`, `segment[*]`,
`slam`, `total`): `onimite frame video.lua peak@0.3s`.
`onimite audio analyze`: -14.0 LUFS, -1.2 dBTP.

Render with `build/onimite_speed` (`-o:speed`): 1800 frames in 3.9 s; the
three-row batch in 11.9 s.

Files: `video.lua` (props, chart geometry at load, the sections),
`timeline.lua` (every cue, read from the song), `ui.lua` (palette, fonts,
backdrop, header), `track.lua` (the music), `data.json`, `rows.json`.

Media: fonts copied from other examples (OFL): Inter ExtraBold
(captions_demo), DM Sans Medium (batch), JetBrains Mono. Emoji come from the
bundled Noto Color Emoji. `story.json` is written for this example; the
music is composed by odawg.
