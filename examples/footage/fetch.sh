#!/bin/sh
# Makes this example's clips into media/: street.mp4 (9:16, 60 fps), surf.mp4
# (24 fps) and clip.mp4, rendered by onimite from tools/gen_media's scripts
# (gen.sh's `footage` part, with $ONIMITE, build/onimite or onimite on the PATH).
# They aren't in the repository: run this once before rendering
# (media/.gitignore keeps them out of commits); delete them to make them again.
set -eu
cd "$(dirname "$0")"
if [ -f media/street.mp4 ] && [ -f media/surf.mp4 ] && [ -f media/clip.mp4 ]; then exit 0; fi
exec ../../tools/gen_media/gen.sh footage
