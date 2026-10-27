# why_onimite

A 53 second pitch for onimite against fframes, made with onimite, music
included: 1920x1080, 60 fps, UK garage at 132 BPM.

```sh
onimite render examples/why_onimite/video.lua -o why_onimite.mp4
```

| bars | scene (song sections) | what |
| --- | --- | --- |
| 1-4 | Title (`title`, `slam`) | "ONIMITE vs FFRAMES" drawn into a text group that an SkSL shader reads as its `uniform shader` child: glitch slices and colour split, a ripple ring from the slam |
| 5-8 | Race (`race`) | eight videos rendering side by side at their measured relative speeds: onimite's biggest wins, then fframes' wins (up to two, its biggest first); DONE pops on the beat |
| 9-12 | Bill (`bill`) | CPU seconds and peak memory, each on the example where onimite needs the smallest share of fframes', counters ticking on the beat |
| 13-16 | Shipping (`ship`) | what each installs before the first frame, measured and to scale: fframes' Rust toolchain, its crates (a falling grain each) and its first build pour into a bin (`physics{}`), onimite's Linux release unpacked (the binary, libSDL3 and its licences) is one block; the sizes come from `bench/facts.json`; an edit in each |
| 17-20 | Built for agents (`agents`) | a real `inspect` session on the saga, replayed: the Bill scene's booms off the beat (`off_beat`), the one number fixed, the re-run clean |
| 21-24 | Tricks (`tricks`) | `svg{}` bird flapping by id override, ligatures (Instrument Serif "office affluent"), Arabic joining (Noto Sans Arabic), Pip, the mascot, as a ProRes 4444 alpha clip with a glow, dancing on a 3D stage (`view3d{}`: a lit turntable, an arc of bars behind Pip rising in a wave on the beat, the camera swaying) |
| 25-29 | Outro (`outro`, `tail`) | "One binary. Lua scripts. All your cores." over the soundtrack's spectrum, then the wordmark |

Files: `facts.lua` picks every number on screen from `bench/facts.json`,
which `tools/bench.sh facts` and `setup` measure on each release
(BENCHMARK.md has the tables); `track.lua` is the
soundtrack, an odawg `song{}` whose sections are the scenes: UK garage after
MJ Cole's "Sincere" in G minor, a swung 2-step on the library's 909
(`machines/909.json`), a sine sub of its own that slides, an electric piano
on jazz ninths (Gm9 Cm9 Abmaj9 D7), speed garage for shipping (four to the
floor, organ stabs, a warping bass of its own), the hook on an upright piano
with a synth pluck inside it for the agents and the last drop, VS Chamber
Orchestra 2's strings for the tricks' breakdown (`sources`, pinned in
`media/pins/vsco.pins`). Every part has a `role`, so `inspect` holds its
level to what it is for. Its own parts carry what the picture answers to:
a boom (the library's 808) and a recorded crash on each drop, the glitch
stutters, the bill's counter ticks on a glockenspiel, a crash on each
scene's downbeat. The picture reads the song:
`timeline.lua` gives every moment as a song position (`"race@1m"`,
`"agents@2:3"`) or as the song's own hits (the counters tick on the `ticks`
part's blips, the tricks cut on the `glitch` part's stutters, the race's
DONEs snap to the nearest eighth); `video.lua` starts each scene on its
section, pumps the picture on the kicks the drums really play
(`score.pulse`), flashes on the impacts (`score.hits`, a `cue` inspect
checks) and glitches on the cuts. The sounds that answer the picture
(DONEs, the crates landing, blips, the recorded crash) are `sound{}` clips on an
`sfx` bus in their scene's `audio`; the shipping scene's blocks are dropped
so they land on the beat. `beat.lua` is the easing; `scenes/` one file per
scene (`tricks.lua` plays its four cuts as a `series`).

Mix: mastered to about -15 LUFS (`master_gain_db` into the limiter's
default ceiling; `onimite audio analyze`), quietest in the shipping and the
tricks, loudest in the outro.

Media: fonts copied from other examples (Bebas Neue, Space Grotesk,
JetBrains Mono, Instrument Serif; OFL), Noto Sans Arabic Bold (OFL, from
the system's Noto fonts), `bird.svg` from svg_demo and `transparent.mov`
(Pip dancing, rendered by `tools/gen_media/mascot.lua`; MIT, made by this
repository's scripts: not committed, `fetch.sh` makes it).
