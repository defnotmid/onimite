# svg_demo

An SVG asset drawn as vectors and animated by element id.

    onimite render examples/svg_demo/video.lua -o svg_demo.mp4

`media/bird.svg` (drawn for this example, CC0) loads with the media like an
image and is parsed once. Each frame draws it with `svg{ src = ..., overrides = ... }`:

- `wing` and `wing_back` rotate about their shoulders. An override's
  `transform` applies in the element's own coordinates, so the rotation
  origin is a point of the path (`svg_bbox{ src, id }` gives a part's box).
- `sun` gets a replacement `fill` (a radial gradient with a focal point
  becomes a colour) and an `opacity`.
- `pupil` moves inside its clip path.

A star from inline `markup` is parsed once per renderer (cached by content)
and drawn three times. The bird uses a linear and a focal radial gradient, a
`<style>` class, a clip path and an `feDropShadow` filter with a region.
