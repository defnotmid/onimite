---
name: onimite-video
description: >-
  Create, animate, review and render videos in code with onimite (one Lua script per video,
  run by one prebuilt Odin binary; GPU vector drawing, SkSL shaders, H.264/H.265 MP4 with an
  AAC mix). Use whenever the user wants a video, animation, motion graphic, explainer, promo,
  social clip, title card, podcast visual, lyric or caption video, or any rendered .mp4 made
  programmatically with onimite, or asks to change, fix, speed up or check an onimite video.
  Covers building onimite, writing the script, designing good-looking motion, beat-synced
  sound (music files or a soundtrack composed with song{}, voice, SFX, loudness), the hot-reload
  preview window, and checking the result without watching it: frames, contact sheets and
  onion skins as PNG, automatic problem detection, loudness numbers, draft and range renders.
---

# Making videos with onimite

onimite renders video from a Lua script. A video is one `video.lua` (plus `media/` beside it
for fonts, images, SVGs, Lottie files, audio, clips, models and shaders; a file linked in with a
symlink counts as its target, so a large model need not be copied) that calls `video{...}` and
`scene{...}`. Each scene's `render(f)` function draws the frame `f` with nodes (`rect`, `text`,
`path`, `group`, `image`, `svg`, `lottie`, `shader`, `view3d`, ...); `animate` and springs move values; an `audio` list
places sound; `captions{}` draws word-timed (Whisper JSON, VTT, SRT) TikTok-style captions. One prebuilt `onimite` binary renders, previews and inspects every script:
there is no project to generate and no build step per video.

