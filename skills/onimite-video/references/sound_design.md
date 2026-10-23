# Sound design

How to build voices from odawg's node kinds, and how to write songs that don't
sound like every other one (adapted from odawg's SOUND_DESIGN.md). The library is
techniques to learn from, not sounds to reuse: a song picks its own sounds, key,
tempo and feel for its video. [audio.md](audio.md) has the format ("Songs and
sounds", "Instruments"). `onimite show video.lua instrument/NAME` prints any
built-in row, and the skill's `library/instruments/synths.json` has the voices
below written out.

## What makes a voice sound expensive

Most cheap-sounding synths are missing the same few things:

- **Movement inside the note.** A static tone is a test signal. Give the
  filter its own envelope (`frequency: [{ "base": 300, "by": "fenv", "octaves": 4 }]`)
  so the note's colour changes over time: a fast fall makes it plucky, a slow
  rise makes it swell. A slow `Lfo` on the cutoff or the pitch keeps a held
  note alive.
- **Response to playing.** Real instruments get brighter as well as louder
  when played harder. Add `{ "by": "velocity", "octaves": 1 }` to a filter's
  cutoff, or put `velocity` in an FM modulator's `amp`. Then a part's
  accents (`X`) and ghosts (`o`) change the tone, not just the level.
- **Key tracking.** A fixed cutoff is bright on low notes and dull on high
  ones. Track the key from a centre: a `Map` of `key` with
  `offset: -60` feeding `{ "by": "track", "octaves": 0.0417 }` (half
  tracking: an octave up opens the filter half an octave).
- **A real filter.** `onepole` is 6 dB/octave with no resonance: it dulls,
  it doesn't shape. Use `lowpass` with `rolloff: -24` and some `q` (0.8–3),
  or the `Ladder` for basses and acid.
- **Width and thickness.** `fatsawtooth` (`count` 3–7, `spread` 8–25
  cents, `width` 0–1) is unison: the copies drift against each other and
  spread across the sides. Keep basses narrow (`width` low or mono) and
  pads wide.
- **A shaped amplitude.** Choose the `Env`'s attack, decay, sustain and
  release for the role: a pluck has no sustain, a pad a slow attack and a
  long release, a bass a short release so notes don't smear.

## Voices by role

| role | oscillators | filter | envelopes | in synths.json |
| --- | --- | --- | --- | --- |
| pad | 5–7 detuned saws, wide; a sine an octave down | 24 dB low-pass, low base, opened slowly by its own `Env`, a slow `Lfo` drift | attack 0.3–2 s, release 1–3 s | `pad` |
| pluck | 2–3 saws or a square | resonant 24 dB low-pass snapped shut by a `Decay` (0.1–0.25 s), velocity opening it | no sustain, decay 0.5–1 s | `pluck` |
| lead | 3–5 saws, a sub square; `mono` with `portamento` | 12 dB low-pass, an `Env` "bite" settling to a sustain | short release; vibrato by an `Lfo` with `delay` and `fade` | `lead` |
| bass | a saw and a sine under it, mono | `Ladder`, a short `Decay` plucking it open by velocity, key-tracked from C2 | short attack and release | `bass` |
| reese | two saws detuned against each other, a sine sub | 24 dB low-pass moved by a slow `Lfo`, then `Drive` | sustained | `reese` |
| stab | 3 saws | resonant low-pass flicked open by a very short `Decay` | fast decay to a little sustain | `stab` |
| brass | 3 saws | 12 dB low-pass whose `Env` attack (50–150 ms) is slower than the amplitude's | the swell is the filter, not the level | `brass` |
| electric piano | FM: a sine carrier, a sine modulator at ratio 1 decaying, a high ratio one for the tine | none | decay 1.5–3 s to a soft sustain | `keys` |
| bell | FM at a non-integer ratio (3.5, 1.4) | none | the modulation dies faster than the tone | `bell` |
| clavinet | a narrow `pulse` | band-pass swept down fast, then a high-pass | short; play staccato | `clav` |
| organ | sines at drawbar ratios 0.5, 1, 2, 3, 4 | none | on and off, plus a `Noise` key click; add a Chorus | `organ` |
| drums | `Osc` sines falling in pitch (`Decay` on frequency), filtered `Noise` | band- or high-pass on the noise | `Decay`s, each a few to a few hundred ms | `machines/808.json`, `909.json` |

The sample sets (audio.md, "Instruments") cover what synthesis does badly: acoustic
pianos, a fingered bass, string sections and a jazz kit. Use them for those
roles instead of imitating them.

## Mixing as part of the sound

- **Effects on the part, space on returns.** A delay or chorus that belongs to
  the sound goes in the part's `effects`. Reverb is a return that parts send
  to, so they share one space: a short `room` for drums and a longer `hall`
  for pads and leads. A high-pass on a return keeps its low end clean.
- **Pumping.** `sidechain` from `drums/kick` ducks pads, basses and stabs in
  dance music; a song that isn't dance music usually shouldn't pump.
- **Levels by measurement.** `onimite audio parts video.lua` reports each
  part's loudness and peak (`--track score/bass` hears one in the mix). The drums and bass anchor the mix, the melody sits clearly
  above the comping, and a part more than about 15 LU under the mix is
  inaudible.

## Writing a song that isn't the default one

Left to itself, a generator writes the most likely song: A minor, Am F C G,
120 bpm, a kick on every beat, a clap on 2 and 4, eight-bar sections built
up and dropped. Choose each of these on purpose:

- **Genre and feel first.** Pick a genre for the piece, find a real reference
  track, and copy its decisions: its tempo, meter, swing, which instruments
  play, and where the kick and snare fall.
- **Key and harmony.** Major keys, modes (Dorian's major IV, Lydian's raised
  4th, Mixolydian's flat 7th), dominant vamps, ii–V–I, borrowed chords and
  suspensions all sound different from a minor loop.
- **Meter and groove.** 3/4 and 6/8 exist (`time_signature`). `swing` and
  `swing_subdivision` set the feel. Accents (`X`) and ghost notes (`o`)
  make a pattern groove, and `humanize` loosens it. A list of bar strings in
  `steps` varies a pattern bar by bar: put a fill in the last bar of a
  phrase.
- **Form.** Let sections be long enough for an idea to develop. Change
  something at each one: a part drops out, the bass pattern changes, the
  drums go half-time.

The reference songs in the skill's `library/songs/` each show one of these
(JSON song files: read one with `song(json_decode(...))` as `examples/disco` does,
with the library's `instruments/`, `machines/` and `styles/` folders in `media/`):

| song | genre | key | meter, tempo | what it shows |
| --- | --- | --- | --- | --- |
| `funk.json` | funk | E major, an E9 vamp | 4/4, 104 bpm, light 16th swing | a syncopated 16th bass, ghost-note snares, clavinet comping |
| `jazz_waltz.json` | jazz waltz | Bb major, ii–V–I, secondary dominants | 3/4, 152 bpm, swung eighths | a walking bass, a ride pattern, comping with anticipations |
| `ballad.json` | ballad | D major, a borrowed iv and bVII | 6/8, a dotted-quarter pulse of 54, slowing at the end | piano arpeggios, strings entering, a suspension resolving |
| `boom_bap.json` | hip-hop | Eb major, I–vi–ii–V | 4/4, 90 bpm, swung 16ths | a lazy kick around the backbeat, a sub bass, EP chords, a bell motif only in the hook |
| `modal.json` | modal groove | D Dorian | 4/4, 116 bpm | a mode's colour note, an organ, a bridge a half step up |
| `drum_and_bass.json` | liquid drum & bass | F minor, round the circle of fourths | 4/4, 172 bpm | a two-step break, a reese, a pad ducked by the kick |
| `night_drive.json` | synthwave/house | D minor | 4/4, 104 bpm | synths.json's synth voices, sends, a build and a drop |
| `lofi_live.json` | lofi | D minor | 4/4 | the sample sets |
