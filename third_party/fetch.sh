#!/bin/sh
# Fetches the reference checkouts into third_party/ (not committed).
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

fetch_repo() {
	name="$1"
	url="$2"
	rev="$3"
	path="$ROOT_DIR/$name"

	if [ ! -d "$path/.git" ]; then
		git clone "$url" "$path"
	fi

	git -C "$path" fetch --tags origin
	git -C "$path" checkout --detach "$rev"
}

# The Rust original oframes ports and benchmarks against (tools/bench.sh).
fetch_repo "fframes" "https://github.com/dmtrKovalenko/fframes.git" "f962cd6df51d19fa06462d470fc57e90cc0f17b0"
