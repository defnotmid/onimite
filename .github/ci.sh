#!/usr/bin/env bash
# What CI runs (.github/workflows/ci.yml), from an onimite checkout with ovg,
# oglyph, ocurves, oksl, odecs, ottis, o3d and odawg beside it; runnable locally too:
#
#   bash .github/ci.sh build   # build/onimite, -o:speed, version v0.0.0-ci (it can update)
#   bash .github/ci.sh test    # odin test, every package that has tests
#   bash .github/ci.sh smoke   # the built binary draws a frame, renders a clip (software), serves MCP, updates itself
#   bash .github/ci.sh songs   # every example song part by part against its parts.json (audio parts --against)
#   bash .github/ci.sh media   # no heavy audio or video committed under examples/ or skills/
#   bash .github/ci.sh readmes # no measured loudness figures in example READMEs (they go stale)
#   bash .github/ci.sh facts   # bench/facts.json measures the latest release; no race figures typed into READMEs
#   bash .github/ci.sh pins    # every sibling checkout names a tag, the same one in both workflows
#
# ONIMITE_TEST_LDFLAGS (set by .github/actions/setup-toolchain) points the
# links at CI's SDL3; unset, the system's is used.
set -eo pipefail
cd "$(dirname "$0")/.."

exe=
[ "${OS:-}" = Windows_NT ] && exe=.exe
mkdir -p build

case ${1:-} in
build)
	odin build . -collection:deps=.. -o:speed -define:ONIMITE_VERSION=v0.0.0-ci -out:"build/onimite$exe" ${ONIMITE_TEST_LDFLAGS:+"-extra-linker-flags:$ONIMITE_TEST_LDFLAGS"}
	;;
test)
	# macOS: the GPU tests in encode and onimite (view3d's GPU half) skip
	# (SDL's Metal driver needs Cocoa, which starts only on the main thread;
	# tests run on worker threads). Every other test is CPU-only, and none
	# of o3d's own tests runs here (no O3D_NO_GPU needed).
	for pkg in onimite script app encode speech; do
		echo "::group::odin test $pkg"
		odin test "$pkg" -collection:deps=.. -out:"build/test_$pkg$exe" ${ONIMITE_TEST_LDFLAGS:+"-extra-linker-flags:$ONIMITE_TEST_LDFLAGS"}
		echo "::endgroup::"
	done
	;;
