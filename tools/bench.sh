#!/usr/bin/env bash
# Benchmark fframes (Rust) against onimite (Odin + Lua) on the same examples.
#
#   tools/bench.sh facts [TAG]     the race, onimite's own rows and every example, measured on onimite's release TAG
#                                  (default: the latest) -> bench/facts.json and BENCHMARK.md's tables
#   tools/bench.sh facts BINARY    the same on a local build -> $OUT/facts.json and the tables printed; bench/ is left alone
#   tools/bench.sh setup           what fframes and Remotion install before their first frame -> bench/facts.json
#   tools/bench.sh visual          the same frames from both sides (VSPECS): PSNR/SSIM and montages in $OUT
#   tools/bench.sh md              BENCHMARK.md's tables again from bench/facts.json
#
# Env: RUNS (3), OUT (.work/bench), OF (visual's onimite: build/onimite), BENCH_ONLY (substring filter on pair and
#      example names), BENCH_FFRAMES=1 (measure fframes' side again), BENCH_ROWS (facts: the rows to measure again,
#      race names, FACT_ROWS ids and example:NAME; every other row is kept from bench/facts.json with the release
#      that measured it, when that was this machine: what a release changed, measured without the rest).
# Needs: cargo, ffmpeg/ffprobe, python3, /usr/bin/time (GNU); facts: gh; setup: curl, docker.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FF="$ROOT/third_party/fframes"
FFBIN="$FF/target/release"
OF="${OF:-$ROOT/build/onimite}"
OUT="${OUT:-$ROOT/.work/bench}"

# Pairs: name | fframes crate | fframes binary | fframes extra args | onimite script (relative to $ROOT) | onimite env (K=V ...)
# Add a line to add a pair. Both sides must produce the same size/fps/duration.
PAIRS=(
  "hello_world|hello-world-example|hello_world_example_bin|--slug onimite|examples/fframes/hello_world/video.lua|"
  "signal_lab|signal-lab|signal-lab||examples/fframes/signal_lab/video.lua|"
  "motion_graphics|motion-graphics-example|motion_graphics_example_bin||examples/fframes/motion_graphics/video.lua|"
  "mg_install|motion-graphics-example|install_scene||examples/fframes/motion_graphics/install.lua|"
  "mg_quote|motion-graphics-example|quote||examples/fframes/motion_graphics/quote.lua|"
  "conference|conference-splash-screen-example|conference_splash_screen_bin||examples/fframes/conference_splash_screen/video.lua|"
  "low_poly_art|low-poly-art-example|low_poly_art_example_bin||examples/fframes/low_poly_art/video.lua|"
  "beta|beta-example|beta_example_bin||examples/fframes/beta/video.lua|"
  "marketing|marketing-example|marketing-example||examples/fframes/marketing/video.lua|"
  "podcast|podcast-example|podcast_example_bin||examples/fframes/podcast/video.lua|"
  "tiktok|tiktok-example|tiktok_example_bin||examples/fframes/tiktok/video.lua|"
  "teej_podcast|teej_podcast_example|teej_podcast_example_bin||examples/fframes/teej_podcast/video.lua|"
  "audio_announce|audio-announce-example|audio_announce_example_bin||examples/fframes/audio_announce/video.lua|"
  "pixel_memory|pixel-example|pixel_memory_example_bin|--song The_Farewell.mp3|examples/fframes/pixel_memory/video.lua|PIXEL_SONG=The_Farewell.mp3"
  "shaders|shaders-example|shaders_example_bin||examples/fframes/shaders/video.lua|"
  "neon_triangle|neon-triangle-example|neon_triangle_example_bin||examples/fframes/neon_triangle/video.lua|"
  "fframes_intro|fframes-intro|fframes-intro||examples/fframes/fframes_intro/video.lua|"
  "made_of_motion|made-of-motion|made-of-motion||examples/fframes/made_of_motion/video.lua|"
  "shader_mode|shader-mode|shader-mode||examples/fframes/shader_mode/video.lua|"
  "svg_in_3d|svg-in-3d-example|svg-in-3d||examples/fframes/svg_in_3d/video.lua|"
  "lottie_launch|lottie-launch|lottie-launch||examples/fframes/lottie_launch/video.lua|"
  "arm|arm-example|arm||examples/fframes/arm/video.lua|"
)

# Frame specs for the visual comparison, per pair name.
declare -A VSPECS=(
  [hello_world]="start,10%,25%,50%,75%,end"
  [signal_lab]="start,25%,50%,75%,end,Product@50%,Data,Data@50%,System,Final"
  [motion_graphics]="start,10%,25%,40%,50%,75%,end"
  [mg_install]="start,10%,25%,50%,75%,end"
  [mg_quote]="start,25%,50%,75%,end"
  [shader_mode]="start,25%,50%,75%,end,Glass@1,Tunnel@4,ShaderLibrary@30,Flow@28,ShaderModeZoom@23,Eclipse@100"
)
for p in conference low_poly_art beta marketing podcast tiktok teej_podcast audio_announce pixel_memory shaders neon_triangle fframes_intro made_of_motion svg_in_3d lottie_launch arm; do
  VSPECS[$p]="start,25%,50%,75%,end"
done

mkdir -p "$OUT/work"
pair_sel() { local p; for p in "${PAIRS[@]}"; do [[ -z "${BENCH_ONLY:-}" || "${p%%|*}" == *"$BENCH_ONLY"* ]] && row_sel "${p%%|*}" && echo "$p"; done; return 0; }
row_sel() { [ -z "${BENCH_ROWS:-}" ] || [[ " $BENCH_ROWS " == *" $1 "* ]]; } # in BENCH_ROWS (all when unset)

# Each example crate alone, as a user builds it (together, cargo would merge their features). A crate whose
# prebuilt FFmpeg doesn't link against this machine's x264 is built again with FFmpeg from source
# (FFMPEG_FORCE_BUILD=1), as fframes' README says, and added to $OUT/ffmpeg_from_source.
build_fframes() { # crate...
  local c
  for c in "$@"; do
    ( cd "$FF" && unset CARGO_TARGET_DIR
      cargo build --release -p "$c" > "$OUT/build.log" 2>&1 && exit 0
      grep -q 'undefined symbol: x264_' "$OUT/build.log" || { tail -20 "$OUT/build.log" >&2; exit 1; }
      echo "$c" >> "$OUT/ffmpeg_from_source"
      # the prebuilt FFmpeg stays in place unless its crate is cleaned first
      cargo clean --release -p ffmpeg-sys-fframes > /dev/null 2>&1
      FFMPEG_FORCE_BUILD=1 cargo build --release -p "$c" )
  done
}

