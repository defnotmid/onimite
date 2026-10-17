# voiceover

A 14 s vignette told by a synthesized voice: three spoken lines made with
`say()` (text to speech with word timings, by ottis), their captions, an
ambient score (an odawg `song{}`) whose sections the lines size and which
ducks under the voice, every animation key placed on the word it belongs to
with `say_cue()`, and one word placed on the music with `say_start()`.

```sh
onimite inspect examples/voiceover/video.lua
onimite show examples/voiceover/video.lua say/strike     # the words and their times
onimite show examples/voiceover/video.lua song/score     # the sections the lines sized
onimite render examples/voiceover/video.lua -o voiceover.mp4
```

The first run downloads ottis's files (835 MB on Linux, 866 MB on macOS:
ONNX Runtime and the models) and synthesizes the three lines (a few
seconds); later runs read the lines from the store (`onimite/say/` in the
user data folder: `~/.local/share/onimite/say/` on Linux).

| time | scene | on the words |
| --- | --- | --- |
| 0-4 s | Stairs (section `climb`) | "climbed": the stairs appear and the keeper climbs, a footstep per stair; "stairs": the keeper reaches the top |
| 4-8 s | Lamp (`top`) | "lamp": the lamp swells in; "dark": its ember dies |
| 8-14 s | Light (`strike`, `beam`) | a riser under "He struck a match", the spark and the scrape on the half beat nearest "match"; "Light" on the downbeat of `beam`: the impact, a bell, the lamp catches; the beam sweeps with a whoosh (the half beat nearest "swept"); "sea": the waves rise |

How it is laid out:

- Say, then song, then placement. Each `say()` returns the line's duration
  and words. The score (ambient in A minor, 120 BPM) has a section per line:
  `{ "climb", duration = { audio = "climb", plus = { seconds = 1.2 } } }` is
  as long as the line plus a breath, rounded up to whole bars, so changing a
  line moves everything after it. The scenes start on the sections
  (`start = score.time("top")`), the lines a beat into them
  (`score.time("top@4n")`).
- One word leads the music the other way round: the last line starts where
  `say_start(strike, "light", score.time("beam"))` says, so "Light" lands on
  the downbeat where the score swells (an `impact` transition: a riser over
  the bar before, then the impact, the strings, a sub and a heartbeat kick).
- `say_cue(line, at, "word")` gives the video time a word is said (`at` is
  where the line's track starts) and names it as a cue; the keys
  (`cue = "dark"`) and the effects (`cue = "light"`) that land there carry
  the same name, so `inspect` reports any that drift off the word.
- The lines' tracks have no `bus`: spoken lines go on the voice bus by
  themselves, duck the score (`ducked = true`) and are never checked against
  the beat. Effects over a song are checked against its grid (`off_beat`),
  so the scrape and the whoosh sit on the half beat nearest their words
  (`score.snap(say_cue(...), "8n")`), their keys with them, and carry no word
  cue; the bell on "Light" is on the word and the grid at once. The
  footsteps and the match's crackle are rolls (hits under a quarter beat
  apart), which are texture and not checked, so they stay on the words.
- The effects are `sound{}`s: a `tick` per step, pink noise and `crackle`s
  for the match, a `bell` on the chord's root there (`score.note("1",
  "beam")`), a `whoosh`.
- Captions: `captions(f, { src = "climb", start = CLIMB_AT, ... })` draws a
  line's captions on the video clock; pages break at the end of a sentence.

## What `inspect` reports, and why

```
cue "stairs": no sound of climb starts within 30 ms of 1.874s (nearest: 1.930s)
cue "match": no sound of strike starts within 30 ms of 9.094s (nearest: 8.976s)
cue "swept": no sound of strike starts within 30 ms of 10.262s (nearest: 10.504s)
cue "sea": no sound of strike starts within 30 ms of 11.067s (nearest: 10.504s)
```

`say_cue` asks `inspect` to confirm each word starts a sound of its line
(`cue_no_hit`). These four words run on from the word before ("spiral
stairs", "a match", "Light swept", "the sea"): the voice doesn't stop or dip
between them, so there is no onset to find. Their times come from the
aligner (20 ms frames). A word that starts a sound of its own, after a
pause or with a hard consonant ("climbed", "lamp", "dark", "Light"), passes.

A `cue_no_hit` on a word after a pause is worth a look: the aligner
sometimes places a word that begins softly late. "Light" and "Lightning"
after a full stop came 44-67 ms after their onset in 3 of 7 takes (seed 7 of
this line put "Light" 67 ms late). Compare `onimite
show video.lua say/strike/5` (the word's time on the video) with `onimite
audio onsets video.lua --track strike`, then try another `seed`, or name the
moment yourself at the onset: `cue("light", t, { hit = "strike" })`.

The voice is *Pocket TTS by Kyutai (CC-BY-4.0)*, voice "alba". The score and
effects are composed by odawg in the script (`song{}`, `sound{}`).
`onimite audio analyze`: -14.1 LUFS, -1.2 dBTP. Fonts:
Instrument Serif and Space Grotesk (OFL, copied from the other examples).
