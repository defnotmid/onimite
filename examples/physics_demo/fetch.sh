#!/bin/sh
# Downloads this example's impact sounds into media/ and checks each against
# its SHA-256: CC0 recordings from Freesound (each sound's page gives its
# licence and author). They aren't in the repository: run this once before
# rendering (media/.gitignore keeps them out of commits). To use another, add
# a line: its file name, the URL, its SHA-256 and who made it.
set -eu
cd "$(dirname "$0")/media"
sum() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -c1-64; }
fetch() { # name url sha256 credit
	if [ -f "$1" ] && [ "$(sum "$1")" = "$3" ]; then return; fi
	curl -fsSL -o "$1" "$2"
	if [ "$(sum "$1")" != "$3" ]; then echo "fetch.sh: $1 isn't the file pinned here (from $2)" >&2; rm -f "$1"; exit 1; fi
	echo "fetched $1: $4"
}
fetch thud.mp3 https://cdn.freesound.org/previews/449/449955_9159316-hq.mp3 8f2d2c815df5c771d1fb8a97b9bea7bc75595b56de543e4922d76923303268c1 "Wooden Thud (Mono), Breviceps (freesound.org/s/449955), CC0"
fetch bounce.mp3 https://cdn.freesound.org/previews/423/423778_8326967-hq.mp3 46cbbee8bf23f20b388679d315cde434d7d8c14e551cc9d64e6fc2c6acdbf74c "Rubber ball bouncing, SomeoneCool15 (freesound.org/s/423778), CC0"
