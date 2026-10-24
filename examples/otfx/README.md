# otfx

[otfx](https://github.com/defnotmid/otfx)'s terminal text effects, full screen:
the frame is the terminal's grid, the effect plays its ticks at otfx's 60 per
second on the text, then holds. Played bare and fullscreen, onimite runs it the
way Omarchy's screensaver runs ttfx in a fullscreen terminal.

```sh
onimite preview examples/otfx/video.lua --bare --fullscreen
# Omarchy's screensaver: its logo on its terminal's grid (Alacritty, font size 18, 5K at 1.6x)
onimite preview examples/otfx/video.lua --bare --fullscreen \
  --set cols=213 --set rows=60 --set text="$(cat ~/.config/omarchy/branding/screensaver.txt)"
onimite render examples/otfx/video.lua -o otfx.mp4
```

- `--set text=...`: the text (default: the ONIMITE banner, in the block letters
  of otfx's own banner, and a tagline), centred on the grid as `--anchor-text c`.
- `--set cols=N --set rows=M`: the grid (default 96×27, 20×40 px cells).
- `term.lua`: the grid the effects share, a seeded RNG over `hash`, and
  `term.cell`, which draws block elements (`█ ▀ ▄ ▉ ▌ ▐ ▓ ▒ ░`) as rects, as
  terminals do, and any other character as a JetBrains Mono glyph.
- `effects/NAME.lua`: one effect, ported from `otfx/src/effects/NAME.odin`.
  `build(cells, seed)` makes the effect's random draws once at load, into
  columns per character, and returns `{ ticks, draw(tick) }`; `draw` reads the
  tick off those columns, so any frame renders on its own.
- `video.lua`: one scene per effect (`effect_scene(name, fx)`).

Effects so far: `decrypt`, `burn` and `thunderstorm`. The last two keep otfx's
timeline and add what a terminal can't draw:

- `burn`: otfx's ignition order (a random growth through the text block) and
  palette, with real fire. Each frame the burning cells are drawn as a heat map
  (red: flame, green: smoke, softened by a blur) that an SkSL shader reads: the
  heat below a point rises to it through turbulent noise, takes a blackbody
  ramp, carves into tongues, and smoke curls above. The fire lights the wall
  behind it, and the scene blooms.
- `thunderstorm`: otfx's storm (rain, branching bolts of `\ / |`, sparks,
  struck letters, the fades), lit as a real one. Each flash flickers as a
  bolt's return strokes do and lights the clouds over it; every glyph is lit by
  its distance to the bolt's channel (half at 170 px), struck letters glow
  white-hot and cool through orange to red, the channel has its own soft glow,
  rain and sparks move between cells, and what is bright blooms. Its cipher alphabet stops at Latin Extended-A
(otfx's goes on into Latin Extended-B, which JetBrains Mono does not draw).
To add one, write `effects/NAME.lua` with the same `build` and add
`effect_scene("NAME", require("effects.NAME").build(cells, 1))` to `video.lua`.
