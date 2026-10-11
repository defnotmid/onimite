#!/usr/bin/env bash
# Benchmark fframes (Rust) against onimite (Odin + Lua) on the same examples.
#
#   tools/bench.sh build     build both sides (cargo release for the fframes examples, odin -o:speed)
#   tools/bench.sh perf      time full renders, RUNS times each, write $OUT/results.tsv + $OUT/summary.md
#   tools/bench.sh visual    export the same frames from both sides, PSNR/SSIM + montages
#   tools/bench.sh video     whole-video PSNR/SSIM between the two MP4s (needs `perf` first)
#   tools/bench.sh all       build + perf + visual + video
#
# Env: RUNS (3), OUT (.work/bench), BENCH_ONLY (substring filter on pair names),
#      BENCH_CONFIGS (space separated subset of the onimite config names below).
# Needs: cargo, odin, ffmpeg/ffprobe, python3, /usr/bin/time (GNU).
# Run examples/fframes/fetch.sh first (the ports use fframes' media).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FF="$ROOT/third_party/fframes"
FFBIN="$FF/target/release"
OF="$ROOT/build/onimite_bench"
OUT="${OUT:-$ROOT/.work/bench}"
RUNS="${RUNS:-3}"

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
)
# onimite configs name:flags (gpu = SDL_GPU render + Vulkan Video hw encode = the default)
OCONFIGS=("gpu:" "software:--software" "native:--native" "software+native:--software --native")
if [ -n "${BENCH_CONFIGS:-}" ]; then
  sel=(); for c in "${OCONFIGS[@]}"; do for w in $BENCH_CONFIGS; do [ "${c%%:*}" = "$w" ] && sel+=("$c"); done; done
  OCONFIGS=("${sel[@]}")
fi

# Frame specs for the visual comparison, per pair name.
declare -A VSPECS=(
  [hello_world]="start,10%,25%,50%,75%,end"
  [signal_lab]="start,25%,50%,75%,end,Product@50%,Data,Data@50%,System,Final"
  [motion_graphics]="start,10%,25%,40%,50%,75%,end"
  [mg_install]="start,10%,25%,50%,75%,end"
  [mg_quote]="start,25%,50%,75%,end"
  [shader_mode]="start,25%,50%,75%,end,Glass@1,Tunnel@4,ShaderLibrary@30,Flow@28,ShaderModeZoom@23,Eclipse@100"
)
for p in conference low_poly_art beta marketing podcast tiktok teej_podcast audio_announce pixel_memory shaders neon_triangle fframes_intro made_of_motion; do
  VSPECS[$p]="start,25%,50%,75%,end"
done

mkdir -p "$OUT/work" "$OUT/vid"
pair_sel() { local p; for p in "${PAIRS[@]}"; do [[ -z "${BENCH_ONLY:-}" || "${p%%|*}" == *"$BENCH_ONLY"* ]] && echo "$p"; done; return 0; }

do_build() {
  ( cd "$FF" && unset CARGO_TARGET_DIR && \
    cargo build --release $(pair_sel | cut -d'|' -f2 | sort -u | sed 's/^/-p /') )
  ( cd "$ROOT" && odin build . -collection:deps=.. -o:speed -out:build/onimite_bench )
}

# run_one <outfile> <cmd...>  -> prints "wall user sys rss_kb bytes"
run_one() {
  local out="$1"; shift
  local dir="${RUN_DIR:-$OUT/work}"
  local tf; tf="$(mktemp "$OUT/time.XXXXXX")"
  rm -f "$out"
  ( cd "$dir" && /usr/bin/time -v -o "$tf" "$@" >"$tf.log" 2>&1 ) || { echo "FAILED: $*" >&2; tail -5 "$tf.log" >&2; rm -f "$tf" "$tf.log"; echo "0 0 0 0 0"; return 0; }
  python3 -I - "$tf" "$out" <<'EOF'
import sys, os, re
t = open(sys.argv[1]).read()
g = lambda p: re.search(p, t).group(1)
wall = 0
for x in g(r"Elapsed \(wall clock\) time \(h:mm:ss or m:ss\): ([\d:.]+)").split(":"): wall = wall * 60 + float(x)
print(wall, g(r"User time \(seconds\): ([\d.]+)"), g(r"System time \(seconds\): ([\d.]+)"),
      g(r"Maximum resident set size \(kbytes\): (\d+)"),
      os.path.getsize(sys.argv[2]) if os.path.exists(sys.argv[2]) else 0)
EOF
  rm -f "$tf" "$tf.log"
}

