#!/bin/sh
# Downloads this example's sound effects into media/ and checks each against
# its SHA-256: CC0 recordings from Freesound (each sound's page gives its
# licence and author). They aren't in the repository: run this once before
# rendering (media/.gitignore keeps them out of commits); a file already
# there and matching is kept. To use another sound, add a line: its file name,
# the URL, its SHA-256 (sha256sum the file you checked) and who made it, and
# its name to media/.gitignore.
set -eu
cd "$(dirname "$0")/media"
sum() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -c1-64; }
fetch() { # name url sha256 credit
	if [ -f "$1" ] && [ "$(sum "$1")" = "$3" ]; then return; fi
	curl -fsSL -o "$1" "$2"
	if [ "$(sum "$1")" != "$3" ]; then echo "fetch.sh: $1 isn't the file pinned here (from $2)" >&2; rm -f "$1"; exit 1; fi
	echo "fetched $1: $4"
}
fetch pieces.mp3 https://cdn.freesound.org/previews/555/555190_2940947-hq.mp3 4de39768ccf07f5d34bb2b1f7ce73a544cfdf39a56edfa96077f26fe15781105 "Board Game Pieces, taure (freesound.org/s/555190), CC0"
