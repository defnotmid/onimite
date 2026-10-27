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

# arm's score and effects aren't in fframes' repository either: its arm-soundtrack binary
# (built by `cargo build --release -p arm-example` in third_party/fframes, which
# tools/bench.sh facts and visual do) writes them into examples/arm/dynamic_media, and both sides
# play those files.
ARM_SOUNDS="$FF/examples/arm/dynamic_media"
if [ ! -f "$ARM_SOUNDS/music.wav" ]; then
	if [ -x "$FF/target/release/arm-soundtrack" ]; then
		( cd "$FF/examples/arm" && "$FF/target/release/arm-soundtrack" >/dev/null )
	else
		echo "fetch.sh: arm's sounds need fframes' arm-soundtrack: cd third_party/fframes && cargo build --release -p arm-example, then run fetch.sh again" >&2
	fi
fi
if [ -f "$ARM_SOUNDS/music.wav" ]; then
	mkdir -p "$HERE/arm/media"
	cp "$ARM_SOUNDS"/*.wav "$HERE/arm/media/"
fi
