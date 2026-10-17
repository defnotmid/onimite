# captions_demo

Word-level captions, TikTok style: a 10 s vertical clip (1080x1920, 30 fps)
over a lo-fi beat composed by odawg (`song{}`), its captions from a
hand-written, Whisper-style word-timed JSON file.

```sh
onimite render examples/captions_demo/video.lua -o captions_demo.mp4
```

| time | scene | what |
| --- | --- | --- |
| 0-5 s | Box (section `box`) | `highlight = "box"`: upper case, a yellow box sliding from word to word (the text inside it turns dark), pages of at most 1.2 s (`max_duration`) |
| 5-10 s | Pop (section `pop`) | `highlight = "fill"`: the active word turns green and pops (`active_scale = 1.22`), the line making room; an outline (`stroke`), upcoming words dimmed, pages by `combine_ms = 1000` |

Files: `media/talk.json` holds the words (`segments[].words[] { word, start,
end }`, as `whisper --word_timestamps True --output_format json` writes).

The beat is a `song{}` in `video.lua`: lo-fi hip hop at 96 BPM in A minor,
two sections of two bars (5 s each) named after the scenes, which start on
them (`start = score.time("pop")`). The `lofi` style gives the swung
boom-bap, the round bass and the keys' filter and chorus; the keys are a
sampled FM electric piano (`{ "Sampler", set = "vcsl/fm_piano" }`), and in
`pop` a soft grand (`osiris/soft_piano`) arpeggiates the chords. The glow
breathes with the kicks the drums really play (`score.pulse(f, { part =
"drums", note = "kick" })`) and the dots count the song's beats
(`score.beat(f)`). `onimite audio analyze`: -13.9 LUFS, -1.2 dBTP. Fonts:
Inter ExtraBold and JetBrains Mono (copied from the other examples).
Samples (CC0 1.0, downloaded on first use): Versilian Community Sample
Library (VCSL) by Versilian Studios LLC; Osiris Piano by Versilian Studios
and Karoryfer Samples.
