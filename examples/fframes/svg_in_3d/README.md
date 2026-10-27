# svg_in_3d

fframes' `svg-in-3d` example, written the onimite way: an svgr UI on the screen of a
turning 3D monitor, and in the UI a 3D render of its own, a cube with an svgr logo on its
faces. 1920x1080, 30 fps, 8 s, no audio. The frame nests four levels:

    logo -> cube (3D) -> UI -> monitor (3D) -> frame

```sh
onimite render examples/fframes/svg_in_3d/video.lua -o svg-in-3d.mp4
onimite preview examples/fframes/svg_in_3d/video.lua
```

- **The logo** never changes, so it is a `bake{}` image, drawn once with mipmaps, and the
  cube's `map`.
- **The UI** changes every frame (a timer, the frame number, a progress bar, the turning
  cube), so it is a panel of the monitor's view and the `map` of its unlit screen.
- **The studio light** is the original's `Environment::studio()`, a dim gradient and four
  softboxes, drawn by `studio.sksl` into an equirectangular `bake{}` and used as both views'
  `environment`.
- **The monitor** is a metal `MeshPhysicalMaterial` with a clear coat on a
  `RoundedBoxGeometry`, a stand and a base; the sun casts its shadow onto a
  `ShadowMaterial` floor.

What differs from fframes: o3d prefilters the studio for rough surfaces in its own way, so
the monitor's edge highlights are a little dimmer; the shadow covers a fixed square, where
fframes fits its map to the casters and cuts off the shadow's far end; the UI panel is
sampled without mipmaps, so the small text on the turned screen differs at its edges.

Fonts: DM Sans and JetBrains Mono, SIL Open Font License.
