# Filters in onimite scripts

SVG filter effects on a group (`group({ filter = { ... } }, fn)`; see Groups in [api.md](api.md)).


```lua
group({ filter = {
  { "blur", std = 6, input = "SourceAlpha", result = "b" },   -- std = n or {sx, sy}
  { "offset", dx = 4, dy = 8, input = "b", result = "o" },
  { "flood", color = "#000", opacity = 0.5, result = "fl" },
  { "composite", op = "in", input = "fl", input2 = "o", result = "s" },
  { "merge", "s", "SourceGraphic" },
  region = { x = -0.2, y = -0.2, w = 1.4, h = 1.5 },           -- objectBoundingBox fractions
} }, function()
  text { "Shadowed", x = 200, y = 300, font = "DM Sans", size = 120, fill = "#fde68a" }
end)

group({ filter = {
  { "color_matrix", type = "saturate", values = { 0.2 } },
  region = { x = 0, y = 400, w = 960, h = 500, units = "userSpaceOnUse" },
} }, function()
  image { src = "photo.jpg", x = 0, y = 400, w = 960, h = 500, fit = "cover" }
end)
```

```lua
group({ filter = {
  { "turbulence", type = "fractalNoise", base_frequency = 0.02, octaves = 3, seed = 4, result = "n" },
  { "displacement_map", input = "SourceGraphic", input2 = "n", scale = 30, x_channel = "R", y_channel = "G" },
  region = { x = 0, y = 0, w = 960, h = 540, units = "userSpaceOnUse" },
} }, function()
  text { "Wobble", x = 200, y = 300, font = "DM Sans", size = 120, fill = "#fde68a" }
end)

group({ filter = {                                                 -- embossed, lit text
  { "blur", std = 3, input = "SourceAlpha", result = "b" },
  { "specular_lighting", input = "b", surface_scale = 5, constant = 1, exponent = 20, color = "#fff",
    light = { "point", x = 300, y = 100, z = 200 }, result = "s" },
  { "composite", op = "in", input = "s", input2 = "SourceAlpha", result = "s2" },
  { "composite", op = "arithmetic", k = {0, 1, 1, 0}, input = "SourceGraphic", input2 = "s2" },
  region = { x = -0.1, y = -0.2, w = 1.2, h = 1.4 },
} }, function()
  text { "Shiny", x = 200, y = 300, font = "DM Sans", size = 120, fill = "#2563eb" }
end)
```

Primitives: `blur`, `offset`, `flood`, `composite` (`op = over|in|out|atop|xor|lighter|
arithmetic`, `k = {k1, k2, k3, k4}`), `merge`, `blend` (`mode`), `color_matrix`
(`type = matrix|saturate|hueRotate|luminanceToAlpha`, `values`), `drop_shadow` (dx, dy, std,
color, opacity), `component_transfer` (`r`, `g`, `b`, `a` = `{ type = identity|table|discrete|
linear|gamma, values, slope, intercept, amplitude, exponent, offset }`), `morphology`
(`operator = erode|dilate`, `radius = n | {rx, ry}`; fractional radii blend the next pixel ring
in, so animated radii move smoothly), `turbulence` (`type = turbulence|
fractalNoise`, `base_frequency = n | {fx, fy}`, `octaves`, `seed`, `stitch`),
`diffuse_lighting` / `specular_lighting` (`color`, `surface_scale`, `constant`, `exponent`,
`light = { "distant", azimuth, elevation } | { "point", x, y, z } | { "spot", x, y, z,
points_at = {x, y, z}, exponent, cone }`), `tile` (repeats its input's subregion),
`displacement_map` (`input2` = the map, `scale`, `x_channel`/`y_channel = R|G|B|A`),
`convolve_matrix` (`kernel` (at most 36 values), `order`, `target`, `divisor`, `bias`,
`edge = duplicate|wrap|none`, `preserve_alpha`) and `image` (`src`, `fit`, `align`). Any
primitive takes `subregion = {x, y, w, h}` (user units) to cut its result. Inputs default to
the previous result; `SourceGraphic` and `SourceAlpha` are built in. Computed in linear RGB
like SVG (`srgb = true` in the list to opt out). Without `region` a filter covers the whole
frame; give it one. Every primitive runs on the GPU (turbulence too), or on the CPU with
`--software`. Kinds also take their SVG element names (`feGaussianBlur`, `feTurbulence`, ...),
`merge` also takes `inputs = { ... }`, and `turbulence` also `num_octaves`.
