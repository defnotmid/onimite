# voiceover

A 20 s vignette (60 fps) told by a synthesized voice: three spoken lines made with
`say()` (text to speech with word timings, by ottis), their captions, a
chamber score for piano and strings (an odawg `song{}`) whose sections the lines size and which
ducks under the voice, every animation key placed on the word it belongs to
with `say_cue()`, and one word placed on the music with `say_start()`.

```sh
sh examples/voiceover/fetch.sh                        # the sound effects (CC0 recordings), once
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
| 0-5.7 s | Stairs (section `climb`) | "climbed": the stairs appear and the keeper climbs, a footstep per stair; "stairs": the keeper reaches the top |
| 5.7-11.4 s | Lamp (`top`) | "lamp": the lamp swells in; "dark": its ember dies |
| 11.4-20 s | Light (`strike`, `beam`) | a held chord under "He struck a match", the spark and the scrape on the half beat nearest "match"; "Light" on the downbeat of `beam`, where the harmony lands home and the strings swell: the lamp's flame catches; the beam sweeps with a whoosh (the half beat nearest "swept"); "sea": the waves rise |

How it is laid out:

- Say, then song, then placement. Each `say()` returns the line's duration
  and words. The score (F major, 84 BPM) has a section per line:
  `{ "climb", duration = { audio = "climb", plus = { seconds = 1.2 } } }` is
  as long as the line plus a breath, rounded up to whole bars, so changing a
  line moves everything after it. The scenes start on the sections
  (`start = score.time("top")`), the lines a beat into them
  (`score.time("top@4n")`).
- One word leads the music the other way round: the last line starts where
  `say_start(strike, "light", score.time("beam"))` says, so "Light" lands on
  the downbeat where the score arrives: the harmony, dark until then (Dm9,
  Bbmaj7, Gm9, a held Csus4), lands on F, the violins swell in and a solo
  violin sings over them, its two-note pickup under "He struck a match".
- `say_cue(line, at, "word")` gives the video time a word is said (`at` is
  where the line's track starts) and names it as a cue; the keys
  (`cue = "dark"`) and the effects (`cue = "light"`) that land there carry
  the same name, so `inspect` reports any that drift off the word.
- The lines' tracks have no `bus`: spoken lines go on the voice bus by
  themselves, duck the score (`ducked = true`) and are never checked against
  the beat. Effects over a song are checked against its grid (`off_beat`),
  so the scrape and the whoosh sit on the half beat nearest their words
  (`score.snap(say_cue(...), "8n")`), their keys with them, and carry no word
  cue; the flame on "Light" is on the word and the grid at once. The
  footsteps are a roll (hits under a quarter beat
  apart), which are texture and not checked, so they stay on the words.
- The effects are real recordings, not synthesized: CC0 sounds from Freesound
  that `fetch.sh` downloads into `media/` and checks against their SHA-256
  (they aren't in the repository; `media/.gitignore` keeps them out of
  commits). Each placement takes the part of its file it needs with `offset`
  and `stop`, leaving the file as recorded: a single footfall per stair cut
  from one take on metal stairs, the match's strike and flare, the lamp's
  flame catching on "Light", a whoosh as the beam sweeps, and night waves on a
  beach under it all, rising for "the sea".
- Captions: `captions(f, { src = "climb", start = CLIMB_AT, ... })` draws a
  line's captions on the video clock; pages break at the end of a sentence.

## What `inspect` reports, and why

```
cue "stairs": no sound of climb starts within 30 ms of 2.089s (nearest: 2.144s)
cue "match": no sound of strike starts within 30 ms of 13.380s (nearest: 13.262s)
cue "swept": no sound of strike starts within 30 ms of 14.548s (nearest: 14.309s)
cue "sea": no sound of strike starts within 30 ms of 15.353s (nearest: 14.790s)
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

The score is a chamber underscore after Ólafur Arnalds' "Near Light": the
osiris soft grand turning a broken-chord figure, and VS Chamber Orchestra 2's
own SFZ files (cello and viola sections, the violin section, a solo violin)
read through the song's `sources` and pinned in `media/pins/vsco.pins` by
`onimite audio pin`. Its levels are set by measurement: at the light the solo
violin and the piano lead, the sections 2-6 LU under; the music sits 10 LU
under the voice.

The voice is *Pocket TTS by Kyutai (CC-BY-4.0)*, voice "alba"; the strings
are *VS Chamber Orchestra 2: Community Edition* (CC0). The effects (CC0, from
Freesound): "Metal Stairs Foot Steps" by sagamusix, "Match - Strike and Light
02" by JarredGibb, "Bonfire Being Lit" by samararaine, "Whoosh" by qubodup and
"Ocean beach at night with small waves" by BonnyOrbit. The score and
effects are composed by odawg in the script (`song{}`, `sound{}`).
`onimite audio analyze`: -14.8 LUFS, -2.0 dBTP. Fonts:
Instrument Serif and Space Grotesk (OFL, copied from the other examples).
