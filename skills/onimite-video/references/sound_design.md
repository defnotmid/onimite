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
| lead | 5 detuned saws, a pulse an octave down whose `width` an `Lfo` drifts; `mono` with `portamento`; a pitch scoop (`Decay` on frequency) on each attack | 24 dB `Ladder`, an `Env` "bite" settling into a singing sustain, then `Drive` with `oversample` | an amp decaying to a sustain, short release; vibrato by an `Lfo` with `delay` and `fade` | `lead` |
| bass | a saw and a sine under it, mono | `Ladder`, a short `Decay` plucking it open by velocity, key-tracked from C2 | short attack and release | `bass` |
| reese | two saws detuned against each other, a sine sub | 24 dB low-pass moved by a slow `Lfo`, then `Drive` | sustained | `reese` |
| stab | 3 saws | resonant low-pass flicked open by a very short `Decay` | fast decay to a little sustain | `stab` |
| brass | 3 saws | 12 dB low-pass whose `Env` attack (50–150 ms) is slower than the amplitude's | the swell is the filter, not the level | `brass` |
| electric piano | FM: a sine carrier, a sine modulator at ratio 1 decaying, a high ratio one for the tine | none | decay 1.5–3 s to a soft sustain | `keys` |
| bell | FM at a non-integer ratio (3.5, 1.4) | none | the modulation dies faster than the tone | `bell` |
| clavinet | a narrow `pulse` | band-pass swept down fast, then a high-pass | short; play staccato | `clav` |
| organ | sines at drawbar ratios 0.5, 1, 2, 3, 4 | none | on and off, plus a `Noise` key click; add a Chorus | `organ` |
| drums | `Osc` sines falling in pitch (`Decay` on frequency), filtered `Noise` | band- or high-pass on the noise | `Decay`s, each a few to a few hundred ms | `machines/808.json`, `909.json`, `linn_80s.json`, `tight_modern.json`, `crunch_bap.json`, `cinematic_perc.json` |

The sample sets (audio.md, "Instruments") cover what synthesis does badly: acoustic
pianos (`vcsl/upright_piano`, `vcsl/fm_piano`, `osiris/soft_piano`), a
fingered bass (`karoryfer/growlybass`), string sections (`vsco2/strings`)
and a stereo jazz kit (`virtuosity/drums`). Use them for those roles, or
layer them with synth voices, instead of imitating them with bare
oscillators. For any other recorded instrument, play a library's own SFZ
(below: an instrument the sets don't have).

## Layering, hybrid graphs, physical modelling and SFZ

Single-oscillator presets sound flat next to records because real production
stacks complementary timbres: a sample for the real-world attack and body, a
synth for sub weight or stereo width, and a third layer that only speaks on
the hardest hits. These are the ways to build such voices
(`library/songs/velvet_horizon.json` uses them together):

- **Multi-layer instruments (`layers`).** Any instrument row can be a stack of
  `layers`, each with its own `instrument`, `gain_db`, velocity window
  (`lo_vel`, `hi_vel`), key range (`lo_key`, `hi_key`), round-robin slot
  (`seq_length`, `seq_position`) or `trigger` (`"attack"`, `"release"`,
  `"first"`, `"legato"`). A layer's instrument can itself be layered, an SFZ
  file or a row of layers: its own layers play where both their conditions
  and the outer layer's hold, at the product of their levels (an outer
  `trigger` of `attack`, the default, keeps an SFZ's release samples). A
  machine can't be a layer (its pads go by key); give it a part.
  - *Hybrid bass (`layered_bass`):* stack `{ "name": "Sampler", "set": "karoryfer/growlybass" }`
    (fingered Jazz Bass with round robins for midrange pluck and fret growl)
    with `synths.json`'s monophonic diode-ladder `bass` (for solid 40–100 Hz
    sub weight).
  - *Velocity-blooming keys (`layered_keys`):* stack `osiris/soft_piano`
    (hammer transient and felt body) with FM `keys` (warm Rhodes sustain),
    plus an FM `bell` layer with `"lo_vel": 96, "hi_vel": 127` that rings
    only on the hardest hits (velocity 0.76 and up). Layers choose by
    velocity; an accent (`X`) doesn't raise it, so give the hits that should
    ring the velocity to reach the layer.
  - *Synth and recorded doubling (`velvet_lead`):* the ladder lead
    `analog_hook` with a solo violin from VS Chamber Orchestra 2's own SFZ
    (`vsco/SViolinVib.sfz`) as a layer.
