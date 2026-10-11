# conference_splash_screen

Port of fframes' `conference-splash-screen` example: a sponsor scene (3.8 s) and a speaker scene (4 s)
over `track.mp3`, 1920x1080 @ 24 fps, 185 frames (7.71 s, the length of the audio as in fframes).

    onimite render examples/fframes/conference_splash_screen/video.lua -o splash.mp4
    onimite frame  examples/fframes/conference_splash_screen/video.lua 145 -o out   # fframes' preview frame

## Choosing the talk

`--set talk=3` picks a talk by 0-based index into `TALKS` (fframes' `--talk 3`), or
`--set talk=emma` by a case-insensitive part of the speaker's name. The default is talk 0.
`TALKS` holds the talks of fframes' `sessions.json`. The avatars of `dynamic_media/` are
copied into `media/`.

    onimite render examples/fframes/conference_splash_screen/video.lua --set talk=3 -o talk3.mp4

## Batch (fframes' `render_all`)

`talks.json` lists every talk, one row each, so one command renders them all:

    onimite render examples/fframes/conference_splash_screen/video.lua \
      --batch examples/fframes/conference_splash_screen/talks.json -o out/talk_{talk}.mp4

## Deviations

- Title and abstract wrap with `text_lines` (shaped, kerned widths, measured at load) instead of fframes'
  per-character integer advances, so a line can break one word differently from the original.
- Montserrat has only a Regular file: "Warsaw" (weight 600) renders in Regular. "Sponsors and Partners"
  (Inter 18pt, 600) uses the ExtraBold file, the only one of that family.
- The avatar circle is an image clipped with `clip_path` instead of an SVG pattern fill.
- Nested `<svg>` viewports are group translate + clip.
- No `scene` ever plays past 7.71 s: the second scene is cut by the audio length, as in fframes.
- fframes' preview/description outputs of `render_all` are not ported.
