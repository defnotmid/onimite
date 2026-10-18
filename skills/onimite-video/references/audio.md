# Sound for onimite videos

You can't hear the result. Place sound from the same numbers that drive the picture, check it
with the commands below, and ask the user to listen in `onimite preview`.

## Files

- Put audio in `media/` beside the script: wav, ogg, mp3, flac, m4a (AAC or Apple Lossless), aac. Stereo is kept
  (`mono = true` on a track folds it to `0.707 * (L + R)` on both sides, like fframes'
  embedded media). The mix is 48 kHz stereo, encoded as AAC in renders.
- A video clip's own sound: put the clip's file name in an `audio` list.
- No music file: compose one with `song{}` (odawg, below), sound effects with `sound{}`.
  Tell the user the music is generated and offer to swap in a real track.
- Narration without a recording: `say()` speaks a line with the time of every word
  ("Spoken lines", below).

## Songs and sounds (odawg)

`song{}` composes music with odawg from data, in Tone.js's vocabulary: sections with tempo,
style, energy and chords; parts playing patterns in them. It is a sound tracks play by name,
like a clip; its sections and markers are cues. Deterministic: the same table and `seed` give
the same samples. The spec's fields are odawg's; the ones a video uses are below:

```lua
local VO = require("vo")                          -- say → song → placement: the lines first
local score = song { "score", key = "A minor", seed = 7,          -- start = 0: where it sits on the video
  instruments = { "instruments/classic.json", "instruments/sfx.json" },  -- files of rows (the library's, copied into media/)
  sections = {
    { "intro", duration = { audio = "intro", plus = { seconds = 1 } },   -- as long as a line: any duration form
      bpm = 84, style = "styles/lofi.json", energy = 0.3, chords = "Am7 Fmaj7 C G" },
    { "build", duration = "2m", bpm = { 84, 124 } },                     -- a ramp
    { "drop",  duration = "8m", flex = { "4m", "8m" }, bpm = 124, style = "styles/house.json", energy = 1 },
  },
  parts = { lead = { instrument = "pluck",
    play = { { "drop@4m..", notes = "E5 G5 A5 - G5 E5 D5 -", subdivision = "8n" } } } },
  markers = { { "logo", at = "drop@2m" } },
}
```

- A bare number is seconds; musical time is a string: `"8n"`, `"8n."`, `"8t"`, `"2m"`,
  `"2:1:0"` (bars:quarters:sixteenths). A section's `duration` (rounded up to whole bars) and
  `start` (exactly there: odawg resizes `flex` sections and nudges tempi before it) and the
  song's `start` take onimite's time forms too (`{ frame = n }` after `video{}`).