# Every example's media; after build_fframes: the ports' arm sounds come from fframes' arm-soundtrack.
fetch_media() { local f; for f in "$ROOT"/examples/*/fetch.sh; do sh "$f" >/dev/null; done; }

# run_one <outfile> <cmd...>  -> prints "wall user sys rss_kb bytes", all 0 when it fails (KEEP_LOG: where to keep its output)
run_one() {
  local out="$1" tf; shift
  tf="$(mktemp "$OUT/time.XXXXXX")"
  rm -f "$out"
  if ( cd "${RUN_DIR:-$OUT/work}" && /usr/bin/time -f '%e %U %S %M' -o "$tf" "$@" >"$tf.log" 2>&1 ); then
    echo "$(cat "$tf") $(stat -c %s "$out" 2>/dev/null || echo 0)"
  else
    echo "FAILED: $*" >&2; tail -5 "$tf.log" >&2; echo "0 0 0 0 0"
  fi
  [ -z "${KEEP_LOG:-}" ] || cp "$tf.log" "$KEEP_LOG"
  rm -f "$tf" "$tf.log"
}

exdir() { # the fframes example directory of a crate (binaries find their media relative to it)
  local t; t="$(grep -l "^name = \"$1\"" "$FF"/examples/*/Cargo.toml | head -1)"
  echo "${t%/Cargo.toml}"
}

vcmp() { # "psnr ssim" of two whole videos, compared in 4:2:0
  local psnr ssim
  psnr=$(ffmpeg -nostdin -hide_banner -i "$1" -i "$2" -lavfi "[0:v]format=yuv420p[a];[1:v]format=yuv420p[b];[a][b]psnr" -f null - 2>&1 | grep -o 'average:[^ ]*' | cut -d: -f2 || true)
  ssim=$(ffmpeg -nostdin -hide_banner -i "$1" -i "$2" -lavfi "[0:v]format=yuv420p[a];[1:v]format=yuv420p[b];[a][b]ssim" -f null - 2>&1 | grep -o 'All:[^ ]*' | cut -d: -f2 || true)
  echo "$psnr $ssim"
}

# ---- visual comparison: same frames from both sides, PSNR/SSIM, fframes | onimite | diff(x4) ----
do_visual() {
  mkdir -p "$OUT/frames" "$OUT/montage"
  sh "$ROOT/third_party/fetch.sh" >/dev/null
  build_fframes $(pair_sel | cut -d'|' -f2 | sort -u)
  fetch_media
  printf 'pair\tframe\tpsnr_db\tssim\n' > "$OUT/visual.tsv"
  local name crate bin fargs script oenv d specs f b psnr ssim
  while IFS='|' read -r name crate bin fargs script oenv; do
    echo "== $name" >&2
    d="$OUT/frames/$name"; rm -rf "${d:?}"; mkdir -p "$d"
    specs="${VSPECS[$name]}"
    ( cd "$(exdir "$crate")" && "$FFBIN/$bin" frame $fargs "$specs" -o "$d/f" >/dev/null 2>&1 )
    env $oenv "$OF" frame "$ROOT/$script" "$specs" -o "$d/o" >/dev/null 2>&1
    for f in "$d"/f/*.png; do
      b="$(basename "$f" .png)"
      [ -f "$d/o/$b.png" ] || { echo "missing onimite frame $b" >&2; continue; }
      psnr=$(ffmpeg -nostdin -hide_banner -i "$f" -i "$d/o/$b.png" -lavfi "[0:v]format=rgb24[a];[1:v]format=rgb24[b];[a][b]psnr" -f null - 2>&1 | grep -o 'average:[^ ]*' | cut -d: -f2)
      ssim=$(ffmpeg -nostdin -hide_banner -i "$f" -i "$d/o/$b.png" -lavfi "[0:v]format=rgb24[a];[1:v]format=rgb24[b];[a][b]ssim" -f null - 2>&1 | grep -o 'All:[^ ]*' | cut -d: -f2)
      printf '%s\t%s\t%s\t%s\n' "$name" "$b" "$psnr" "$ssim" | tee -a "$OUT/visual.tsv"
      ffmpeg -nostdin -y -v error -i "$f" -i "$d/o/$b.png" -filter_complex \
"[0:v]format=rgb24,split[x1][x2];[1:v]format=rgb24,split[y1][y2];\
[x2][y2]blend=all_mode=difference,lutrgb=r=val*4:g=val*4:b=val*4,scale=640:-1[c];\
[x1]scale=640:-1[a];[y1]scale=640:-1[b];[a][b][c]hstack=inputs=3" -frames:v 1 "$OUT/montage/${name}_${b}.png"
    done
  done < <(pair_sel)
}

# ---- facts: the numbers the films and the site quote, measured on a published release ----
# The race (PAIRS), FACT_ROWS, every example (as the site renders its cards) and the release's archives;
# BENCHMARK.md's Method says how each is measured. $OUT/facts/runs.tsv has every run.
FACT_ROWS=( # id | output to count (_OUT_ is $OUT/facts) | onimite's arguments, scripts relative to $SRC
  "saga_frame|_OUT_/frame/3000.png|frame examples/onimite_saga/video.lua 3000 -o _OUT_/frame"
  "saga_inspect|_OUT_/none|inspect examples/onimite_saga/video.lua"
  "saga_inspect_all|_OUT_/none|inspect examples/onimite_saga/video.lua --all-frames"
  "otfx_burn_software|_OUT_/otfx_sw.mp4|render examples/otfx/video.lua burn@0..burn@3s --software -o _OUT_/otfx_sw.mp4"
)
EXAMPLE_SETS=( # name | example | its --set: the variants the site shows a card for, beside each example's default
  "social_clip_kit_16x9|social_clip_kit|format=16x9"
)
example_rows() { # FACT_ROWS of every example in $SRC, id example:<name>
  local d name row
  for d in "$SRC"/examples/*/video.lua; do
    name="$(basename "$(dirname "$d")")"
    echo "example:$name|_OUT_/ex_$name.mp4|render examples/$name/video.lua --qp 22 -o _OUT_/ex_$name.mp4"
  done
  for row in "${EXAMPLE_SETS[@]}"; do
    IFS='|' read -r name d args <<< "$row"
    echo "example:$name|_OUT_/ex_$name.mp4|render examples/$d/video.lua --qp 22 --set $args -o _OUT_/ex_$name.mp4"
  done
}
FACT_COLS='id\timpl\trun\twall_s\tuser_s\tsys_s\trss_kb\tbytes\tframes\tduration_s\twidth\theight\tfps\tothers_cpu_s\tothers_gpu_s\tredone\tdate\tnote'

