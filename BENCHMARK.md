# fframes (Rust) vs onimite (Odin + Lua): same examples, 1:1

Machine: AMD Ryzen 9 9900X3D (12 cores / 24 threads), AMD RX 9070 XT (RADV, Vulkan), Linux 7.2, 123 GB RAM.
All outputs 1920x1080 unless noted, same fps and duration on both sides (frame counts verified with ffprobe).

**What you need to reproduce this.** The benchmark pairs fframes' own
examples with the onimite ports of them in `examples/fframes/`. Their media
is fframes' and is not committed: `examples/fframes/fetch.sh` fetches
fframes into `third_party/fframes` (the commit pinned in
`third_party/fetch.sh`) and copies the media next to the ports. Then
`tools/bench.sh all` (or `build`, `perf`, `visual`, `video`) runs everything;
it is table-driven (`PAIRS` at the top, each row naming the fframes crate
and binary and the onimite script under `examples/fframes/`). Raw data from the runs below:
`bench/results_full_2026-10-12.tsv`, `bench/visual.tsv` and `bench/video_cmp.tsv` (2026-10-12),
`bench/results_full_2026-10-10.tsv` and `bench/results.tsv` (2026-10-10).

## Full run (2026-10-12)

Against fframes' latest main (f962cd6, 2026-10-12): its new segment scheduler
made its Skia examples faster (fframes_intro 48.2 -> 38.0 s, shader_mode
6.0 -> 4.1 s, audio_announce 11.7 -> 9.5 s), and its examples now ship real
fonts (Fredoka One, Inter, JetBrains Mono) instead of macOS ones, so text
that both sides skipped before is drawn on both. Median of 3 runs on an idle
machine (load under 2 before the run), the same method as below.

| Example | Frames | fframes wall / CPU / RSS | onimite GPU wall / CPU / RSS | onimite native wall | GPU vs fframes |
| --- | --- | --- | --- | --- | --- |
| hello_world | 900 | 1.53 s / 31 s / 1.8 GB | 1.93 s / 0.5 s / 92 MB | 1.79 s | 0.79x |
| signal_lab | 720 | 1.78 s / 29 s / 7.4 GB | 1.59 s / 0.6 s / 104 MB | 1.29 s | 1.1x |
| motion_graphics | 240 | 2.87 s / 2.9 s / 393 MB | 0.61 s / 0.2 s / 92 MB | 0.47 s | 4.7x |
| mg_install | 600 | 6.36 s / 6.4 s / 360 MB | 1.35 s / 0.4 s / 93 MB | 1.00 s | 4.7x |
| mg_quote | 180 | 2.14 s / 2.2 s / 351 MB | 0.49 s / 0.2 s / 93 MB | 0.40 s | 4.4x |
| conference | 185 | 3.17 s / 8.9 s / 823 MB | 0.54 s / 0.3 s / 120 MB | 0.66 s | 5.9x |
| low_poly_art | 600 | 2.41 s / 52 s / 2.9 GB | 1.39 s / 2.5 s / 183 MB | 1.51 s | 1.7x |
| beta | 1920 | 10.7 s / 214 s / 28 GB | 4.09 s / 1.4 s / 343 MB | 4.45 s | 2.6x |
| marketing | 1310 | 11.6 s / 252 s / 18 GB | 2.83 s / 1.3 s / 136 MB | 2.25 s | 4.1x |
| podcast | 3600 | 7.19 s / 152 s / 2.0 GB | 7.44 s / 2.6 s / 128 MB | 6.63 s | 0.97x |
| tiktok | 3070 | 28.7 s / 595 s / 17 GB | 6.34 s / 2.4 s / 138 MB | 6.75 s | 4.5x |
| teej_podcast | 7200 | fails (libav error -22 on the stand-in media) | 29.0 s / 38 s / 672 MB | 30.5 s | - |
| audio_announce | 1418 | 9.49 s / 156 s / 12 GB | 4.82 s / 5.3 s / 177 MB | 5.42 s | 2.0x |
| pixel_memory (The_Farewell) | 4980 | 46.1 s / 646 s / 14 GB | 13.6 s / 9.3 s / 1.1 GB | 18.3 s | 3.4x |
| shaders* | 240 | 1.75 s / 13 s / 2.6 GB | 0.63 s / 0.2 s / 92 MB | 1.01 s | 2.8x |
| neon_triangle* | 360 | 1.43 s / 13 s / 3.9 GB | 0.86 s / 0.3 s / 92 MB | 0.95 s | 1.7x |
| fframes_intro | 7650 | 38.0 s / 635 s / 11 GB | 19.3 s / 16 s / 1.2 GB | 43.4 s | 2.0x |
| made_of_motion (1440x1080, 24 fps) | 489 | 7.29 s / 73 s / 4.4 GB | 2.13 s / 2.5 s / 912 MB | 3.47 s | 3.4x |
| shader_mode | 932 | 4.11 s / 50 s / 7.8 GB | 3.04 s / 1.9 s / 326 MB | 4.08 s | 1.4x |

