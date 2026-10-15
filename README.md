# onimite

<img src="assets/logo.png" width="96" alt="Pip, onimite's mascot: a small red pixel-art firecracker">

Make videos with code. A video is a Lua script: scenes, shapes, text,
images, SVG and Lottie, clips, shaders, music, sound effects and spoken
lines. One small native binary renders it to MP4, plays it in a live
preview that reloads on save, and checks it for you: frames, contact
sheets, problems found automatically, loudness and beats. It is built so
that a coding agent can make a video end to end and know it is right
without watching it.

```sh
onimite render examples/why_onimite/video.lua -o why_onimite.mp4
onimite preview examples/why_onimite/video.lua      # plays with sound, reloads on save
onimite inspect examples/why_onimite/video.lua      # what is wrong, by script line
```

- **Small.** One binary and the SDL3 library beside it (and Lua's DLL on
  Windows), 17.3-20.7 MB on disk (a 7.7-8.7 MB download; v0.0.7). Nothing
  else to install, no build step per video. (`say()`'s voice models are an
  optional 835-866 MB download, made on first use.)
- **Fast.** Frames are built on every core and drawn on the GPU (Vulkan,
  Metal), with hardware encoding when there is one. On the 18 fframes
  examples ported 1:1 it is faster on 16, with 0.4-9.1% of fframes' CPU time
  and 0.8-26.5% of its memory; fframes wins two
  ([BENCHMARK.md](BENCHMARK.md)).
- **Checkable.** `inspect`, `show`, `frame`, `strip`, `onion`, `audio
  analyze` and `--json` on every command answer "is it right?" without a
  human watching; an MCP server and an agent skill come with it.

### When to use something else

