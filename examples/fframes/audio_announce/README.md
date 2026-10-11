# audio_announce

Port of fframes' `audio-announce`: an automated announcement video for a voice-over.
The voice-over is the sound of `video.mp4`. On screen are glowing word-wrapped
subtitles from `subtitles.vtt`, a looping transparent avatar clip with the same
glow, and four spectrum "waves" made of cubic splines over the background.
1920x1080 @ 30 fps, as long as the audio (1418 frames, 47.27 s).

    onimite render examples/fframes/audio_announce/video.lua -o audio_announce.mp4

Ported 1:1:
- fframes' `text_break_lines` is `text_lines` (width 1400), lines
  `trunc(i * 1.2 * 120)` apart, `dominant-baseline="middle"`.
- The `glow` SVG filter graph, in sRGB.
- `svg_waves.rs`: Thomas-algorithm control points, `step_by` and `rev().step_by`.
- `visualize_audio_frame` with 512 samples, a Hann window and smoothing over 4 frames.

## Media

- `background.png`, `JetBrainsMono-Regular.ttf`, `subtitles.vtt` and `video.mp4`
  (its AAC track is the audio) are copied from the original.
- `transparent.mov` (ProRes 4444 with alpha) is the original's avatar clip,
  played looping and stretched to 300x300 like fframes' `into_resized_image`.
- The waves analyse the stereo mix of `video.mp4` at 48 kHz (fframes reads
  the left channel at the file's rate), so wave heights differ slightly.

## Comparison with fframes

Frames at start, 2 s, 25%, 50%, 75% and end were compared side by side with
the original: PSNR is 45 to 47 dB over the whole frame with the current
engine, and about 55 dB on the avatar.
- Subtitle wrapping, positions and timing are identical.
- The text stroke and glow differ by sub-pixel anti-aliasing.

Audio analysis is the same (-24.9 LUFS, true peak -6.8 dBTP).

## Performance

About 197 fps for the full render (1418 frames in 7.2 s). Wrapped lines are
cached per subtitle phrase, and the filter tables are built once at load.