- **Sample + synth inside one node graph (`nodes`).** `Sampler` is a regular
  node kind (`{ "class": "Sampler", "set": "vsco2/strings" }`). Mixing a
  `Sampler` node with a 7-voice `fatsawtooth` `Osc` and a sub sine into one
  shared 24 dB resonant `Filter` (`symphonic_pad` in `velvet_horizon.json`)
  fuses bowed orchestral strings with wide analogue saws under one filter
  envelope, LFO drift and `cutoff` automation knob.
- **Physical modelling (`Comb`).** A `Comb` node with `"delay": 0` tunes its
  delay line to the note's exact period (compensating for its one-pole
  `damp` filter). Exciting it with a short pink `Noise` burst (`Decay` 10–15 ms)
  and a short `fatsawtooth` pluck (`karplus_pluck`) gives a plucked string or
  harp with natural acoustic decay.
- **Layered drums (machine + stereo acoustic kit).** A `909` or `808` is mono
  and punchy; `virtuosity/drums` is a stereo acoustic kit with velocity layers
  and round robins. Route both into a `drumbus` with a glue `Compressor` and
  `EQ3`: let the `909` carry the sub kick and backbeat clap, and high-pass the
  acoustic kit at 140 Hz (`Filter` `highpass`) to play ghost-note snares (`o`),
  swung 16th hats, ride cymbals and stereo tom/crash fills without muddying the
  low end.
- **SFZ instruments and pinned sources.** Point `instrument` at an `.sfz` file
  (`{ "name": "lib/piano.sfz", "ampeg_release": 0.4, "cc64": 127 }`), in the
  media folder or in a library the song declares in `sources` (next section).
  Its regions' velocity splits, round robins, release triggers, keyswitches,
  filters and envelopes play as SFZ has them, and only the zones the song's
  notes reach are downloaded.

## An instrument the sets don't have: an SFZ library

Most free sample libraries ship an SFZ file that maps their samples to
keys, velocities and round robins. Play that file; don't map samples by
their file names. Names lie: some of VS Chamber Orchestra 2's run an octave
low (its flute's "C3" sounds C4), and its own SFZ maps them right.
`library/songs/sfz_chamber.json` is the worked example: harp, flute, violin,
trumpet and cellos from VS Chamber Orchestra 2.

1. **Find a library with its own SFZ** and a licence that allows commercial
   use (CC0-1.0, CC-BY-3.0 or CC-BY-4.0; any other is refused,
   `licence_not_allowed`). The sfzinstruments organisation on GitHub holds
   many (Karoryfer's, Versilian's); VS Chamber Orchestra 2's are on its
   repository's `SFZ` branch.
2. **Pin a commit:** the source's `url` is the raw files at a commit hash
   (`https://raw.githubusercontent.com/OWNER/REPO/COMMIT/`), never a branch,
   so what a song plays can't change under it.
3. **Declare it** in the song's `sources`: a name, the `url`, `licence`,
   `credit`, `page` and `pins` (a path in the media folder; songs can share
   one pins file).
4. **Play it:** an instrument named `SOURCE/PATH.sfz`, with opcodes
   overriding the file's: `{ "vsco/SViolinVib.sfz", ampeg_attack = 0.05, ampeg_release = 0.5 }`.
   It can be a part's instrument or a layer.
5. **`onimite audio pin video.lua`** fetches what the song's notes reach and
   writes each file's SHA-256 and size to the pins. It fails (non-zero) when
   a file couldn't be fetched; run it again. Look over the new lines and keep
   them with the song. After that, `render`, `inspect` and the preview fetch
   a pinned file the first time a note needs it.
6. **Read the findings** (`onimite inspect video.lua`): `unsupported_opcode`
   names what isn't played, with its use count and the file and line of its
   first use (VS Chamber Orchestra 2's `ampeg_dynamic` only matters when a CC
   moves an envelope during a note).
7. **Level it by measurement.** An SFZ plays at its author's levels, which
   differ a lot: one note at the same velocity spans 17.6 dB across
   `sfz_chamber`'s five files. Set each part's `gain_db` from its loudness
   per scene (`onimite audio analyze video.lua --track score/flute`) and
   `onimite audio parts video.lua` (below). `onimite inspect` warns about a
   part buried under the mix (`buried_part`) and names the raise; make it,
   and run `inspect` again (a raise moves the mix).

## Mixing as part of the sound

- **Effects on the part, space on returns.** A delay or chorus that belongs to
  the sound goes in the part's `effects`. Reverb is a return that parts send
  to, so they share one space: a short `room` for drums and a longer `hall`
  for pads and leads. A high-pass on a return (`200–400 Hz`) keeps its low end
  clean.
- **Carving frequency pockets (anti-masking).** When `pad`, `keys` and `lead`
  all play in the same octave, they crowd the 250–630 Hz band. High-pass
  non-bass parts (`160–280 Hz` on pads, keys, plucks and leads), dip the
  boxy low-mids (`EQ3` `mid: -2` to `-3 dB` on pads and comping keys), and
  spread parts across the stereo field (`pan: -0.22` on keys, `+0.25` on arp,
  `-0.15` on brass, lead dead-centre).
- **Pumping.** `sidechain` from `drums/kick` ducks pads, basses and stabs in
  dance music; a song that isn't dance music usually shouldn't pump.
- **One reference level.** Every voice in `synths.json` reaches −18 LUFS
  max momentary (its loudest 400 ms) for one note at velocity 0.8, played
  alone (C4; the basses C2). Swapping one voice for another keeps the
  part's level. A voice of your own set to the same reference drops in the
  same way. A chord of four notes comes out about 6 dB louder.
- **Levels, energy arc and spectrograms.** `onimite audio analyze video.lua`
  reports each scene's loudness, stereo width, crest and the masking between
  buses; `--track score/bass` hears one part as it sounds in the mix, per
  scene, and `onimite audio parts video.lua` gives each part's loudness and
  peak alone:
  - The scenes' loudness should follow the arrangement's `energy` arc (e.g.
    an intro at −19 LUFS, a verse at −16, a build at −15, a drop at −12).
  - Inside a drop, drums and bass anchor the mix, the lead sits 3–5 LU above
    the comping (`keys`, `pad`, `arp`), and no active part sits more than
    15 LU below the mix (it is inaudible there). `inspect` reports a part
    that does in every section it has notes in (`buried_part`), naming the
    `gain_db` raise that puts it 12 LU under where it plays loudest; take
    the number, don't round it by taste, and check again until none is left.
  - Keep low-end sub energy (`20–120 Hz`) out of low-energy intros and
    breakdowns so the drop hits with physical contrast.

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
- **Development.** A motif repeated unchanged is a loop. `vary` changes
  each repeat (up a step, mirrored, thinned out, filled in), and `pickup`
  leads a phrase in. `automation` moves what a loop can't: a filter opening
  over a build, a send thrown on a phrase's last word, a fade (audio.md,
  "Movement").

