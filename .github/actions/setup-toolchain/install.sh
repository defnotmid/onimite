#!/usr/bin/env bash
# Installs the onimite toolchain on a CI runner. Called by action.yml, one
# subcommand per cached piece:
#
#   install.sh odin    Odin release + the vendor C libraries that ship as source
#                      (Box2D's is fetched from GitHub on Linux)
#   install.sh sdl3    SDL3 shared library built from source (Linux, macOS)
#   install.sh lua     Lua static library built from source (macOS)
#   install.sh env     exports ODIN_ROOT, PATH and the linker flags
#
# Inputs (environment): TOOLS_DIR, ODIN_VERSION, SDL_VERSION, LUA_VERSION,
# LUA_SHA256. Also runnable locally with GITHUB_ENV / GITHUB_PATH pointed at
# scratch files.
set -euo pipefail

: "${TOOLS_DIR:?}"
os=$(uname -s)
case "$os" in
	Linux) platform=linux ;;
	Darwin) platform=macos ;;
	MINGW* | MSYS* | CYGWIN*) platform=windows ;;
	*) echo "unsupported OS: $os" >&2; exit 1 ;;
esac
case "$(uname -m)" in
	arm64 | aarch64) arch=arm64 ;;
	*) arch=amd64 ;;
esac
odin_dir="$TOOLS_DIR/odin"
sdl_dir="$TOOLS_DIR/sdl3"
lua_dir="$TOOLS_DIR/lua"
# Matches Odin's default -minimum-os-version, so every static library and the
# SDL3 dylib link without version-mismatch warnings.
if [ "$platform" = macos ]; then
	export MACOSX_DEPLOYMENT_TARGET=11.0
fi
jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)

