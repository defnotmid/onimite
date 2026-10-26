# designer_handoff

A designer's files driven straight into an animated product card: 15 s at
1920x1080, 60 fps. The script imports the three formats a designer hands
over and redraws or re-types nothing:

| file | format | used for |
| --- | --- | --- |
| `tokens.json` | W3C design tokens | colours, type styles, spacing, radii, the card shadow and the copy |
| `media/illustration.svg` | SVG | the product illustration: drawn on as line art, then shown with `svg{}` |
| `media/badge.json` | Lottie (Bodymovin) | the confirmation badge that bursts when the button is pressed |

```sh
onimite render examples/designer_handoff/video.lua -o designer_handoff.mp4
```

| seconds | scene | what |
| --- | --- | --- |
| 0-3 | Files | the three files land as cards, each with a live thumbnail of itself (the SVG, the Lottie playing, the token colours) |
| 2.5-7 | Tokens | a spec sheet made from `tokens.json`: colours dark to light with names and values, each type style set in itself, the spacing scale as bars, the radii as corners |
| 6.5-11.5 | Build | the card assembles: its paths draw on as line art, the SVG fades in over them, the copy slides in, and the designer's redlines show the spacing tokens in use |
| 11.5-15 | Ship | a cursor presses the button, the label turns to "Added" and the Lottie badge bursts over the corner; the speaker's ring glows |

How the files come in:

- **Tokens**: `json_decode` reads `tokens.json` at load. `tok("color.brand")`
  returns a token's `$value`; `tokens_of(group, order)` lists a group for the
  spec sheet. Every colour, size, padding, radius, the shadow and every
  string on the card come from it: edit a token and the card follows.
- **SVG**: the illustration's `<path>` data is read once per render with
  `shared()` and parsed with `path_data()`, so the line-art draw-on strokes
  the designer's own paths (`path_length = 1` dashes, staggered back to
  front). Then `svg{}` draws the document itself, recolouring the light
  ring, the status light and the sparkle by id from the tokens.
- **Lottie**: `lottie{}` plays `badge.json` from the click (`time`,
  `loop = false`), its Disc, Burst and Ring layers recoloured from the
  tokens; in the Files scene it loops as a thumbnail.

Layout is measured: the title and tagline wrap inside the card's padding
with `text_lines`, the button fits the longer of its two labels with
`text_width`, and the card's height is the sum of its rows and the spacing
tokens between them.

Render with `build/onimite` (Vulkan Video): 450 frames in 1.1 s.

Media: `illustration.svg`, `badge.json` and `tokens.json` are made for this
example (MIT, this repository). Fonts copied from other examples (OFL):
Space Grotesk Medium, DM Sans Medium, JetBrains Mono. No audio.
