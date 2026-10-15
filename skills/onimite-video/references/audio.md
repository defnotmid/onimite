# Sound for onimite videos

You can't hear the result. Place sound from the same numbers that drive the picture, check it
with the commands below, and ask the user to listen in `onimite preview`.

## Files

- Put audio in `media/` beside the script: wav, ogg, mp3, flac, m4a/aac. Stereo is kept
  (`mono = true` on a track folds it to `0.707 * (L + R)` on both sides, like fframes'
  embedded media). The mix is 48 kHz stereo, encoded as AAC in renders.
- A video clip's own sound: put the clip's file name in an `audio` list.
- No assets: synthesize in Lua at load and register the samples with `audio_add` (below), or
  use short synthesized blips as placeholders. Tell the user which sounds are placeholders.
- Narration without a recording: `say()` speaks a line with the time of every word
  ("Spoken lines", below).

## Placing tracks

Tracks go in an `audio` list on `video{}` (video time) or on a `scene{}` (times relative to
the scene start, so sounds move with the scene when durations change):

```lua
local CARD_IN, TITLE_AT = 0.8, 3.0          -- the same constants the animation uses

video { width = 1920, height = 1080, fps = 30,
  audio = {
    { "music.mp3", start = 0, gain_db = -18, fade_in = 1.5, fade_out = 2.5,
      curve = "equal_power", ducked = true },
    { "take.wav", start = 6, stop = 8, offset = 0.5 },     -- the file's 0.5 s .. 2.5 s
  } }

scene { "Intro", duration = 4,
  audio = {
    { "whoosh.ogg", start = CARD_IN - 0.15, gain_db = -10 },
    { "vo.wav", start = 0.6, voice = true },
  },
  render = function(f) end }

scene { "Title", duration = 6,
  audio = { { "pop.wav", start = TITLE_AT + 0.03, gain_db = -12, pan = 0.3 } },
  render = function(f) end }
```

Track fields:

