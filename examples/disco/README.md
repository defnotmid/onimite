# French touch

A 76-second French touch track, hard and electronic, with Stardust's filtered pump, Bob
Sinclar's clap-and-chop disco loops and Flight Facilities' glossy synths as inspiration (none
of them copied). Synth voices of its own play with someone else's recorded instruments: every
library is fetched from where its authors publish it, pinned by SHA-256, and only the samples
the song's notes reach. The band plays one loop, and the whole loop goes through a grain of
distortion and one low-pass whose cutoff is the arrangement: a club heard through a wall in
the intro, opening over the groove, wide for the hook, back down and resonating in the break,
a bar's climb into the drop (the build is the filter, no riser), closing in the outro. A
talk-box lead of our own, the violin section and a synth arpeggio play over it, and everything
ducks hard under the 909 kick.

The video reads the song over one ray-traced club: a mirror ball of tilted facets that throws
flecks of three spotlights across the walls and the floor and sparkles on the open hats, beams
in the haze, a light-up floor whose columns are the spectrum, the spots coming on as the
filter opens (the light reads the same automation lane the engine plays) and a strobe on the
drop's kicks.

```sh
onimite preview examples/disco/video.lua
onimite render  examples/disco/video.lua -o disco.mp4
onimite audio parts examples/disco/video.lua                         # the balance table, part by section
onimite audio analyze examples/disco/video.lua --waveform disco.png  # bands, crest, width, masking
```

The first run fetches what the notes reach into odawg's data folder (`$ODAWG_DATA`, else
`odawg/` in the user data folder), verified against the pins; after that it renders offline.
Mastered to about -14 LUFS (`onimite audio analyze`): quieter in the intro, loudest in the drop.

## Layout

| file | what it holds |
| --- | --- |
| `video.lua` | the video at 60 fps: the song loaded from `media/song.json`, what the club reads of it (the kick and the open hats, the spectrum, the filter's lane), the words per section |
| `shaders/common.sksl` | the club, shared by its passes: the room, the ball's facets, the flecks, the floor, the haze |
| `shaders/haze.sksl`, `soft.sksl` | the light in the air, traced at half resolution and softened |
| `shaders/room.sksl`, `glow.sksl` | the surfaces and the ball with the haze over them; the lens (bloom, stars, tone mapping) |
| `media/song.json` | the song (JSON5; odawg's CLI renders the same file): B-flat minor at 126, intro, groove, hook, break, drop, outro; its sources, its percussion set, its own voices (talk box, grit bass) and layered rows, its parts with their roles, the filter's automation |
| `media/machines/909.json` | the library's TR-909, copied in so the song travels alone |
| (the skill's `library/instruments/effects.json`) | the phaser on the loop bus, named in the song's `effects` |
| `media/pins/*.pins` | `sha256 size path` for every file the song fetches, a file per source |

## The band

| part | role | played on | through |
| --- | --- | --- | --- |
| drums | drums | the 909, driven: kick, hats, open hats, doubled clap and snare, a crash on the hook and the drop | the master; its kick ducks everything else |
| percussion | texture | VCSL tambourine, shaker and congas | a set the song writes out (`pads`, a list a round robin) |
| bass | bass | `bassline`: `grit` (a saw and a square through a barking ladder, driven hard) with Karoryfer Fashionbass's `fashionbass_clean.sfz` inside it: a played line, a half step into every root | the `loop` bus |
| guitar | comp | Karoryfer Emilyguitar, its authors' `emily_clean.sfz`: sixteenth chops, accents off the beat | the `loop` bus |
| stabs | comp | `stabs`: the library's saw stab with VCSL's upright piano in it, pushed ahead of the beat | the `loop` bus |
| pad | pad | `silk`: VSCO 2 CE's violas with the library's synth pad layered in, from the hook to the drop | the `loop` bus |
| talk | melody | `talk`: a saw and a pulse through three formant band-passes that open from "oo" to "ah" on each note, gliding | the master |
| violins | counter | VSCO 2 CE's violin section in the hook, a half note each, against the lead | the master |
| arp | counter | the library's pluck up and down the chord in sixteenths in the drop, through the echo | the master |

`loop` is a distortion, a 24 dB low-pass and a phaser (the skill library's
`instruments/effects.json`, a row of nodes: four all-pass stages an LFO sweeps every four
seconds). Its cutoff moves on the lane
`buses/loop/Filter/frequency` (260 Hz to 16 kHz), and its resonance rises in the break
(`buses/loop/Filter/q`). Each part's `role` holds its level: `inspect` reports a part that sits
outside its role's band (`role_balance`), and `audio parts` prints the table.

## Sources and trust

A source is `{ url, page, licence, credit, pins }`. Files under its name are fetched from its
https URL when a note first reaches them, and checked against its pins. A file that isn't
pinned plays silent (`not_pinned`); a licence other than CC0 or CC-BY is refused.
`onimite audio pin examples/disco/video.lua` writes the pins. The pins here were made by
fetching once and trusting what came. Treat a song's `sources` like code you run, and prefer
an author's own published hashes.

## Licences

Every library is CC0 1.0: commercial use is allowed and no credit is required; the video
credits them anyway.

- [Fashionbass](https://github.com/sfzinstruments/karoryfer.fashionbass) and
  [Emilyguitar](https://github.com/sfzinstruments/karoryfer.emilyguitar) by Karoryfer
  Samples (D. Smolken)
- [VS Chamber Orchestra 2: Community Edition](https://github.com/sgossner/VSCO-2-CE) and the
  [Versilian Community Sample Library](https://github.com/sgossner/VCSL) by Versilian Studios

Song by odawg; video by onimite.
