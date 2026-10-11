#!/usr/bin/env bash
# Compile the preview UI's Slang modules to SPIR-V (Vulkan) and MSL (Metal)
# for each stage; the entry points are `vs_main` and `fs_main`. Matrices are
# column-major in memory, as the Odin side uploads them. Ported from
# ../paf/shaders/build.sh. Windows runs SDL_GPU on Vulkan, so no DXIL.
#
# Requires slangc (https://shader-slang.org); only needed to edit shaders,
# the blobs are committed.
set -euo pipefail
cd "$(dirname "$0")"

UNITS=(
	rect2d:vert:vs_main rect2d:frag:fs_main
)
FLAGS=(-matrix-layout-column-major -O2 -I .)

echo "Slang -> SPIR-V, MSL:"
for unit in "${UNITS[@]}"; do
	IFS=: read -r m suffix entry <<<"$unit"
	slangc "$m.slang" "${FLAGS[@]}" -entry "$entry" -target spirv -o "$m.$suffix.spv"
	slangc "$m.slang" "${FLAGS[@]}" -entry "$entry" -target metal -o "$m.$suffix.msl"
	echo "  $m.slang:$entry -> $m.$suffix.{spv,msl}"
done
# The encoder's RGBA -> NV12 compute pass (encode/gpu_nv12.odin).
slangc rgba_to_nv12.slang "${FLAGS[@]}" -entry cs_main -stage compute -target spirv -o rgba_to_nv12.comp.spv
slangc rgba_to_nv12.slang "${FLAGS[@]}" -entry cs_main -stage compute -target metal -o rgba_to_nv12.comp.msl
spirv-val --target-env vulkan1.2 rgba_to_nv12.comp.spv
echo "  rgba_to_nv12.slang:cs_main -> rgba_to_nv12.comp.{spv,msl}"
rm -f *.vert *.frag
echo "Done."
