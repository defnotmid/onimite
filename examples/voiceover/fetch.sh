#!/bin/sh
# Downloads this example's sound effects into media/ and checks each
# against its SHA-256. They are CC0 recordings from Freesound (each sound's
# page gives its licence and author) and aren't in the repository: run this
# once before rendering (media/.gitignore keeps them out of commits). To use
# another sound, add a line: its file name, the URL, its SHA-256 (sha256sum the
# file you checked) and who made it, and its name to media/.gitignore.
set -eu
cd "$(dirname "$0")/media"
sum() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -c1-64; }
fetch() { # name url sha256 credit
	if [ -f "$1" ] && [ "$(sum "$1")" = "$3" ]; then return; fi
	curl -fsSL -o "$1" "$2"
	if [ "$(sum "$1")" != "$3" ]; then echo "fetch.sh: $1 isn't the file pinned here (from $2)" >&2; rm -f "$1"; exit 1; fi
	echo "fetched $1: $4"
}
fetch steps.mp3 https://cdn.freesound.org/previews/452/452421_9398458-hq.mp3 385e1c7593dbb24cc2e2f3d3151bd8e78a6427cec28a5afd543bce4408ebe874 "Metal Stairs Foot Steps, sagamusix (freesound.org/s/452421), CC0"
fetch match.mp3 https://cdn.freesound.org/previews/248/248236_4056007-hq.mp3 5ea2469d43e4d2bbae75f2a798df0a38d91e5cec470f6b853728d916340716ac "Match - Strike and Light 02, JarredGibb (freesound.org/s/248236), CC0"
fetch flame.mp3 https://cdn.freesound.org/previews/186/186374_2421128-hq.mp3 0c130f9a45747d648ce6bf2f6351fded5ab860e2187cf91fd40a8aaf1cd674d1 "Bonfire Being Lit, samararaine (freesound.org/s/186374), CC0"
fetch whoosh.mp3 https://cdn.freesound.org/previews/60/60013_71257-hq.mp3 ebdb219e7f36f7e1aecdb045d6d8bdad059119af319863777c7302a69fa41a92 "Whoosh, qubodup (freesound.org/s/60013), CC0"
fetch sea.mp3 https://cdn.freesound.org/previews/465/465435_5902878-hq.mp3 4797a5bfa66d30ac7e1cf175ca0e0b5af35cca3661abf57133fa4c3990286001 "Ocean beach at night with small waves, BonnyOrbit (freesound.org/s/465435), CC0"