finfo() { # "frames duration width height fps" of a video, tab separated; blanks when it isn't one
  ffprobe -v error -select_streams v:0 -count_packets -of default=nw=1 \
    -show_entries stream=nb_read_packets,width,height,r_frame_rate:format=duration "$1" 2>/dev/null |
    awk -F= '{v[$1] = $2} END {split(v["r_frame_rate"], r, "/"); OFS = "\t"
      if (v["duration"] + 0 > 0) print v["nb_read_packets"], v["duration"], v["width"], v["height"], r[1] / r[2]; else print "", "", "", "", ""}'
}

machine() { # "cpu|gpu|mesa": what fframes' reused rows must have been measured on
  printf '%s|%s|%s' "$(lscpu | sed -n 's/^Model name: *//p' | head -1)" \
    "$( (clinfo 2>/dev/null | sed -n 's/^ *Device Name *\([^(]*\).*/\1/p' | head -1 | sed 's/ *$//') || true)" \
    "$( (pacman -Q mesa 2>/dev/null || true) | awk '{print $2}' | sed 's/^[0-9]*://; s/-[0-9]*$//')"
}

cpu_ticks() { # "busy kthreads": the machine's busy CPU (user, nice, system) and its kernel threads' (work for a run: writeback, the GPU driver), in clock ticks
  python3 -I -c '
import os
k = 0
for p in os.listdir("/proc"):
    try:
        r = open("/proc/" + p + "/stat").read() if p.isdigit() else ""
    except OSError:
        continue
    r = r[r.rindex(")") + 2:].split() if r else []
    if r and int(r[6]) & 0x00200000:
        k += int(r[11]) + int(r[12])
c = open("/proc/stat").readline().split()
print(int(c[1]) + int(c[2]) + int(c[3]), k)'
}

gpu_clients() { # "pid:client ns" for every GPU client of this user's processes: its engines' busy time (DRM fdinfo drm-engine-*)
  python3 -I -c '
import os
for p in os.listdir("/proc"):
    if not p.isdigit():
        continue
    seen = set()
    try:
        fds = os.listdir("/proc/" + p + "/fdinfo")
    except OSError:
        continue
    for fd in fds:
        try:
            lines = open("/proc/" + p + "/fdinfo/" + fd).read().splitlines()
        except OSError:
            continue
        f = dict(l.split(":", 1) for l in lines if ":" in l)
        cid = f.get("drm-client-id", "").strip()
        if not cid or cid in seen:
            continue
        seen.add(cid)
        ns = sum(int(v.split()[0]) for k, v in f.items() if k.startswith("drm-engine-") and v.split())
        print(p + ":" + cid, ns)'
}

wait_idle() { # until other processes use under half a core and the GPU is under 10% busy
  local b0 b1 gpu waited=0 tck; tck="$(getconf CLK_TCK)"
  while :; do
    b0="$(cpu_ticks | awk '{print $1 - $2}')"; sleep 1; b1="$(cpu_ticks | awk '{print $1 - $2}')"
    gpu="$(cat /sys/class/drm/card*/device/gpu_busy_percent 2>/dev/null | sort -n | tail -1)"
    [ $(( 2 * (b1 - b0) )) -lt "$tck" ] && [ "${gpu:-0}" -lt 10 ] && return
    [ $(( waited % 30 )) -ne 0 ] || echo "   waiting for an idle machine: $(( (b1 - b0) * 10 / tck ))/10 cores busy, GPU ${gpu:-?}%" >&2
    waited=$(( waited + 1 ))
  done
}

fact_run() { # id impl round outfile cmd...  -> a row of $OUT/facts/runs.tsv
  local id="$1" impl="$2" r="$3" out="$4" res others gpu t0 note="" redone=-1; shift 4
  while :; do
    redone=$(( redone + 1 ))
    wait_idle
    # A GPU idle for half a minute takes about 0.1 s to wake: every run starts on a woken one.
    [ -z "${WAKE:-}" ] || ( cd "$SRC" && $WAKE >/dev/null 2>&1 ) || true
    rm -f "$OUT/facts/log"
    gpu_clients > "$OUT/facts/gpu0"
    # after the scan, which is this script's own work (it read every process's fdinfo)
    t0="$(cpu_ticks)"
    res=$(KEEP_LOG="$OUT/facts/log" run_one "$out" "$@")
    # Other work's CPU seconds during the run: the machine's busy time, less the kernel threads' and the run's own.
    others="$(echo "$t0 $(cpu_ticks) $(getconf CLK_TCK) $res" | awk '{o = (($3 - $1) - ($4 - $2)) / $5 - $7 - $8; printf "%.2f", o < 0 ? 0 : o}')"
    # Other work's GPU seconds: every client's engine time since, the run's own aside (it has exited).
    gpu="$(gpu_clients | awk 'NR == FNR {a[$1] = $2; next} {d = $2 - a[$1]; if (d > 0) s += d} END {printf "%.2f", s / 1e9}' "$OUT/facts/gpu0" -)"
    # Failed (wall 0), or others used under half a core and the GPU under a tenth of the run, on average: keep it.
    # Over half a core, a sub-second GPU-bound render ran up to 65% slow (v0.0.63's first run).
    echo "$res $others $gpu" | awk '{exit !($1 == 0 || ($6 < 0.5 * $1 && $7 < 0.1 * $1))}' && break
    echo "   $id ($impl) overlapped ${others} s of other work's CPU, ${gpu} s of its GPU: again" >&2
  done
  note="$(grep -oE 'checked [0-9]+ frames' "$OUT/facts/log" | grep -oE '[0-9]+' | head -1 || true)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$impl" "$r" "$(echo $res | tr ' ' '\t')" "$(finfo "$out")" \
    "$others" "$gpu" "$redone" "$(date +%F)" "$note" >> "$OUT/facts/runs.tsv"
}

