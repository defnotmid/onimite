# French disco

An 80-second French disco house track on a style that isn't one of odawg's. The style brings
its own band, and every recorded instrument in it is someone else's library: fetched from
where its authors publish it, pinned by SHA-256, and only the samples the song's notes reach.
The video reads the song: a scene per section, a dance floor whose tiles are the spectrum, a
mirror ball that swells on the real kicks.

```sh
onimite preview examples/disco/video.lua
onimite render  examples/disco/video.lua -o disco.mp4
onimite audio analyze examples/disco/video.lua --waveform disco.png   # bands, crest, width, masking
```

The first run fetches about 73 MB into odawg's data folder (`$ODAWG_DATA`, else `odawg/` in
the user data folder), verified against the pins; after that it renders offline. The mix:
-14.5 LUFS, -1.0 dBTP.

## Layout

| file | what it holds |
| --- | --- |
| `video.lua` | the video: the song loaded from `media/song.json`, the floor, the ball, the words per section |
| `media/song.json` | the song (JSON5): its form (intro, groove, lift, break, drop, outro at 122 BPM in D minor), harmony and buses; odawg's CLI renders the same file |
| `media/styles/french_disco.json` | the style: its sources, its percussion set, its parts by energy |
| `media/styles/french_disco/*.sfz` | mappings over VSCO 2 CE's raw WAVs (VSCO's names run an octave low: A3 sounds A4) |
| `media/styles/french_disco/*.pins` | `sha256 size path` for every file the song fetches |

## The mix

| part | played on | through |
| --- | --- | --- |
| kick, hats | odawg's 909 (`DrumMachine`) | the master; the kick is the pump's key |
| percussion | VCSL claps, tambourine, shaker, congas, cowbell | a set the style writes out (`pads`, a list is a round robin) |
| bass | Karoryfer Fashionbass, its authors' own `fashionbass_clean.sfz` | the pump |
| guitar | Karoryfer Emilyguitar, its authors' own `emily_clean.sfz`, voiced as ninth chords | the pump; the intro and break chops through the dark filter first |
| violins, strings | VSCO 2 CE violin section, spiccato and sustained | the pump |
| brass, trombone | VSCO 2 CE trumpet and tenor trombone, staccato | the pump |

`pump` is a compressor keyed by the kick (`buses = { pump = { key = "kick", ... } }`), so
the band breathes on every beat; `dark` is a resonant low-pass into the pump.

## Sources and trust

A source is `{ url, page, licence, credit, pins }`: files under its name are fetched from its
https URL when a note first reaches them and checked against its pins. A file that isn't
pinned plays silent (`not_pinned`); a licence other than CC0 or CC-BY is refused. The pins
here were made by fetching once and trusting what came; treat a song's `sources` like code
you run, and prefer an author's own published hashes.

## Licences

Every library is CC0 1.0: commercial use is allowed and no credit is required; the video
credits them anyway.

- [Fashionbass](https://github.com/sfzinstruments/karoryfer.fashionbass) and
  [Emilyguitar](https://github.com/sfzinstruments/karoryfer.emilyguitar) by Karoryfer
  Samples (D. Smolken)
- [VS Chamber Orchestra 2: Community Edition](https://github.com/sgossner/VSCO-2-CE) and the
  [Versilian Community Sample Library](https://github.com/sgossner/VCSL) by Versilian Studios

Song and style by odawg; video by onimite.
