# voiceover

A 12.6 s vignette told by a synthesized voice: three spoken lines made with
`say()` (text to speech with word timings, by ottis), their captions, a pad
underneath that ducks under the voice, and every animation key and sound
effect placed on the word it belongs to with `say_cue()`.

```sh
onimite inspect examples/voiceover/video.lua
onimite show examples/voiceover/video.lua say/strike     # the words and their times
onimite render examples/voiceover/video.lua -o voiceover.mp4
```

The first run downloads ottis's files (835 MB on Linux, 866 MB on macOS:
ONNX Runtime and the models) and synthesizes the three lines (a few
seconds); later runs read the lines from the store (`onimite/say/` in the
user data folder: `~/.local/share/onimite/say/` on Linux).

| time | scene | on the words |
| --- | --- | --- |
| 0-3.2 s | Stairs | "climbed": the stairs appear and the keeper climbs, a footstep per stair; "stairs": the keeper reaches the top |
| 3.2-7.1 s | Lamp | "lamp": the lamp swells in; "dark": its ember dies |
| 7.1-12.6 s | Light | "match": a spark and a struck match; "Light": the lamp catches with a bell; "swept": the beam sweeps with a whoosh; "sea": the waves rise |

How it is laid out:

- Each `say()` returns the line's duration and words; the scenes start one
  after the other from those durations (`video.lua`, the top), so changing a
  line moves everything after it.
- `say_cue(line, at, "word")` gives the video time a word is said (`at` is
  where the line's track starts) and names it as a cue; the keys
  (`cue = "dark"`) and the effects (`cue = "match"`) that land there carry
  the same name, so `inspect` reports any that drift off the word.
- The lines' tracks have no `bus`: spoken lines go on the voice bus by
  themselves, duck the pad (`ducked = true`) and are never checked against
  the beat. The pad has no beat, so the effects placed on words aren't
  either (`off_beat` only applies over music with a steady beat).
- Captions: `captions(f, { src = "climb", start = CLIMB_AT, ... })` draws a
  line's captions on the video clock; pages break at the end of a sentence.

## What `inspect` reports, and why

```
cue "stairs": no sound of climb starts within 30 ms of 1.974s (nearest: 2.030s)
cue "match": no sound of strike starts within 30 ms of 8.284s (nearest: 8.167s)
cue "swept": no sound of strike starts within 30 ms of 9.452s (nearest: 9.694s)
cue "sea": no sound of strike starts within 30 ms of 10.257s (nearest: 9.694s)
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
effects are synthesized in the script (`../common/synth.lua`). Fonts:
Instrument Serif and Space Grotesk (OFL, copied from the other examples).
