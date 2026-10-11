# captions_demo

Word-level captions, TikTok style: a 10 s vertical clip (1080x1920, 30 fps)
over a synthesized 120 BPM beat, its captions from a hand-written,
Whisper-style word-timed JSON file.

```sh
onimite render examples/captions_demo/video.lua -o captions_demo.mp4
```

| time | scene | what |
| --- | --- | --- |
| 0-5 s | Box | `highlight = "box"`: upper case, a yellow box sliding from word to word (the text inside it turns dark), pages of at most 1.2 s (`max_duration`) |
| 5-10 s | Pop | `highlight = "fill"`: the active word turns green and pops (`active_scale = 1.22`), the line making room; an outline (`stroke`), upcoming words dimmed, pages by `combine_ms = 1000` |

Files: `media/talk.json` holds the words (`segments[].words[] { word, start,
end }`, as `whisper --word_timestamps True --output_format json` writes);
`beat.lua` synthesizes the beat at load (kick, clap, hats, a saw bass, from
`../common/synth.lua`), registered with `audio_add()`. Fonts:
Inter ExtraBold and JetBrains Mono (copied from the other examples).