exdir() { # the fframes example directory of a crate (binaries find their media relative to it)
  local t; t="$(grep -l "^name = \"$1\"" "$FF"/examples/*/Cargo.toml | head -1)"
  echo "${t%/Cargo.toml}"
}

vinfo() { # "frames duration" of an mp4
  ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets:format=duration \
    -of csv=p=0 "$1" 2>/dev/null | tr '\n' ' ' || true
}

record() { # pair impl config run <res> <file>
  local res fr; res="$5"; fr="$(vinfo "$6")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(echo $res | tr ' ' '\t')" "$(echo $fr | tr ' ' '\t')" >> "$OUT/results.tsv"
}

do_perf() {
  [ -n "${BENCH_APPEND:-}" ] || printf 'pair\timpl\tconfig\trun\twall_s\tuser_s\tsys_s\trss_kb\tbytes\tframes\tduration_s\n' > "$OUT/results.tsv"
  local name crate bin fargs script oenv r res c cname cflags v
  while IFS='|' read -r name crate bin fargs script oenv; do
    echo "== $name" >&2
    v="$OUT/vid/${name}_fframes.mp4"
    for r in $(seq 1 "$RUNS"); do
      res=$(RUN_DIR="$(exdir "$crate")" run_one "$v" "$FFBIN/$bin" render $fargs -o "$v")
      record "$name" fframes default "$r" "$res" "$v"
    done
    for c in "${OCONFIGS[@]}"; do
      cname="${c%%:*}"; cflags="${c#*:}"; v="$OUT/vid/${name}_onimite_${cname}.mp4"
      for r in $(seq 1 "$RUNS"); do
        res=$(run_one "$v" env $oenv "$OF" render "$ROOT/$script" -o "$v" $cflags)
        record "$name" onimite "$cname" "$r" "$res" "$v"
      done
    done
  done < <(pair_sel)
  summarize
}

summarize() {
  python3 -I - "$OUT/results.tsv" > "$OUT/summary.md" <<'EOF'
import sys, csv, statistics as st
rows = list(csv.DictReader(open(sys.argv[1]), delimiter="\t"))
keys = []
for r in rows:
    k = (r["pair"], r["impl"], r["config"])
    if k not in keys: keys.append(k)
print("| pair | impl | config | frames | wall s | fps | CPU s (user+sys) | peak RSS MB | size MB | kbit/s |")
print("|---|---|---|---|---|---|---|---|---|---|")
for k in keys:
    rs = [r for r in rows if (r["pair"], r["impl"], r["config"]) == k and float(r["wall_s"]) > 0 and r["frames"]]
    if not rs:
        print(f"| {k[0]} | {k[1]} | {k[2]} | failed | | | | | | |"); continue
    med = lambda f: st.median(float(r[f]) for r in rs)
    wall = med("wall_s"); cpu = st.median(float(r["user_s"]) + float(r["sys_s"]) for r in rs)
    frames = int(float(rs[0]["frames"])); dur = float(rs[0]["duration_s"])
    size = med("bytes")
    print(f"| {k[0]} | {k[1]} | {k[2]} | {frames} | {wall:.2f} | {frames/wall:.0f} | {cpu:.1f} | {med('rss_kb')/1024:.0f} | {size/1e6:.2f} | {size*8/dur/1000:.0f} |")
EOF
  cat "$OUT/summary.md"
}

# ---- visual comparison: same frames from both sides, PSNR/SSIM, fframes | onimite | diff(x4) ----
do_visual() {
  mkdir -p "$OUT/frames" "$OUT/montage"
  printf 'pair\tframe\tpsnr_db\tssim\n' > "$OUT/visual.tsv"
  local name crate bin fargs script oenv d specs f b psnr ssim
  while IFS='|' read -r name crate bin fargs script oenv; do
    echo "== $name" >&2
    d="$OUT/frames/$name"; rm -rf "$d"; mkdir -p "$d"
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

# ---- whole-video comparison (frame counts and sizes must match) ----
do_video() {
  local name crate bin fargs script c cname a b psnr ssim
  printf 'pair\toframes_config\tpsnr_db\tssim\n' > "$OUT/video_cmp.tsv"
  while IFS='|' read -r name crate bin fargs script oenv; do
    for c in "${OCONFIGS[@]}"; do
      cname="${c%%:*}"; a="$OUT/vid/${name}_fframes.mp4"; b="$OUT/vid/${name}_onimite_${cname}.mp4"
      [ -f "$a" ] && [ -f "$b" ] || continue
      psnr=$(ffmpeg -nostdin -hide_banner -i "$a" -i "$b" -lavfi "[0:v]format=yuv420p[a];[1:v]format=yuv420p[b];[a][b]psnr" -f null - 2>&1 | grep -o 'average:[^ ]*' | cut -d: -f2 || true)
      ssim=$(ffmpeg -nostdin -hide_banner -i "$a" -i "$b" -lavfi "[0:v]format=yuv420p[a];[1:v]format=yuv420p[b];[a][b]ssim" -f null - 2>&1 | grep -o 'All:[^ ]*' | cut -d: -f2 || true)
      printf '%s\t%s\t%s\t%s\n' "$name" "$cname" "$psnr" "$ssim" | tee -a "$OUT/video_cmp.tsv"
    done
  done < <(pair_sel)
}

case "${1:-all}" in
  build) do_build ;;
  perf) do_perf ;;
  visual) do_visual ;;
  video) do_video ;;
  all) do_build; do_perf; do_visual; do_video ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
