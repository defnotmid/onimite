# onimite saga

A two minute film about onimite, made with onimite, music included: slow and
dramatic, then K-pop, then a twist. 1920x1080, 60 fps, a tempo that changes
from 36 to 168 BPM, a soundtrack composed by odawg (`song{}`) in C# minor
that follows K-pop's own switch-ups: VS Chamber Orchestra 2's string sections
and a drone in the void; a verse of four on the floor under a dembow rim and
a tresillo 808; a quiet grand piano in the half-time hush; the chorus as
Jersey club on the royal road (Amaj7 B7 G#m7 C#m9), Pip's hook on a lead the
violins double; a tape stopping; the matrix's half-step dread pulse. Its
sound effects are the interface's own (keys, blips, DONEs) and, where
something physical lands, a recorded swoosh (Freesound, CC0, fetched by
`fetch.sh`), a real crash cymbal and an 808 boom.

```sh
onimite preview examples/onimite_saga/video.lua
onimite render  examples/onimite_saga/video.lua -o onimite_saga.mp4
```

It is also the reference for laying out a long video so an agent can change
any part of it by reading only that part.

## Layout

| file | what it holds |
| --- | --- |
| `video.lua` | the manifest: the video, its music, the pumping and the flashes, the scenes in order |
| `music/score.lua` | the song: a section per scene (its bars, tempo and ramps, chords, energy), the drops' transitions; each section is a cue |
| `music/act1.lua` ... | what each part plays in that act's sections (play entries: steps, degrees, chords, notes, events) |
| `music/parts.lua` | the sources (VS Chamber Orchestra 2, pinned in `media/pins/vsco.pins`), the film's own layered rows (the string sections, the hook's lead with violins, the bells with a glockenspiel), the instruments (a part each, with its `role`: the 909, the 808, rows of the skill's library, effects, sends, side-chain), the hook, the builders the acts use |
| `scenes/<name>.lua` | one scene: its own constants and drawing, then the `scene{}` call that places it on its section |
| `scenes/family.lua` | the cards OVG, ODECS and OKSL share |
| `look.lua` | palette, type, springs and the parts several scenes share |
| `fx.lua` | the shaders (backdrops, glitch, dissolve, tunnel, matrix rain) |
| `sfx.lua` | the sound effects: `sound{}` clips built once; each scene places a track per sound (a key, a pop) on the `sfx` bus |
| `facts.lua`, `code.lua` | the numbers and code shown on screen |

Pip is drawn by `examples/common/pip.lua`; nothing else comes from
`examples/common/`. Pip dancing as an alpha clip, `media/transparent.mov`,
and the whooshes' recording, `media/swoosh.mp3`, aren't committed: `fetch.sh`
makes the one and downloads the other (SHA-256 checked), once, before the first render
(`tools/gen_media/gen.sh onimite_saga`).

## How music and picture stay together

Nothing is timed by hand. The song's sections are the scenes, so a scene
starts on `score.time("race")`; a moment inside a section is a position on
the song (`"slam@4n"`, the `logo_hit` marker); a sound `lb` beats into a
scene starts `score.seconds(lb, "race")` after it, measured on the tempo map
however fast it is there. The picture pumps on the kicks the drums really
play (`score.pulse(f, { part = "drums", note = "kick", range = "one..slow" })`)
and flashes on the drops' booms (`score.hits { part = "fx", note = "C#2" }`,
a `flash` cue `inspect` checks against the song). The drops' booms and
crashes are the song's `fx` and `fx_crash` parts; what leads into a drop is
the music itself (the build's rolls and its pad's opening filter, the
countdown), no riser.

## Changing it

Find the code from what you see, then read just that file:

```sh
onimite show video.lua                         # the video; follow the paths it lists
onimite show video.lua scene/Race/nodes --at race@2s   # what the scene draws, by script line
onimite timeline video.lua                     # scenes on their sections, the song's sections, parts and cues
onimite timeline video.lua Hush..OVG           # only that stretch
onimite show video.lua song/score/parts/bass   # every note a part plays
```

- Change a scene: edit `scenes/<name>.lua`, then check only it:
  `onimite inspect video.lua Race`, `onimite strip video.lua Race -n 8`.
- Move or stretch a scene: change its section in `music/score.lua` (its
  `duration` in bars, its `bpm` or ramp). Everything after it moves: the
  scenes, the music and every sound placed in beats.
- Add a scene: add its section to `music/score.lua`, write `scenes/new.lua`
  like the others (`local AT = score.time("new")`, `scene { "New", cue = "new",
  start = AT, ... }`), and `require("scenes.new")` in `video.lua` in order.
  A scene lasts until the next one's start.
- Change a scene's sounds: its `SOUNDS` list, next to its `scene{}` call
  (`sfx.at("race", 2.5, sfx.done(), 0.14)`: a DONE 2.5 beats in). Hits go on
  the beat or the half-beat (`inspect` checks them against the song's grid:
  `off_beat`); rolls and typing are texture. Balance all effects against the
  score with the `sfx` bus in `video.lua`.
- Change the music of one act: edit `music/actN.lua`; an instrument or its
  level: `music/parts.lua`. Hear one part alone with
  `onimite audio render video.lua --track score/bass -o bass.wav`, check its
  level with `onimite audio analyze video.lua montage..last --track score/bass`.
  `frame`, `strip` and `inspect` don't render the music, so they stay fast.
- Levels: the parts' `role` and `gain_db` in `music/parts.lua` (`inspect`'s
  `role_balance` names a part outside its role's band), the per-section lanes
  in `music/score.lua`; `video.lua`'s `master_gain_db` and limiter finish the
  mix (about -15 LUFS, `audio analyze`; the hush far quieter, the
  choruses loudest).

## Scenes

A scene's render gets `lb`, the beats since its section starts, and `gb`, the
song's beat (`score.beat(f)`); the tempo map makes them musical whatever the
speed. `look.kick(gb)` is the beat's pulse, `look.snap(lb - cue)` and
`look.soft(...)` the springs for entrances on a beat.
