# Third-party notices

onimite is MIT licensed ([LICENSE](LICENSE)). Every license it carries is a
separate file in [LICENSES/](LICENSES); binary releases ship `LICENSE`,
`LICENSES/` and this file.

## In the onimite binary

| Component | What it does | License file |
| --- | --- | --- |
| ovg | vector renderer | `LICENSES/ovg-MIT.txt` |
| femtovg | ovg is a port of it (used under its MIT option) | `LICENSES/femtovg-MIT.txt` |
| nanovg | femtovg's origin: the tessellation, antialiasing and shader design ovg inherits through it | `LICENSES/nanovg-Zlib.txt` |
| oksl | SkSL shader compiler (and o3d's ShaderMaterial compiler) | `LICENSES/oksl-MIT.txt` |
| odecs | codecs and containers | `LICENSES/odecs-MIT.txt` |
| libwebp | odecs' WebP decoder is a restructured port of libwebp's decoder and copies its tables | `LICENSES/libwebp-BSD-3-Clause.txt` |
| libopus 1.6.1 | odecs' Opus decoder is a restructured port of it | `LICENSES/libopus-BSD-3-Clause.txt` |
| gen2brain/h265 | odecs' H.265 decoder began as a port of it | `LICENSES/gen2brain-h265-MIT.txt` |
| oxideav-h265 | cross-reference for odecs' H.265 decoder and transforms | `LICENSES/oxideav-h265-MIT.txt` |
| Kvazaar | odecs' H.265 encoder follows it (CABAC, SAO decisions, context tables) | `LICENSES/Kvazaar-BSD-3-Clause.txt` |
| OpenH264 | the CABAC tables in odecs' H.264 decoder | `LICENSES/OpenH264-BSD-2-Clause.txt` |
| Apple ALAC | odecs' Apple Lossless decoder is a restructured port of Apple's reference decoder | `LICENSES/ALAC-Apache-2.0.txt` |
| Lua 5.4 | script runtime | `LICENSES/Lua-MIT.txt` |
| SDL 3 | window, input, audio, GPU (bundled shared library) | `LICENSES/SDL3-Zlib.txt` |
| kb_text_shape | text shaping | `LICENSES/kb_text_shape-Zlib.txt` |
| stb_image, stb_truetype | images (o3d's textures too), font outlines (used under MIT) | `LICENSES/stb-MIT.txt` |
| miniaudio | audio decoding (used under MIT-0) | `LICENSES/miniaudio-MIT-0.txt` |
| Box2D 3.1 | rigid-body physics (`physics{}`) | `LICENSES/Box2D-MIT.txt` |
| Box3D | 3D rigid-body physics (`physics3d{}`) | `LICENSES/Box3D-MIT.txt` |
| o3d | 3D layers (`view3d{}`): the scene, its software and SDL_GPU renderers, glTF import | `LICENSES/o3d-MIT.txt` |
| cgltf (`vendor:cgltf`) | o3d's glTF 2.0 / GLB parsing | `LICENSES/cgltf-MIT.txt` |
| three.js | o3d follows its conventions and models: MeshStandardMaterial's shading, PCF shadows, equirectangular environment lighting, GLTFLoader's material and scene rules | `LICENSES/three.js-MIT.txt` |
| ottis | text to speech with word timings (`say()`): runs Pocket TTS and the word aligner through ONNX Runtime | `LICENSES/ottis-MIT.txt` |
| Pocket TTS (Kyutai, github.com/kyutai-labs/pocket-tts) | ottis ports its text preparation and chunking, the generation loop's end-of-speech rule and the decoder fade-in | `LICENSES/pocket-tts-MIT.txt` |
| odawg | sound (`song{}`, `sound{}`, the mix): composing songs from data, its synths, drum machines, samplers and effects, the master and the preview stream, loudness, onsets and spectra | `LICENSES/odawg-MIT.txt` |
| Odin core and vendor packages (Copyright 2016-2025 Ginger Bill) | the runtime and core library every Odin program links, and the vendor bindings above (`vendor:cgltf` among them) | `LICENSES/Odin-Zlib.txt` |
| Noto Color Emoji (COLRv1 build, Copyright 2022 Google Inc.) | the emoji fallback font, embedded via ovg | `LICENSES/OFL-1.1.txt` |
| Bitstream Vera Sans (Copyright 2003 Bitstream, Inc.) | the preview window's interface font, embedded via ovg | `LICENSES/Bitstream-Vera.txt` |
| DM Sans (Copyright 2014 The DM Sans Project Authors), Instrument Serif (Copyright 2022 The Instrument Serif Project Authors), Bebas Neue (Copyright 2019 The Bebas Neue Project Authors), JetBrains Mono (Copyright 2020 The JetBrains Mono Project Authors) | the built-in fonts (`assets/fonts/`; DM Sans and JetBrains Mono are static instances of the Google Fonts variable fonts) | `LICENSES/OFL-1.1.txt` |

## Downloaded at run time (`say()`)

The first `say()` that needs synthesis downloads these into ottis's data
directory (`$OTTIS_DATA`, else `ottis/` in the user data folder; 835 MB on Linux, 866 MB on macOS), each
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

## Downloaded at run time (`song{}` Samplers)

A song whose parts play a `Sampler` downloads the zones its notes reach,
the first time, into `$ODAWG_DATA`, else `odawg/` in the user data folder, each
file pinned by commit and SHA-256. None of it is in this repository or the
binary. Every source is CC0 1.0:

| Sample set | From |
| --- | --- |
| Versilian Community Sample Library (VCSL), Versilian Studios LLC | github.com/sgossner/VCSL |
| VS Chamber Orchestra 2: Community Edition, Versilian Studios LLC | github.com/sgossner/VSCO-2-CE |
| Osiris Piano, Versilian Studios and Karoryfer Samples | github.com/sfzinstruments/Osiris_Piano |
| Growlybass, Karoryfer Samples | github.com/sfzinstruments/karoryfer.growlybass |
| Virtuosity Drums, Versilian Studios and Karoryfer Samples | github.com/sfzinstruments/virtuosity_drums |

`examples/disco` names four more CC0 1.0 libraries as sources, fetched the same way when it
plays (pinned by SHA-256, never in this repository): Karoryfer Samples' Fashionbass and
Emilyguitar (github.com/sfzinstruments), and Versilian Studios' VS Chamber Orchestra 2:
Community Edition and VCSL (github.com/sgossner).

## Ported from

- fframes (https://github.com/dmtrKovalenko/fframes): onimite ports its
  design, command line, examples and its Shadertoy-to-SkSL rewrite.
  `LICENSES/fframes-MIT.txt`.
- Reimplemented in ottis, not copied: torchaudio's CTC forced alignment
  (BSD-2-Clause), the formulation of the word aligner's Viterbi pass, and
  SentencePiece's Unigram Viterbi encoding (Apache-2.0).

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
  skottie resources (`LICENSES/Skia-BSD-3-Clause.txt`); the same spiral is in
  `examples/onimite_saga/media/`.
- `examples/fox/media/Fox.glb`: the Fox from Khronos' glTF-Sample-Assets.
  The model is CC0 (PixelMannen); its rigging and animations are CC-BY 4.0
  by @tomkranis (`LICENSES/CC-BY-4.0.txt`).
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