smoke)
	out=${RUNNER_TEMP:-${TMPDIR:-/tmp}}/onimite-smoke
	mkdir -p "$out"
	"build/onimite$exe" --help > /dev/null
	"build/onimite$exe" frame examples/scenes/video.lua 0 --software -o "$out"
	"build/onimite$exe" render examples/scenes/video.lua 0..15 --software --native -o "$out/scenes.mp4"
	test -s "$out/0.png" && test -s "$out/scenes.mp4"
	# On the CPU the file doesn't depend on the thread count (builders
	# record, one player draws in bands on the pool, the native encoder codes
	# fixed slices): a cross-fade on every thread and on one is the same file.
	"build/onimite$exe" render examples/scenes/video.lua 90..105 --software --native -o "$out/fade.mp4"
	"build/onimite$exe" render examples/scenes/video.lua 90..105 --software --native --threads 1 -o "$out/fade1.mp4"
	cmp "$out/fade.mp4" "$out/fade1.mp4"
	# A sound file is a video of itself: audio analyze measures a WAV given
	# by its bare name from the folder it's in.
	"build/onimite$exe" audio render examples/scenes/video.lua 0..30 -o "$out/sound.wav"
	(cd "$out" && "$OLDPWD/build/onimite$exe" audio analyze sound.wav) | grep -q '^integrated'
	# motion pairs each draw with itself a quarter frame earlier: the
	# Middle title's card slides up as it enters, named by its line.
	"build/onimite$exe" motion examples/scenes/video.lua Middle@0.1s --software | grep -q 'px a frame.*rect  video.lua:12'
	# show lists odawg's node kinds and a kind's fields from its registry.
	"build/onimite$exe" show examples/scenes/video.lua node_kind/Filter --json | grep -q '"frequency"'
	# The MCP server starts, answers, serves the guide and renders with
	# paths relative to its --dir (as the Claude Desktop extension runs it).
	work="$out/mcp"
	mkdir -p "$work"
	cp examples/scenes/video.lua "$work/"
	printf '%s\n' \
		'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
		'{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"guide","arguments":{}}}' \
		'{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"render","arguments":{"script":"video.lua","range":"0..5","output":"mcp.mp4"}}}' \
		| "build/onimite$exe" mcp --dir "$work" --update-check false > "$out/mcp.out"
	grep -q '"serverInfo"' "$out/mcp.out"
	test "$(grep -c '"isError":false' "$out/mcp.out")" = 2
	test -s "$work/mcp.mp4"
	# update: the real releases answer; then a fake newer release (this
	# binary again, in this platform's archive) replaces a copy of it.
	"build/onimite$exe" update --check
	case "$(uname -s)" in
	Linux) platform=linux-x86_64 archive=tar.gz ;;
	Darwin) platform=macos-arm64 archive=tar.gz ;;
	*) platform=windows-x86_64 archive=zip ;;
	esac
	upd="$out/update"
	rm -rf "${upd:?}"
	name="onimite-v99.0.0-$platform"
	mkdir -p "$upd/installed" "$upd/release/$name"
	cp "build/onimite$exe" "$upd/installed/"
	cp "build/onimite$exe" "$upd/release/$name/"
	echo new >"$upd/release/$name/MARKER"
	if [ "$archive" = zip ]; then
		(cd "$upd/release" && 7z a -tzip -bd "$name.zip" "$name" >/dev/null)
	else
		tar -czf "$upd/release/$name.tar.gz" -C "$upd/release" "$name"
	fi
	(cd "$upd/release" && { sha256sum "$name.$archive" 2>/dev/null || shasum -a 256 "$name.$archive"; } >SHA256SUMS)
	ONIMITE_UPDATE_FROM="$upd/release" "$upd/installed/onimite$exe" update
	test -f "$upd/installed/MARKER"
	# The old files are gone (Windows keeps the running .exe until the next update).
	if [ -z "$exe" ] && ls "$upd/installed" | grep -q '\.old$'; then
		echo "update left old files: $(ls "$upd/installed")" >&2
		exit 1
	fi
	"$upd/installed/onimite$exe" --version
	;;
songs)
	# An odawg pin or an edit that changes how an example song sounds (a
	# part's notes, its first notes, its level by more than 1 LU) fails
	# here, naming the part. After a change you mean, write the table
	# again: onimite audio parts examples/X/video.lua --json > examples/X/parts.json
	# An example whose script makes a song and has no table fails too, so
	# none goes unchecked.
	fail=0
	for script in examples/*/video.lua; do
		dir=$(dirname "$script")
		table="$dir/parts.json"
		echo "::group::$dir"
		if [ -f "$table" ]; then
			"build/onimite$exe" audio parts "$script" --against "$table" || fail=1
		elif "build/onimite$exe" audio parts "$script" --json | grep -q '"name"'; then
			echo "$dir makes songs and has no parts.json: onimite audio parts $script --json > $table"
			fail=1
		fi
		echo "::endgroup::"
	done
	exit $fail
	;;
pins)
	# A checkout without a ref takes a sibling's moving default branch (oksl's
	# did until v0.0.62): every sibling is at a tag, the same in CI as in the
	# release.
	awk '
		function flush() {
			if (repo != "") {
				if (ref == "") {
					print file ": " repo " has no ref"; bad = 1
				} else if ((repo in pin) && pin[repo] != ref) {
					print file ": " repo " at " ref ", elsewhere at " pin[repo]; bad = 1
				} else {
					pin[repo] = ref
				}
			}
			repo = ""; ref = ""
		}
		FNR == 1 || /^ *- (uses|name|run):/ { flush() }
		/^ *repository: defnotmid\// { file = FILENAME; repo = $0; sub(/.*defnotmid\//, "", repo) }
		/^ *ref: / { ref = $0; sub(/.*ref: */, "", ref) }
		END { flush(); exit bad }
	' .github/workflows/ci.yml .github/workflows/release.yml
	;;
