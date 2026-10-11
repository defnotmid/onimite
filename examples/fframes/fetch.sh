#!/bin/sh
# Copies the fframes files the ports use (assets.tsv) from the pinned fframes
# checkout, fetching it first if needed. Run once before rendering a port or
# running tools/bench.sh; run again after the pin in third_party/fetch.sh moves.
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$HERE/../.." && pwd)"
FF="$ROOT/third_party/fframes"

sh "$ROOT/third_party/fetch.sh"

grep -v '^#' "$HERE/assets.tsv" | while IFS="$(printf '\t')" read -r dst src; do
	mkdir -p "$(dirname -- "$HERE/$dst")"
	cp "$FF/$src" "$HERE/$dst"
done

# shader-mode's soundtrack is not in fframes' repository either, and fframes
# refuses to render without it: both sides get the same 31 s 220 Hz stand-in.
for wav in "$HERE/shader_mode/media/reference-audio.wav" "$FF/examples/shader-mode/dynamic_media/reference-audio.wav"; do
	[ -f "$wav" ] || ffmpeg -v error -f lavfi -i "sine=frequency=220:duration=31" -ar 48000 -ac 2 "$wav"
done
