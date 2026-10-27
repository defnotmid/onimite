#!/usr/bin/env bash
# Compile the encoder's RGBA -> NV12 compute pass (encode/gpu_nv12.odin) from
# Slang to SPIR-V (Vulkan) and MSL (Metal). Matrices are column-major in
# memory, as the Odin side uploads them. Windows runs SDL_GPU on Vulkan, so
# no DXIL. (The preview's UI is drawn by ovg, with ovg's shaders.)
#
# Requires slangc (https://shader-slang.org); only needed to edit shaders,
# the blobs are committed.
set -euo pipefail
cd "$(dirname "$0")"

FLAGS=(-matrix-layout-column-major -O2 -I .)

echo "Slang -> SPIR-V, MSL:"
# The encoder's RGBA -> NV12 compute pass (encode/gpu_nv12.odin).
slangc rgba_to_nv12.slang "${FLAGS[@]}" -entry cs_main -stage compute -target spirv -o rgba_to_nv12.comp.spv
slangc rgba_to_nv12.slang "${FLAGS[@]}" -entry cs_main -stage compute -target metal -o rgba_to_nv12.comp.msl
spirv-val --target-env vulkan1.2 rgba_to_nv12.comp.spv
echo "  rgba_to_nv12.slang:cs_main -> rgba_to_nv12.comp.{spv,msl}"
echo "Done."