onimite is one opinionated program, not a library. If you want to write a
video in Rust and compile it into your own program, with the whole language
and its crates at hand, use [fframes](https://github.com/dmtrKovalenko/fframes)
(onimite began by porting its examples and keeps parity with them). If you
want React and the web platform (HTML, CSS, npm), use
[Remotion](https://www.remotion.dev). For a TypeScript animation library
with an editor, use [Motion Canvas](https://motioncanvas.io). What each
puts on disk before the first frame, measured on Linux: fframes 3.4 GB
(Rust toolchain, 311 crates, the first build), Remotion 682 MB (Node.js,
251 packages, Chrome Headless Shell).

onimite is built from sibling Odin projects and Odin's vendor packages:

| piece | what |
| --- | --- |
| [`ovg`](https://github.com/defnotmid/ovg) | 2D vector canvas (femtovg lineage): software backend + SDL_GPU (Vulkan / Metal / D3D12) |
| [`odecs`](https://github.com/defnotmid/odecs) | H.264 / H.265 / AAC codecs (native Odin, Vulkan Video when available), MP4, WebP, clip decoding |
| [`oksl`](https://github.com/defnotmid/oksl) | shader compiler for SkSL, Shadertoy and GLSL: SPIR-V, MSL and a CPU interpreter |
| [`ottis`](https://github.com/defnotmid/ottis) | text to speech with word timings (Kyutai's Pocket TTS through ONNX Runtime, loaded at run time; models downloaded on first use) |
| [`o3d`](https://github.com/defnotmid/o3d) | 3D in three.js's vocabulary: an SDL_GPU renderer and a software one drawing the same pixels, glTF 2.0 (skins, morph targets, animations) and 3MF import |
| `vendor:lua/5.4` | the script runtime |
| `vendor:sdl3` | GPU device and the preview window |
| `vendor:stb`, `vendor:kb_text_shape`, `vendor:miniaudio`, `vendor:cgltf` | fonts, images, PNG output; text shaping; ogg / mp3 / flac decoding; glTF parsing (o3d) |

## Features

- **Scripts**: `video{}` and `scene{}` with overlaps and transitions, a node
  tree (shapes, paths, text, images, groups), keyframes with easings and
  springs, and a standard library after Remotion (`sequence`, `series`,
  `loop`, `freeze`, `stagger`, transitions, a beat clock). Data comes in as
  `props` from `--props`, `--set` or one `--batch` row per video;
  `json_decode` reads JSON files.
- **Drawing** (ovg): gradients, patterns, dashes, clip paths, masks, the 16
  blend modes and every SVG 1.1 filter primitive (feTurbulence on the GPU,
  fractional morphology radii), with filter regions. Text is shaped
  (ligatures, kerning, Arabic, Indic, bidi) and drawn as outlines, with
  per-glyph fallback and bundled colour emoji.
- **Media**: fonts, png / jpeg / bmp / gif / tga / webp images (decoded on
  first use, kept within `--image-cache MB`), SVG documents and Lottie
  animations with per-id / per-layer overrides, video clips (.mp4, .mov,
  .webm, ProRes 4444 and VP9 alpha), subtitles and word-level captions
  (Whisper JSON, VTT, SRT; TikTok-style `captions{}`), audio spectra, glTF
  and 3MF models (.glb, .gltf, .3mf).
- **Shaders** (oksl): SkSL as in fframes, Shadertoy code and GLSL ES
  fragment shaders (a real preprocessor, `texture`, `switch`, `discard`),
  and multipass programs mixing them (`passes`: feedback, any pass's last
  frame; Shadertoy's Common + Buffer A-D + Image is one spelling). Images,
  clips and groups of nodes bind as inputs. The software backend runs the same
  shaders on oksl's CPU interpreter.
- **3D** (o3d): `view3d{}` draws a scene described in three.js's terms
  (perspective and orthographic cameras; ambient, hemisphere, point,
  directional and spot lights with up to 4 PCF shadow maps; tone mapping
  and fog; box, sphere, plane, cylinder and torus meshes plus per-frame 3D
  lines, point clouds, wireframe and `instances`; MeshStandardMaterial,
  MeshBasicMaterial, LineBasicMaterial and PointsMaterial with texture
  maps, and GLSL ES ShaderMaterial; an equirectangular environment and
  background; glTF 2.0 and 3MF models, including skinned characters, morph
  targets and punctual lights, posed at a time of their animations with
  optional `morphs` and `material` overrides) into a box
  composited like any layer, on the GPU or, the same picture, on the CPU.
- **Sound**: tracks on the video or scenes with gain, pan, fades, voice
  ducking and a master limiter; audio synthesized by the script
  (`audio_add`); onsets and the beat of any clip (`audio_onsets`); AAC in
  the MP4.
- **Voice**: `say(name, text)` speaks a line (ottis: Pocket TTS by Kyutai,
  CC-BY-4.0) with the time of every word, and its captions; `say_cue` puts
  animation keys and sound effects on spoken words, and `inspect` checks
  them against the voice. Lines are kept on disk by content, so only new or
  changed lines are synthesized, where the script loads. It works on Linux
  x86_64 and macOS Apple Silicon (the Windows build has it, untested).
- **Cues**: `cue(name, t)` names a moment and `cue = "name"` on scenes, tracks
  and animate keys lands them on it; `inspect` reports what drifts off, and
  cues work as times.
- **Output**: H.264 / H.265 MP4 (Vulkan Video, or odecs' native encoder),
  or PNG frames. Frames build on all cores and draw on the GPU (or on the
  CPU with `--software`); the output does not depend on the thread count.
- **Checking without watching**: PNG frames, contact sheets, onion skins,
  frames as SVG, snapshot tests, `inspect` (missing media and fonts,
  clipped or overlapping text, NaN, script errors, unused options, sync drift),
  undefined globals as errors, loudness analysis, onsets, and stable
  error codes in `--json` output.
- **Preview**: a window with sound, scrubbing, a timeline with thumbnails
  and waveforms, hot reload of the script, its modules, shaders, data and
  media.

The full script API is [skills/onimite-video/references/api.md](skills/onimite-video/references/api.md);
[skills/onimite-video](skills/onimite-video) is a skill for coding agents
that make videos with onimite.

## Build

```sh
git clone https://github.com/defnotmid/onimite
git clone https://github.com/defnotmid/ovg
git clone https://github.com/defnotmid/oksl
git clone https://github.com/defnotmid/odecs
git clone https://github.com/defnotmid/ottis
git clone https://github.com/defnotmid/o3d
cd onimite
mkdir -p build    # a fresh clone has no build/ (gitignored); Odin will not create it
odin build . -collection:deps=.. -o:speed -out:build/onimite
```

`deps` is the parent directory holding `ovg`, `oksl`, `odecs`, `ottis` and `o3d`. Use
`-o:speed`: unoptimized builds are many times slower. On Linux the binary
links the system SDL3 (`pacman -S sdl3`, `apt install libsdl3-dev` on Ubuntu
25.04+, otherwise build SDL 3 from source as `.github/actions/setup-toolchain`
does) and libcurl (ottis downloads its models with it: `pacman -S curl`,
`apt install libcurl4-openssl-dev`); Odin
ships SDL3 for Windows. Odin's Linux release ships some vendor C libraries
as source; build them once:

```sh
sh "$(odin root)/vendor/stb/src/build_stb.sh"
sh "$(odin root)/vendor/kb_text_shape/src/build_unix.sh"
sh "$(odin root)/vendor/miniaudio/src/build_miniaudio.sh"
sh "$(odin root)/vendor/cgltf/src/build_cgltf.sh"
bash "$(odin root)/vendor/box2d/build_box2d.sh"   # needs cmake; fetches Box2D 3.1.1 (its WASM step may fail: harmless)
```

Tests (every package that has them, as CI runs them):

```sh
bash .github/ci.sh test
```

### macOS

Apple Silicon, SDL_GPU on Metal (the committed MSL shaders). With the Xcode
command line tools and Homebrew:

```sh
brew install sdl3 lua@5.4        # lua@5.4 is keg-only; `lua` is 5.5
# Odin's vendor C libraries that ship as source (the stb darwin libs are prebuilt):
sh "$(odin root)/vendor/miniaudio/src/build_miniaudio.sh"
sh "$(odin root)/vendor/kb_text_shape/src/build_unix.sh"
sh "$(odin root)/vendor/cgltf/src/build_cgltf.sh"
# vendor:lua links `lua5.4`; point the linker at the keg:
odin build . -collection:deps=.. -o:speed -out:build/onimite \
    -extra-linker-flags:"-L$(brew --prefix lua@5.4)/lib"
```

Tests take the same flag. SDL's Metal driver needs Cocoa, which starts only
on the main thread, so the GPU tests in `encode` and `onimite` (view3d's GPU
half) skip under the test runner on macOS. There is no Vulkan Video on macOS: `render` encodes with odecs'
native encoder.

## Use it with an AI agent

The `onimite-video` skill (`skills/onimite-video`) teaches a coding agent to write, check
and render onimite videos. No terminal tools are needed; use whichever fits your agent:

- **Claude Code** (terminal, desktop app or IDE): type
  `/plugin marketplace add defnotmid/onimite`, then `/plugin install onimite@defnotmid`.
- **Codex**: ask it `$skill-installer install https://github.com/defnotmid/onimite/tree/main/skills/onimite-video`.
- **Any other agent that can run commands**: paste this into it:
  *"Install the agent skill at https://github.com/defnotmid/onimite/tree/main/skills/onimite-video
  (the folder holds SKILL.md and a references/ folder) into your skills directory, then
  install the onimite binary as the skill describes."*

The skill downloads the `onimite` release binary itself (see Releases).

`onimite mcp` also serves the commands as MCP tools (JSON-RPC over stdio): typed arguments,
frames returned as images, no shell quoting, and a `guide` tool that returns this skill, built
into the binary. The Claude Code plugin registers it; for other MCP clients the server is the
command `onimite` with the argument `mcp` (the binary on PATH; `--dir PATH` sets the folder
relative paths start in).

**Claude Desktop**: download
[onimite-macos-arm64.mcpb](https://github.com/defnotmid/onimite/releases/latest/download/onimite-macos-arm64.mcpb)
or [onimite-windows-x86_64.mcpb](https://github.com/defnotmid/onimite/releases/latest/download/onimite-windows-x86_64.mcpb)
and open it: Desktop installs the extension with its own copy of onimite and asks for a work
folder (default `Documents/onimite`). Claude writes the video files there with a filesystem
extension (Desktop's Filesystem extension, given the same folder). When a newer release is
out, Claude says so; ask it to update (the `update` tool), then quit and reopen Desktop.
The extension's "Check for updates" setting turns the check off.

## Releases

Install the latest release with one command (it checks the archive against
`SHA256SUMS` and puts an `onimite` launcher in `~/.local/bin`, on Windows its
folder on the user `PATH`; run it again to update, `ONIMITE_VERSION=vX.Y.Z`
pins a release):

```sh
curl -fsSL https://defnotmid.com/install.sh | sh          # macOS (Apple Silicon), Linux (x86_64)
irm https://defnotmid.com/install.ps1 | iex               # Windows (PowerShell)
```

`onimite --version` prints the release it is. `onimite update` replaces it with
the latest release: it reads that release's `SHA256SUMS`, downloads this
platform's archive, checks it, runs the new binary once, then swaps it in (an
installer's `current` link moves to the new version's directory; anywhere else,
a Desktop extension or an unpacked archive, the files are replaced in place).
`onimite update --check` only says whether a newer release is out. `onimite mcp`
does that check once as it starts (off with `--update-check false` or
`ONIMITE_NO_UPDATE_CHECK=1`).

Push a tag `vX.Y.Z` (`git tag v0.1.0 && git push origin v0.1.0`; a tag with
a `-`, like `v0.2.0-rc1`, makes a prerelease, which the installers skip).
`.github/workflows/release.yml` builds `-o:speed` stripped binaries against the
default branches of ovg, oksl and odecs, and ottis and o3d at their pinned
tags, with the tag as their
`--version`, and publishes a GitHub release:

| asset | |
| --- | --- |
| `onimite-vX.Y.Z-linux-x86_64.tar.gz` | built on Ubuntu 22.04 (runs on glibc 2.35+), `libSDL3.so.0` beside the binary (rpath `$ORIGIN`); needs the system libcurl (`libcurl.so.4`) |
| `onimite-vX.Y.Z-macos-arm64.tar.gz` | macOS 11+, `libSDL3.0.dylib` beside the binary (rpath `@executable_path`) |
| `onimite-vX.Y.Z-windows-x86_64.zip` | best effort (unsigned, tested only in CI), left out if the Windows build fails; `SDL3.dll` and `lua54.dll` beside the binary |
| `onimite-video-skill-vX.Y.Z.tar.gz` | the agent skill as of the tag (`onimite-video/` with `SKILL.md`, `references/` and `LICENSE`), matching the binaries |
| `SHA256SUMS` | checksums of the archives |

Each archive holds `LICENSE`, `LICENSES/` and `THIRD_PARTY_NOTICES.md` too.
On macOS the binary and the SDL3 dylib are signed with the Developer ID
Application certificate (hardened runtime, secure timestamp) and notarized
by Apple; a bare binary can't be stapled, so Gatekeeper checks the
notarization online on first launch. The Linux and Windows builds are not
signed. The Apple secrets live in the `release` GitHub environment.

## Commands

The commands of fframes' project CLI, with its outputs (text, or one JSON
document with `--json`) and exit codes (1 on failure, 2 for inspect and
snapshot failures and usage errors). `onimite --help` lists every option.

```sh
onimite render   video.lua [range] -o out.mp4 [--draft]   # the video (+ AAC mix), or PNGs into a directory
onimite video.lua                                         # the same: render is the default
onimite render   video.lua --batch rows.json -o out/{name}.mp4   # one video per row (or rows.csv)
onimite frame    video.lua Intro@1s,50%,end -o frames [--svg]  # PNGs of single frames, with their problems (-o shot.png: one)
onimite strip    video.lua [range] -n 12 --columns 4 --width 480 -o strip.png
onimite onion    video.lua Intro@0..Intro@1s -n 6 -o onion.png   # frames blended, later ones stronger
onimite snapshot video.lua 1s,Intro@end [--update] [--dir _frame_snapshots]
onimite timeline video.lua [range]                        # scenes (cue, source line), audio tracks, cues
onimite mcp                                               # every command as MCP tools on stdio (preview opens the window)
onimite show     video.lua [path] [--at t] [--page n]     # one thing, its fields and children: scene/Race, cue/drop,
                                                          # bus/sfx, track/12, clip/x, media/logo.png, fonts,
                                                          # bodies, body/ball, node/scenes/race.lua:19[2]
onimite inspect  video.lua [range] [--every 0.25s] [--all-frames] [--info] [--fail-on error|warning|never]
onimite probe   file.mp4 [--json]          # container, video and audio streams of a media file (no ffprobe needed)
onimite audio render  video.lua [range] -o audio.wav [--float]
onimite audio analyze video.lua [range] [--waveform w.png] # LUFS, LRA, true peak, clipping, silence, per scene
onimite audio at      video.lua 3.1s,6.2s                 # what plays: file position, level, ducking
onimite audio onsets  video.lua [range] [--min 0.1]       # where sounds start, and the beat
                                                          # (audio commands: --track FILE hears one track)
onimite preview  video.lua [at] [--paused] [--no-loop] [--mute]
onimite update   [--check]                                # replace this release with the latest (--check: only say)
```

- `render`: `--draft` is half resolution (unless `--scale`), QP 32 and a
  one second GOP; `--h265`, `--qp N`, `--native` (no hardware encoder).
- Common options: `--json`, `--scale S`, `--media DIR` (default `media/`
  beside the script), `--props FILE`, `--set K=V`, `--software` (draw on
  the CPU), `--threads N` (default one per core; `1` runs everything on one
  thread with the same output), `--image-cache MB` (decoded images kept in
  memory, default 1024; the least recently used are freed between frames
  and decode again when shown).
- Times and ranges read like fframes: `120`, `3.2s`, `1:05`, `50%`,
  `start`, `end`, `Intro`, `#2`, `Intro[1]` (the second scene named Intro),
  `Intro@1.5s`, `Intro@end` (an offset must land inside its scene), cues
  and sync ids like scenes (`drop`, `drop@0.5s`, `drop@-6`), `a..b` (end
  exclusive, `drop..beat[8]`), `a..`, `..b`, `all`.
- `--batch rows.json|rows.csv` renders one video per row, the row as
  `props` (`--set` over the row over `--props`). `-o` takes `{field}` and
  `{index}`; `--rows 2..3` / `--only 2` pick rows. A failing row is
  reported and the batch goes on (exit 1 if any failed). See
  `examples/batch/`.
- `frame --svg` also writes each frame's node tree as SVG next to its PNG
  (`onimite/svg_export.odin`).
- `snapshot`: missing snapshots are created; a frame whose pixels differ by
  more than `--threshold` (16) in more than `--max-diff` (0.1%) of pixels
  fails with `name.actual.png` and `name.diff.png`; `--update` (or
  `ONIMITE_UPDATE_SNAPSHOTS=1`, `FFRAMES_UPDATE_SNAPSHOTS=1`) accepts it.
  A snapshot of another size than the frame (checked at another `--scale`)
  is an error naming both sizes (`snapshot_size`).
- With `--json`, every diagnostic and finding has a stable `code` and the
  `fields` its message is made from, and a failed command prints
  `{"error": ..., "code": ...}`. The codes are listed in
  [problems.md](skills/onimite-video/references/problems.md).

`render` builds several frames at once: each builder loads the script into
its own Lua state (render procs must be pure per frame, as in fframes) and
records its frames, and one thread draws them on the GPU in frame order,
converts them to I420 there and hands them to the encoder thread. The set
of builders grows only while drawing waits for frames. `--software` draws
and converts on all cores the same way. `tools/threads_check.sh` compares
decoded frames of the pool and `--threads 1`.

## Scripts

```lua
video { width = 1920, height = 1080, fps = 30, background = "#ffffff" }

scene { "Intro", duration = 2, render = function(f)
  local y = animate(f, { { start = 0, stop = 0.4, from = 60, to = 0, easing = ease_out } })
  group({ transform = translate(0, y), opacity = animate(f, { { start = 0, stop = 0.3, from = 0, to = 1 } }) }, function()
    rect { x = 160, y = 240, w = 600, h = 120, rx = 24, fill = "#0ea5e9" }
    text { "Hello", x = 200, y = 320, font = "DM Sans", size = 48, weight = 700, fill = "#ffffff" }
  end)
end }

scene { "Outro", duration = 3, overlap = { previous = 0.5 }, render = function(f)
  text { "Bye", x = 960, y = 560, align = "center", font = "Bebas Neue", size = 160, fill = "#0ea5e9" }
end }
```

A video is a `video.lua` with a `media/` folder beside it (fonts, images,
SVG, Lottie and caption files, audio, clips, `.sksl` / `.glsl` / `.frag` shaders).
DM Sans, Instrument Serif, Bebas Neue and JetBrains Mono are built in; any
other font is a file copied into `media/`.
`require` and `dofile` resolve beside the script and `SCRIPT_DIR` is its
directory. Everything outside `render` runs once when the script loads, so
layouts, measured text and data belong there; `shared(name, fn)` computes
large load-time data once per render instead of once per frame builder.

[api.md](skills/onimite-video/references/api.md) documents the core
script API (nodes, groups, paints, text and measuring, images, animation,
the standard library, sync points, the script environment) and links the
topic files: [audio.md](skills/onimite-video/references/audio.md) (tracks,
mixing, onsets, spectra, generated audio),
[media.md](skills/onimite-video/references/media.md) (SVG, Lottie, clips,
subtitles, captions), [shaders.md](skills/onimite-video/references/shaders.md),
[filters.md](skills/onimite-video/references/filters.md) and
[problems.md](skills/onimite-video/references/problems.md).

## Preview

`onimite preview video.lua [at]` opens a window with the video above a
timeline (ruler, scenes with thumbnails, cue marks, each bus's sound as one
lane that opens to a lane per track; hovering a row names it with the path
`onimite show` takes) and plays it with sound, looping, as fframes' player
does. Sound joins as the script's clips are built, without holding up the
picture.
Saving any file in the script's folder reloads it within a quarter second
(changes in `media/` reload the media); an edit that fails to load is shown
while the last good version keeps playing. The status line shows the GPU,
the preview resolution, render time, latency and the problems found in the
frames shown; a click opens them in the Watch.

The video, the timeline and Watch views are tabs in panels, as in oasic:
drag a tab onto another panel's tab strip, centre or edge to move it there
or split the panel; drag a splitter to resize; `x` closes a tab; `+` lists
what opens in the panel (the video, the timeline, a Watch on each section,
a split, closing it) and Ctrl+P every scene, cue and problem to go to, both
filtered as you type. A timeline in a panel beside another and taller than
wide runs top to bottom, its scenes and lanes as columns. The **Watch** lists the video's scenes (with
the problems seen in each), cues (with their sync findings: drift, a `hit`
with no sound near it), problems and media (thumbnails; failed files, sounds
no track plays), each row coloured by its status; a click goes to its
frame, and N jumps to the next row with a warning or an error.

The window never waits on Lua, a fence or a file: a render worker owns the
script, the media and the canvas and publishes frames through a mailbox
(the newest request wins, so scrubbing drops stale frames), SDL's audio
callback is the playback clock, and the UI thread only draws.

| key | |
| --- | --- |
| Space | play / pause (also a click on the video) |
| Left / Right, J / K | previous / next frame (held: repeats) |
| Ctrl+Left / Ctrl+Right | one second back / forward |
| Home, 0, Shift+J, Shift+Left | the bookmark, then the first frame |
| End, Shift+G, Shift+Right | last frame |
| Page Down, S, W / Page Up, Shift+S, B | next / previous scene |
| Up, L / Down, H | volume up / down |
| Ctrl+Down, Ctrl+H | mute |
| M | set / clear the bookmark (reloads return to it) |
| = / - | zoom the timeline (also Ctrl+wheel; a zoomed timeline you scroll stops following the playhead until Follow); Ctrl+0 fits it |
| T | collapse / expand the timeline |
| Z | fit the video in its panel (the wheel over the video zooms around the cursor, dragging pans) |
| F | fullscreen |
| D / I | the Watch on the problems / the media (the Watch button: open / close it) |
| N / Shift+N | next / previous scene, cue, problem or media row with a warning or an error |
| Shift+L | loop |
| R | reload |
| Ctrl+P | go to a scene, cue or problem (type to filter, Up/Down, Enter) |
| Ctrl+O | open a script (or drop a `.lua` file) |
| Esc / Q | close the list, then the Watch, leave fullscreen, then the window |

`--exit-after N` closes after N window frames and prints frame timings;
`ONIMITE_PREVIEW_CAPTURE=out.png` also writes the last frame.

## Examples

Each folder in `examples/` is a `video.lua` with its `media/`.

| example | shows |
| --- | --- |
| `onimite_saga` | a 2 min film laid out for agents: a manifest, a file per scene on its cue, a tempo map, a music clip per act |
| `onimite_saga_2` | 77 s 3D comic-book sequel (`view3d{}` + `.3mf` speaker horns, all 5 sibling mascots, GLSL sketchbook-to-color wipes, physics outtakes) |
| `why_onimite` | a 50 s beat-synced pitch: BPM clock, quick cuts, a soundtrack synthesized in Lua, a shader title |
| `suite` | onimite, ovg, oksl, odecs and o3d in every frame: an SkSL world warping a group with a 3D gyroscope in it, alpha clips, a WebP skyline |
| `data_story` | a 30 s chart explainer drawn from `props`, one video per `--batch` row |
| `motion_poster` | a generative poster made of noise: SVG filter primitives, `noise()`, an SkSL warp |
| `social_clip_kit` | one promo in 9:16, 1:1 and 16:9 through `--batch`: adaptive layout, word captions, an alpha clip |
| `designer_handoff` | design tokens through `json_decode`, an SVG drawn on from its own paths, a recoloured Lottie badge |
| `shadertoy_multipass` | Common + two feedback buffers + Image, a group channel feeding a buffer |
| `shader_passes` | `passes` in two dialects: an SkSL trail reading its own last frame, coloured by a GLSL pass |
| `captions_demo` | word-level TikTok captions from Whisper-style JSON, two highlight styles |
| `lottie_demo` | four Lottie files with text and shapes, one with a text-layer override |
| `svg_demo` | an SVG bird animated by element id |
| `three_d` | `view3d{}`: an orbiting camera, shadows, metal, standard, basic and custom `ShaderMaterial` meshes, a 2D title over the 3D |
| `fox` | a downloaded, skinned glTF model (the Khronos Fox) playing its clips, then a `ShaderMaterial` override on the model |
| `pip_demo` | Pip, the mascot, in each mood: one pixel-art SVG with parts shown and hidden by id |
| `transitions` | every standard-library transition between scenes |
| `physics_demo` | rigid bodies (`physics{}`) simulated at load: tiles dropped into a word, a pop per impact |
| `audio_demo` | tracks on the video and scenes, voice ducking, effects on animation constants |
| `voiceover` | spoken lines made with `say()`, their captions, keys and effects on spoken words (`say_cue`) |
| `media_demo` | a synced clip, WebVTT subtitles, an audio spectrum, durations from media |
| `batch` | a title card per row of `rows.json` / `rows.csv` |
| `scenes` | scene overlaps (cross-fades) |
| `fframes/` | all 17 fframes example crates (19 videos) ported 1:1, the benchmark material (media: `examples/fframes/fetch.sh`) |

`examples/common/synth.lua` holds the instruments the synthesized soundtracks
share (plain Lua, not part of onimite).

Every sound, voice line, clip, photo and texture in them, and the decoder test clips
in `testdata/`, are generated by `tools/gen_media/gen.sh` (onimite renders
and synthesizes them; ffmpeg and espeak-ng convert and speak). Fonts and
other third-party files are listed in THIRD_PARTY_NOTICES.md. The exception
is `examples/fframes/`: its media, fonts and shaders are fframes' own, not
committed here, and `examples/fframes/fetch.sh` copies them from a pinned
fframes checkout.

## Benchmarks

On the 18 fframes examples that render on both sides (1920x1080, Ryzen 9
9900X3D + RX 9070 XT, fframes' main of 2026-10-12), onimite is faster on
16, using 0.4-9.1% of fframes' CPU time and 0.8-26.5% of its memory; fframes wins
`hello_world` and, narrowly, `podcast`, where the hardware encoder is the
bottleneck. Numbers, method and caveats are in
[BENCHMARK.md](BENCHMARK.md). The ports of fframes' examples they were
measured on are in `examples/fframes/`; `examples/fframes/fetch.sh` fetches
fframes and their media, then `tools/bench.sh all` reproduces the run.

[PARITY.md](PARITY.md) maps every fframes feature to onimite.

## Layout

| path | package | |
| --- | --- | --- |
| `onimite/` | `onimite` | core: timeline and easing, scenes, node tree, drawing, text, media, captions, 3D layers, time specs, SVG export |
| `script/` | `onimite_script` | the Lua host: the script API bound to the core builders; `std.lua`, the standard library |
| `encode/` | `onimite_encode` | RGBA to BT.709 I420 (GPU compute or CPU), odecs H.264 / H.265, MP4; clip and audio decoding |
| `app/` | `onimite_app` | command rows and one dispatch (after paf / raddbg): the commands, their output, batches, the preview |
| `main.odin` | `main` | the command line: parses arguments into command rows |
| `platform/`, `render/`, `ui/` | | SDL3 window and input, the UI's 2D renderer, the raddbg-style UI (ported from paf) |
| `shaders/` | | Slang shaders (UI, GPU colour conversion) with committed SPIR-V and MSL (`build.sh`) |
| `tools/` | | `gen_media/` (generated media), `bench.sh`, `threads_check.sh` |

Each package's errors are codes with operands (`*/errors.odin`); text is
made only at the edge.

## Not yet

WebM and alpha video output (odecs has no VP9 / AV1 / ProRes encoder; such
clips work as inputs).

## License

MIT, see [LICENSE](LICENSE). Third-party notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
