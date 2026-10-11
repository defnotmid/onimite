# transitions

Every transition of the standard library (`script/std.lua`) in 12 seconds:
seven cards, each entering by the transition it names over its overlap with
the card before (`scene{ ..., transition = { kind, duration, easing, ... } }`),
which leaves by the same one: fade, slide (spring timing), wipe (soft edge),
clock_wipe, zoom and glitch. Inside each card the dots and letters pop with
`stagger(..., { from = "center" })`, the caption comes in through a
`sequence` and the corner dial turns with `loop`.

```sh
onimite render examples/transitions/video.lua -o transitions.mp4
```

Fonts (OFL): Bebas Neue and JetBrains Mono, copied from
why_onimite.
