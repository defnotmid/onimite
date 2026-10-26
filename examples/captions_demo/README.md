# captions_demo

Word-level captions, TikTok style: a 10 s vertical clip (1080x1920, 60 fps)
over an Afrobeats groove composed by odawg (`song{}`), its captions from a
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

The beat is a `song{}` in `video.lua`: Afrobeats at 96 BPM in Eb major after
Wizkid's "Essence", two sections of two bars (5 s each) named after the
scenes, which start on them (`start = score.time("pop")`). No library style:
a clean, palm-muted highlife guitar picks sixteenths around the chords
(Karoryfer's Emily guitar, its own SFZ through the song's `sources`, pinned in
`media/pins/emily.pins`), the library's 808 plays a skipping kick, the rim off
the beat, swung shakers and congas, a fingered bass (Karoryfer's growlybass)
sits over a sine sub as one `layers` row, an FM electric piano holds the
chords, and in `pop` a flute (VS Chamber Orchestra 2's own SFZ) plays the
hook. The guitar leads 4 LU under the mix; the bass and the kit sit just
under it, the piano 9 under. The glow
breathes with the kicks the drums really play (`score.pulse(f, { part =
"drums", note = "kick" })`) and the dots count the song's beats
(`score.beat(f)`). `onimite audio analyze`: -13.8 LUFS, -1.2 dBTP. Fonts:
Inter ExtraBold and JetBrains Mono (copied from the other examples).
Samples (CC0 1.0, downloaded on first use): Emilyguitar and Growlybass by
Karoryfer Samples; VS Chamber Orchestra 2: Community Edition by Versilian
Studios LLC.