\* fframes' default CPU renderer draws no shader layers, so its time
understates the work.

onimite is faster on 16 of the 18 comparable examples, with 1-10% of
fframes' CPU time and 1-26% of its memory. fframes wins hello_world and,
narrowly, podcast: there the hardware encoder is onimite's bound, while
fframes runs x264 on every core (onimite's native encoder is 1.79 s and
6.63 s there). shader_mode's soundtrack is a 220 Hz stand-in on both sides
(`examples/fframes/fetch.sh`). fframes crashed once on pixel_memory
("double free or corruption") in a run the day before; all three runs here
completed.

Changes in onimite since 2026-10-10 that show here: the SDL_GPU backend
draws a frame's shapes in a few batched draw calls (low_poly_art 2.2 ->
1.4 s); a blurred group of one filled shape is drawn as that shape with
soft edges instead of a blurred layer (pixel_memory 22 -> 14 s); frames are
converted to NV12 on the GPU, the layout the hardware encoder takes; frame
builders are added only when a loaded builder falls behind (shader_mode
steadier, 576 -> 326 MB).

## Quality (2026-10-12)

Whole videos and single frames compared with ffmpeg (PSNR / SSIM, 4:2:0),
every pair (`bench/video_cmp.tsv`, `bench/visual.tsv`).

| pair | whole video PSNR / SSIM | single frames PSNR |
| --- | --- | --- |
| hello_world | 44.5 dB / 0.999 | 46.2-48.5 dB |
| signal_lab | 42.2 dB / 0.998 | 43.5-47.1 dB |
| neon_triangle | 43.6 dB / 0.996 | 45.3-93.3 dB |
| shaders | 41.7 dB / 0.992 | 40.7-78.7 dB |
| podcast | 39.7 dB / 0.995 | 31.8-45.9 dB |
| mg_quote | 34.9 dB / 0.998 | 45.2-47.5 dB (2 identical) |
| made_of_motion | 34.8 dB / 0.945 | 36.8-48.7 dB |
| beta | 34.4 dB / 0.995 | 44.5-52.4 dB |
| low_poly_art | 32.0 dB / 0.988 | 27.2-29.8 dB |
| mg_install | 31.2 dB / 0.993 | 27.8-90.6 dB (1 identical) |
| tiktok | 30.0 dB / 0.990 | 24.6-47.6 dB |
| fframes_intro | 29.8 dB / 0.952 | 37.9-41.8 dB |
| shader_mode | 29.7 dB / 0.986 | 19.5-72.4 dB (2 identical) |
| motion_graphics | 28.9 dB / 0.995 | 16.1-89.7 dB (1 identical) |
| audio_announce | 25.7 dB / 0.929 | 21.9-29.4 dB |
| conference | 24.2 dB / 0.962 | 18.1-38.2 dB |
| marketing | 21.9 dB / 0.971 | 12.3-49.9 dB |
| teej_podcast | - (fframes fails) | 26.1 dB |
| pixel_memory | 11.2 dB / 0.638 | 6.6-27.3 dB |

