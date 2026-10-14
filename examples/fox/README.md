# fox

A downloaded glTF model in `view3d{}`: the Khronos sample Fox, skinned, playing
its three clips (Survey, Walk, Run) while the camera orbits, then running again
with a `ShaderMaterial` override on the whole model (iridescent stripes and a
swell along the normals, on the skinned pose). 60 fps, 13.4 s.

```sh
onimite preview examples/fox/video.lua
onimite show examples/fox/video.lua media/Fox.glb   # its meshes, nodes and clips
```

`media/Fox.glb` comes from [glTF-Sample-Assets](https://github.com/KhronosGroup/glTF-Sample-Assets/tree/main/Models/Fox):
the model is CC0 (PixelMannen); its rigging and animations are CC-BY 4.0 by
[@tomkranis](https://sketchfab.com/tomkranis) (`LICENSES/CC-BY-4.0.txt`).