The reference songs in the skill's `library/songs/` each show one of these
(JSON song files: read one with `song(json_decode(...))` as `examples/disco` does,
with the library's `instruments/`, `machines/`, `styles/` and `pins/` folders in `media/`):

| song | genre | key | meter, tempo | what it shows |
| --- | --- | --- | --- | --- |
| `funk.json` | funk | E major, an E9 vamp | 4/4, 104 bpm, light 16th swing | a syncopated 16th bass, ghost-note snares, clavinet comping |
| `jazz_waltz.json` | jazz waltz | Bb major, ii–V–I, secondary dominants | 3/4, 152 bpm, swung eighths | a walking bass, a ride pattern, comping with anticipations |
| `ballad.json` | ballad | D major, a borrowed iv and bVII | 6/8, a dotted-quarter pulse of 54, slowing at the end | piano arpeggios, strings entering, a suspension resolving |
| `boom_bap.json` | hip-hop | Eb major, I–vi–ii–V | 4/4, 90 bpm, swung 16ths | a lazy kick around the backbeat, a sub bass, EP chords, a bell motif only in the hook |
| `modal.json` | modal groove | D Dorian | 4/4, 116 bpm | a mode's colour note, an organ, a bridge a half step up |
| `drum_and_bass.json` | liquid drum & bass | F minor, round the circle of fourths | 4/4, 172 bpm | a two-step break, a reese, a pad ducked by the kick |
| `night_drive.json` | synthwave/house | D minor | 4/4, 104 bpm | synths.json's synth voices, sends, a build and a drop |
| `velvet_horizon.json` | French-touch / nu-disco | F Dorian | 4/4, 112 bpm, 16th swing | hybrid sample+synth node graphs (`symphonic_pad`), multi-layer instruments (`layered_bass`, velocity-switched `layered_keys`, a synth lead doubled by an SFZ violin), physical-modelled `Comb` pluck, 909 + high-passed stereo acoustic kit |
| `sfz_chamber.json` | chamber waltz | D major | 3/4, 80 bpm, slowing at the end | a library's own SFZ files through `sources` and pins, opcode overrides, velocity layers as dynamics, levels set by measurement |
| `lofi_live.json` | lofi | D minor | 4/4 | the sample sets |
