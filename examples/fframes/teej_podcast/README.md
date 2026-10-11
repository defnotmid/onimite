# teej_podcast

Port of fframes' `teej-podcast` example: two synced podcast video feeds
side by side in clipped frames with black borders, and a 12-entry chapter list
whose orange highlighter springs (mass 0.45, stiffness 130, damping 20) to the
current chapter. The current chapter's text turns black, and titles are cut
with an ellipsis to fit. 1920x1080 @ 24 fps, 300 s (the length of the feeds).

    onimite render examples/fframes/teej_podcast/video.lua -o teej_podcast.mp4

Media (stand-ins): the original's `main.rs` loads `dynamic_media/` at run time
rather than a compiled media folder. The fframes repository ships 5-minute
stand-ins there, and this port copies them into `media/` unchanged:
`left.mp4` and `right.mp4` (1280x720 H.264 at 24 fps, with mono AAC) and
`SofiaSansSemiCondensed-VariableFont_wght.ttf`. `left.jpg` / `right.jpg` are only
the editor's fallback images, so they are not needed. The same files are what the
benchmark's fframes render uses.

How the parts map:
- `get_synced_video_frame(start_from 0, no loop)` + `<image x=… width="1920">`
  (height auto, 1080) + `clip-path` become `video_frame{ x, y = 0, w = 1920, h = 1080, fit = "contain" }`
  inside `group{ clip = frame rect }`;
- `<use href="#left-video-frame" fill="none" stroke="#000" stroke-width="10">`
  becomes the same rect stroked, drawn under the clipped feed;
- `create_transition_keyframes_for_chapters` becomes `CHAPTER_KEYS` (built at
  load), a spring per chapter start, each at most 1 s long;
- `fit_titles` is `text_fit` ("…" marker, trailing spaces trimmed) against
  `470 - width("mm:ss") - width("  ")`, measured once at load;
- the three `<tspan>`s become `spans = { {start}, {"  "}, {title} }`.