| field | meaning |
| --- | --- |
| first entry or `src` | the media file (or an `audio_add` name) |
| `start` | when it starts: seconds, `{ frame = n }`, `{ minutes = 1, seconds = 5 }`, `{ audio = "f" }`, with `plus` / `minus`, or a list (summed) |
| `stop` | when it ends, same forms; omitted = to the end of the file; `stop = { audio = "f" }` is the file's length on the timeline |
| `offset` | seconds into the file to start from |
| `gain_db` | level in dB (0 = as recorded) |
| `pan` | -1 (left) .. 1 (right) |
| `fade_in`, `fade_out` | seconds |
| `curve` | `"linear"` (default) or `"equal_power"` (for crossfades between two tracks) |
| `voice` | marks a voice track that `ducked` tracks dip under |
| `ducked` | `true` (fframes' `duck_under_voice`: -12 dB, 0.2 s attack before the voice, 0.3 s hold, 0.8 s release, voice gaps under 0.8 s merged) or `{ depth_db, attack, hold, release, merge_gap }` |
| `mono` | play a stereo file as mono |
| `cue` | the cue its first sound should land on (`inspect` checks; see Cues in api.md) |
| `bus` | the bus it is mixed through (below) |

A scene or video length can follow audio: `duration = { audio = "vo.wav" }` or
`{ audio = "vo.wav", plus = { seconds = 1 } }`.

### Timing and levels

- Derive SFX times from the animation's constants or the beat timeline. Whooshes start
  ~150 ms before the movement peaks; pops and clicks land on the frame the element appears
  (+0-50 ms).
- Over music, hits land on the beat or the half-beat: in beats, whole and half numbers
  (`cue + 3`, `cue + 2.5`), never `cue + 3.4`; rolls and typing on 16ths (`j * 0.125`). Move the
  animation key with its sound: both come from the same number. `inspect` reports a hit that
  isn't (`off_beat`, below).
- Gains relative to a voice normalised near 0 dB: music under voice -16 to -22 dB (plus
  ducking), music alone -8 to -12 dB, UI SFX -8 to -14 dB, whooshes -8 to -12 dB.
- Crossfade two clips with overlapping spans, `fade_out` on one and `fade_in` on the other
  over the overlap, both `curve = "equal_power"` (`examples/suite`).

## Buses: music and sound effects

Keep the score and the sound effects apart. The score is one clip (or a clip per section); each
sound effect is a short clip placed by the scene it belongs to, in that scene's `audio` list
(times from the scene's start, so it moves with the scene). Put each on a bus:

```lua
video { ..., buses = { music = { gain_db = 0 }, sfx = { gain_db = -6 }, voice = { gain_db = 0 } },
  audio = { { "score", start = 0, bus = "music" } } }
scene { "Race", duration = 4, audio = {
  { "done", start = 2.5, gain_db = -17, bus = "sfx" },     -- a DONE as the bar lands
}, render = function(f) end }
```

- A bus's gain adds to its tracks': one number balances all the effects against the score.
- A bus has a kind, which decides how onimite treats its sounds: `music` (the score;
  `inspect` measures the beat from it), `sfx` (sounds answering the picture; checked against
  that beat), `voice` (speech; its tracks duck the music like `voice = true`, never
  beat-checked; tracks playing a `say` line with no `bus` go on it) or `other` (no role). A bus named after a kind has it; otherwise give
  `kind = "music"` etc. (`buses = { score = { kind = "music" } }`); `timeline` shows it
  (`bus   sfx [sfx] ...`).
- `timeline` shows a bus as one line (`sfx  443 tracks (171 sounds)`); with a range it lists the
  tracks in it. `audio analyze` reports each bus's loudness alone (buses by name, as `show buses` lists them); `--track sfx` hears it alone.
- One track per sound, on the event that makes it (a key press, a pop, a card landing): `audio
  at` names it and it can be moved or put on a cue alone. Synthesize each kind once as a named
  clip (`audio_add("tick_2200", fn)`) and place it as often as needed.
  `examples/onimite_saga/sfx.lua` is a small library (blips, DONEs, ticks, beeps, impacts,
  whooshes, glitches) with `sfx.typing`: a key per visible character, timed the way the scene
  reveals the text.
- Sounds that are part of the music (a riser into a drop, the drums) stay in the score; sounds
  that answer something on screen (a click, a pop, a typed key) belong to the scene.

## The master bus

Tracks sum linearly into a master bus with de-click fades, then `master_gain_db` and a
limiter (fframes' `AudioMixOptions`):

```lua
video { width = 1920, height = 1080, fps = 30, duration = 5,
  audio = { { "music.mp3", start = 0 } },
  master_gain_db = 3.5,              -- before the limiter
  limiter = { ceiling_db = -1.5 },   -- default -1 dBFS; limiter = false turns it off
}
```

The limiter stops loud overlaps from clipping, but a limiter working hard squashes the mix:
fix track gains first. To hit a loudness target with a hot synthesized track, raise
`master_gain_db` and lower `ceiling_db` until `audio analyze` shows the target with true peak
under -1 dBTP (why_onimite: `master_gain_db = 5.5`, `ceiling_db = -3.4` gives -13.9 LUFS,
-1.5 dBTP).

## Checking without listening

```bash
onimite timeline video.lua                        # every track: span, gain, fades; every sync point
onimite audio at video.lua 3.1s,drop              # what plays at a moment: file position, level, ducking, voice
onimite audio analyze video.lua                   # loudness report, per scene, and per second
onimite audio analyze video.lua --waveform w.png  # read the image: waveform, loudness, scenes, onsets, cues
onimite audio analyze video.lua Intro             # one scene or range
onimite audio onsets video.lua [range] [--min 0.3] # where sounds start (seconds strength) and the beat
onimite audio render video.lua Intro -o intro.wav # the mix of a range, for the user to listen to
```

Every audio command takes `--track FILE`: that track alone, as it sounds in the mix (the others
still duck it). Give each synthesized layer its own clip (`drums`, `bass`, ...) and `--track`
checks one layer at a time.

Targets for the report:
- Integrated loudness about -14 LUFS for web and social (-16 for podcasts, -23 for
  broadcast). More than 2 LU off: change the track gains or `master_gain_db`.
- True peak at or below -1 dBTP; clipped samples 0.
- Loudness range 4-10 LU for music videos and explainers; far higher means quiet and loud
  parts need balancing (or a long silent intro/outro).
- Silent ranges only where silence is intended: an unexpected one means a track ends early,
  a file is missing (`inspect` and `timeline` show it) or a start time is wrong.
- Per scene: scenes with voice within ~2 LU of each other.

The per-second loudness line (`--json`: `loudness.momentary_lufs`, every 100 ms) shows the
shape of the music: a quiet intro, a build, a jump of several LU where it drops. The waveform
image marks scenes, track starts, every onset (white ticks, as tall as they are strong) and
the script's cues: each sound should sit where its visual event is. Put the moments that must
meet on the same `cue` and `inspect` checks them (Cues in api.md); for one-off checks
use `audio at` on the event time and a `frame` of the same time.

`inspect` also checks every sound against the music's beat (`off_beat`, problems.md): the
music is the tracks on a bus named `music`; around each hit it measures the beat from the
music's strong onsets (following tempo changes; silent where the music has no steady beat)
and reports hits more than 30 ms off the half-beat grid, one finding per scene (the `scene{}`
or `video{}` line that placed them) with the count and the loudest, by its clip name and
time. Speech is not checked: tracks on the `voice` bus or with `voice = true`. A hit is a sound's attack; rolls and typing (one instrument, hits under a quarter beat
apart) are texture and are not checked. Fix the number that placed it (and the animation key
from the same number), then run `inspect` again.

## Music you were given

`audio onsets` (and `audio_onsets` in the script) listens for you:

```lua
local MUSIC_AT = 0                                 -- where the track starts in the video
local o = audio_onsets("music.mp3")                -- analysed once per clip, at load or render
-- o.onsets = { { time, strength }, ... }   seconds into the file; strength 0..1 (the rise in level)
-- o.bpm, o.offset                          the steady beat (nil bpm: none found)
-- o.beats = { ... }                        every beat time to the end of the file
local clock = beat_clock(o.bpm, MUSIC_AT + o.offset)
local hits = {}
for _, h in ipairs(o.onsets) do
  if h.strength > 0.6 then hits[#hits + 1] = MUSIC_AT + h.time end   -- the big hits only
end
cue("hit", hits)
```

- The BPM is an estimate (60-200, leaning to 120): check it against `audio onsets` and a `frame`
  or two on beats. It finds the beat, not which beat starts a bar: the strongest onsets usually
  fall on bar starts.
- Cut scenes where the per-second loudness jumps; land titles on strong onsets.
- `cue("drop", t, { hit = "music.mp3" })` makes `inspect` confirm the song really hits there.

## Audio-reactive visuals

Any value in `render` can follow the sound: `audio_spectrum` for the spectrum at a moment,
`pulse(clock.beat(t), sharpness)` for the beat, onset times (`audio_onsets`) for hits.
Pass shader uniforms the same numbers (`uniforms = { uBass = bass }`).

```lua
local levels = audio_spectrum(f, { src = "music.mp3", sample_size = 512, smooth = 2, window = "hann",
  bands = 32, log = true, levels = { -20, 26 } })   -- 32 bands, an equal pitch step each, as 0..1
for i, v in ipairs(spectrum_centered(levels)) do    -- low frequencies in the middle
  local h = v * 300 + 6
  rect { x = 200 + (i - 1) * 48, y = 900 - h, w = 36, h = h, rx = 8, fill = "#38bdf8" }
end
```

The magnitude spectrum of the clip's stereo mix. With a frame `f` it is what the track playing
`src` plays at that frame, wherever the track sits on the video (silence while it does not
play); with a number it is that time in the clip (for a clip no track plays). Averaged over
`smooth` frames each side; deterministic per frame.
`sample_size` is a power of two up to 2048. Without options the values are raw magnitudes
(`sample_size / 2` bins, dominated by the lows); `bands = n` averages them into n groups,
`log = true` makes the groups an equal pitch step wide (bin 1 to 12 kHz), `levels = { lo, hi }`
maps decibels to 0..1. Check the bar heights in a `frame` PNG. Patterns: `examples/media_demo`,
`examples/why_onimite/ui.lua`, `examples/social_clip_kit`.

## Generated audio

`audio_add(name, sound)` makes media clip `name` from sound the script made; tracks,
`{ audio = name }` durations, `audio_spectrum` and `audio_onsets` then use it like a file.
Give it a function: it runs only when the sound is needed (render, the audio commands,
`timeline`, the preview, or the script reading the clip), once per render, so `frame`, `strip`
and `inspect` stay fast. Clips build side by side, each in its own fresh load of the script on
another core: a build function may use what the script computes at load (constants, cue
times, other modules), not anything frames or other builds change. The preview plays at
once and each clip joins the sound as it is built, the ones nearest the playhead first; a
frame reading a clip still being built (`audio_spectrum`, `audio_onsets`) shows silence and
is drawn again when it lands. Renders and the other commands always wait for the clip.

```lua
local function build()
  local mix = audio_buffer(2)                  -- 2 s of stereo at 48 kHz, kept natively
  local n, x = 48000, {}
  for k = 1, n do local t = (k - 1) / 48000 x[k] = math.sin(2 * math.pi * 440 * t) * math.exp(-t * 4) end
  mix:add(0.5, x, 0)                           -- a mono list at 0.5 s, pan 0 (add_stereo for two lists)
  mix:lowpass(9000)                            -- or a function of seconds: automation
  mix:normalize(0.89)                          -- peak at about -1 dBFS (mix:gain(g) for a fixed level)
  return mix
end
audio_add("beep", build)

video { width = 1280, height = 720, fps = 30, duration = 2,
  audio = { { "beep", start = 0, gain_db = -6 } } }
```

Write one sound at a time into the buffer and drop its list: the whole mix never lives in
Lua tables (a Lua value is 16 bytes, a buffer sample 4). `audio_add` also takes
`{ left, right, rate }` lists and file bytes (a WAV packed with `string.pack`), decoded by the
name's extension.

The examples' soundtracks share their instruments in `examples/common/synth.lua` (kick,
clap, hats, toms, bass, chords, plucks, leads, bells, risers, impacts, glitches, blips, ticks,
a sidechain, filter automation); copy it next to your `video.lua`:

```lua
local synth = dofile("synth.lua")
local function build()
  local s = synth.new(30, { seed = 120 })          -- 30 s of silence (origin = t: a clip that starts at t)
  s.kicks({ 0, 0.5, 1.0 }, 0.8)                     -- bass, chords and leads duck under these
  for _, t in ipairs({ 0, 0.5, 1.0 }) do s.kick(t, 0.9) end
  s.chord(0, 2, { 57, 60, 64 }, 0.1, 1800, 0.01, 1)
  return s.finish()                                  -- low-passed, peak at -1 dBFS
end
audio_add("track", build)
```

For a long video give each section its own clip and track (`synth.new(seconds, { origin =
section_start })`, `{ "act2", start = section_start }`): the sections build side by side,
`--track act2` checks one section, and they don't all live in memory at once. A tempo that changes is
`examples/common/tempo.lua`. Patterns: `examples/why_onimite/track.lua` (one clip),
`examples/onimite_saga/music/` (a clip per act on a tempo map). Tell the user the music is
synthesized and offer to swap in a real track.

## Spoken lines

`say(name, text, opts)` speaks `text` at load (ottis: Kyutai's Pocket TTS through ONNX
Runtime, English) and times every word by forced alignment against the audio it made:

```lua
local AT = 2.0                                  -- where the line's track starts on the video
local line = say("intro", "The keeper climbed the spiral stairs. Up top, the lamp was dark.",
  { voice = "alba", seed = 3 })                 -- temperature = 0.3 (the default)
-- line.duration                                 seconds
-- line.words[i]  = { text, start, stop, estimated, chunk }   seconds into the line
-- line.chunks[i] = { text, start, stop, first, count }       sentence groups, first: a word index
-- line.ready                                    false: a silent placeholder (tts_unavailable)
local LAMP = say_cue(line, AT, "lamp")          -- cue "lamp" at AT + its start, returns that time
local DARK = say_cue(line, AT, "dark", { name = "dark_hit" })   -- name the cue; nth = 2 for a repeat
local W3 = say_cue(line, AT, 3)                 -- by index in line.words

video { width = 1920, height = 1080, fps = 30, buses = { music = {}, voice = {}, sfx = {} },
  audio = {
    { "score", start = 0, bus = "music", ducked = true },
    { "intro", start = AT },                    -- no bus: the voice bus
    { "thud.wav", start = DARK, bus = "sfx", cue = "dark_hit" },
  } }
scene { "Keeper", duration = { audio = "intro", plus = { seconds = AT + 1 } }, render = function(f)
  captions(f.global_seconds, { src = "intro", start = AT, x = 160, y = 960, w = 1600 })
  local glow = animate(f.global_seconds, { { start = LAMP, stop = LAMP + 0.4, from = 0, to = 1, cue = "lamp" } })
end }
```

What `say(name, ...)` makes, under `name`:

- an audio clip (24 kHz mono, resampled to the mix) for tracks, `{ audio = name }`
  durations, `audio_spectrum` and `audio_onsets`;
- captions for `captions{ src = name }`, `caption_words` and `caption_pages`: a cue per
  sentence, so a page never runs from one sentence into the next. Their times are seconds
  into the line: give `start` = where the track starts to draw them on the video clock;
- the returned data. Saying the same name with the same text and options again returns the
  same line; another text under the same name is an error (give each line its own name).

Options: `voice` (default `alba`; 27 voices: alba, anna, azelma, bill_boerst, caro_davy,
charles, cosette, daan, eponine, estelle, eve, fantine, george, giovanni, jane, javert,
jean, juergen, lola, marius, mary, michael, paul, peter_yearsley, rafael, stuart_bell,
vera; or a recording in `media/` to clone, below), `seed` (a whole number: another take of the same line), `temperature` (0.3: how much
a take varies). The same text, voice, seed and temperature give the same samples on a given
machine.

Cloning a voice: `voice` names a recording in `media/` (any sound the media reads: `.wav`,
`.m4a` such as a phone's voice memo, `.mp3`, `.aac`, `.flac`, `.ogg`; or a `.safetensors`
voice saved by `ottis clone`), and the line is spoken in that voice:

```lua
local line = say("intro", "Welcome back to the workshop.", { voice = "me.wav" })
```

- The recording: one speaker, 5 to 30 seconds (longer is cut at 30 s), clean speech without
  music or noise. Trailing silence is trimmed.
- It is cloned once (about 0.1 s) and shared by every `say` that names it, and only when a
  line has to be spoken: stored lines need no cloning.
- Lines are kept by the recording's contents: change the file and its lines are spoken again.
- Clone only a voice you may use: your own, or a speaker who agreed to it. Don't use a
  cloned voice to pass speech off as someone's who did not say it.
- A `voice` that is neither a built-in voice nor a file in `media/` is an error
  (`tts_unavailable`: the line is silent, with estimated word times, and a render refuses it).

Placing things on words:

- **Put every animation key and sound effect that answers the voice on a word cue**
  (`say_cue`), and the speech on a `voice` bus. Tracks of a `say` clip with no `bus` go on
  the video's first `voice`-kind bus (or are marked `voice = true` when there is none):
  they duck the music (`ducked` tracks) and are never checked against the beat.
- Lay out from the line: scene starts and the next line's `start` from `line.duration`, so
  a changed sentence moves everything after it (`examples/voiceover`).
- Effects on words land between beats; over music with a steady beat `inspect` reports
  them (`off_beat`). Keep word-placed effects over music without a strong beat (pads), or
  move the effect to the nearest half-beat when the music matters more.

Checking without listening:

- `onimite show video.lua say/intro` lists the words with their times; `say/intro/9` is
  one word and when each track playing the line says it on the video. `says` lists the lines.
- `say_cue` gives the cue `hit = name`, so `inspect` reports a word that starts no sound of
  its line within 30 ms (`cue_no_hit`). Expected for words that run on from the word before
  ("spiral stairs", "the sea"): the voice doesn't pause, so there is no onset to find, and
  the time is the aligner's (20 ms steps). Words that start after a pause or with a hard
  consonant have onsets and pass. A `cue_no_hit` on a word after a pause is worth a look:
  the aligner sometimes places a softly starting word ("Light") 40-70 ms late; compare with
  `audio onsets video.lua --track intro` and try another `seed`.
- Numbers and symbols ("$3.50", said as words) are `estimated`: they share the time between
  their neighbours. `say_cue` names them without the hit check.

Where lines come from and what it costs:

- The first `say` that needs synthesis downloads ottis's files, about 835 MB on Linux and
  866 MB on macOS (ONNX Runtime 1.30.0, the Pocket TTS model, the word aligner, the voice;
  each other voice about 4-8 MB when first used), into `$OTTIS_DATA` or `ottis/` in the user
  data folder (`~/.local/share` or `$XDG_DATA_HOME` on Linux, `~/Library/Application Support`
  on macOS, `%LOCALAPPDATA%` on Windows), with progress on stderr; then each line takes about a quarter of
  its length to synthesize (one line at a time). The engine takes about 1.4 GB while it
  works and is freed when the script has loaded.
- Every synthesized line is kept by content in `onimite/say/` in the same user data folder
  (`~/.local/share/onimite/say/` on Linux; its key: the
  text, voice, seed, temperature and the model versions), so later runs, renders and batch
  rows read it back in milliseconds and only new or changed lines are synthesized.
- A line is made where the script loads, like a media file is read: a line that was never
  synthesized is synthesized then, and every later load reads it. The preview makes the
  missing lines before its window opens; an edit that adds or changes a line synthesizes it
  in the reload while the last version keeps showing (its picture holds for those seconds).
- A line that can't be synthesized (no network for the download, ONNX Runtime or a model
  that doesn't load, an unknown voice) is
  `tts_unavailable`: the script still loads with the line silent, `inspect` lists it, and
  `render` refuses to start (error code `load_errors`) rather than ship silent narration.

Licences: the audio must be credited *Pocket TTS by Kyutai (CC-BY-4.0)* (put it in the
video's credits or description). The voices `cosette` and `jean` come from recordings
licensed for non-commercial use only: `say` warns (`tts_noncommercial`). Kyutai's terms
forbid using it to impersonate real people or pass generated speech off as a real recording.
English only; no voice cloning. `say()` works on Linux x86_64 and macOS Apple Silicon; the
Windows x86_64 build (and a Linux arm64 build from source) has it, untested. Intel Macs and
Windows on Arm are unsupported: onimite does not build there.
