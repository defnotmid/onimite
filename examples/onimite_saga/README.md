# onimite saga

A two minute film about onimite, made with onimite, music included: slow and
dramatic, then K-pop, then a twist. 1920x1080, 60 fps, a tempo that changes
from 54 to 168 BPM, a soundtrack synthesized in Lua.

```sh
onimite preview examples/onimite_saga/video.lua
onimite render  examples/onimite_saga/video.lua -o onimite_saga.mp4
```

It is also the reference for laying out a long video so an agent can change
any part of it by reading only that part.

## Layout

| file | what it holds |
| --- | --- |
| `video.lua` | the manifest: the video, its music, the scenes in order (about 80 lines) |
| `cues.lua` | the tempo map and every named moment, in beats; each is a sync point |
| `scenes/<name>.lua` | one scene: its own constants and drawing, then the `scene{}` call that places it on its cue |
| `scenes/family.lua` | the cards OVG, ODECS and OKSL share |
| `look.lua` | palette, type, springs and the parts several scenes share |
| `fx.lua` | the shaders (backdrops, glitch, dissolve, tunnel, matrix rain) |
| `sfx.lua` | the sound effects: short clips built once; each scene places a track per sound (a key, a pop) on the `sfx` bus |
| `music/act1.lua` ... | the score: one clip per act, played from where the act starts |
| `music/parts.lua` | what the acts' score shares: progression, hook, groove, the filter and level |
| `facts.lua`, `code.lua` | the numbers and code shown on screen |

Shared pieces come from `examples/common/`: `tempo.lua` (tempo maps) and
`synth.lua` (instruments).

## Changing it

Find the code from what you see, then read just that file:

```sh
onimite show video.lua                         # the video; follow the paths it lists
onimite show video.lua scene/Race/nodes --at RACE@2s   # what the scene draws, by script line
onimite timeline video.lua                     # scenes with their cue and file, music clips, other cues
onimite timeline video.lua Hush..OVG           # only that stretch
```

- Change a scene: edit `scenes/<name>.lua`, then check only it:
  `onimite inspect video.lua Race`, `onimite strip video.lua Race -n 8`.
- Move a scene or a hit: change its beat in `cues.lua`. The scene starts there
  and the music's hits on that cue move with it; `inspect` reports anything
  tagged with the cue that no longer meets it.
- Add a scene: write `scenes/new.lua` like the others (a `scene{}` with
  `start = C.time(C.NEW)` and `cue = "NEW"`), add `C.NEW` to `cues.lua`
  (beat and `C.SCENES`), and `require("scenes.new")` in `video.lua` in order.
  A scene lasts until the next one's start.
- Change a scene's sounds: its `SOUNDS` list, next to its `scene{}` call
  (`sfx.at(C.RACE, 2.5, sfx.done(), 0.14)`: a DONE 2.5 beats in). They move
  with the scene. Balance all effects against the score with the `sfx` bus
  in `video.lua`; `onimite audio analyze video.lua` reports each bus.
- Change the score of one act: edit `music/actN.lua`; hear it alone with
  `onimite audio render video.lua --track act2 -o act2.wav`, check levels with
  `onimite audio analyze video.lua --track act2`. `frame`, `strip` and
  `inspect` don't synthesize the music, so they stay fast.
- Levels: `music/parts.lua` sets one `LEVEL` for every act; `video.lua`'s
  `master_gain_db` and limiter finish the mix (`audio analyze`: -14.6 LUFS,
  -1.0 dBTP).

## Scenes

A scene's render gets `lb`, the beats since its cue, and `gb`, the beat of
the film (`C.beat(f)`); the tempo map makes them musical whatever the speed.
`look.kick(gb)` is the kick's pulse, `look.snap(lb - cue)` and
`look.soft(...)` the springs for entrances on a beat.