# Moves the contents of an archive's single top-level directory into $2.
extract_into() {
	local archive="$1" dest="$2" tmp
	tmp=$(mktemp -d)
	case "$archive" in
		*.zip) 7z x -y -bd -o"$tmp" "$archive" >/dev/null ;;
		*) tar -xzf "$archive" -C "$tmp" ;;
	esac
	mkdir -p "$dest"
	local top=("$tmp"/*)
	if [ "${#top[@]}" -eq 1 ] && [ -d "${top[0]}" ]; then
		cp -R "${top[0]}"/. "$dest"/
	else
		cp -R "$tmp"/. "$dest"/
	fi
	rm -rf "${tmp:?}"
}

install_odin() {
	: "${ODIN_VERSION:?}"
	local ext=tar.gz
	[ "$platform" = windows ] && ext=zip
	local asset="odin-$platform-$arch-$ODIN_VERSION.$ext"
	local dl
	dl=$(mktemp -d)
	echo "Downloading $asset"
	curl -fsSL --retry 3 -o "$dl/$asset" "https://github.com/odin-lang/Odin/releases/download/$ODIN_VERSION/$asset"
	rm -rf "${odin_dir:?}"
	extract_into "$dl/$asset" "$odin_dir"
	rm -rf "${dl:?}"

	# vendor:box2d ships as C source on Linux; the macOS and Windows releases
	# have it prebuilt. ODIN_ROOT must point here: the script otherwise builds
	# into whatever ODIN_ROOT the environment already has.
	if [ "$platform" = linux ]; then
		export ODIN_ROOT="$odin_dir"
		# Fetches Box2D's source and builds it with cmake; its trailing WASM
		# build fails without a WASM toolchain, which the script tolerates.
		bash "$odin_dir/vendor/box2d/build_box2d.sh"
	fi
	"$odin_dir/odin" version
}

install_sdl3() {
	: "${SDL_VERSION:?}"
	local src
	src=$(mktemp -d)
	git clone --quiet --depth 1 --branch "release-$SDL_VERSION" https://github.com/libsdl-org/SDL.git "$src"
	local extra=()
	if [ "$platform" = macos ]; then
		extra+=("-DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET")
	fi
	cmake -S "$src" -B "$src/build" -G Ninja \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX="$sdl_dir" \
		-DCMAKE_INSTALL_LIBDIR=lib \
		-DSDL_SHARED=ON -DSDL_STATIC=OFF \
		-DSDL_TESTS=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_EXAMPLES=OFF \
		"${extra[@]}" >/dev/null
	cmake --build "$src/build" --parallel "$jobs" >/dev/null
	rm -rf "${sdl_dir:?}"
	cmake --install "$src/build" >/dev/null
	rm -rf "${src:?}"
	ls -l "$sdl_dir/lib"
}

# vendor:lua/5.4 links `system:lua5.4` on macOS. A static liblua5.4.a alone in
# its directory makes -llua5.4 pick it, so the binary carries Lua and needs
# no Homebrew keg at run time.
install_lua() {
	: "${LUA_VERSION:?}" "${LUA_SHA256:?}"
	local src
	src=$(mktemp -d)
	curl -fsSL --retry 3 -o "$src/lua.tar.gz" "https://www.lua.org/ftp/lua-$LUA_VERSION.tar.gz"
	echo "$LUA_SHA256  $src/lua.tar.gz" | shasum -a 256 -c -
	tar -xzf "$src/lua.tar.gz" -C "$src"
	make -C "$src/lua-$LUA_VERSION/src" liblua.a \
		SYSCFLAGS="-DLUA_USE_MACOSX -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" >/dev/null
	rm -rf "${lua_dir:?}"
	mkdir -p "$lua_dir/lib"
	cp "$src/lua-$LUA_VERSION/src/liblua.a" "$lua_dir/lib/liblua5.4.a"
	rm -rf "${src:?}"
}

# Exports for later steps:
#   ODIN_ROOT, PATH       the pinned Odin
#   ONIMITE_LDFLAGS       -extra-linker-flags for a release link (search paths only)
#   ONIMITE_TEST_LDFLAGS  the same plus an rpath to the CI SDL3, for tests
#   SDL3_LIB_DIR          where the SDL3 library to bundle lives
export_env() {
	local root="$odin_dir" ldflags="" testflags="" sdl_lib=""
	case "$platform" in
		linux)
			sdl_lib="$sdl_dir/lib"
			ldflags="-L$sdl_lib"
			testflags="$ldflags -Wl,-rpath,$sdl_lib"
			;;
		macos)
			sdl_lib="$sdl_dir/lib"
			ldflags="-L$sdl_lib -L$lua_dir/lib"
			testflags="$ldflags -Wl,-rpath,$sdl_lib"
			;;
		windows)
			# Odin ships SDL3.dll and lua54.dll; tests find them on PATH.
			root=$(cygpath -w "$odin_dir")
			sdl_lib="$odin_dir/vendor/sdl3"
			cygpath -w "$odin_dir/vendor/sdl3" >>"$GITHUB_PATH"
			cygpath -w "$odin_dir/vendor/lua/5.4/windows" >>"$GITHUB_PATH"
			;;
	esac
	if [ "$platform" = windows ]; then
		cygpath -w "$odin_dir" >>"$GITHUB_PATH"
	else
		echo "$odin_dir" >>"$GITHUB_PATH"
	fi
	if [ "$platform" = macos ]; then
		# Odin links through `clang` with -L/usr/local/lib, -L/opt/homebrew/lib
		# and -L/opt/local/lib ahead of -extra-linker-flags, so a Mac with
		# Homebrew's SDL3 or Lua would link those instead of the pinned ones
		# (seen on a developer Mac). This clang drops the three paths. Added
		# last to GITHUB_PATH, it comes first on PATH.
		mkdir -p "$TOOLS_DIR/bin"
		cat >"$TOOLS_DIR/bin/clang" <<'WRAP'
#!/bin/sh
for a; do
	shift
	case "$a" in
	-L/usr/local/lib | -L/opt/homebrew/lib | -L/opt/local/lib) ;;
	*) set -- "$@" "$a" ;;
	esac
done
exec /usr/bin/clang "$@"
WRAP
		chmod +x "$TOOLS_DIR/bin/clang"
		echo "$TOOLS_DIR/bin" >>"$GITHUB_PATH"
	fi
	{
		echo "ODIN_ROOT=$root"
		echo "ONIMITE_LDFLAGS=$ldflags"
		echo "ONIMITE_TEST_LDFLAGS=$testflags"
		echo "SDL3_LIB_DIR=$sdl_lib"
		if [ "$platform" = macos ]; then
			echo "MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"
		fi
	} >>"$GITHUB_ENV"
}

case "${1:-}" in
	odin) install_odin ;;
	sdl3) install_sdl3 ;;
	lua) install_lua ;;
	env) export_env ;;
	*) echo "usage: $0 odin|sdl3|lua|env" >&2; exit 2 ;;
esac