Read `references/design.md` before designing, `references/api.md` while writing the script
and `references/audio.md` for sound; `api.md` lists the topic files (media, shaders, filters,
3D in three.js's terms, problem codes) to read when the video needs them. When matching a supplied reference video, follow the
reference-analysis section of `references/design.md` first: its cuts and pacing win over the
defaults below.

For more than this skill holds (working examples, the README's full command and API notes,
how something is implemented), read the repository:
[github.com/defnotmid/onimite](https://github.com/defnotmid/onimite) ("Examples" in section 2
says how to get the examples matching your binary).

(Structure adapted from fframes' `fframes-video` skill, MIT.)

## 1. Install

### Release binary

If `onimite --version` already works, skip to section 2. Otherwise install the latest
release with one command (the installer checks the download against the release's
checksums and puts an `onimite` launcher in `~/.local/bin`, or on Windows puts its folder
on your user `PATH`; running it again updates):

```bash
curl -fsSL https://defnotmid.com/install.sh | sh     # macOS (Apple Silicon), Linux (x86_64)
irm https://defnotmid.com/install.ps1 | iex          # Windows, in PowerShell
```

If `~/.local/bin` is not on `PATH`, the installer says so: add it, or call
`~/.local/bin/onimite`. When the installer finds no release, build from source (below).

`onimite update` replaces an installed release with the latest one (checked against its
`SHA256SUMS` and run once before it is swapped in); `onimite update --check` only says
whether a newer one is out. A source build (`dev`) does not update itself.

To install by hand instead, download the archive for your platform from
[github.com/defnotmid/onimite/releases](https://github.com/defnotmid/onimite/releases)
(`X.Y.Z` is the release):

- Linux x86_64: `onimite-vX.Y.Z-linux-x86_64.tar.gz` (glibc 2.34+; needs the system libcurl,
  `libcurl.so.4`)
- macOS Apple Silicon: `onimite-vX.Y.Z-macos-arm64.tar.gz` (signed and notarized)
- Windows x86_64: `onimite-vX.Y.Z-windows-x86_64.zip` (when present; unsigned, best effort,
  tested only in CI)
- `SHA256SUMS` to check them: `sha256sum -c --ignore-missing SHA256SUMS`

Each unpacks to `onimite-vX.Y.Z-<platform>/` with the binary and the SDL3 library next to
it (no system SDL3 needed; on Windows `lua54.dll` too). Keep them together, and put the directory on your `PATH`
(or call `onimite` by its full path). Check it with `onimite --help`.

### From source

onimite is built with the [Odin](https://odin-lang.org) compiler from seven sibling
repositories (the build's `deps` collection is their parent directory):

```bash
git clone https://github.com/defnotmid/onimite
git clone https://github.com/defnotmid/ovg     # 2D vector canvas: software + SDL_GPU (Vulkan / Metal / D3D12)
git clone https://github.com/defnotmid/oksl    # shader compiler: SkSL, Shadertoy and GLSL to SPIR-V, MSL, CPU
git clone https://github.com/defnotmid/odecs   # every image, sound and clip decoder, and the MP4 encoder
git clone https://github.com/defnotmid/odawg   # songs and the mix in Tone.js's vocabulary, loudness, onsets, spectra
git clone https://github.com/defnotmid/ottis   # text to speech with word timings (say)
git clone https://github.com/defnotmid/o3d     # 3D in three.js's vocabulary: SDL_GPU + software, glTF 2.0 (skins, morphs) + 3MF + OBJ + USD
cd onimite
mkdir -p build
odin build . -collection:deps=.. -o:speed -out:build/onimite
```

Lua 5.4 and SDL3 come through Odin's `vendor:` packages; Odin ships the SDL3 library
for Windows, Linux and macOS link the system one (`pacman -S sdl3`, `apt install libsdl3-dev`, `brew install sdl3`), and Linux links libcurl (`apt install libcurl4-openssl-dev`). Odin's Linux release ships
some vendor C libraries (kb_text_shape, Box2D) as source to build once (the
onimite README, "Build"); macOS needs a few extra steps (the README, "macOS"). Use `-o:speed`: unoptimized builds are many times slower.
If `build/onimite` already exists and no `.odin` file is newer, skip the build.

Every command below is `onimite <command> video.lua ...`; with a fresh build use the full
path, e.g. `R() { /abs/path/onimite/build/onimite "$@"; }`. `onimite --help` lists every
command and option.

## 2. Create a video

```
my-video/
  video.lua          # the video
  scenes/intro.lua   # optional modules: require("scenes.intro")
  media/             # fonts (.ttf/.otf/.ttc), images, .svg, Lottie / caption .json, audio, clips, .vtt/.srt, .sksl/.glsl/.frag, .glb/.gltf/.3mf/.obj/.usdz/.usdc
```

```lua
video { width = 1920, height = 1080, fps = 30, background = "#0b0d12" }

scene { "Intro", duration = 3, render = function(f)
  local y = animate(f, { { start = 0.2, from = 60, to = 0, easing = spring { stiffness = 180, damping = 20 } } })
  local a = animate(f, { { start = 0.2, stop = 0.6, from = 0, to = 1, easing = ease_out } })
  group({ transform = translate(0, y), opacity = a }, function()
    text { "Hello", x = 960, y = 560, align = "center", font = "DM Sans", size = 140, weight = 700, fill = "#f5f5f5" }
  end)
end }

scene { "Outro", duration = 2.5, overlap = { previous = 0.4 }, render = function(f)
  text { "onimite", x = 960, y = 560, align = "center", font = "DM Sans", size = 96, fill = "#7dd3fc",
    opacity = animate(f, { { start = 0, stop = 0.4, from = 0, to = 1 } }) }
end }
```

- Built in, with nothing in `media/`: `DM Sans` (weights 400, 500, 700), `Instrument Serif`
  (400, and `italic = true`), `Bebas Neue` (400, display caps), `JetBrains Mono` (400, 700).
  Name the family and a numeric `weight`; the nearest weight is drawn.
- Any other font: copy its file (`.ttf`, `.otf` or `.ttc`) into `media/` and use its family
  name (`font = "Poppins"`). A family in `media/` replaces the built-in one of the same name.
  Fonts installed on the machine work the same way, copied from its font folder
  (`/usr/share/fonts/`, `~/.local/share/fonts/`; macOS `/System/Library/Fonts/`,
  `/Library/Fonts/`, `~/Library/Fonts/`; Windows `C:\Windows\Fonts\`); onimite never
  reads those folders itself, so the video renders the same everywhere. `show video.lua fonts`
  lists the families text can use.
- `require("name")` and `dofile` resolve beside the script; `SCRIPT_DIR` is its directory
  (for `io.open` on data files). Script lines in errors, `inspect` and `show` (and a file's
  `debug.getinfo` source) are paths from the script's folder (`scenes/race.lua:23`), whatever
  the working directory. Data comes in as `props` (`--props file.json`, `--batch`
  rows, `--set key=value`); `arg.key` holds the raw `--set` string.
- Everything outside `render` runs once when the script loads: put data, layouts and text
  measurements there. Drawing calls (`rect`, `text`, `group`, ...) only work inside `render`.

### Examples

The examples in the onimite repository are working patterns to read and borrow from:

| example | shows |
| --- | --- |
| `examples/onimite_saga` | a 2 min film laid out for agents: a manifest, one file per scene on its section, a song whose sections follow the scenes with tempo ramps (`music/score.lua`), its parts in their own files, `sound{}` effects; its README shows how to find and change any part |
| `examples/disco` | a song from a JSON5 file on a style of its own (`media/styles/french_disco.json`) whose instruments are other people's CC0 libraries fetched by URL and pinned; buses (a pump keyed by the kick, a dark filter); a picture that reads the song: a ray-traced club in shader `passes` (a mirror ball throwing flecks, haze traced at half resolution in a scaled shader fed in as an input, a spectrum floor), a scene per section |
| `examples/why_onimite` | 50 s beat-synced promo: BPM clock (`beat_clock` in `beat.lua`), quick cuts as a `series`, one timeline of beats for picture and sound (`timeline.lua`), sections as sync points (`cue()` and each scene's `cue`), soundtrack composed with `song{}` (`track.lua`) and read back for the cuts (`score.time`, `score.hits`), glitch cuts, shader title, spectrum outro |
| `examples/suite` | one composition per frame: an SkSL world warping a `uniform shader` group child, an SVG animated by id, ProRes 4444 and VP9-alpha clips in masked portals, a WebP skyline, spectrum-driven uniforms |
| `examples/data_story` | 30 s explainer drawn from `props` (one video per `--batch` row): springy bar chart with `stagger`, a line drawn on, a donut, counters, `mix_color`, scene transitions |
| `examples/motion_poster` | generative 1080x1350 poster from noise: `turbulence` and animated `morphology` filters, `noise()`, an SkSL warp, beat-synced ripples |
| `examples/social_clip_kit` | one promo in 9:16, 1:1 and 16:9 from `--batch` rows: layout computed from the canvas at load, text fitted with `text_width`, word captions from generated WebVTT, an alpha clip, beat-synced cuts, story-style progress bar |
| `examples/designer_handoff` | designer files in: `tokens.json` via `json_decode` (colours, type, spacing, copy), an SVG drawn on from its own paths (`shared` + `path_data`) then shown with `svg{}` overrides, a Lottie badge recoloured from the tokens |
| `examples/shadertoy_multipass` | Shadertoy multipass: Common + two feedback buffers + Image, a group channel feeding a buffer, buffers at half resolution |
| `examples/shader_passes` | `passes` in two dialects: an SkSL trail reading its own last frame (feedback) and a group input, coloured by a GLSL pass |
| `examples/captions_demo` | word-level TikTok captions from a Whisper-style JSON: `captions{}` with a sliding box and a colour pop, `max_duration` / `combine_ms` paging, synthesized beat |
| `examples/lottie_demo` | `lottie{}`: After Effects (Lottie) animations at the scene clock, a speed / offset, a script-picked frame, a per-layer override; `lottie_info` |
| `examples/svg_demo` | `svg{}` with per-id overrides (a flapping bird) |
| `examples/three_d` | `view3d{}`: a 3D scene in three.js's terms (an orbiting camera, a shadow-casting light, standard, metal, basic and custom `ShaderMaterial` meshes, a textured floor, a generated sky as the environment, a transparent outline label on the floor drawn from its curves) under a 2D title card |
| `examples/fox` | a downloaded, skinned glTF model (the Khronos Fox) playing its clips under an orbiting camera, then a `ShaderMaterial` override on the whole model |
| `examples/pip_demo` | Pip, the mascot (`examples/common/pip.lua`): a pixel-art SVG whose `display="none"` parts (blink, moods, spark frames) are swapped with `visible` overrides, a squash on the beat |
| `examples/transitions` | every `transition` kind between scenes (`scene{ transition = ... }`), `stagger`, `loop`, `sequence` |
| `examples/physics3d_demo` | 3D rigid bodies: `physics3d{}` at load, a wrecking ball on a rod knocking down a block tower, a kinematic sweeper, bouncing orbs drawn with `physics3d_instances`; a ragdoll down a staircase (ball joints with `cone`/`twist` limits along each limb, hinges with `limit` at knees and elbows); ragdoll letters (ONIMITE in stick strokes, a body per stroke, ball joints with soft `hertz` springs where strokes touch, so each letter holds its shape but flops down the stairs); `sound{}` effects placed on `sim.contacts` (thinned by speed and spacing) |
| `examples/graph_paper` | the artsy one, on a drafting sheet: ONIMITE and the libraries' seven marks as outlines (`outline{}` of text and of each SVG's `silhouette`) drawn on with a pen, morphed into each other (`morph`/`morph_at`) as their rows trade places, lifted off the page as bevelled solids (`ExtrudeGeometry`, `side_material`) spinning through each other in two rings, burst at the camera, then raining down as `outline` physics bodies until the sheet is full, under a title block; the picture's timing read from an odawg song (`track.lua`) and a tick per landing |
| `examples/physics_demo` | rigid bodies: `physics{}` simulated once at load (in `shared`), tiles dropped into a word with `start` staggers, `physics_at` per frame, a pop per impact from `sim.contacts` (the saga's NotNeeded scene: a wrecking ball on a rope; why_onimite's Ship: 311 grains poured) |
| `examples/otfx` | otfx's terminal text effects (decrypt) full screen on a cell grid, played with `preview --bare --fullscreen`, text from `--set text=...`: a per-character timeline built at load from seeded `hash` draws, read by tick each frame; block elements drawn as rects so the banner's halves meet; `require`d modules shared between effects (`term.lua`, `effects/NAME.lua`) |
| `examples/audio_demo` | tracks on video and scenes, voice + ducking, SFX on animation constants |
| `examples/voiceover` | spoken lines made with `say()` (text to speech with word times), their captions, keys and SFX on spoken words (`say_cue`), a pad ducking under the voice; its README explains the `cue_no_hit` findings left on run-together words |
| `examples/cuts` | an edit as a list of cuts: `scene{ clip = { file, from, to } }` per row, clips of other sizes and frame rates (a 9:16 60 fps phone clip letterboxed, 24 fps footage), whole files and ranges, fade / slide / wipe between cuts with the sound crossfading, a label naming each cut |
| `examples/footage` | footage anywhere a picture goes: a clip inside an SVG's silhouette (Pip, `mask_type = "alpha"`), inside text, through an SkSL ripple (a clip as a shader child), a grid at four speeds and backwards; each scene's clip row (`picture = false`) places the sound, its render draws the same row's picture |
| `examples/media_demo` | `video_frame` clip with its sound, WebVTT `subtitle_at`, `audio_spectrum` bars, durations from media |
| `examples/batch` | data-driven title card: `props` with defaults, `--batch rows.json` / `rows.csv`, `--props`, `--set` |
| `examples/scenes` | scene structure and overlaps |

The examples are not in the release download. Read them at the release you have, so they
match its API: `onimite --version` prints the tag (`v0.1.0`; `dev` for a source build: use
`main`), then

- browse `https://github.com/defnotmid/onimite/tree/TAG/examples/NAME` (most have a README
  saying what they cover), or read one file raw:
  `https://raw.githubusercontent.com/defnotmid/onimite/TAG/examples/NAME/video.lua`;
- or fetch only the examples you need, with their media:

  ```bash
  git clone --depth 1 --branch TAG --filter=blob:none --sparse https://github.com/defnotmid/onimite onimite-examples
  git -C onimite-examples sparse-checkout set examples/NAME examples/common
  ```

  `onimite preview onimite-examples/examples/NAME/video.lua` plays one. Copy what you
  borrow into the user's project; don't edit the checkout.

## 3. The loop

**Do not write tests for a video.** No test files, harnesses or visual-regression suites
unless the user asks; validate with `inspect`, PNG frames, strips, onion skins, audio numbers
and the preview. (`snapshot` exists for when the user wants regression checks.)

**Offer the preview before a full render.** `onimite preview` is the review step; do not
render the whole video as routine. When a change is ready:

1. Show a complete copyable command with absolute paths, starting near the change:
   `/abs/onimite/build/onimite preview /abs/my-video/video.lua 8.5s`. Say what they will see.
2. Offer to launch it. It blocks until the window closes, so run it in the background. The
   preview reloads on every save of any file in the script's folder (script, modules,
   shaders, data; `media/` changes reload the media), so one open window follows all later
   edits; tell the user that instead of relaunching it.

**Footage and marks.** A video file works wherever a script does: `onimite strip
/abs/footage/take.mp4 -n 12`, `frame take.mp4 12.5s`, `audio analyze take.mp4`, `timeline take.mp4`
look through it at its own size and rate (its folder's other files stay unread). To let the
user point at what they want (where to cut, where a fade should start), open the clip, or the
script, in the preview and tell them the keys: `[` then `]` mark a range, `P` a moment, Delete
removes the mark under the playhead. The marks are written beside it (`take.mp4` ->
`take.marks.json`, `video.lua` -> `video.marks.json`), numbered as made, in seconds:

```json
{ "source": "take.mp4", "fps": 30, "marks": [ { "n": 1, "from": 12.4, "to": 15.9 }, { "n": 2, "at": 31.0 } ] }
```

Read them with `onimite show take.mp4 marks` (or the file) and write the edit from them, e.g.
`scene { clip = { "take.mp4", from = 12.4, to = 15.9 } }`. Marks are the user's pointers, not
edits: the agent makes every change; when the user says "mark 2", it is that row.

After every change:

1. `onimite timeline video.lua`: scenes with frame and second ranges, every audio track with
   its span, gain and fades. Check structure and pacing first.
2. `onimite inspect video.lua`: checks a frame every 0.25 s plus every scene's first and last
   frame; reports missing media, fonts and glyphs, text cut off by the canvas or drawn over
   other text, invalid colours, transforms and path data, NaN, zero-size shapes, empty
   frames, shader compile errors and Lua errors with tracebacks, each with scene, time and
   the script line that drew it. Exit code 2 on errors
   (`--fail-on warning` to fail on warnings too). Fix everything; a warning only on a
   scene's first frames is usually an entrance: check it in a strip.
3. `onimite strip video.lua Intro -n 12 -o strip.png`: a labelled contact sheet of evenly
   spaced frames. Open it with your image tool. Fastest way to judge layout and rhythm.
4. `onimite frame video.lua Intro@end,Outro@50% -o frames`: full-size PNGs (named after the
   spec, e.g. `frames/1s.png`; `-o shot.png` for a single frame) with the problems found in
   them, for type, alignment and contrast. An offset past its scene's end is an error.
5. `onimite onion video.lua "Intro@0..Intro@1s" -n 6 -o onion.png`: frames blended (later
   ones stronger) to show a movement's path, easing, overshoot and stagger.
6. Sound: `onimite audio analyze video.lua` (LUFS, true peak, clipping, silence, per scene
   and per second), `onimite audio onsets video.lua` (where sounds start, the beat) and
   `onimite audio at video.lua 3.1s` (what plays at an event). See `references/audio.md`.

`inspect` also reports options a call did not use (`rect.fil`, did you mean `fill`?), an
animate key that jumps for want of a `stop`, and sync points that drifted apart, sounds off the music's beat, physics bodies that start inside each other, leave the canvas or still move
when frames run past the simulation; an undefined
global (`eas_out`) is an error naming the closest one. Fix them like any other problem.

Rules:
- Look at the PNGs before saying anything looks good.
- Prefer one `strip` to many `frame` calls; add `--scale 0.5` when composition is enough.
- Add `--json` when parsing output: one JSON document on stdout, progress and warnings on
  stderr (Vulkan driver chatter also goes to stderr; ignore it).
- Wrap long-running commands in `timeout` in automation.

### Rendering

```bash
onimite render video.lua -o out.mp4                 # the whole video, H.264 + AAC mix
onimite video.lua -o out.mp4                        # the same: render is the default
onimite render video.lua Intro --draft -o intro.mp4 # one scene, half size, fast encode
onimite render video.lua 10s..20s -o part.mp4       # a range; the audio is cut to match
onimite render video.lua -o frames/                 # PNGs (any -o not ending in .mp4): frames/000000.png ...
```

`--draft`: half resolution (unless `--scale`), QP 32, one-second GOP. A scaled size rounds to
even (1080x1350 at half is 540x676). `--h265`, `--qp N`
(0 best .. 51), `--native` (odecs' own encoder instead of Vulkan Video hardware encoding),
`--software` (draw on the CPU; also for machines without a usable GPU), `--scale S`,
`--threads N` (default one per core: a quarter render songs, audio and `say()` lines, the
rest frames; 1: everything on one thread; output does not depend on it). There is no WebM or alpha video output.

### Data-driven videos and batches

Read per-video data from `props` (always a table) so one script makes many videos:

```bash
onimite render card.lua --props ada.json -o ada.mp4         # props from a JSON object (any command)
onimite render card.lua --set name="Ada" --set size=40      # props.name = "Ada", props.size = 40
onimite render card.lua --batch rows.json -o out/{name}.mp4 # one video per row (array of objects)
onimite render card.lua --batch rows.csv --only 2           # CSV: header + rows; out/2.mp4
```

Precedence: `--set` over the batch row over `--props`. `{field}` in `-o` comes from the row,
`{index}` is the row number from 1 (default `out/{index}.mp4`); `--rows a..b` (inclusive).
A failing row is reported and the others still render (exit 1 if any failed); `--json`
lists every row's result. CSV and `--set` values that read as JSON numbers are numbers.
Template: `examples/batch/`.

### Addressing time

`120` (frame), `3.2s`, `1:05.5`, `50%`, `start`, `end`; scenes by the name given to `scene{}`:
`Intro` (its first frame, or the whole scene where a range is expected), `#2` (scene index,
from 0 as `timeline` prints it),
`Intro[1]` (the second scene named Intro); inside a scene `Intro@1.5s`, `Intro@12`,
`Intro@50%`, `Intro@end` (past the scene's end is an error, not the next scene). Cues and sync
ids (`timeline` lists them) work the same: `drop` (its frame), `drop@0.5s`, `drop@-12` (before
it), `beat[3]`; a scene's name wins over a cue's. Ranges: `a..b` (end exclusive), `a..`, `..b`,
`all`, with any of these as ends (`drop..beat[8]`, `Intro..drop@1s`). Separate several times
with commas.

### All commands

| command | use it to |
| --- | --- |
| `show [PATH] [--at T] [--page N]` | explore the video like a debugger's watch window: the video, then `scenes`, `scene/Race`, `scene/Race/nodes`, `cue/drop`, `bus/sfx`, `track/12`, `clip/x`, `says`, `say/intro` (a spoken line's words and times), `say/intro/3` (one word, and when each track playing it says it on the video), `songs`, `song/score` (a song's sections and parts), `song/score/parts/bass` (every note on the video), `instruments` and `instrument/MonoSynth` (the built-in rows, as data to copy), `media` and `media/logo.png` (the files besides sounds), `fonts`, `bodies` and `body/ball` (what `physics{}` and `physics3d{}` simulated: start, end, still moving), `marks` and `mark/2` (what the user marked in the preview), `node/scenes/race.lua:19[2]`; an unknown path lists the ones there are; each has a summary, its fields, its children by path (20 a page) and the script line that made it |
| `timeline [RANGE]` | scenes (with their cue and the file and line that defines them), audio tracks, cues, songs (sections, tracks); a range lists only what happens in it |
| `inspect [RANGE] [--every 0.1s \| --all-frames] [--info] [--fail-on error\|warning\|never]` | find problems without looking (exit 2 on failure; `--info` also lists text entirely off canvas) |
| `strip [RANGE] -n N [--columns 4] [--width 480] [-o strip.png]` | flow and motion in one image |
| `frame SPECS [-o frames] [--svg]` | full-size PNGs; `--svg` also writes each frame's node tree as SVG to read positions, text and colours |
| `onion RANGE [-n 6] [-o onion.png]` | a movement's trajectory and easing |
| `preview [AT] [--paused] [--no-loop] [--mute] [--bare] [--fullscreen] [--exit-after N]` | real-time window with sound and hot reload, for the user (`--bare`: the video alone, no controls, panels or timeline, played once, then the window closes, Escape sooner; `--fullscreen`: open fullscreen; both together play a script full screen like a screensaver; `--exit-after N`: close after N window frames). Playback that misses frames steps down to 75, 50, 35 or 25% of the window's size (a step that doesn't help is undone: the script isn't limited by pixels) and back up once it keeps up; the status line shows the size; a paused frame renders at full size, so judge detail paused. The window opens before the script loads (it loads once, in the window): a script that fails shows its error there until an edit fixes it, and an `AT` that names nothing warns and starts as without it |
| `render [RANGE] [-o out.mp4 \| dir] [--draft] [--h265] [--qp N] [--native]` | encode the video or a part, or write PNGs |
| `render --batch rows.json\|rows.csv [-o out/{name}.mp4] [--rows a..b \| --only N]` | one video per data row, the row as `props` |
| `snapshot SPECS [--update] [--dir _frame_snapshots] [--threshold 16] [--max-diff 0.001]` | compare frames with approved PNGs; writes `.actual.png`/`.diff.png`, exit 2 on a difference; a PNG of another size (another `--scale`) is the error `snapshot_size` |
| `audio analyze [RANGE] [--waveform w.png]` | loudness (LUFS, LRA), true peak, clipping, silence, per scene |
| `audio at SPECS` | which tracks play at a moment, where in their file, how loud, ducking; a song's section and the notes sounding |
| `audio render [RANGE] [-o audio.wav] [--float]` | the mix as a stereo WAV |
| `audio onsets [RANGE] [--min 0.1]` | where sounds start (seconds, strength) and the beat (BPM, first beat) |
| `audio pin` | fetch what the songs play from their sources and write their pins (after a `not_pinned` finding) |
| `audio parts [--against parts.json]` | each song alone, part by part: notes, the first of them, LUFS, peak; keep a `--json` of a song you like, and `--against` it after a change names each part that moved (exit 1) |
| `probe FILE...` | the streams of media files (container, video, audio) |
| `update [--check]` | replace an installed release with the latest (`--check`: only say whether one is out) |

The audio commands take `--track FILE` to hear one track alone, as it sounds in the mix.

Common options: `--json`, `--scale S`, `--media DIR` (default `media/` beside the script),
`--props FILE`, `--set K=V`, `--software`, `--threads N`, `--image-cache MB` (decoded images
kept in memory, default 1024).

### As MCP tools

`onimite mcp` serves these commands as MCP tools on stdin/stdout; the Claude Code plugin
(`/plugin marketplace add defnotmid/onimite`, then `/plugin install onimite@defnotmid`)
registers it (the `onimite` binary must be on PATH), and the Claude Desktop extension
(`onimite-macos-arm64.mcpb`, `onimite-windows-x86_64.mcpb` in the releases) bundles its own
binary and a work folder (`onimite mcp --dir PATH`: relative paths start there). A release
build looks for a newer release as it starts (`--update-check false` or
`ONIMITE_NO_UPDATE_CHECK=1`: it doesn't); when one is out, the next tool result says so:
tell the user, and run `update` when they agree (in Claude Desktop the extension's "Check
for updates" setting turns the check off). `guide`
returns this skill and its references, built into the binary. Tools: `render`, `frame`, `strip`,
`onion`, `snapshot`, `show`, `timeline`, `inspect`, `audio_render`, `audio_analyze`,
`audio_at`, `audio_onsets`, `audio_parts`, `audio_pin`, `probe`, `update` (the server keeps running the old version
until the app restarts), and `preview`, which opens the window for the user and
returns at once (one window per script; it reloads on save, so open it once and keep
editing). Every script tool takes `script` and
optionally `media`, `props`, `set` (`{"key": value}`), `scale`, `software`; the rest are the
options above by name (`specs`, `range`, `output`, `count`, `fail_on`, `all_frames`, ...).
A call answers with the command's `--json` document; `frame`, `strip`, `onion` and
`audio_analyze` with `waveform` return their PNGs as images too (without `output` the files
are not kept). A failing command is an error result with its code; an `inspect` or
`snapshot` that fails adds `{"failed": true}`. Each call loads the script afresh.

### Preview keys

Space play/pause · Left/Right or J/K step a frame · Ctrl+Left/Right one second · Home/0
(Shift+J, Shift+Left) the bookmark, then the start · End (Shift+G, Shift+Right) last frame ·
PgDn/S/W, PgUp/B/Shift+S next/previous scene · M set the bookmark (reloads return to it) ·
`[` / `]` mark a range's in / out · P mark a moment (again: unmark) · Delete / Backspace remove
the mark under the playhead (the marks file beside the script, `show marks`) ·
Up/L, Down/H volume · Ctrl+Down/Ctrl+H mute · Shift+L loop · =/- zoom the timeline, Ctrl+0
fit it · Z fit the video in its panel · T hide timeline · F fullscreen · D/I the Watch on problems/media · N/Shift+N
next/previous row with a warning or error · Ctrl+P go to a scene, cue, problem or mark (type to
filter, Up/Down, Enter) · R reload · Ctrl+O open a script · Esc closes the list, the
Watch, fullscreen, then the window · Q close.
Click or drag the timeline to scrub; once zoomed, it stops following the playhead when you
scroll it, and its Follow button brings it back. Over the video, the wheel zooms around the
cursor and dragging pans (a click still plays/pauses). Views are tabs in panels: drag a tab to another panel or
its edge, `+` lists the views to open in that panel and its splits (type to filter). A timeline
in a panel at the side, taller than wide, runs top to bottom. The Watch lists scenes, cues (with drift / missing-hit
findings), problems, media (failed, unused sounds) and marks; a click on a row goes to its frame. A
script that fails to load shows its error in the window while the last good version keeps
playing.

## 4. Writing the video

- One scene per idea, 2-6 s each. Inside a scene `f.seconds` and `f.index` count from the
  scene start; `f.global_seconds` / `f.global_index` from the video start.
- `animate(f, keys)` with keys `{ start, stop, from, to, easing }` is the default for
  motion. Leave `stop` nil on a trailing spring so it settles naturally. Before the first key
  the value is its `from`; after the last it holds its `to`.
- `ease_in`, `ease_out`, `ease_in_out` are Odin's cubic curves (stronger than CSS); the CSS
  curves are `cubic_bezier(0.42, 0, 1, 1)`, `(0, 0, 0.58, 1)`, `(0.42, 0, 0.58, 1)`.
  `easing.quadratic_out` ... `easing.back_out`, `easing.elastic_out`, `easing.bounce_out` too.
- Put animated values on a wrapping `group{ transform, opacity }` and keep the content
  inside it fixed; animate transforms and opacity, not font sizes or layout.
- `render` must be a pure function of `f`. Renders build frames on most cores, each builder in
  its own Lua state, so state carried from one frame to the next breaks: no counters, no
  accumulating tables, no `math.random` without a per-frame seed (use a hash of the index).
  Caches keyed by input (like a text-layout memo) are fine.
- Measure text rather than guess: `text_width{}`, `text_size{}` (the size that fits a width),
  `text_fit{}` (ellipsis), `text_lines{}` (wrapping) work at load and while rendering.
  `inspect` catches anything leaving the canvas; give cards and panels a group `box` and it
  also catches what spills out of them (`outside_box`).
- Use the video-level `render` (with `render_scenes(f)`) for things across every scene: a
  HUD, a beat pump, flashes, grain.
- Compose time with the standard library (`references/api.md`, "Composition helpers")
  instead of offset arithmetic: `sequence(f, from, dur, fn)` gives `fn` a frame whose clock
  starts at 0 (`g.progress` 0..1), `series(f, { {dur, fn}, ... })` plays parts back to
  back, `loop(f, period, fn)` and `freeze(f, at, fn)` wrap or stop the clock (clips and
  shaders follow), `stagger(i, each, { n, from = "center" })` offsets item starts.
- Footage: `scene { clip = { "a.mp4", from = 12, to = 15.5 } }` is a cut of a file with its
  sound (crossfading with any transition); `speed` (slow motion, fast, negative backwards),
  `picture = { fit, fade_out, ... }` and `sound = { lead, extend, gain_db, speed, ... }` set
  each side; a list of such scenes joins or edits clips (`references/media.md`, "Cuts and
  joining clips").
- A scene without `render` is fine as a label (for `Card@2s` addressing and per-scene
  loudness) when the video-level `render` draws everything.
- Debug values with `io.stderr:write(...)` inside `render` and run `frame` on one frame
  (renders call `render` on many threads, in any order).

### Beat sync

Put the BPM and every cue, in beats, in one place that the scenes and the audio both read
(full pattern and a synthesized soundtrack in `references/design.md`). Name the moments that
must meet with `cue(name, t)` and put the scenes, tracks and keys that land there on it
(`cue = "name"`): `inspect` then reports anything that drifts off them, and `frame video.lua drop` shows the
moment (Cues in `references/api.md`). With supplied music, `audio_onsets("music.mp3")`
gives the BPM, the first beat and every hit (`references/audio.md`):

```lua
local FPS = 60
local clock = beat_clock(120)                            -- std: bpm, offset of beat 0, beats per bar
local SLAM, SUB = 4, 6                                   -- cues, in beats
local SNAP = spring { stiffness = 320, damping = 22 }
-- in render: local b = clock.beat(f)                    (the video's beat, from any frame)
--   title scale: ease(SNAP, (b - SLAM) * clock.spb)   (0 before the slam)
--   kick pump:   scale(1 + 0.01 * pulse(b, 8), ...)    (pulse(b / 4, 6): once a bar)
-- scenes on the grid: scene { "Drop", start = clock.time(32) } (lasts until the next start)
-- media on a beat: video_frame(f, { ..., start_from = clock.time(12) })
```

### Long videos

Lay a long video out so any part can be changed by reading only that part
(`examples/onimite_saga` and its README):

- `video.lua` is a manifest: the video, its music, `require("scenes.x")` in order.
- One scene per file; it calls `scene{}` itself with `start` on its cue and `cue` the cue's
  name, so `timeline` shows the file and line, and a scene lasts until the next one starts.
- One cues file with every named moment (`cue()`), read by scenes and music.
- Music in one clip per section; each scene places its own sound effects on an `sfx` bus.
  Shared drawing in one kit file.
- To change what you see at a moment: `onimite show video.lua scene/Name/nodes --at 1:12`
  names the line that drew each element (`via` the scene line when a
  helper drew it); edit that line and check only that range (`inspect video.lua Scene`).
- Explore instead of reading files: `show video.lua`, then follow the paths it lists. Output
  stays a page long however long the video is.

### Performance

- Build static data at load, not per frame: layouts, measured text, point lists, colours.
- Large load-time data (decoded paths, parsed files): wrap it in
  `shared("name", function() ... end)` so a render computes it once instead of once per
  builder, and parse big SVG path strings once with `path_data(d)`. Synthesized audio: pass
  `audio_add` the build function itself, writing into an `audio_buffer`.
- `text_width` keeps its results: measure inside `render` freely. Fit titles with `text_size`.
- Groups with `blur`, `opacity`, masks and filters draw into layers sized to their content,
  so a blur on a small element is cheap; give `filter = {...}` a `region` (it covers the
  whole frame without one).
- Measure, don't guess: `render ... --json` reports `elapsed_seconds`; compare a range
  (`render video.lua Intro -o /tmp/x.mp4 --json`) before and after a change.

## 5. Making it look good

The short version of `references/design.md`:

- One idea per scene, large type, margins of 8-10% of the width, two or three colours plus
  neutrals and one accent.
- Elements enter with a spring or ease-out over 300-600 ms and leave faster (200-300 ms,
  ease-in). Related items stagger by 60-120 ms. Give 1-2 s to read after motion settles; keep
  a little ambient motion in holds; never move everything at once.
- Cross-fade scenes with `overlap = { previous = 0.4 }` (added to the scene's duration),
  give the entering scene `transition = { "wipe", duration = 0.5, easing = ease_in_out }`
  (fade, slide, wipe, clock_wipe, zoom, glitch; the previous scene leaves by it), or carry an
  element across the cut. `transition(kind, p, a, b, opts)` switches content inside a scene.
  With music, cut on bars and land hits on beats.
- At 1920x1080: titles 96-140 px, body 44-60 px, at most ~8 words per line and 3 lines per
  card. Portrait 1080x1920: same pixel sizes or larger, content inside the middle 80%.
- Check every scene against the checklist in `references/design.md` with a strip.

## 6. Sound

Put audio files in `media/` (wav, ogg (Vorbis or Opus), opus, mp3, flac, m4a (AAC or ALAC), aac; stereo kept) and place them on the
video or on a scene (times relative to the scene):

```lua
local CARD_IN = 0.8   -- when the card lands: the animation uses it too
video { width = 1920, height = 1080, fps = 30, duration = 10,   -- or scenes
  audio = {
    { "music.mp3", start = 0, gain_db = -18, fade_in = 1, fade_out = 2, curve = "equal_power", ducked = true },
    { "vo.wav", start = 0.6, voice = true },
    { "whoosh.ogg", start = CARD_IN - 0.15, gain_db = -8 },
  } }
```

Without assets, compose the music with `song{}` (odawg: sections with `bpm`, `style`,
`energy`, `chords`; parts, each on an instrument row: Tone.js's synths built in, and in this
skill's `library/` folder (copy it into `media/`) drums, basses, pads, sound effects, a
TB-303, the TR-808/909 from their circuits and seven styles, all data to change; sampled
pianos, strings, bass and a drum kit (CC0, downloaded on first use); any `.sfz` file as
an instrument (`instrument = "lib/piano.sfz"`); `references/audio.md`,
"Songs and sounds" and "Instruments") and place it
like a clip (`{ "score", bus = "music", ducked = true }`); its sections are cues, and its
notes drive the picture (`score.time("drop@1m")`, `score.pulse(f, { part = "drums", note =
"kick" })`, `score.hits { ... }`). Sound effects: `sound { "impact", instruments = "instruments/sfx.json" }`. Lines first, then the
song, then placement (say → song → placement), one leader per moment (`say_cue` for the
music following the voice, `say_start` for the voice following the music).
Time SFX from the same constants that drive the animation. Check with `audio analyze`
(about -14 LUFS integrated for web video, true peak at or below -1 dBTP, no unintended
silence) and `audio at`; adjust track `gain_db`, or `master_gain_db` on `video{}` for the
whole mix (a track normalised to -1 dBFS typically needs about -3 to -5 dB). Then let the
user listen in the preview.

### Voiceover: spoken lines

`say(name, text, { voice, seed })` speaks a line at load (text to speech by ottis; `voice` is
one of 27 built-in voices or a recording in `media/` to clone, references/audio.md) and gives
the time of every word; the line is a clip `name` for tracks, `{ audio = name }` and spectra,
and captions `name`. Put picture and sound on the words, not on guessed numbers:

```lua
local AT = 1.0                                        -- where the line's track starts
local intro = say("intro", "Up top, the lamp was dark.", { seed = 3 })
local DARK = say_cue(intro, AT, "dark")               -- the video time "dark" is said; cue "dark"
video { ..., buses = { music = {}, voice = {}, sfx = {} },
  audio = { { "intro", start = AT },                  -- speech goes on the voice bus by itself
            { "thud.wav", start = DARK, bus = "sfx", cue = "dark" } } }
-- in render: animate(f.global_seconds, { { start = DARK, stop = DARK + 0.5, from = 1, to = 0, cue = "dark" } })
--            captions(f, { src = "intro", start = AT, ... })
```

- **Place every key and sound effect that answers the voice on a word cue** (`say_cue`),
  and the speech on a `voice` bus (a track playing a `say` clip without a `bus` goes there,
  or is marked `voice = true` when the video has none): it ducks the music and is never
  beat-checked. Lay scenes out from `line.duration` so a changed line moves what follows.
- `say()` works on Linux x86_64 and macOS Apple Silicon; the Windows x86_64 build has it
  but it is untested there.
- `inspect` checks each cued word starts a sound of its line (`cue_no_hit`); a word that
  runs on from the one before ("the sea") has no onset of its own and is reported: that is
  expected, check it with `show video.lua say/intro/N`. Read `references/audio.md`
  ("Spoken lines") for voices, the first-run download (835 MB on Linux, 866 MB on macOS)
  and the credit the audio needs (*Pocket TTS by Kyutai, CC-BY-4.0*).

## 7. Finish

1. `onimite inspect video.lua --fail-on warning` passes, or the remaining warnings are
   understood entrances.
2. A strip of every scene looks right; key frames checked at full size.
3. `onimite audio analyze video.lua` shows sensible levels.
4. Offer the preview at the relevant second. When the user asks for the final export, run
   `onimite render video.lua -o out.mp4` and confirm with
   `onimite probe out.mp4`. Report the output path and duration.

## Gotchas

- `print(...)` in a script writes to stderr: stdout is the command's output (one JSON
  document with `--json`, the MCP server's messages).
- `rect`/`text`/`group` at load: "can only be called while rendering a frame". Draw inside
  `render`; measure (`text_width` & co) anywhere.
- `video{}`, `scene{}`, `cue`, `physics{}`, `physics3d{}`, `audio_add`, `captions_load` and `say` inside
  `render`: "works at load, not while rendering a frame". They set the video up; call them at
  the top level of the script.
- A video needs scenes or a `duration` ("the video has no scenes and no duration").
- `animate` picks its value type from the first key's `from`: number, colour string, `{x, y}`
  or transform. Keep every key of one call the same type.
- `text` defaults to black, 16 px and the left edge at `x`; `align = "center"` centres on `x`;
  `y` is the alphabetic baseline unless `baseline` says otherwise.
- An unknown font family draws in DM Sans; `inspect` reports it ("No match for ...
  font-family"). Glyphs no font has are reported too.
- Zero-size rects and zero-radius circles are reported by `inspect`: animate sizes from a
  small positive value or skip drawing.
- An invalid colour or transform string is an Error diagnostic (a Lua error at load).
- `subtitle_at(f, ...)`, `caption_words(f, ...)` and `captions(f, ...)` read the frame's clock,
  which is scene-relative inside a scene; pass `f.global_seconds` (a number) to use video time.
  Beat clocks and `audio_spectrum(f, { src })` already use the video's time.
- Changing `media/` reloads the media in the preview; a renamed font needs its new family
  name in the script.
- No WebM or transparent output: renders are opaque MP4 (alpha clips work as inputs).
- A `say()` line that was never synthesized is made when the script loads (about a quarter
  of its length; the first time ever, ottis's 835-866 MB download first), in every command (in the
  preview, while its window shows the load); the lines a load is missing are made together.
  Later loads read them back. A line that can't be made is
  silent (`line.ready == false`, `tts_unavailable`, an error): `inspect` names it and
  `render` refuses to start, as it does whenever the load found an error (`load_errors`).
