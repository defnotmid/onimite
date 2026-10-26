#!/bin/sh
# Gets the media this example doesn't commit into media/: run it once before
# rendering (media/.gitignore keeps them out of commits). A file already there
# is kept; delete it to get it again.
set -eu
cd "$(dirname "$0")"

# Downloaded: the whooshes' recording, a CC0 sound from Freesound (its page
# gives its licence and author), checked against its SHA-256. To use another,
# change the line: its file name, the URL, its SHA-256 and who made it.
sum() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -c1-64; }
fetch() { # name url sha256 credit
	if [ -f "media/$1" ] && [ "$(sum "media/$1")" = "$3" ]; then return; fi
	curl -fsSL -o "media/$1" "$2"
	if [ "$(sum "media/$1")" != "$3" ]; then echo "fetch.sh: $1 isn't the file pinned here (from $2)" >&2; rm -f "media/$1"; exit 1; fi
	echo "fetched $1: $4"
}
fetch swoosh.mp3 https://cdn.freesound.org/previews/169/169867_2834921-hq.mp3 5cc27a658b5cdbbfed83c4986c5d94de98d83c146ac0158a43750d3cd77479ff "swoosh, Halgrimm (freesound.org/s/169867), CC0"

# Made: transparent.mov, Pip dancing on alpha (ProRes 4444), rendered by
# onimite from tools/gen_media/mascot.lua and encoded by ffmpeg (gen.sh's
# `onimite_saga` part, with $ONIMITE, build/onimite or onimite on the PATH).
[ -f media/transparent.mov ] || ../../tools/gen_media/gen.sh onimite_saga
