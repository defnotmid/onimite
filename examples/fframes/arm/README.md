# arm

fframes' `arm` example, "FFRAMES, ASSEMBLED", written the onimite way: a 37 second film
about a lab robot with a camera eye. It wakes in the dark lab, its eye light searching the
floor; the lights flicker on; it spells `fframes` with letter pieces from a rack, gets too
confident, throws the "a" across the floor in a spin, sighs, picks it up carefully, puts it
in its place and bows. 1920x1080, 60 fps.

```sh
examples/fframes/fetch.sh     # needs fframes' arm-soundtrack (cargo build --release -p arm-example)
onimite render examples/fframes/arm/video.lua -o arm.mp4
```

The score and every sound effect are the original's: `fetch.sh` runs its `arm-soundtrack`
and copies the WAVs into `media/`; the film places them at the story's events.

- **The robot** (`arm.lua`) is a tree of groups, one a joint, with built-in geometries in
  each joint's frame (rounded boxes, a lathe, extruded plates and lettering, instanced bolts
  and fins) and analytic inverse kinematics on `mat4_*` transforms.
- **The lab** (`lab.lua`): the concrete's colour, roughness and normal maps, the floor paint
  and the screens are `bake{}` images drawn when the script loads; the studio light is the
  original's, baked by `studio.sksl` and used as the `environment`; the floor mirrors the
  scene through the view's `reflector`.
- **The performance** (`story.lua`) is a list of keys with the original's easings; the
  throw is `physics3d{}`, whose contacts place the clatters, sparks and camera shake.
- The beam is 16 additive cones, the dust and sparks are particle emitters, and each shot's
  `depth_of_field` keeps sharp what the original racks focus on.

What differs from fframes: the throw is Box3D's, so the letter lands on its face and the
robot picks it up from behind; the letters' slots follow Inter's kerning; there is no
motion blur on the swing (the original renders three moments of a half-open shutter); the
dust moves with the beam and the sparks are dots rather than bright streaks; the bins on
the shelves take onimite's `hash`. `inspect` reports `extrude_folded` on the 3D letters: o3d
insets their outlines for the bevel without a miter limit, so acute corners fold.

Fonts: Inter and IBM Plex Mono, SIL Open Font License.
