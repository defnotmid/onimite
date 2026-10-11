#!/usr/bin/env bash
# Renders examples with the task pool and with --threads 1 and compares the
# decoded frames (ffmpeg framemd5) and sound (md5 of the decoded samples):
# the output must not depend on the thread count. Every render runs under `timeout` (a hang is a failure).
#
#   tools/threads_check.sh [example ...]      (default: the set below; names
#                                              not in examples/ are looked up in examples/fframes/)
#
# Env: BIN (build/onimite_speed), RANGE (0..90), CONFIGS ("gpu software native"),
#      LIMIT (seconds per render, 300). Exit 1 on any difference or timeout.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${BIN:-$ROOT/build/onimite_speed}"
RANGE="${RANGE:-0..90}"
LIMIT="${LIMIT:-300}"
CONFIGS="${CONFIGS:-gpu software native}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
export PIXEL_SONG="${PIXEL_SONG:-The_Farewell.mp3}"
EXAMPLES=("$@")
[ ${#EXAMPLES[@]} -eq 0 ] && EXAMPLES=(why_onimite suite data_story motion_poster social_clip_kit designer_handoff shadertoy_multipass captions_demo lottie_demo media_demo transitions audio_demo voiceover)

frames() { ffmpeg -v error -i "$1" -an -f framemd5 - | grep -v '^#'; }
sound() { ffmpeg -v error -i "$1" -vn -f md5 - 2>/dev/null; }
status=0
for ex in "${EXAMPLES[@]}"; do
  for cfg in $CONFIGS; do
    flags=()
    [ "$cfg" = software ] && flags=(--software)
    [ "$cfg" = native ] && flags=(--native)
    ok=1
    for t in pool one; do
      extra=()
      [ $t = one ] && extra=(--threads 1)
      if ! timeout "$LIMIT" "$BIN" render "$ROOT/$( [ -d "$ROOT/examples/$ex" ] && echo examples || echo examples/fframes )/$ex/video.lua" "$RANGE" -o "$OUT/$t.mp4" "${flags[@]}" "${extra[@]}" >/dev/null 2>&1; then
        echo "$ex $cfg: render with $t failed or timed out"; ok=0; status=1
      fi
    done
    if [ $ok = 1 ]; then
      if diff <(frames "$OUT/pool.mp4") <(frames "$OUT/one.mp4") >/dev/null &&
        [ "$(sound "$OUT/pool.mp4")" = "$(sound "$OUT/one.mp4")" ]; then
        echo "$ex $cfg: same"
      else
        echo "$ex $cfg: DIFFERENT"; status=1
      fi
    fi
    rm -f "$OUT"/*.mp4
  done
done
exit $status
