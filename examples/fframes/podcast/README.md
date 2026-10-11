# podcast

Port of fframes' `podcast` example: three podcast participants (goose, guest,
duck) as avatar circles filled with image patterns, each with a 16-bar
visualisation of `final.mp3` under it, below a goose and a duck illustration
split by a divider. The duck is drawn through a mask and a clip path.
1920x1080 @ 60 fps, 60 s (the audio map runs `final.mp3` from 0 s to 60 s; the
file is 21 s long, so the bars rest at their minimum after that).

    onimite render examples/fframes/podcast/video.lua -o podcast.mp4

Media: `final.mp3`, `goose.jpeg`, `guest.jpg`, `duck.jpg` (copied from the
original). How the parts map:
- each `<pattern x="0%" y="0%" width="100%" height="100%" viewBox="0 0 480 480">`
  becomes `pattern{ units = "bbox", w = 1, h = 1 }` whose content is the
  480x480 image scaled by 360/480, the viewBox mapped onto the circle's box;
- `<mask id="right-section-mask">` becomes `mask = function() rect ... end`, and the
  `matrix(-1 0 0 1 1256.75 161.456)` clip rect becomes an equivalent `clip`;
- `visualize_audio_frame(S32, smooth_level 2, no window)` becomes
  `audio_spectrum{ sample_size = 32, smooth = 2 }`.

The illustration's path data is copied verbatim.

Deviations: the spectrum bars analyse the 48 kHz stereo mix rather than the
left channel at the file's rate, so their heights differ slightly. Otherwise
frames match fframes within 0.14/255 on average.
