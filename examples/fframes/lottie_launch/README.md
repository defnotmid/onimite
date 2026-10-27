# lottie_launch

fframes' `lottie-launch` example, written the onimite way: an 18 second vertical launch
video for Lottie support, 1080x1920 at 60 fps. Every animation in it is a Lottie file from
`media/`, played with `lottie{}`; the music is composed when the video renders, so the
example ships no audio.

```sh
onimite render examples/fframes/lottie_launch/video.lua -o lottie-launch.mp4
onimite preview examples/fframes/lottie_launch/video.lua
```

- **The beat** (`beat.lua`, 120 BPM) times everything: the scenes (a hook, a grid of
  twelve animations, the code that plays the tiger, a dive into the tiger's eye, an outro)
  overlap by 0.3 s for their cross-fades, and every pop, keystroke and cut is on its grid.
- **Each element** enters with the original's soft spring and fades with its CSS curves
  (`ease`), and the text is placed by its shaped width (`text_width`).
- **The score** (`soundtrack.lua`) is the original's, as a `song{}`: a part per voice
  (a drum kit, bass, a chord pad, plucks, keystrokes, whooshes, impacts), each voice a row
  of nodes from the original's recipe, the pad and bass pumping under the kick, the pad's
  level and cutoff on automation lanes. Each part plays at the original's gain, raised or
  lowered by what `inspect`'s role_balance named, and the song is lowered to the original's
  peak, then mastered as the original is, to about -14 LUFS (`onimite audio analyze`).

What differs from fframes: the text sits a few pixels from the original's, which sums
whole-pixel advances without kerning; onimite's Lottie player draws gradients with opacity
stops differently from velato (the fire's inner flame is paler); odawg's filters, noise and
saws make the music close, not identical, and its balance is odawg's roles', not the
original's mix.

- Emoji animations (`media/*.json` except the two below): [Noto Animated Emoji](https://googlefonts.github.io/noto-emoji-animation/) by Google, CC BY 4.0.
- `media/switch.json` and `media/watermelon.json`: [lottie-ios](https://github.com/airbnb/lottie-ios) samples, Apache 2.0.
- Fonts: Anton, IBM Plex Mono and Instrument Serif, SIL Open Font License.