- Styles are data: a style file (`style = "styles/house.json"`, from the media folder; the
  skill's `library/styles/` has `acid_house`, `ambient`, `booty_house`, `chicago_house`,
  `house`, `lofi` and `synthwave` to copy and change) or the song's own: `styles = { footwork =
  { swing = 0.1, parts = { drums = { ... }, bass = { ... } } } }` (a partial spec, used as
  `style = "footwork"`). Parts not given come from the section's style. A song's part of the
  same name is changes over the style's (what it doesn't set, the style's part gives:
  instrument, octave, level, sends); a new name adds a part. A style's entries play by the
  section's `energy` in bands `[lo, hi)`. A part's `instrument` is a row (below).
- Transitions are written, never picked: `transition = "riser"`, `"impact"` or `"fill"` with
  `transition_part = "fx"` (or `"drums/snare"` for a fill) plays one note on that part (a
  riser 0.35, an impact 0.8), and `"cut"`/`"pause"`/`"none"` shape the change. A drop that
  sounds like one is three parts' notes: a riser over the two bars before, an impact and a
  crash on the downbeat (`play` entries; `examples/suite/track.lua`).
- Positions (`time`, ranges, `at`): `"drop"`, `"drop@1m"`, `"drop@-4n"`, `"drop@0.5s"`,
  `"2:0:0"`, `"end"`; ranges `"drop..outro"` (to the end of outro), `"drop@4m.."` (to the end
  of drop; `"drop@4m..end"` to the song's end).
- A play entry's `humanize` is seconds, as in Tone.js: each note moves by up to ± that much
  (and its velocity a little). A player is within about ±0.01; `0.004`-`0.008` keeps a groove
  tight, and anything over 0.03 is a warning (`0.12` moves notes up to ±120 ms, most of a
  sixteenth at 120 BPM: it sounds out of time). Swing is the style's `swing` (0..1).
- The song's `gain_db` (default -10, headroom for the mix) replaces the default: `gain_db = -3`
  is 7 dB louder, not 3 dB quieter. `room = { { from, to }, ... }` (seconds) or
  `room = "voice"` (where the voice bus plays): each part dips there by its `room_db` (default
  0: the styles give their pads, keys and leads some).
- A misspelled key or a bad value is a warning or error at the script line
  (`song_finding`, problems.md); a song that can't be composed is a load error.
- Section and marker names are cues (`frame video.lua drop@1m`), so they must be unique
  across the video's songs: two songs sharing one is a load error.

The song object answers on the video clock, with `beat_clock`'s signatures (a drop-in for
`beat_clock`):

```lua
local T = score.time                      -- T("drop@1m"), T(8): a number is a beat
score.start, score.duration, score.key    -- seconds; score.sections[i] = { name, start, stop, bpm, bars, ... }
score.beat(f), score.bar(f)               -- from a frame or video seconds
score.seconds("2m", "drop")               -- a length, measured where (default: the start): a bar is shorter where it's faster
score.frame("drop", fps)                  -- its frame (fps: the video's)
score.snap(t, "8n")                       -- the nearest grid point
score.pulse(f, 9)                         -- 1 on every beat, decaying (beat_clock's)
score.pulse(f, { part = "drums", note = "kick", decay = 8 })   -- from the notes really there
score.section(f)                          -- { name, progress, bar, beat, index }, bars and beats from 0
score.hits { part = "drums", note = "snare", range = "chorus" } -- seconds: cue("snare", ...) checks flashes
score.events { part = "lead", range = "drop" }                 -- { time, note, duration, velocity, part }
score.note("5", "drop@2m")                -- an in-key note name (the chord's 5th there), for a blip
```

Resolve bar offsets through the song (`T("chorus@2m")`), never `T("chorus") + 2 *
score.seconds("1m")`: under a tempo change the sum is wrong. `pulse`/`hits` reading a part
or note with nothing there warn (`no_events`: a style without that part).

`sound{ instrument, note, duration = "8n", velocity = 1, effects, sends, pan, sidechain,
gain_db, instruments }` is a one-note song, named by its content (`"impact~3f2a9c01"`): place
it like a clip, as often as needed. Its instrument is a row as a part's is: `sound { "impact",
instruments = "instruments/sfx.json" }`, `sound { { "Synth", oscillator = { type = "sine" } } }`.
With no `note` it plays the row's own pitch (a `done` chime is high, a `thump` low); its other
keys are a part's (`effects = { { "FeedbackDelay", delay_time = "8n", wet = 0.3 } }`).

```lua
local SFX = "instruments/sfx.json"                      -- the library's sound effects, in media/
video { width = 1920, height = 1080, fps = 60, duration = score.duration,
  buses = { music = {}, voice = {}, sfx = { gain_db = -6 } },
  audio = {
    { "score", bus = "music", ducked = true },          -- start: the song's own start
    { "intro", start = T("intro@4n") },                 -- a say line
    { sound { "impact", instruments = SFX }, start = T("drop"), bus = "sfx" },
    { sound { "blip", instruments = SFX, note = score.note("5", "explain"), duration = "16n" }, start = T("explain") + 0.8, bus = "sfx" },
  } }
```

- A song track takes the track fields: `gain_db` adds to its parts, `fade_in`/`fade_out`/`curve`
  and `stop` let it through a window (crossfade two songs as two clips), `offset` starts it that
  far in, `ducked` dips it under the voice. Each song keeps its own tempo; there is no song
  inside a song.
- A song plays to its end plus its tail (reverb, releases). Its parts are `score/drums`,
  `score/bass`: `--track score/bass` hears one alone, `show video.lua song/score/parts/bass`
  lists its notes.
- Nothing of a song's sound is kept: the mix and the preview stream it; `audio_energy` and
  `audio_spectrum` on a song read its tables (what each frame measures, read from the song's
  render: made once, kept, only where it sounds); `audio_onsets("score")` and `hits` are its
  notes, exact. A `frame`, `strip` or `onion` makes only the stretch its frames read. In the
  preview a song's lane opens to its parts, a part to its notes (a piano roll, a row per drum
  pad), each drawn where it plays; a bus opens to a row per sound; a song's track also opens to
  its `bands` row (a spectrogram: third-octave bands, 20 Hz at the bottom). The lanes'
  waveforms and the bands fill in as the song renders in the background, the stretch at the
  playhead first; the sound and the picture never wait for it, and a bands row costs nothing
  until it is open.

### Instruments

An instrument is a row of data: nodes wired by name, and options (the settings it takes,
each a name for one or more of its nodes' fields). Nothing is built in but Tone.js's classes;
everything else is a file of rows you copy and change. A part's `instrument` is:

- a built-in row: `"Synth"`, `"MonoSynth"`, `"FMSynth"`, `"AMSynth"`, `"MembraneSynth"`,
  `"MetalSynth"`, `"NoiseSynth"`, `"PluckSynth"`, `"Sampler"`, `"Player"`, with Tone's
  settings as changes: `{ "MonoSynth", oscillator = { type = "fatsawtooth" }, filter = { q = 4 } }`.
  `onimite show video.lua instruments` lists them; `show video.lua instrument/MonoSynth` prints
  one as data, its options and nodes;
- a name from the files the song (or its style) names: `instruments = { "instruments/classic.json",
  "instruments/sfx.json" }`, then `instrument = "pluck"` or `{ "pad", cutoff = 300, cutoff2 = 1200,
  envelope = { attack = 2 } }`;
- a file of one row: `instrument = "machines/909.json"`, `{ "instruments/tb303.json", cutoff = 500 }`;
- a row of your own, in the song's `instruments = { name = row }` or a file (below).

The skill's `library/` folder is a set of such files: copy it (or the files you use) into the
media folder, `media/instruments/...`, and change anything. A style file names its rows the
same way (`../instruments/classic.json`), so `library/styles/` works where it lands beside them.

| file | rows | options |
| --- | --- | --- |
| `instruments/classic.json` | drums `kick`, `snare`, `clap`, `hat`, `open_hat`, `crash`, `tom`; `bass`, `sub_bass`, `pad`, `stab`, `pluck`, `lead`, `bell`; `synth_kit` (a machine of the drums) | `cutoff`, `cutoff2` (Hz: where a filter starts and ends), `decay` (seconds: the fall's time constant), `envelope = { attack }` |
| `instruments/sfx.json` | `riser`, `whoosh`, `impact`, `thump`, `fall`, `tape_chord`, `tick`, `beep`, `crackle`, `glitch`, `blip`, `done` | `cutoff`, `cutoff2`, `tone` (riser, whoosh: the rising tone's level) |
| `instruments/tb303.json` | a TB-303: one voice, accents and slides (`portamento`) | `oscillator = { type }`, `tune`, `cutoff`, `resonance`, `filter_envelope = { octaves }`, `decay`, `accent` |
| `instruments/808_bass.json`, `909_bass.json` | a machine's kick as a bass, tuned to the note | `decay` (1), `tone` (0.5), `tune` (semitones) |
| `machines/808.json`, `machines/909.json` | the TR-808 and TR-909 from their circuits, 18 pads | `decay` (1: as built), `tone` (0.5), `tune` (semitones) |
| `styles/*.json` | seven styles (above) | |

A machine's notes play its pads by name (`steps = { kick = "x...x..." }`), else the pad at
the note's pitch: `kick`, `snare`, `clap`, `rim`, `hat`, `open_hat`, `crash`, `ride`, `tom_low`,
`tom_mid`, `tom_high`, `shaker`, `cowbell`, `conga_low`, `conga_mid`, `conga_high`, `clave`,
`maracas` (`x` hit, `X` accent, `.` rest); `synth_kit` has the seven drums above.

A row, as the files write it (the Lua is the same data: a node's kind first, then its
inputs; a field's base first, then what moves it):

```lua
instruments = { wobble = {
  nodes = {
    osc = { "Osc", wave = "sawtooth" },
    lfo = { "Lfo", rate = "8n" },                                     -- a Tone length: per beat
    env = { "Env", attack = 0.01, release = 0.3 },
    out = { "Filter", "osc", frequency = { 400, by = "lfo", octaves = 2 }, q = 6, amp = "env" },
  },
  out = "out",                                                        -- what it plays
  options = { cutoff = "out/frequency", speed = "lfo/rate" },          -- { "wobble", cutoff = 300 }
} }
```

- Node kinds: `Osc`, `Noise`, `Random`, `Env`, `Decay`, `Ramp`, `Lfo`, `Filter`, `Drive`, `Slew`,
  `Map`, `Mix`, `Mul`, `Comb`, `Sampler`, `Clip`; every node also has `gain_db`, `pan` and `amp`.
  A field is a number, a choice, a Tone length, or `{ base, by, octaves | ratio | sweep |
  index | amount | depth | at_most }` (or a list of those); `by` is a node or the note's
  `velocity`, `accent`, `slide`, `gate`. The order of the nodes means nothing.
- A row also takes `length` (a one-shot's seconds), `note` (the pitch with none given), `mono`,
  `portamento`, `velocity`. A machine is `{ pads = { kick = { instrument, key, choke, gain_db } } }`.
- An option's target is `"node/field"`, `"node/field/octaves"`, or `{ path, op = "mul" | "add" |
  "octaves", scale, offset }` (a list for several). A key the row doesn't read, a target that
  reaches nothing or a field an option shadows is a warning at the script line
  (`song_finding`: `unknown_key`, `unknown_option_target`, `control_shadows_field`).
- Read a file's rows for more: `library/instruments/*.json` are written this way.

The sample sets a `Sampler` plays, recorded instruments under CC0 (free for any use, no
credit needed):

| `set` | what it is |
| --- | --- |
| `"vcsl/upright_piano"` | Yamaha upright piano: C and G of every octave, three velocity layers |
| `"vcsl/fm_piano"` | Yamaha TX81Z FM electric piano: major thirds, three velocity layers |
| `"osiris/soft_piano"` | Yamaha C2 grand, half-stick and soft pedal: quiet, intimate; two velocity layers |
| `"karoryfer/growlybass"` | Squier Jazz Bass, fingered, recorded direct: three velocity layers, two round robins |
| `"vsco2/strings"` | string ensemble sustains with vibrato (cello, viola, violin sections); two velocity layers |
| `"virtuosity/drums"` | jazz kit through a stereo mic: kick, snare, cross-stick, hats, two toms, crash, ride; velocity layers and round robins |

A set downloads the first time a song plays it (only the notes the song reaches), into
`$ODAWG_DATA` or `odawg/` in the user data folder, each file checked against a pinned
SHA-256. The preview opens without waiting for it; its
notes join the sound once it has loaded. Offline, a set that can't be fetched is an
`asset_unavailable` finding and its notes are silent.

```lua
parts = {
  drums = { instrument = { "machines/909.json", tone = 0.55 },
            play = { { "drop", steps = { kick = "x...x...x...x...", hat = "..x...x...x...x." } } } },
  bass  = { instrument = { "instruments/tb303.json", cutoff = 320, resonance = 8.6, accent = 0.75 } },
  keys  = { instrument = { "Sampler", set = "osiris/soft_piano", release = 1.2 }, sends = { hall = -10 } },
  strings = { instrument = { "Sampler", set = "vsco2/strings", attack = 1.2, release = 2.5 } },
}
```

### Your own samples and styles

A `Sampler` also plays sets you bring, and a section can use a style from a file. Paths are
relative to the media folder (`media/` beside the script); keep sets in a subfolder of it
(`media/kit/`, `media/keys/`) so they aren't also loaded as tracks. Sample files are WAV or
FLAC (any rate; a WAV's own loop points are used).

```lua
local score = song { "score", bpm = 120, key = "C major",
  sets = {
    kit  = { pads = { kick = "kit/kick.wav", snare = "kit/snare.wav", hat = "kit/hat.wav" },
             credit = "my kit (CC0)" },
    keys = { zones = { { file = "keys/c3.wav", root = "C3" },
                       { file = "keys/c4.wav", root = "C4", hi_velocity = 90 },
                       { file = "keys/c4_hard.wav", root = "C4", lo_velocity = 91, gain_db = -2 } },
             loop = true },                                    -- the files' own loops sustain
  },
  sections = { { "a", duration = "8m", style = "styles/mine.json", chords = "C F G C" } },
  parts = {
    drums  = { instrument = { "Sampler", set = "kit" } },
    piano  = { instrument = { "Sampler", set = "keys", release = 0.6 } },
    rhodes = { instrument = { "Sampler", set = "rhodes/rhodes.sfz" } },   -- an SFZ instrument
  },
}
video { ..., audio = { { score, start = 0 } } }                -- a song or its name
```

- **Pads** sit on the drum pads (`steps = { kick = "x..." }` plays them), as one-shots.
  **Zones** answer the keys around their `root`; without `lo` and `hi` each zone's keys run
  halfway to the next root above and below. Zones also take `gain_db`, `one_shot`, `offset`
  (frames into the file), velocity ranges; zones on the same keys and velocities take turns
  (round robins).
- **SFZ**: `set = "path/to/file.sfz"` reads its regions (`sample`, `key`, `lokey`, `hikey`,
  `pitch_keycenter`, `lovel`, `hivel`, `volume`, `tune`, `offset`, loops, `seq_position`;
  `<global>`/`<group>` inheritance, `default_path`). Other opcodes are an
  `unsupported_opcode` info finding; the rest plays.
- **Style files**: `style = "styles/mine.json"` (a name with a `/` or ending `.json`), the
  same shape as a song's own `styles = { name = { parts, returns, swing } }`. A style's
  parts may name the song's sets.
- A song is what it is made of: its spec and the files it reads. Editing a sample or a style
  file and saving makes it a new song (the preview reloads and renders it again); nothing is
  stale.
- The samples are yours: onimite never uploads or redistributes them. Credit them as their
  licence asks (`credit`).
- **Sources** (someone else's library by URL): a song or a style declares
  `sources = { lib = { url = "https://...", page, licence = "CC0-1.0", credit, pins = "lib.pins" } }`
  and names its files under the source (`set = "lib/piano.sfz"`, `pads = { kick = "lib/kick.wav" }`).
  A file is fetched over https the first time a note reaches it, into odawg's data folder, and
  checked against the pins (`sha256 size path` lines). An unpinned file plays silent
  (`not_pinned`): `onimite audio pin video.lua` fetches what the songs play and adds the new
  files to each source's pins file (in the media folder). A licence other than CC0 or CC-BY is
  refused (`licence_not_allowed`).
  Pins say what was trusted the first time it was fetched: treat a song's `sources` like code
  you run. `examples/disco` is a complete style built this way.

### Routing

Without routing a song is mixed the usual way: each part into the master, its sends into
shared returns (one reverb for every part that sends to `hall`). Routing is data:

```lua
buses = { glue = { effects = { { "Compressor", threshold = -18, ratio = 3 } }, to = "master" } },
parts = {
  drums = { to = "glue" },                                -- into the bus instead of the master
  keys  = { sends = { hall = -12, glue = -6 } },          -- a send goes to a return or a bus
  pad   = { key = "drums",                                -- its compressor hears the drums
            effects = { { "Compressor", threshold = -30, ratio = 8, attack = 0.001 } } },
}
```

- `to` moves a part's or a bus's output onto a bus; `sends` add a path at a gain (dB);
  `key` is what a part's compressor or gate listens to (a real sidechain on the drums'
  sound, not only their notes).
- Paths of different latency are lined up where they meet. A loop is a `routing_loop`
  finding; the edge closing it is left out and the song still plays.
- `audio analyze` measures the mix and each bus: their bands, crest, width and correlation,
  and where buses crowd each other in a band (`masking`).

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
| first entry or `src` | the media file (or an `audio_add`, `say`, `song` or `sound` name) |
| `start` | when it starts: seconds, `{ frame = n }`, `{ minutes = 1, seconds = 5 }`, `{ audio = "f" }`, with `plus` / `minus`, or a list (summed); a song on `video{}` without one: its own start |
| `stop` | when it ends, same forms; omitted = to the end of the file; `stop = { audio = "f" }` is the file's length on the timeline |
| `offset` | seconds into the file to start from |
| `gain_db` | level in dB (0 = as recorded) |
| `pan` | -1 (left) .. 1 (right) |
| `fade_in`, `fade_out` | seconds |
| `curve` | `"linear"` (default) or `"equal_power"` (for crossfades between two tracks) |
| `voice` | marks a voice track that `ducked` tracks dip under |
| `ducked` | `true` (fframes' `duck_under_voice`: -12 dB, 0.2 s attack before the voice, 0.3 s hold, 0.8 s release, voice gaps under 0.8 s merged) or `{ depth_db, attack, hold, release, merge_gap }` |
| `mono` | play a stereo file as mono |
| `effects` | a clip's effect chain, as a song part's is written: `{ { "Filter", type = "highpass", frequency = 200 }, { "Reverb", wet = 0.2 } }`; a misspelled effect or key is a load finding at the track's line (`effect_finding`); a song's or sound's effects go on its parts or its `sound{}` |
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

The mix is odawg's: tracks (clips as Players, songs as their parts) sum linearly with
de-click fades into a master bus, then `master_gain_db` and odawg's true-peak `Limiter`
(fframes' `AudioMixOptions`). The render and the preview are one stream: the same samples.

```lua
video { width = 1920, height = 1080, fps = 30, duration = 5,
  audio = { { "music.mp3", start = 0 } },
  master_gain_db = 3.5,              -- before the limiter
  limiter = { ceiling_db = -1.5 },   -- true peak, default -1 dBTP; limiter = false turns it off
}
```

The limiter stops loud overlaps from clipping, but a limiter working hard squashes the mix:
fix track gains first. To hit a loudness target with a hot synthesized track, raise
`master_gain_db` and lower `ceiling_db` until `audio analyze` shows the target with true peak
under -1 dBTP (why_onimite: `master_gain_db = 5.5`, `ceiling_db = -3.4` gives -14.3 LUFS,
-3.4 dBTP).

## Checking without listening

```bash
onimite timeline video.lua                        # every track: span, gain, fades; every sync point; songs: sections, tracks
onimite show video.lua song/score                 # a song: sections, parts, findings; song/score/parts/bass: every note
onimite audio at video.lua 3.1s,drop              # what plays at a moment: file position, level, ducking, voice; a song's section and the notes sounding
onimite audio analyze video.lua                   # loudness, crest, width, bands; per scene, per bus, masking; per second
onimite audio analyze video.lua --waveform w.png  # read the image: waveform, loudness, spectrogram, scenes, onsets, cues
onimite audio analyze video.lua Intro             # one scene or range
onimite audio onsets video.lua [range] [--min 0.3] # where sounds start (seconds strength) and the beat
onimite audio pin video.lua                       # fetch and pin what the songs play from their sources (after not_pinned)
onimite audio render video.lua Intro -o intro.wav # the mix of a range, for the user to listen to
```

Every audio command takes `--track FILE`: that track alone, as it sounds in the mix (the others
still duck it); a bus name hears the bus, `--track score/bass` one part of a song. `inspect`
renders each song alone through odawg's checks (`silent_part`, `clipping`, `true_peak`) and
reports what reading and composing it found (`song_finding`).

Targets for the report:
- Integrated loudness about -14 LUFS for web and social (-16 for podcasts, -23 for
  broadcast). More than 2 LU off: change the track gains or `master_gain_db`.
- True peak at or below -1 dBTP; clipped samples 0.
- Loudness range 4-10 LU for music videos and explainers; far higher means quiet and loud
  parts need balancing (or a long silent intro/outro).
- Silent ranges only where silence is intended: an unexpected one means a track ends early,
  a file is missing (`inspect` and `timeline` show it) or a start time is wrong.

What the sound is made of (the JSON has each for the mix, each scene and each bus; `band_hz`
names the 31 third-octave bands of every `bands_db`, 20 Hz to 20 kHz):
- `crest_db` (peak over RMS): about 8-14 dB for mixed music; much higher is spiky (drums
  with no body), lower is squashed.
- `width_db` (side over mid) and `correlation` (1 mono, 0 unrelated, below 0 out of phase):
  a correlation below 0 means a part will cancel in mono; fix its stereo effect.
- `bands_db`: where the energy is. A mix with nothing below 60 Hz has no bass; one band far
  above its neighbours is a resonance.
- `masking`: two buses within 6 dB of each other in a band, both within 15 dB of the mix
  there, crowd each other (`{ section, a, b, band_hz, overlap_db }`). Cut one of them there
  (an EQ on its part or bus), or move one in time or in pitch.
- The PNG's spectrogram shows the same bands over time under the waveform: a drop's low end,
  a breakdown's empty bottom, a hi-hat line across the top.
- Per scene: scenes with voice within ~2 LU of each other.

The per-second loudness line (`--json`: `loudness.momentary_lufs`, every 100 ms) shows the
shape of the music: a quiet intro, a build, a jump of several LU where it drops. The waveform
image marks scenes, track starts, every onset (white ticks, as tall as they are strong) and
the script's cues: each sound should sit where its visual event is. Put the moments that must
meet on the same `cue` and `inspect` checks them (Cues in api.md); for one-off checks
use `audio at` on the event time and a `frame` of the same time.

`inspect` also checks every sound against the music's beat (`off_beat`, problems.md): the
music is the tracks on a bus named `music`; over a song it is the song's own grid (the
half-beat from its section's start) where a drum plays in that section (none: no beat to be
off, as over pads); elsewhere, around each hit it measures the beat from the
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

Any value in `render` can follow the sound: `audio_energy` for how loud it is now,
`audio_spectrum` for the spectrum at a moment, `pulse(clock.beat(t), sharpness)` for the beat, onset times (`audio_onsets`) for hits.
Pass shader uniforms the same numbers (`uniforms = { uBass = bass }`).

```lua
local levels = audio_spectrum(f, { src = "music.mp3", sample_size = 512, smooth = 2, window = "hann",
  bands = 32, log = true, levels = { -20, 26 } })   -- 32 bands, an equal pitch step each, as 0..1
for i, v in ipairs(spectrum_centered(levels)) do    -- low frequencies in the middle
  local h = v * 300 + 6
  rect { x = 200 + (i - 1) * 48, y = 900 - h, w = 36, h = h, rx = 8, fill = "#38bdf8" }
end
```

`audio_energy(f, { src, bus, smooth = 0 })` -> `{ rms, peak, low, mid, high }`, each 0..1:
the clip `src` where its tracks play it, else every track playing at `f` (on bus `bus` only,
when given) summed by gain; `low` is the energy below 375 Hz (kick, bass), `mid` to 2.8 kHz
(voice), `high` above; `smooth` averages that many frames each side:

```lua
local e = audio_energy(f, { bus = "music", smooth = 2 })
circle { cx = 960, cy = 540, r = 120 + 80 * e.low, fill = "#f472b6" }
view3d { ..., bloom = { intensity = 0.3 + e.rms }, ... }
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

Prefer `song{}` and `sound{}`: `audio_add` is for sound the script computes itself. Patterns:
`examples/why_onimite/track.lua` (one song on a fixed tempo), `examples/onimite_saga/music/`
(a song whose sections follow the scenes, tempo ramps, its parts in their own files),
`examples/onimite_saga/sfx.lua` (`sound{}` effects on a bus). Tell the user the music is
composed and offer to swap in a real track.

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
`.m4a` (AAC or Apple Lossless) such as a phone's voice memo, `.mp3`, `.aac`, `.flac`, `.ogg`; or a `.safetensors`
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

- **One leader per moment.** The voice follows the music: `{ "features", start =
  say_start(VO.features, "Onimite", T("drop")) }` (where to start the line so the word lands at
  the time; the inverse of `say_cue`). The music follows the voice: give the section a `start`
  from `say_cue(...)` and odawg lands it there (or reports `start_unreachable`). Lua runs in
  order, so per moment decide who leads: say → song → placement.
- A sound snapped to the grid (`score.snap(t, "8n")`) shouldn't also carry the word's cue.

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
