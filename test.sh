#!/bin/sh
# Smoke-tests a built ffmpeg/ffprobe: each codec, filter and format the build
# promises is present and works. POSIX sh so it runs as-is on Alpine, Debian,
# Ubuntu and macOS, which is how CI shows the Linux binaries need no host libraries.
#
# Usage: ./test.sh BIN_DIR
set -eu

if [ $# -ne 1 ]; then
	echo "usage: $0 BIN_DIR" >&2
	exit 2
fi

ROOT=$(cd "$(dirname "$0")" && pwd)
. "$ROOT/versions.env"
BIN=$(cd "$1" && pwd)
FF=$BIN/ffmpeg
FP=$BIN/ffprobe
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

step() {
	echo "--- $*"
}

step "version"
for b in "$FF" "$FP"; do
	"$b" -hide_banner -version | head -1 | grep -q "version $FFMPEG_VERSION-gvtlabs " ||
		fail "$b: expected $FFMPEG_VERSION-gvtlabs, got: $("$b" -hide_banner -version | head -1)"
done

step "linkage"
case $(uname -s) in
Linux)
	# A static binary has no program interpreter (dynamic loader) to ask for.
	if command -v readelf >/dev/null; then
		for b in "$FF" "$FP"; do
			readelf -l "$b" | grep -q "Requesting program interpreter" && fail "$b is dynamically linked"
		done
	fi
	;;
Darwin)
	for b in "$FF" "$FP"; do
		extra=$(otool -L "$b" | tail -n +2 | awk '{print $1}' | grep -vE '^/usr/lib/(libSystem\.B|libz\.1)\.dylib$' || true)
		[ -z "$extra" ] || fail "$b links libraries that are not on every Mac: $extra"
	done
	;;
esac

# has KIND COLUMN NAME... checks `ffmpeg -KIND` lists each NAME in COLUMN.
has() {
	kind=$1 col=$2
	shift 2
	"$FF" -hide_banner "-$kind" >"$T/list" 2>/dev/null
	for n in "$@"; do
		awk -v n="$n" -v c="$col" '$c == n { found = 1 } END { exit !found }' "$T/list" ||
			fail "missing $kind: $n"
	done
}

step "components"
has encoders 2 libx264 libsvtav1 libmp3lame aac mjpeg png pcm_s16le
has decoders 2 libdav1d h264 hevc vp9 vp8 aac mp3 opus mjpeg png webp
has muxers 2 mp4 avif hls image2 null wav mp3 matroska
has demuxers 2 mov,mp4,m4a,3gp,3g2,mj2 hls matroska,webm image2 wav mp3
has filters 2 showinfo select scale crop pad fps tile format setsar aresample
has protocols 1 https http file pipe

step "h264 + aac in mp4"
"$FF" -nostdin -v error -f lavfi -i testsrc2=size=320x240:rate=25:duration=2 \
	-f lavfi -i sine=frequency=440:duration=2 \
	-c:v libx264 -preset veryfast -crf 23 -c:a aac -b:a 128k -movflags +faststart \
	"$T/av.mp4"
codecs=$("$FP" -v error -show_entries stream=codec_name -of csv=p=0 "$T/av.mp4" | tr '\n' ' ')
[ "$codecs" = "h264 aac " ] || fail "unexpected streams in av.mp4: $codecs"

step "hls fmp4 packaging"
mkdir "$T/hls"
"$FF" -nostdin -v error -i "$T/av.mp4" -c copy -f hls -hls_time 1 -hls_playlist_type vod \
	-hls_segment_type fmp4 -hls_segment_filename "$T/hls/seg_%03d.m4s" "$T/hls/index.m3u8"
grep -q '#EXT-X-MAP:URI="init.mp4"' "$T/hls/index.m3u8" || fail "hls playlist has no fmp4 init segment"
ls "$T"/hls/seg_*.m4s >/dev/null || fail "hls wrote no segments"

step "avif with libsvtav1, decoded with libdav1d"
"$FF" -nostdin -v error -f lavfi -i testsrc2=size=128x128:rate=10:duration=1 \
	-c:v libsvtav1 -pix_fmt yuv420p -crf 40 -preset 8 -svtav1-params lp=2:lookahead=0 -an \
	"$T/preview.avif" 2>/dev/null
stream=$("$FP" -v error -select_streams v:0 -show_entries stream=codec_name,width,height -of csv=p=0 "$T/preview.avif")
[ "$stream" = "av1,128,128" ] || fail "unexpected preview.avif stream: $stream"
"$FF" -nostdin -v error -c:v libdav1d -i "$T/preview.avif" -map 0:v -f null - || fail "libdav1d could not decode preview.avif"

step "mp3 audio extraction"
"$FF" -nostdin -v error -i "$T/av.mp4" -vn -c:a libmp3lame -q:a 4 "$T/audio.mp3"
[ "$("$FP" -v error -show_entries stream=codec_name -of csv=p=0 "$T/audio.mp3")" = mp3 ] ||
	fail "audio.mp3 is not mp3"

step "jpeg frames, showinfo timestamps and tiling"
"$FF" -nostdin -i "$T/av.mp4" -vf "select='not(mod(n\,10))',showinfo,scale=64:-2,tile=2x2" \
	-frames:v 1 -q:v 2 -f image2 -c:v mjpeg "$T/tile.jpg" 2>"$T/showinfo.log"
grep -q 'pts_time:' "$T/showinfo.log" || fail "showinfo printed no timestamps"
[ "$("$FP" -v error -show_entries stream=codec_name -of csv=p=0 "$T/tile.jpg")" = mjpeg ] ||
	fail "tile.jpg is not a jpeg"

step "ffprobe json"
"$FP" -v error -show_entries format=duration:stream=width,height -of json "$T/av.mp4" |
	grep -q '"width": 320' || fail "ffprobe json has no width"

echo "PASS"