do_facts() {
  local arg="${1:-}" tag rel="" oni dest md reuse name crate bin fargs script oenv row id out args here
  local -A fresh=() failed=()
  if [ -n "$arg" ] && [ -f "$arg" ]; then
    oni="$(realpath "$arg")"; tag="$("$oni" --version | awk '{print $2}')"
    dest="$OUT/facts.json"; md=-
  else
    tag="$arg"
    [ -n "$tag" ] || tag="$(gh release view -R defnotmid/onimite --json tagName -q .tagName)"
    rel="$OUT/release/$tag"
    mkdir -p "$rel"
    gh release download "$tag" -R defnotmid/onimite -D "$rel" --clobber -p SHA256SUMS -p "onimite-$tag-*.tar.gz" -p "onimite-$tag-*.zip"
    ( cd "$rel" && sha256sum --check --ignore-missing --quiet SHA256SUMS )
    tar -xzf "$rel/onimite-$tag-linux-x86_64.tar.gz" -C "$rel"
    oni="$rel/onimite-$tag-linux-x86_64/onimite"
    "$oni" --version | grep -qF "$tag" || { echo "$oni doesn't say it is $tag" >&2; exit 1; }
    dest="$ROOT/bench/facts.json"; md="$ROOT/BENCHMARK.md"
  fi
  # The scripts timed: a release's own (its tree's examples, bench and skills, which they read, with
  # the fetched media linked in below), or the working tree's for a build.
  SRC="$ROOT"
  if [ -n "$rel" ]; then
    SRC="$OUT/src/$tag"
    rm -rf "${SRC:?}"; mkdir -p "$SRC"
    git -C "$ROOT" archive "$tag" examples bench skills | tar -x -C "$SRC"
  fi
  mkdir -p "$OUT/facts/race" "$OUT/facts/frame"
  WAKE="$oni frame examples/scenes/video.lua 0 -o $OUT/facts/wake.png"
  printf "$FACT_COLS\n" > "$OUT/facts/runs.tsv"
  : > "$OUT/ffmpeg_from_source"
  local -a rows=() all=("${FACT_ROWS[@]}")
  mapfile -t -O "${#all[@]}" all < <(example_rows | awk -F'|' -v o="${BENCH_ONLY:-}" 'o == "" || index($1, o)')
  for row in "${all[@]}"; do row_sel "${row%%|*}" && rows+=("$row"); done
  sh "$ROOT/third_party/fetch.sh" >/dev/null
  # fframes' rows: reused from bench/facts.json when they were measured at this commit on this machine.
  here="$(git -C "$FF" rev-parse HEAD)|$(machine)"
  [ -n "${BENCH_FFRAMES:-}" ] || reuse="$(python3 -I - "$ROOT/bench/facts.json" "$here" <<'EOF' 2>/dev/null || true
import json, sys
f = json.load(open(sys.argv[1]))
ff = f["measured"]["fframes"]
if ff["commit"] + "|" + ff["machine"] == sys.argv[2]:
    for r in f["race"]["rows"]:
        if r["fframes"]: print(r["name"], "failed" if "failed" in r["fframes"] else "ok")
EOF
)"
  while IFS='|' read -r name crate bin fargs script oenv; do
    case "$(awk -v n="$name" '$1 == n {print $2}' <<< "${reuse:-}")" in
      failed) failed[$name]=1 ;;
      ok) [ -s "$OUT/facts/race/${name}_fframes.mp4" ] || fresh[$name]=1 ;;
      *) fresh[$name]=1 ;;
    esac
  done < <(pair_sel)
  build_fframes $(for name in "${!fresh[@]}"; do pair_sel | awk -F'|' -v n="$name" '$1 == n {print $2}'; done | sort -u)
  fetch_media
  [ "$SRC" = "$ROOT" ] || ( cd "$ROOT" && git ls-files -z -o -i --exclude-standard -- examples | xargs -0 -r cp -l --parents -t "$SRC" )
  echo "== warm-up (fframes measured for: ${!fresh[*]})" >&2
  while IFS='|' read -r name crate bin fargs script oenv; do
    [ -z "${failed[$name]:-}" ] || continue
    if [ -n "${fresh[$name]:-}" ] && ! ( cd "$(exdir "$crate")" && "$FFBIN/$bin" render 0s..1s $fargs -o "$OUT/facts/warm.mp4" >/dev/null 2>&1 ); then
      echo "   fframes fails to render $name: not timed" >&2
      failed[$name]=1
      printf "%s\tfframes\t1\t0\t0\t0\t0\t0\t\t\t\t\t\t\t0\t%s\tfails\n" "$name" "$(date +%F)" >> "$OUT/facts/runs.tsv"
      continue
    fi
    ( cd "$SRC" && env $oenv "$oni" render "$SRC/$script" 0s..1s -o "$OUT/facts/warm.mp4" >/dev/null 2>&1 ) || true
  done < <(pair_sel)
  local -a w
  for row in "${rows[@]}"; do
    IFS='|' read -r id out args <<< "$row"
    read -r -a w <<< "${args//_OUT_/$OUT/facts}"
    # a render warms on its first second, unless it names its own range
    [ "${w[0]}" != render ] || [[ "${w[2]}" == *..* ]] || w=(render "${w[1]}" 0s..1s "${w[@]:2}")
    ( cd "$SRC" && "$oni" "${w[@]}" >/dev/null 2>&1 ) || true
  done
  for r in $(seq 1 "${RUNS:-3}"); do
    echo "== round $r" >&2
    while IFS='|' read -r name crate bin fargs script oenv; do
      [ -z "${failed[$name]:-}" ] || continue
      if [ -n "${fresh[$name]:-}" ]; then
        out="$OUT/facts/race/${name}_fframes.mp4"
        RUN_DIR="$(exdir "$crate")" fact_run "$name" fframes "$r" "$out" "$FFBIN/$bin" render $fargs -o "$out"
      fi
      out="$OUT/facts/race/${name}_onimite.mp4"
      RUN_DIR="$SRC" fact_run "$name" onimite "$r" "$out" env $oenv "$oni" render "$SRC/$script" -o "$out"
    done < <(pair_sel)
    for row in "${rows[@]}"; do
      IFS='|' read -r id out args <<< "$row"
      RUN_DIR="$SRC" fact_run "$id" onimite "$r" "${out//_OUT_/$OUT/facts}" "$oni" ${args//_OUT_/$OUT/facts}
    done
  done
  printf 'pair\tpsnr_db\tssim\n' > "$OUT/facts/quality.tsv"
  while IFS='|' read -r name crate bin fargs script oenv; do
    [ -z "${failed[$name]:-}" ] && [ -s "$OUT/facts/race/${name}_fframes.mp4" ] && [ -s "$OUT/facts/race/${name}_onimite.mp4" ] || continue
    printf '%s\t%s\n' "$name" "$(vcmp "$OUT/facts/race/${name}_fframes.mp4" "$OUT/facts/race/${name}_onimite.mp4" | tr ' ' '\t')" >> "$OUT/facts/quality.tsv"
  done < <(pair_sel)
  facts_write "$dest" "$tag" "$rel" "$here"
  facts_md "$dest" "$md"
}