media)
	# No heavy media in the repository: an audio or video file over 256 KB
	# under examples/ or skills/ fails, named. Such a file is made or fetched
	# on first use (an example's fetch.sh, checked by hash) and listed in
	# its media/.gitignore.
	# What the commit holds: jj's list in a jj working copy (git's index
	# there is jj's, not current), else git's (CI's checkout).
	if jj root >/dev/null 2>&1; then
		list() { jj file list examples skills; }
	else
		list() { git ls-files examples skills; }
	fi
	fail=0
	while IFS= read -r f; do
		case "$f" in
		*.mp4 | *.mov | *.webm | *.mkv | *.avi | *.wav | *.mp3 | *.ogg | *.opus | *.flac | *.m4a | *.aac)
			[ -f "$f" ] || continue
			size=$(wc -c <"$f")
			if [ "$size" -gt 262144 ]; then
				echo "$f: $size bytes: heavy media isn't committed; make or fetch it on first use (an example's fetch.sh) and list it in its media/.gitignore"
				fail=1
			fi
			;;
		esac
	done < <(list)
	exit $fail
	;;
readmes)
	# An example's README states no measured loudness: a figure copied from
	# `audio analyze` goes stale with the next change to the mix or the
	# limiter. It gives the target ("about -14 LUFS") and names the command;
	# balances in LU (a part's place under the mix) are design, not figures.
	if grep -nE -- '-[0-9]+(\.[0-9]+)? ?(LUFS|dBTP|dBFS)' examples/*/README.md | grep -vE 'about -[0-9]+ LUFS'; then
		echo "measured loudness in an example README (above): give the target (about -14 LUFS) and name onimite audio analyze"
		exit 1
	fi
	;;
facts)
	# The race against fframes, the release sizes and the installs are
	# measured on each release by tools/bench.sh facts (and setup) into
	# bench/facts.json, which BENCHMARK.md's tables, the films (through
	# bench/facts.lua) and the site show. It measures the latest release:
	# after one, run tools/bench.sh facts on a quiet machine and commit what
	# it writes. A README states none of those figures (they went stale): a
	# line naming fframes or Remotion holds no figure outside `code`.
	fail=0
	have=$(python3 -c 'import json; print(json.load(open("bench/facts.json"))["measured"]["onimite"]["tag"])')
	# The newest tag but one on the commit being checked: a release commit
	# carries the facts of the release before it (its own come after its tag).
	head=$(git rev-parse HEAD)
	latest=$(git ls-remote --tags origin 'v*' | awk -v head="$head" '
		{ t = $2; sub("refs/tags/", "", t) }
		t ~ /\^\{\}$/ { sub(/\^\{\}$/, "", t); peeled[t] = $1; next }
		{ obj[t] = $1 }
		END { for (t in obj) if ((t in peeled ? peeled[t] : obj[t]) != head) print t }' | sort -V | tail -1)
	if [ "$have" != "$latest" ]; then
		echo "bench/facts.json measures $have, the latest release is $latest: run tools/bench.sh facts on a quiet machine and commit what it writes"
		fail=1
	fi
	figure='[0-9]+(\.[0-9]+)? ?(s|ms|MB|GB|MiB|GiB|%|×)([^a-zA-Z]|$)'
	for f in README.md examples/why_onimite/README.md examples/onimite_saga/README.md; do
		if sed 's/`[^`]*`//g' "$f" | grep -nE "(fframes|Remotion).*$figure|$figure.*(fframes|Remotion)" | sed "s|^|$f:|" | grep .; then
			echo "a measured figure beside fframes or Remotion (above): point to BENCHMARK.md, whose tables bench/facts.json fills"
			fail=1
		fi
	done
	exit $fail
	;;
*)
	echo "usage: bash .github/ci.sh build | test | smoke | songs | media | readmes | facts" >&2
	exit 2
	;;
esac
