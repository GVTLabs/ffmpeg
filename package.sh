#!/bin/sh
# Packs a build.sh output directory (or the complete corresponding source) into
# a release tarball and its checksum.
# mise's github backend picks the asset for a host by the OS and arch words in
# the file name, so keep NAME's "linux"/"macos" and "x86_64"/"arm64" parts, and
# keep the source archive free of OS and arch words so mise ignores it.
#
# Usage:
#   ./package.sh BUILD_DIR OS ARCH OUT_DIR
#   ./package.sh source OUT_DIR
set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
. "$ROOT/versions.env"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

if [ "${1:-}" = source ] && [ $# -eq 2 ]; then
	NAME=ffmpeg-$FFMPEG_VERSION-source
	mkdir -p "$2"
	OUT=$(cd "$2" && pwd)
	mkdir -p "$STAGE/$NAME"
	cp -R "$ROOT/Dockerfile" "$ROOT/LICENSE" "$ROOT/README.md" \
		"$ROOT/build.sh" "$ROOT/package.sh" "$ROOT/test.sh" "$ROOT/versions.env" \
		"$STAGE/$NAME/"
	if [ -d "$ROOT/.build/src" ] && [ ! -e "$ROOT/.build/src/ffmpeg/config.h" ]; then
		WORK=$ROOT/.build "$ROOT/build.sh" --fetch-only
		mkdir -p "$STAGE/$NAME/.build"
		cp -R "$ROOT/.build/src" "$STAGE/$NAME/.build/src"
	else
		WORK=$STAGE/$NAME/.build "$ROOT/build.sh" --fetch-only
		mkdir -p "$ROOT/.build"
		[ -d "$ROOT/.build/src" ] || cp -R "$STAGE/$NAME/.build/src" "$ROOT/.build/src"
	fi
elif [ $# -eq 4 ]; then
	NAME=ffmpeg-$FFMPEG_VERSION-$2-$3
	mkdir -p "$4"
	OUT=$(cd "$4" && pwd)
	cp -R "$1" "$STAGE/$NAME"
	chmod 755 "$STAGE/$NAME/bin/"*
else
	echo "usage: $0 BUILD_DIR OS ARCH OUT_DIR | $0 source OUT_DIR" >&2
	exit 2
fi

XZ_OPT=${XZ_OPT:--T0} tar -C "$STAGE" -cJf "$OUT/$NAME.tar.xz" "$NAME"
cd "$OUT"
if command -v sha256sum >/dev/null; then
	sha256sum "$NAME.tar.xz" >"$NAME.tar.xz.sha256"
else
	shasum -a 256 "$NAME.tar.xz" >"$NAME.tar.xz.sha256"
fi
echo "$OUT/$NAME.tar.xz"