facts_save() { # facts as JSON on stdin -> the file $1, a line for each race row, onimite row, example, archive and install
  python3 -I -c '
import json, sys
def dump(x, d=0):
    pad = "\n" + " " * (d + 1)
    if isinstance(x, dict) and d < 2:
        return "{" + ",".join(pad + json.dumps(k) + ": " + dump(v, d + 1) for k, v in x.items()) + "\n" + " " * d + "}"
    if isinstance(x, list) and d < 3 and x and isinstance(x[0], dict):
        return "[" + ",".join(pad + json.dumps(v) for v in x) + "\n" + " " * d + "]"
    return json.dumps(x)
s = dump(json.load(sys.stdin))
open(sys.argv[1], "w").write(s + "\n")' "$1"
}

facts_write() { # dest tag release-dir fframes-provenance: facts.json from $OUT/facts' runs and bench/facts.json's reused fframes rows
  # A release's scripts are its tag's; a build's are the working tree's, changed or not.
  local examples="$2" changed=0
  if [ -z "$3" ]; then
    examples="$(git -C "$ROOT" describe --tags --always HEAD)"
    [ -z "$(git -C "$ROOT" status --porcelain -- examples)" ] || changed=1
  fi
  python3 -I - "$ROOT" "$OUT/facts" "$2" "$3" "$4" "$(git -C "$FF" describe --tags --exact-match 2>/dev/null || true)" \
    "$examples" "$changed" "$(uname -sr)" "${BENCH_ROWS:-}" \
    "$(awk '/MemTotal/ {print $2 * 1024}' /proc/meminfo)" "$(printf '%s\n' "${FACT_ROWS[@]}" | cut -d'|' -f1)" \
    "$(pair_sel | awk -F'|' '{print $1 ":" $2}')" "$(cat "$OUT/ffmpeg_from_source")" <<'EOF' | facts_save "$1"
import sys, csv, json, os, re, glob, datetime, statistics as st, tarfile, zipfile
root, out, tag, rel, ffhere, fftag, examples, changed, osname, bench_rows, ram, ids, pairs, built_from_source = sys.argv[1:]
ffcommit, cpu, gpu, mesa = ffhere.split("|")
path = f"{root}/bench/facts.json"
old = json.load(open(path)) if os.path.exists(path) else {}
old_ff = old.get("measured", {}).get("fframes", {})
old_race = {r["name"]: r for r in old.get("race", {}).get("rows", [])}
# BENCH_ROWS: the rows not measured again are kept, each with the release that measured it, from a run on this
# machine only (a row measured elsewhere can't stand beside these)
partial = bench_rows.split()
old_on = old.get("measured", {}).get("onimite", {})
old_tag = old_on.get("tag")
if partial and (old_ff.get("machine") != ffhere.split("|", 1)[1] or old_ff.get("commit") != ffcommit):
    sys.exit("BENCH_ROWS keeps rows measured on this machine against the same fframes commit only; bench/facts.json's weren't")
def kept(f):
    return f if not f or "tag" in f else dict(f, tag=old_tag)
rows = list(csv.DictReader(open(f"{out}/runs.tsv"), delimiter="\t"))
quality = {q["pair"]: q for q in csv.DictReader(open(f"{out}/quality.tsv"), delimiter="\t")}
pairs = [p.split(":") for p in pairs.split()]
r3 = lambda x: round(x, 3)

def fact(id, impl):
    rs = [r for r in rows if r["id"] == id and r["impl"] == impl]
    ok = [r for r in rs if float(r["wall_s"]) > 0]
    if not rs: return None
    if len(ok) < len(rs): return {"failed": len(rs) - len(ok), "runs": len(rs)}
    wall = [float(r["wall_s"]) for r in ok]
    f = {"tag": tag, "wall_s": r3(st.median(wall)), "wall_min_s": r3(min(wall)), "wall_max_s": r3(max(wall)),
         "cpu_s": r3(st.median(float(r["user_s"]) + float(r["sys_s"]) for r in ok)),
         "rss_bytes": int(st.median(int(r["rss_kb"]) for r in ok)) * 1024}
    v = ok[0]
    if v["frames"]:
        f.update(frames=int(v["frames"]), width=int(v["width"]), height=int(v["height"]), fps=float(v["fps"]), duration_s=r3(float(v["duration_s"])))
    if v["note"].isdigit(): f["frames_checked"] = int(v["note"])
    return f

# fframes' side: this run's, or the rows bench/facts.json had at the same commit on this machine
race, reused = [], set()
for name in ([] if not partial else [n for n in old_race if n not in partial]):
    race.append(dict(old_race[name], onimite=kept(old_race[name].get("onimite"))))
for name, crate in pairs:
    a = fact(name, "fframes")
    if a is None:
        a = old_race[name]["fframes"]
        reused.add(crate)
    b = fact(name, "onimite")
    row = {"name": name, "fframes": a, "onimite": b}
    if a and b and "wall_s" in a and "wall_s" in b:
        same = all(a.get(k) == b.get(k) for k in ("frames", "width", "height", "fps"))
        row["comparable"] = same
        if same: row["speedup"] = round(a["wall_s"] / b["wall_s"], 2)
    q = quality.get(name)
    if q and q["psnr_db"] and q["ssim"]:
        row["psnr_db"], row["ssim"] = (99.0 if q["psnr_db"] == "inf" else round(float(q["psnr_db"]), 1)), round(float(q["ssim"]), 4)
    race.append(row)
order = {r["name"]: i for i, r in enumerate(old.get("race", {}).get("rows", []))}
race.sort(key=lambda r: order.get(r["name"], len(order)))
sp = [r["speedup"] for r in race if "speedup" in r]
best = max((r for r in race if "speedup" in r), key=lambda r: r["speedup"], default=None)
# crates built with FFmpeg from source: this run's builds, and those of the reused rows
source_built = sorted(set(built_from_source.split()) | (set(old_ff.get("ffmpeg_from_source", [])) & reused)
                     | (set(old_ff.get("ffmpeg_from_source", [])) if partial else set()))

install, sums = [], {}
for path in sorted(glob.glob(f"{rel}/onimite-{tag}-*")) if rel else []:
    m = re.fullmatch(rf"onimite-{re.escape(tag)}-(.+)\.(tar\.gz|zip)", os.path.basename(path))
    if not m: continue
    if m.group(2) == "zip":
        unpacked = sum(i.file_size for i in zipfile.ZipFile(path).infolist())
    else:
        unpacked = sum(t.size for t in tarfile.open(path) if t.isfile())
    install.append({"target": m.group(1), "archive": os.path.basename(path), "download_bytes": os.path.getsize(path), "unpacked_bytes": unpacked})
if rel:
    sums = dict(reversed(l.split()) for l in open(f"{rel}/SHA256SUMS") if l.strip())

def dates(ds):
    d = sorted(set(x for x in ds if x))
    return d[0] if len(d) == 1 else f"{d[0]}..{d[-1]}" if d else None
ff_dates = [r["date"] for r in rows if r["impl"] == "fframes"] + ((old_ff.get("measured") or "").split("..") if reused else [])
timed = [r for r in rows if float(r["wall_s"]) > 0]
facts = {
    "measured": {
        "date": datetime.date.today().isoformat(),
        "machine": {"cpu": cpu, "gpu": gpu, "mesa": mesa, "os": osname, "ram_bytes": int(ram)},
        "onimite": {"tag": tag, "archive_sha256": sums.get(f"onimite-{tag}-linux-x86_64.tar.gz"), "examples": examples,
                    "examples_changed": changed == "1",
                    "measured": dates([r["date"] for r in rows if r["impl"] == "onimite"] + ((old.get("measured", {}).get("onimite", {}).get("measured") or "").split("..") if partial else [])),
                    **({"measured_again": sorted(set(partial) | (set(old_on.get("measured_again", [])) if old_tag == tag else set())),
                        "rest_from": old_on.get("rest_from", old_tag) if old_tag == tag else old_tag} if partial else {})},
        "fframes": {"tag": fftag or None, "commit": ffcommit, "machine": f"{cpu}|{gpu}|{mesa}", "measured": dates(ff_dates),
                    "ffmpeg_from_source": source_built},
        "kept": max(int(r["run"]) for r in rows),
        # over the runs behind every figure: a partial run's, and those of the run its kept rows are from
        "others_cpu_s_max": max([float(r["others_cpu_s"]) for r in timed] + ([old["measured"].get("others_cpu_s_max", 0)] if partial else []), default=0),
        "others_gpu_s_max": max([float(r.get("others_gpu_s") or 0) for r in timed] + ([old["measured"].get("others_gpu_s_max", 0)] if partial else []), default=0),
        "redone": sum(int(r["redone"]) for r in rows) + (old["measured"].get("redone", 0) if partial else 0),
    },
    "install": install,
    "race": {"examples": old["race"]["examples"] if partial else len({c for _, c in pairs}), "compared": len(sp), "onimite_faster": sum(1 for x in sp if x > 1),
             "median_speedup": round(st.median(sp), 2) if sp else None,
             "best": best and {"name": best["name"], "speedup": best["speedup"]}, "rows": race},
    "onimite": {id: fact(id, "onimite") or kept(old.get("onimite", {}).get(id)) for id in ids.split()},
    "examples": dict({k: kept(v) for k, v in old.get("examples", {}).items()} if partial else {},
                     **{r["id"].split(":", 1)[1]: fact(r["id"], "onimite") for r in rows if r["id"].startswith("example:")}),
    "setup": old.get("setup", []),
}
print(json.dumps(facts))
EOF
  echo "wrote $1" >&2
}

