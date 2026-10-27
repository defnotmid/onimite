#!/usr/bin/env bash
# What CI runs (.github/workflows/ci.yml), from an onimite checkout with ovg,
# oglyph, oksl, odecs, ottis, o3d and odawg beside it; runnable locally too:
#
#   bash .github/ci.sh build   # build/onimite, -o:speed, version v0.0.0-ci (it can update)
#   bash .github/ci.sh test    # odin test, every package that has tests
#   bash .github/ci.sh smoke   # the built binary draws a frame, renders a clip (software), serves MCP, updates itself
#   bash .github/ci.sh songs   # every example song part by part against its parts.json (audio parts --against)
#   bash .github/ci.sh media   # no heavy audio or video committed under examples/ or skills/
#   bash .github/ci.sh readmes # no measured loudness figures in example READMEs (they go stale)
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
*)
	echo "usage: bash .github/ci.sh build | test | smoke | songs | media | readmes" >&2
	exit 2
	;;
esac
