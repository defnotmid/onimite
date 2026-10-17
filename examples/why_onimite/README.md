# why_onimite

A 50 second pitch for onimite against fframes, made with onimite, music
included: 1920x1080, 60 fps, 140 BPM.

```sh
onimite render examples/why_onimite/video.lua -o why_onimite.mp4
```

| bars | scene (song sections) | what |
| --- | --- | --- |
| 1-4 | Title (`title`, `slam`) | "ONIMITE vs FFRAMES" drawn into a text group that an SkSL shader reads as its `uniform shader` child: glitch slices and colour split, a ripple ring from the slam |
| 5-8 | Race (`race`) | eight videos rendering side by side at their measured relative speeds, onimite's six biggest wins and fframes' two (hello_world, and narrowly podcast); DONE pops on the beat |
| 9-12 | Bill (`bill`) | CPU seconds (tiktok) and peak memory (beta), counters ticking on the beat |
| 13-16 | Shipping (`ship`) | what each installs before the first frame, measured and to scale: fframes' Rust toolchain, its 311 crates (a falling grain each) and the 2.5 GB first build pour into a bin (`physics{}`), onimite's 19.7 MB (the v0.0.7 Linux binary and libSDL3) is one block; an edit in each |
| 17-20 | Built for agents (`agents`) | a real `inspect` session on the saga, replayed: the Bill scene's booms off the beat (`off_beat`), the one number fixed, the re-run clean |
| 21-24 | Tricks (`tricks`) | `svg{}` bird flapping by id override, ligatures (Instrument Serif "office affluent"), Arabic joining (Noto Sans Arabic), Pip, the mascot, as a ProRes 4444 alpha clip with a glow, dancing on a 3D stage (`view3d{}`: a lit turntable, an arc of bars behind Pip rising in a wave on the beat, the camera swaying) |
| 25-29 | Outro (`outro`, `tail`) | "One binary. Lua scripts. All your cores." over the soundtrack's spectrum, then the wordmark |

Files: `facts.lua` holds every number on screen with its source
(BENCHMARK.md "Full run", the measured installs); `track.lua` is the
soundtrack, an odawg `song{}` whose sections are the scenes: house on
TR-909 circuit models (`DrumMachine`) for the title, race and bill, a
TB-303 line (the `acid_house` style's `AcidSynth`) taking over for
shipping and the agents, a breakdown under the tricks, the last drop with
a lead hook, an ambient tail. Its transitions make the risers and the two
impacts; its own parts add the glitch stutters, the bill's counter blips and
a crash on each scene's downbeat. The picture reads the song:
`timeline.lua` gives every moment as a song position (`"race@1m"`,
`"agents@2:3"`) or as the song's own hits (the counters tick on the `ticks`
part's blips, the tricks cut on the `glitch` part's stutters, the race's
DONEs snap to the nearest eighth); `video.lua` starts each scene on its
section, pumps the picture on the kicks the drums really play
(`score.pulse`), flashes on the impacts (`score.hits`, a `cue` inspect
checks) and glitches on the cuts. The sounds that answer the picture
(DONEs, the crates landing, blips, crashes) are `sound{}` clips on an
`sfx` bus in their scene's `audio`; the shipping scene's blocks are dropped
so they land on the beat. `beat.lua` is the easing; `scenes/` one file per
scene (`tricks.lua` plays its four cuts as a `series`).

Mix: `onimite audio analyze` gives -14.0 LUFS integrated, -1.5 dBTP true
peak (`master_gain_db = 3` into a -1.5 dB limiter).

Media: fonts copied from other examples (Bebas Neue, Space Grotesk,
JetBrains Mono, Instrument Serif; OFL), Noto Sans Arabic Bold (OFL, from
the system's Noto fonts), `bird.svg` from svg_demo and `transparent.mov`
(Pip dancing, rendered by `tools/gen_media/mascot.lua`; MIT, this
repository).
