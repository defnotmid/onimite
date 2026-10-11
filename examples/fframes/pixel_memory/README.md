# pixel_memory

Port of fframes' `pixel-memory`: a randomized memorial video. A seeded RNG picks
the song, shuffles the photos and strings together photo scenes (parallax grid,
floating photo, Fibonacci spiral, developing polaroids, spiral heap) over a
drifting bokeh background that gathers into a heart for the closing signature.
1920x1080 @ 30 fps, as long as the song.

    onimite render examples/fframes/pixel_memory/video.lua -o pixel_memory.mp4
    PIXEL_SONG=The_Farewell.mp3 onimite frame examples/fframes/pixel_memory/video.lua 70s -o out

The original's flags are environment variables: `PIXEL_SEED` (`--seed`, 48),
`PIXEL_SONG` (`--song`), `PIXEL_TEXT` (`--enter-text`).

## Randomness

The generator follows the original's draws (song, photo order, scene
sequence, bokeh, per-scene motion) using Lua's `math.random` seeded with
`PIXEL_SEED`, so a seed always gives the same video, though not the one
fframes' `StdRng` gives for that seed. Photos come from the 68 in `media/`
(a subset of the original's `photos/`), repeating once all have been shown.

The original's video scene never appears: it resolves its clip in the song
media only and skips itself ("No duration found for scene"); its draw is
kept so the scene mix stays the same.

## Media

`media/` holds the font, the four songs and 68 of the original's photos.
Decoded photos take about 11 MB each in memory.

## Comparison with fframes

With fframes' generator (before the switch to `math.random`), frames were
compared side by side for `PIXEL_SONG=The_Farewell.mp3` (19 frames across all
scene types) and for the default seed (5 frames): PSNR was 32 to 48 dB on
frames with photos, the leftover differences being anti-aliasing and blur
edges. The scenes themselves are unchanged; only the random draws differ now.

The bokeh circles keep their focal point at 40% (`fx`/`fy`) and their
filter region (-50%, 200% of the circle's box); the photo shadows their
-20%, 140% regions.

Deviations:
- The polaroid year caption asks for `'Indie Flower', cursive, sans-serif`.
  None of these is installed, so fframes warns and draws no text, and this port
  draws none either. Set `CAPTION_FONT` to draw it.
- Audio: fframes' mix of the same mp3 measures about 1 dB louder (-12.5 vs
  -13.5 LUFS integrated); that comes from fframes' mp3 path, not the script.
- `transform-origin="center center"` resolves against the view box (the middle
  of the video), as usvg does, not against the photo.

## Performance

About 38 fps for the full render. Each of the ~130 bokeh circles is its own
blurred group, as in fframes; ovg sizes those layers to their content, so
they stay cheap. Static data (bokeh, keyframes, layouts, node props) is built
at load, and `render` only updates the animated fields.
