# why_onimite

A 50 second pitch for onimite against fframes, made with onimite, music
included: 1920x1080, 60 fps, 140 BPM.

```sh
onimite render examples/why_onimite/video.lua -o why_onimite.mp4
```

| bars | scene | what |
| --- | --- | --- |
| 1-4 | Title | "ONIMITE vs FFRAMES" drawn into a text group that an SkSL shader reads as its `uniform shader` child: glitch slices and colour split, a ripple ring from the slam |
| 5-8 | Race | six videos rendering side by side at their measured relative speeds; DONE pops on the beat |
| 9-12 | Bill | CPU seconds (tiktok) and peak memory (beta), counters ticking on the beat |
| 13-16 | Shipping | what each installs before the first frame, measured and to scale: fframes' Rust toolchain, its 311 crates (a falling grain each) and the 2.5 GB first build pour into a bin (`physics{}`), onimite's 17.6 MB is one block; an edit in each |
| 17-20 | Built for agents | a real `inspect` session on the saga, replayed: the Bill scene's booms off the beat (`off_beat`), the one number fixed, the re-run clean |
| 21-24 | Tricks | `svg{}` bird flapping by id override, ligatures (Instrument Serif "office affluent"), Arabic joining (Noto Sans Arabic), Pip, the mascot, as a ProRes 4444 alpha clip with a glow |
| 25-29 | Outro | "One binary. Lua scripts. All your cores." over the soundtrack's spectrum, then the wordmark |

Files: `facts.lua` holds every number on screen with its source
(BENCHMARK.md "Full run", the measured installs); `timeline.lua`
says on which beat everything happens; `track.lua` synthesizes the
soundtrack from the same timeline (kick, clap, hats, ducked bass, detuned
stabs, arp, pad, risers, impacts, glitch stutters, blips) when the script
loads with the instruments in `../common/synth.lua`, registered with
`audio_add("track.wav", track.build)` (run once per render, about 1.3 s of Lua); the
section starts are sync points (`cue()` and each scene's `cue`); `beat.lua` is the clock
(the standard library's `beat_clock`) and easing; `scenes/` one file per
scene (`tricks.lua` plays its four cuts as a `series`).

Mix: `onimite audio analyze` gives -14.3 LUFS integrated, -1.3 dBTP true
peak. Full render with `build/onimite_speed`: 2571 frames in 5.7 s (7.2 s
wall including the synthesis, 193 MB peak RSS).

Media: fonts copied from other examples (Bebas Neue, Space Grotesk,
JetBrains Mono, Instrument Serif; OFL), Noto Sans Arabic Bold (OFL, from
the system's Noto fonts), `bird.svg` from svg_demo and `transparent.mov`
(Pip dancing, rendered by `tools/gen_media/mascot.lua`; MIT, this
repository).