facts_md() { # facts.json md: BENCHMARK.md's tables, between its facts markers (md -: printed)
  python3 -I - "$1" "$2" <<'EOF'
import sys, json
facts = json.load(open(sys.argv[1]))
def s(x): return "-" if x is None else f"{x:.2f}" if x < 10 else f"{x:.1f}" if x < 100 else f"{x:.0f}"
def b(x): return f"{x / 2**30:.1f} GiB" if x >= 2**30 else f"{x / 2**20:.0f} MiB"
def side(f): return "not run" if not f else "fails" if "failed" in f else f"{s(f['wall_s'])} s / {s(f['cpu_s'])} s / {b(f['rss_bytes'])}"
m = facts["measured"]
race = facts["race"]["rows"]
install = facts["install"]
o, ff, mc = m["onimite"], m["fframes"], m["machine"]
again = o.get("measured_again")
out = [f"onimite {o['tag']} ({'the release binary' if o['archive_sha256'] else 'a local build'}, measured {o['measured']}; the scripts at {o['examples']}{', changed' if o['examples_changed'] else ''}"
       + (f"; measured again with it: {', '.join(r.replace('example:', '') for r in again)}, the other rows {o['rest_from']}'s, as each row's tag says" if again else "") + ") "
       f"against fframes {ff['tag'] or ff['commit'][:7]} (measured {ff['measured']}), on {mc['cpu']}, {mc['gpu'] or 'GPU unknown'}, Mesa {mc['mesa'] or 'unknown'}, "
       f"{mc['os']}: the median of {m['kept']} runs after a warm-up (wall / CPU / peak RSS). Each run waited for an idle machine; "
       f"{m['redone']} that overlapped other work were run again. Generated by `tools/bench.sh facts` from `bench/facts.json`."
       + (f" fframes' {', '.join(ff['ffmpeg_from_source'])} built with FFmpeg from source "
       f"(FFMPEG_FORCE_BUILD=1, as its README says): the prebuilt FFmpeg doesn't link against this machine's x264." if ff.get("ffmpeg_from_source") else ""), "",
       "| Example | Frames | Size, fps | fframes | onimite | fframes / onimite | PSNR / SSIM |", "| --- | --- | --- | --- | --- | --- | --- |"]
for r in race:
    v = r["onimite"] if r["onimite"] and "frames" in r["onimite"] else r["fframes"] or {}
    size = f"{v['width']}x{v['height']}, {v['fps']:g}" if "width" in v else "-"
    ratio = f"{r['speedup']:.2f}x" if "speedup" in r else ("frames differ" if r.get("comparable") is False else "-")
    quality = f"{r['psnr_db']:.1f} dB / {r['ssim']:.3f}" if "psnr_db" in r else "-"
    out.append(f"| {r['name']} | {v.get('frames', '-')} | {size} | {side(r['fframes'])} | {side(r['onimite'])} | {ratio} | {quality} |")
rc = facts["race"]
if rc["compared"]:
    out += ["", f"{rc['examples']} fframes examples, {len(race)} videos: onimite is faster on {rc['onimite_faster']} of the {rc['compared']} compared; the median ratio is {rc['median_speedup']:.2f}x."]
out += ["", "| onimite | wall (min-max) | CPU | peak RSS |", "| --- | --- | --- | --- |"]
for id, f in facts["onimite"].items():
    extra = f", {f['frames_checked']} frames checked" if f and "frames_checked" in f else f", {f['frames']} frames" if f and "frames" in f else ""
    out.append(f"| {id}{extra} | " + ("fails |  |  |" if not f or "failed" in f else f"{s(f['wall_s'])} s ({s(f['wall_min_s'])}-{s(f['wall_max_s'])}) | {s(f['cpu_s'])} s | {b(f['rss_bytes'])} |"))
if facts.get("examples"):
    out += ["", "Every example, as the site renders it (`onimite render video.lua --qp 22`):", "",
            "| Example | frames, size, fps | wall (min-max) | fps rendered | CPU | peak RSS |", "| --- | --- | --- | --- | --- | --- |"]
    for name, f in facts["examples"].items():
        if not f or "failed" in f:
            out.append(f"| {name} | fails | | | | |")
            continue
        out.append(f"| {name} | {f['frames']}, {f['width']}x{f['height']}, {f['fps']:g} | {s(f['wall_s'])} s ({s(f['wall_min_s'])}-{s(f['wall_max_s'])}) | "
                   f"{f['frames'] / f['wall_s']:.0f} | {s(f['cpu_s'])} s | {b(f['rss_bytes'])} |")
if install:
    out += ["", "| Release archive | download | unpacked |", "| --- | --- | --- |"]
    out += [f"| {i['archive']} | {i['download_bytes'] / 1e6:.1f} MB | {i['unpacked_bytes'] / 1e6:.1f} MB |" for i in install]
if facts["setup"]:
    out += ["", "What the others install before their first frame (`tools/bench.sh setup`):", "",
            "| Tool | packages | on disk |", "| --- | --- | --- |"]
    for t in facts["setup"]:
        parts = " + ".join(f"{p['name']} {p['bytes'] / 1e6:.0f} MB" for p in t["parts"])
        out.append(f"| {t['name']} {t['version']} (measured {t['measured']}) | {t['deps']} {t['kind']} | {sum(p['bytes'] for p in t['parts']) / 1e6:.0f} MB: {parts} |")
    out += [f"\n{t['name']}: {t['note']}." for t in facts["setup"] if t.get("note")]
if sys.argv[2] == "-":
    print("\n".join(out))
    sys.exit()
md = open(sys.argv[2]).read()
a, z = "<!-- facts -->", "<!-- /facts -->"
assert a in md and z in md, "BENCHMARK.md needs the <!-- facts --> and <!-- /facts --> markers"
md = md[:md.index(a) + len(a)] + "\n" + "\n".join(out) + "\n" + md[md.index(z):]
open(sys.argv[2], "w").write(md)
print("wrote " + sys.argv[2], file=sys.stderr)
EOF
}

