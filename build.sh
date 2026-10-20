#!/usr/bin/env bash
# Builds static ffmpeg and ffprobe into OUT_DIR/bin, with the licences of
# everything linked into them in OUT_DIR/licenses.
#
# Linux builds run inside the Alpine stage of the Dockerfile: linking against
# musl gives one binary that runs on any distro, and musl resolves DNS itself,
# where a static glibc binary needs the host's exact glibc for https:// inputs.
# macOS builds run natively; there the third-party libraries are static and only
# libSystem and libz (both part of every macOS install) stay dynamic.
#
# Usage: ./build.sh [--fetch-only | OUT_DIR]
set -euo pipefail

if [ $# -ne 1 ]; then
	echo "usage: $0 [--fetch-only | OUT_DIR]" >&2
	exit 2
fi

ROOT=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=versions.env
. "$ROOT/versions.env"

WORK=${WORK:-$ROOT/.build}
SRC=$WORK/src
PREFIX=$WORK/prefix
JOBS=$(getconf _NPROCESSORS_ONLN)

sha256() {
	if command -v sha256sum >/dev/null; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

# fetch_tarball NAME URL SHA256
fetch_tarball() {
	local dir=$SRC/$1 file=$SRC/$1.download
	[ -d "$dir" ] && return
	curl -fsSL --retry 3 -o "$file" "$2"
	local got
	got=$(sha256 "$file")
	if [ "$got" != "$3" ]; then
		echo "checksum mismatch for $2: expected $3, got $got" >&2
		exit 1
	fi
	mkdir "$dir.tmp"
	tar -xf "$file" -C "$dir.tmp" --strip-components=1
	mv "$dir.tmp" "$dir"
	rm "$file"
}

# fetch_git NAME URL COMMIT [FETCH_ARGS...]
fetch_git() {
	local dir=$SRC/$1 url=$2 commit=$3
	shift 3
	[ -d "$dir" ] && return
	rm -rf "$dir.tmp"
	git init -q "$dir.tmp"
	git -C "$dir.tmp" fetch -q "$@" "$url" "$commit"
	git -C "$dir.tmp" checkout -q --detach "$commit"
	mv "$dir.tmp" "$dir"
}

fetch_sources() {
	mkdir -p "$SRC"
	fetch_tarball openssl "$OPENSSL_URL" "$OPENSSL_SHA256"
	# x264 derives its revision number (r3108) from the commit count, and writes
	# it into every H.264 stream it encodes, so the history must not be shallow.
	fetch_git x264 "$X264_URL" "$X264_COMMIT"
	fetch_git svtav1 "$SVTAV1_URL" "$SVTAV1_COMMIT" --depth 1
	fetch_tarball dav1d "$DAV1D_URL" "$DAV1D_SHA256"
	fetch_tarball lame "$LAME_URL" "$LAME_SHA256"
	fetch_tarball ffmpeg "$FFMPEG_URL" "$FFMPEG_SHA256"
}

if [ "$1" = "--fetch-only" ]; then
	fetch_sources
	exit 0
fi

mkdir -p "$1"
OUT=$(cd "$1" && pwd)

rm -rf "$PREFIX" "${OUT:?}/bin" "${OUT:?}/licenses"
mkdir -p "$SRC" "$PREFIX" "$OUT/bin" "$OUT/licenses"

export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig

case $(uname -s) in
Linux)
	FFMPEG_LDEXEFLAGS=-static
	awk '/Copyright \(C\)/,/\*\//' /usr/include/zlib.h >"$OUT/licenses/zlib-LICENSE"
	cat >"$OUT/licenses/musl-COPYRIGHT" <<-'EOF'
	Copyright © 2005-2020 Rich Felker, et al.

	Permission is hereby granted, free of charge, to any person obtaining
	a copy of this software and associated documentation files (the
	"Software"), to deal in the Software without restriction, including
	without limitation the rights to use, copy, modify, merge, publish,
	distribute, sublicense, and/or sell copies of the Software, and to
	permit persons to whom the Software is furnished to do so, subject to
	the following conditions:

	The above copyright notice and this permission notice shall be
	included in all copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
	EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
	MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
	IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
	CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
	TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
	SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
	EOF
	;;
Darwin)
	export MACOSX_DEPLOYMENT_TARGET=13.0
	# configure links CoreFoundation, CoreVideo and CoreMedia into every macOS
	# build, even with VideoToolbox off; drop the ones nothing calls.
	FFMPEG_LDEXEFLAGS=-Wl,-dead_strip_dylibs
	;;
*)
	echo "unsupported OS: $(uname -s)" >&2
	exit 1
	;;
esac

