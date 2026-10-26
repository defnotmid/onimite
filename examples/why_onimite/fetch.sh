#!/bin/sh
# Gets the media this example doesn't commit into media/: run it once before
# rendering (media/.gitignore keeps them out of commits). A file already there
# is kept; delete it to get it again.
set -eu
cd "$(dirname "$0")"

# Made: transparent.mov, Pip dancing on alpha (ProRes 4444), rendered by
# onimite from tools/gen_media/mascot.lua and encoded by ffmpeg (gen.sh's
# `why_onimite` part, with $ONIMITE, build/onimite or onimite on the PATH).
[ -f media/transparent.mov ] || ../../tools/gen_media/gen.sh why_onimite