# ---- setup: what fframes and Remotion put on disk before their first frame ----
# BENCHMARK.md's Method says what is counted. Installs are deleted afterwards; $OUT/setup.log has their output.
# Does nothing when facts.json holds fframes' pinned tag (in SETUP_IMAGE) and Remotion's latest release already.
tree_bytes() { # the files under the given paths, each inode once
  find "$@" -type f -printf '%D %i %s\n' | awk '!seen[$1 " " $2]++ {t += $3} END {printf "%.0f\n", t}'
}

do_setup() {
  local d="$OUT/setup" ff node tool crates build deps ffver nodever nodetar mods chrome rver rdeps
  ffver="$(git -C "$FF" describe --tags --exact-match | sed 's/^v//')"
  rver="$(curl -sSfL https://registry.npmjs.org/remotion/latest | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["version"])')"
  if [ "$(python3 -I -c 'import json, sys; print(" ".join(s["version"] + " " + s.get("system", "") for s in json.load(open(sys.argv[1])).get("setup", [])))' "$ROOT/bench/facts.json" 2>/dev/null)" = "$ffver ${SETUP_IMAGE:-ubuntu:22.04} $rver " ]; then
    echo "setup: fframes $ffver (in ${SETUP_IMAGE:-ubuntu:22.04}) and Remotion $rver are measured already" >&2
    return
  fi
  rm -rf "${OUT:?}/setup"
  mkdir -p "$d/fframes/home" "$d/remotion/home"
  ff="$d/fframes"
  : > "$OUT/setup.log"
  docker build -q -t onimite-bench-fframes - >>"$OUT/setup.log" 2>&1 <<EOF
FROM ${SETUP_IMAGE:-ubuntu:22.04}
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates build-essential pkg-config \
    yasm nasm ffmpeg libx264-dev libx265-dev libopus-dev libclang-dev clang ninja-build libvpx-dev libasound2-dev \
    libfreetype-dev libfontconfig1-dev git > /dev/null
EOF
  in_image() { # command: run in the image as this user, the install mounted at /m
    docker run --rm --user "$(id -u):$(id -g)" -v "$ff:/m" -w /m -e HOME=/m/home -e XDG_CACHE_HOME=/m/home/.cache \
      -e RUSTUP_HOME=/m/rustup -e CARGO_HOME=/m/cargo -e PATH=/m/cargo/bin:/usr/local/bin:/usr/bin:/bin \
      onimite-bench-fframes bash -c "$1" >>"$OUT/setup.log" 2>&1
  }
  curl -sSfL -o "$ff/rustup-init" https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init
  curl -sSfL https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init.sha256 | awk '{print $1"  '"$ff"'/rustup-init"}' | sha256sum --check --quiet
  chmod +x "$ff/rustup-init"
  in_image "./rustup-init -y --profile minimal --default-toolchain stable --no-modify-path"
  rm -f "$ff/rustup-init"
  tool="$(tree_bytes "$ff/rustup" "$ff/cargo")"
  in_image "cargo install --locked cargo-fframes --version $ffver && cargo fframes new my-video --yes && cd my-video \
    && { cargo build --release > /m/build.log 2>&1 || { cat /m/build.log; grep -q 'undefined symbol: x264_' /m/build.log \
      && touch /m/ffmpeg-from-source && cargo clean && FFMPEG_FORCE_BUILD=1 cargo build --release; }; } \
    && cargo tree -e normal,build --target x86_64-unknown-linux-gnu --prefix none --format '{p}' | sed 's/ (\\*)\$//' | sort -u | wc -l > /m/crates.count"
  crates=$(( $(tree_bytes "$ff/rustup" "$ff/cargo") - tool ))
  build="$(tree_bytes "$ff/my-video/target" "$ff/home")"
  deps=$(( $(cat "$ff/crates.count") - 1 ))
  # Remotion on Node.js LTS.
  nodetar="$(curl -sSfL https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt | awk '/linux-x64.tar.xz$/ {print $2}')"
  curl -sSfL -o "$d/remotion/$nodetar" "https://nodejs.org/dist/latest-v24.x/$nodetar"
  curl -sSfL https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt | grep " $nodetar\$" | awk '{print $1"  '"$d/remotion/"'"$2}' | sha256sum --check --quiet
  tar -xJf "$d/remotion/$nodetar" -C "$d/remotion"
  rm -f "$d/remotion/$nodetar"
  node="$d/remotion/${nodetar%.tar.xz}"
  nodever="$("$node/bin/node" --version)"
  mkdir -p "$d/remotion/my-video"
  ( export HOME="$d/remotion/home" XDG_CACHE_HOME="$d/remotion/home/.cache" PATH="$node/bin:$PATH" npm_config_cache="$d/remotion/npm-cache"
    cd "$d/remotion/my-video" && npm init -y >>"$OUT/setup.log" 2>&1 \
      && npm install "remotion@$rver" "@remotion/cli@$rver" react react-dom >>"$OUT/setup.log" 2>&1 )
  mods="$(tree_bytes "$d/remotion/my-video/node_modules")"
  ( export HOME="$d/remotion/home" XDG_CACHE_HOME="$d/remotion/home/.cache" PATH="$node/bin:$PATH" npm_config_cache="$d/remotion/npm-cache"
    cd "$d/remotion/my-video" && npx remotion browser ensure >>"$OUT/setup.log" 2>&1 )
  chrome=$(( $(tree_bytes "$d/remotion/my-video/node_modules" "$d/remotion/home") - mods ))
  [ "$chrome" -gt 0 ] || { echo "setup: remotion browser ensure put nothing in node_modules or HOME (see $OUT/setup.log)" >&2; exit 1; }
  rdeps="$(python3 -I -c 'import json, os, sys; d = sys.argv[1]; print(sum(1 for k in json.load(open(d + "/package-lock.json"))["packages"] if k and os.path.isdir(os.path.join(d, k))))' "$d/remotion/my-video")"
  python3 -I - "$ROOT/bench/facts.json" "$ffver" "$deps" "$tool" "$crates" "$build" "$rver" "$rdeps" "$nodever" "$(tree_bytes "$node")" "$mods" "$chrome" "$([ -f "$ff/ffmpeg-from-source" ] && echo 1 || true)" "${SETUP_IMAGE:-ubuntu:22.04}" <<'EOF' | facts_save "$ROOT/bench/facts.json"
import sys, json, os, datetime
path, ffver, deps, tool, crates, build, rver, rdeps, nodever, node, mods, chrome, source, image = sys.argv[1:]
facts = json.load(open(path)) if os.path.exists(path) else {}
today = datetime.date.today().isoformat()
facts["setup"] = [
    {"name": "fframes", "version": ffver, "measured": today, "deps": int(deps), "kind": "crates",
     "system": image, "parts": [{"name": "Rust toolchain", "bytes": int(tool)}, {"name": "crates", "bytes": int(crates)}, {"name": "first build", "bytes": int(build)}],
     "note": f"installed in {image} with the packages its README lists, " + ("where the first build still didn't link against the prebuilt FFmpeg, so FFmpeg was built from source (FFMPEG_FORCE_BUILD=1)" if source else
             "whose x264 (0.163) its prebuilt FFmpeg links against; with a newer x264 (0.165 on Arch) the first build doesn't link and FFmpeg compiles from source, a bigger first build")},
    {"name": "Remotion", "version": rver, "measured": today, "deps": int(rdeps), "kind": "packages", "node": nodever,
     "parts": [{"name": "Node.js", "bytes": int(node)}, {"name": "node_modules", "bytes": int(mods)}, {"name": "Chrome Headless Shell", "bytes": int(chrome)}]},
]
for s in facts["setup"]:
    print(s["name"], s["version"], s["deps"], s["kind"], ", ".join(f"{p['name']} {p['bytes'] / 1e6:.0f} MB" for p in s["parts"]), file=sys.stderr)
print(json.dumps(facts))
EOF
  rm -rf "${OUT:?}/setup"
  facts_md "$ROOT/bench/facts.json" "$ROOT/BENCHMARK.md"
}

case "${1:-}" in
  facts) do_facts "${2:-}" ;;
  md) facts_md "$ROOT/bench/facts.json" "$ROOT/BENCHMARK.md" ;; # the tables again from bench/facts.json
  setup) do_setup ;;
  visual) do_visual ;;
  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