build_openssl() {
	fetch_tarball openssl "$OPENSSL_URL" "$OPENSSL_SHA256"
	cd "$SRC/openssl"
	# ffmpeg does not verify TLS certificates unless asked to (-tls_verify 1).
	# When it is asked, the CA bundle is at /etc/ssl on Debian, Alpine and macOS.
	./Configure --prefix="$PREFIX" --libdir=lib --openssldir=/etc/ssl \
		no-shared no-module no-docs no-tests
	make -j"$JOBS" build_libs
	make install_dev
	cp LICENSE.txt "$OUT/licenses/openssl-LICENSE.txt"
}

build_x264() {
	fetch_git x264 "$X264_URL" "$X264_COMMIT"
	cd "$SRC/x264"
	./configure --prefix="$PREFIX" --enable-static --enable-pic --disable-cli --disable-opencl
	make -j"$JOBS"
	make install-lib-static
	cp COPYING "$OUT/licenses/x264-COPYING"
}

build_svtav1() {
	fetch_git svtav1 "$SVTAV1_URL" "$SVTAV1_COMMIT" --depth 1
	cd "$SRC/svtav1"
	# The build directory stays out of the source tree: SVT-AV1 tracks a `Build/`
	# directory, which is the same path as `build/` on macOS, and its version
	# string reads "-dirty" if any tracked file changes.
	local build=$WORK/build/svtav1
	rm -rf "$build"
	cmake -S . -B "$build" \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX="$PREFIX" \
		-DCMAKE_INSTALL_LIBDIR=lib \
		-DBUILD_SHARED_LIBS=OFF \
		-DBUILD_APPS=OFF \
		-DBUILD_DEC=OFF \
		-DBUILD_TESTING=OFF
	cmake --build "$build" -j"$JOBS"
	cmake --install "$build"
	cp LICENSE.md "$OUT/licenses/svt-av1-LICENSE.md"
	cp PATENTS.md "$OUT/licenses/svt-av1-PATENTS.md"
}

build_dav1d() {
	fetch_tarball dav1d "$DAV1D_URL" "$DAV1D_SHA256"
	cd "$SRC/dav1d"
	local build=$WORK/build/dav1d
	rm -rf "$build"
	meson setup "$build" \
		--prefix="$PREFIX" \
		--libdir=lib \
		--buildtype=release \
		--default-library=static \
		-Denable_tools=false \
		-Denable_tests=false
	ninja -C "$build" -j"$JOBS"
	ninja -C "$build" install
	cp COPYING "$OUT/licenses/dav1d-COPYING"
}

build_lame() {
	fetch_tarball lame "$LAME_URL" "$LAME_SHA256"
	cd "$SRC/lame"
	./configure --prefix="$PREFIX" \
		--enable-static --disable-shared \
		--disable-frontend --disable-decoder --disable-gtktest \
		--disable-dependency-tracking
	make -j"$JOBS"
	make install
	cp COPYING "$OUT/licenses/lame-COPYING"
}

build_ffmpeg() {
	fetch_tarball ffmpeg "$FFMPEG_URL" "$FFMPEG_SHA256"
	cd "$SRC/ffmpeg"
	make distclean >/dev/null 2>&1 || true
	# --disable-autodetect keeps the binary to exactly the features listed here:
	# without it, whatever the build host has installed (SDL, VideoToolbox, ...)
	# links in silently. It also turns off threads and zlib, so those are explicit.
	# --enable-version3 is required to link OpenSSL 3 (Apache 2.0) into a GPL build.
	./configure \
		--prefix="$PREFIX" \
		--extra-version=gvtlabs \
		--pkg-config-flags=--static \
		--extra-cflags="-I$PREFIX/include" \
		--extra-ldflags="-L$PREFIX/lib" \
		--extra-ldexeflags="$FFMPEG_LDEXEFLAGS" \
		--disable-autodetect \
		--disable-shared --enable-static \
		--disable-debug --disable-doc --disable-ffplay \
		--enable-gpl --enable-version3 \
		--enable-pthreads --enable-zlib \
		--enable-openssl \
		--enable-libx264 --enable-libsvtav1 --enable-libdav1d --enable-libmp3lame
	make -j"$JOBS"
	install -m 755 ffmpeg ffprobe "$OUT/bin/"
	cp COPYING.GPLv3 "$OUT/licenses/ffmpeg-COPYING.GPLv3"
	cp LICENSE.md "$OUT/licenses/ffmpeg-LICENSE.md"
}

build_openssl
build_x264
build_svtav1
build_dav1d
build_lame
build_ffmpeg

echo "built $("$OUT/bin/ffmpeg" -hide_banner -version | head -1)"
