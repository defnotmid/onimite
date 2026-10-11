# Third-party notices

onimite is MIT licensed ([LICENSE](LICENSE)). Every license it carries is a
separate file in [LICENSES/](LICENSES); binary releases ship `LICENSE`,
`LICENSES/` and this file.

## In the onimite binary

| Component | What it does | License file |
| --- | --- | --- |
| ovg | vector renderer | `LICENSES/ovg-MIT.txt` |
| femtovg | ovg is a port of it (used under its MIT option) | `LICENSES/femtovg-MIT.txt` |
| oksl | SkSL shader compiler | `LICENSES/oksl-MIT.txt` |
| odecs | codecs and containers | `LICENSES/odecs-MIT.txt` |
| libwebp | tables in odecs' WebP decoder | `LICENSES/libwebp-BSD-3-Clause.txt` |
| Lua 5.4 | script runtime | `LICENSES/Lua-MIT.txt` |
| SDL 3 | window, input, audio, GPU (bundled shared library) | `LICENSES/SDL3-Zlib.txt` |
| kb_text_shape | text shaping | `LICENSES/kb_text_shape-Zlib.txt` |
| stb_image, stb_truetype | images, font outlines (used under MIT) | `LICENSES/stb-MIT.txt` |
| miniaudio | audio decoding (used under MIT-0) | `LICENSES/miniaudio-MIT-0.txt` |
| Box2D 3.1 | rigid-body physics (`physics{}`) | `LICENSES/Box2D-MIT.txt` |
| ottis | text to speech with word timings (`say()`): runs Pocket TTS and the word aligner through ONNX Runtime | `LICENSES/ottis-MIT.txt` |
| Noto Color Emoji (COLRv1 build, Copyright 2022 Google Inc.) | the emoji fallback font, embedded via ovg | `LICENSES/OFL-1.1.txt` |

## Downloaded at run time (`say()`)

The first `say()` that needs synthesis downloads these into ottis's data
directory (`$OTTIS_DATA`, else `~/.local/share/ottis`; about 830 MB), each
pinned by SHA-256. None of it is in this repository or the binary.

| What | From | License |
| --- | --- | --- |
| ONNX Runtime 1.30.0 (CPU), loaded with dlopen | github.com/microsoft/onnxruntime releases | MIT; its `LICENSE` and `ThirdPartyNotices.txt` are extracted next to the library |
| Pocket TTS `english_2026-04` weights | Kyutai, huggingface.co/kyutai/pocket-tts | CC-BY-4.0 |
| ONNX export of those weights | huggingface.co/KevinAHM/pocket-tts-onnx | CC-BY-4.0 |
| Precomputed voices | huggingface.co/kyutai/pocket-tts-without-voice-cloning | CC-BY-4.0; each voice's source recording carries its own license (huggingface.co/kyutai/tts-voices): `cosette` (Expresso) and `jean` (EARS) are non-commercial, and onimite warns about them (`tts_noncommercial`) |
| wav2vec2-base-960h (the word aligner) | Facebook AI, ONNX export by huggingface.co/onnx-community | Apache-2.0 |

Audio made with `say()` must be credited: *Pocket TTS by Kyutai
(CC-BY-4.0)*. Kyutai's acceptable-use terms for Pocket TTS prohibit, among
other things, voice impersonation or cloning without explicit and lawful
consent, and presenting generated audio as genuine recordings of real people
or events. `examples/voiceover` is spoken with the voice `alba`.

## Ported from

- fframes (https://github.com/dmtrKovalenko/fframes): onimite ports its
  design, command line, examples and its Shadertoy-to-SkSL rewrite.
  `LICENSES/fframes-MIT.txt`.

## Example assets (in `examples/`, not in the binary)

- `examples/fframes/` uses fframes' own media, fonts and shaders. They are
  not in this repository: `examples/fframes/fetch.sh` copies them from a
  fframes checkout, under fframes' terms.

- Fonts, SIL Open Font License 1.1 (`LICENSES/OFL-1.1.txt`): Anton (2020 The
  Anton Project Authors), Archivo Black (2017 The Archivo Black Project
  Authors), Bebas Neue (2019 The Bebas Neue Project Authors), DM Sans
  (2014-2017 Indian Type Foundry, Reserved Font Name 'Poppins'), Fredoka One
  (2011 Milena B Brandao, Reserved Font Name "Fredoka"), IBM Plex Mono (2017
  IBM Corp.), Instrument Serif (2022 The Instrument Serif Project Authors),
  Inter (2016 The Inter Project Authors), JetBrains Mono (2020 The JetBrains
  Mono Project Authors), Montserrat (2011 The Montserrat Project Authors),
  Noto Sans Arabic (2022 The Noto Project Authors), Sofia Sans Semi Condensed
  (2019 The Sofia Sans Project Authors), Space Grotesk (2020 The Space
  Grotesk Project Authors).
- `examples/lottie_demo`: the dalek animation from lottie-web
  (`LICENSES/lottie-web-MIT.txt`); the spiral and trim animations from Skia's
  skottie resources (`LICENSES/Skia-BSD-3-Clause.txt`).
- `examples/svg_demo` bird and the ovg demo rocket: CC0, drawn for onimite.
- Generated media, part of this repository (MIT, like the code): every
  sound, voice line, video clip and photo in `examples/` (music, effects,
  `vo.wav` / `vo2.m4a`, `clip.mp4`, the alpha clips `transparent.mov`,
  `avatar_vp9_alpha.webm` and `mascot.webm`, `canyon.webp`) is rendered or
  synthesized by onimite from the scripts in `tools/gen_media/` and
  converted by `tools/gen_media/gen.sh`, which regenerates them all. The
  voice lines are placeholders spoken by espeak-ng (run by `gen.sh` as a
  build tool, like ffmpeg; neither ships with onimite) and may be replaced
  by other synthesized speech (e.g. Gemini TTS) with the same words and
  lengths.
- Made for the examples (MIT, this repository): the Lottie `title.json`
  (lottie_demo) and `badge.json`, `illustration.svg` and `tokens.json`
  (designer_handoff); the caption files `talk.json` and `story.json`;
  `subs.vtt` (media_demo).
