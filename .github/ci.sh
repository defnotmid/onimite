#!/usr/bin/env bash
# What CI runs (.github/workflows/ci.yml), from an onimite checkout with ovg,
# oksl, odecs and ottis beside it; runnable locally too:
#
#   bash .github/ci.sh build   # build/onimite, -o:speed
#   bash .github/ci.sh test    # odin test, every package that has tests
#   bash .github/ci.sh smoke   # the built binary draws a frame and renders a clip (software)
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
	odin build . -collection:deps=.. -o:speed -out:"build/onimite$exe" ${ONIMITE_TEST_LDFLAGS:+"-extra-linker-flags:$ONIMITE_TEST_LDFLAGS"}
	;;
test)
	# macOS: the GPU test in encode skips (SDL's Metal driver needs Cocoa,
	# which starts only on the main thread; tests run on worker threads).
	# Every other test is CPU-only.
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
		| "build/onimite$exe" mcp --dir "$work" > "$out/mcp.out"
	grep -q '"serverInfo"' "$out/mcp.out"
	test "$(grep -c '"isError":false' "$out/mcp.out")" = 2
	test -s "$work/mcp.mp4"
	;;
*)
	echo "usage: bash .github/ci.sh build | test | smoke" >&2
	exit 2
	;;
esac