The low single frames are mid-animation frames where the two sides' easing
differs slightly (named easings are cubics on onimite's side) and glyph
edges; pixel_memory picks its photos at random on fframes' side, so its
pictures differ by design.

## Full run (2026-10-10)

After GPU colour conversion, odecs' pipelined Vulkan Video encoder and the
pooled native encoder. Median of 3 runs, load 4-8. fframes runs each binary
from its example directory with its default config (CPU renderer + libx264,
signal-lab on Skia).

| Example | Frames | fframes wall / CPU / RSS | onimite GPU wall / CPU / RSS | onimite native wall | GPU vs fframes |
| --- | --- | --- | --- | --- | --- |
| hello_world | 900 | 1.54 s / 31 s / 1.9 GB | 1.95 s / 0.7 s / 88 MB | 1.73 s | 0.79x |
| signal_lab | 720 | 1.89 s / 24 s / 6.6 GB | 1.69 s / 0.8 s / 107 MB | 1.23 s | 1.1x |
| motion_graphics | 240 | 2.50 s / 2.5 s / 312 MB | 0.68 s / 0.3 s / 88 MB | 0.46 s | 3.7x |
| mg_install | 600 | 6.70 s / 6.7 s / 322 MB | 1.34 s / 0.5 s / 88 MB | 0.91 s | 5.0x |
| mg_quote | 180 | 2.29 s / 2.3 s / 335 MB | 0.51 s / 0.2 s / 88 MB | 0.38 s | 4.5x |
| conference | 185 | 3.01 s / 8.6 s / 693 MB | 0.64 s / 0.6 s / 371 MB | 0.67 s | 4.7x |
| low_poly_art | 600 | 2.49 s / 51 s / 3.0 GB | 4.66 s / 3.0 s / 114 MB (later 1.90-1.94 s) | 4.95 s | 0.53x (later 1.3x) |
| beta | 1920 | 11.4 s / 205 s / 28 GB | 4.72 s / 2.0 s / 382 MB | 5.02 s | 2.4x |
| marketing | 1310 | 11.9 s / 234 s / 19 GB | 8.49 s / 1.6 s / 130 MB | 4.45 s | 1.4x |
| podcast | 3600 | 7.57 s / 144 s / 2.0 GB | 7.45 s / 3.9 s / 150 MB | 6.69 s | 1.0x |
| tiktok | 3070 | 30.0 s / 579 s / 15 GB | 6.37 s / 2.8 s / 143 MB | 7.72 s | 4.7x |
| teej_podcast | 7200 | fails (libav error -22 on the stand-in media) | 31.0 s / 46 s / 860 MB | 34.0 s | - |
| audio_announce | 1418 | 11.7 s / 184 s / 12 GB | 3.99 s / 3.1 s / 383 MB | 4.99 s | 2.9x |
| pixel_memory (The_Farewell) | 4980 | 49.4 s / 697 s / 12 GB | 103 s / 26 s / 1.9 GB (later 16.6-20.7 s) | 104 s | 0.48x (later 2.4-3.0x) |
| shaders* | 240 | 1.84 s / 13 s / 2.7 GB | 0.71 s / 0.3 s / 88 MB | 1.04 s | 2.6x |
| neon_triangle* | 360 | 1.54 s / 14 s / 3.9 GB | 0.97 s / 0.4 s / 88 MB | 1.03 s | 1.6x |
| fframes_intro† | 7650 | 48.2 s / 735 s / 8.7 GB | 22.6 s / 18 s / 1.3 GB | - | 2.1x |
| made_of_motion†‡ | 489 | 7.45 s / 72 s / 4.5 GB | 6.03 s / 10.6 s / 3.5 GB | 5.97 s | 1.2x |
| shader_mode†§ | 932 | 6.0 s / 72 s / 6.4 GB | 3.28 s / 2.6 s / 360 MB | 4.71 s | 1.8x |

\* fframes' default CPU renderer draws no shader layers, so its time
understates the work.

† Single run, measured when the pair was added (fframes-intro renders on
Skia/Vulkan with libx264 crf 16, as shipped).

‡ 1440x1080, 24 fps. Both sides decompress 19 MB of gzipped vector ink
(75 MB of path text) when the video is built; made-of-motion renders on
Skia/Vulkan with libx264 crf 16, as shipped; onimite holds a parsed copy per
Lua frame builder, hence the RSS.

§ 18 SkSL programs (one Shadertoy) on every frame, up to 156 card layers a
frame; shader-mode renders on Skia/Vulkan with libx264 crf 17, as shipped.
Its soundtrack is not in fframes' Git: both sides need a 31 s WAV
(measured with a 220 Hz stand-in).

"Later": content-sized layers and multi-core frame building, the same day,
turned pixel_memory and low_poly_art into wins. With them onimite is faster
on 17 of the 18 comparable examples, using a small fraction of the CPU and
memory. fframes still wins hello_world: a trivial scene where the hardware
encoder is the bottleneck while fframes runs x264 on all cores.

## Method

- fframes: `cargo build --release -p <example crate>` in `third_party/fframes`; each binary runs `<bin> render -o out.mp4`
  from a scratch directory.
- onimite: `odin build . -collection:deps=.. -o:speed -out:build/onimite_bench`, then
  `build/onimite_bench render examples/fframes/<example>/video.lua -o out.mp4 [flags]`.
- Each measurement is 3 runs under `/usr/bin/time -v`; the table shows the median (wall, CPU = user + sys, max RSS).
  Wall includes process start, media and font loading and the final mux.
- Configurations: onimite `gpu` (the default) draws on SDL_GPU / Vulkan, converts to I420 on the GPU and encodes with
  Vulkan Video H.264 at constant QP 23; `native` uses odecs' software H.264 encoder (QP 23). fframes encodes with
  libx264 as each example ships it (CRF 16-23); no hardware-encode variant was built on that side.

## Quality (first run, 2026-10-10)

Before fframes' examples shipped their fonts (see 2026-10-12).

Frames and whole videos compared with ffmpeg (PSNR / SSIM, 4:2:0). `tools/bench.sh`
also writes montages (fframes | onimite | difference x4) to `$OUT` (`.work/bench`);
they show fframes' media, so they stay local.

| pair | whole video PSNR / SSIM | single frames PSNR |
| --- | --- | --- |
| hello_world | 29.1 dB / 0.986 | 26.2-26.3 dB |
| signal_lab | 27.7 dB / 0.981 | 24.2-26.7 dB |
| mg_install | 21.7 dB / 0.970 | 18.1-18.9 dB (static frames 66.9 dB or identical) |
| mg_quote | 18.1 dB / 0.950 | 14.0-14.1 dB |
| motion_graphics | 15.2 dB / 0.935 | 10.8-13.4 dB (fframes lacks two text lines, see below) |

Layout, colours, positions and animation state match; the differences are
glyph edges. onimite text is slightly heavier, and in the Bebas Neue /
JetBrains Mono examples text widths differ by 1-2 px, which outlines every
glyph in the difference. fframes renders motion_graphics without its
"I FIXED" and "(for real)" lines because "Helvetica Neue" is not installed
on the machine (onimite substitutes Nimbus Sans), so its time there is also
understated.

## Caveats

- 2026-10-10: the machine was shared with other jobs during some runs, so times near 1-2 s are noisy. The
  2026-10-12 run was on an idle machine; run-to-run spread inside each 3-run set was small (<5%).
- Quality is not matched (constant QP 23 vs CRF), so sizes and bitrates are not an equal-quality comparison.
- fframes' motion-graphics binaries run with `concurrency: 1` as shipped, not at maximum speed.
