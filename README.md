# ffmpeg

Static `ffmpeg` and `ffprobe` builds, built from source at pinned versions for:

| Platform     | Release asset                          |
| ------------ | -------------------------------------- |
| linux x86_64 | `ffmpeg-<version>-linux-x86_64.tar.xz` |
| linux arm64  | `ffmpeg-<version>-linux-arm64.tar.xz`  |
| macOS arm64  | `ffmpeg-<version>-macos-arm64.tar.xz`  |
| source       | `ffmpeg-<version>-source.tar.xz`       |

The Linux binaries are fully static (musl), so the same file runs on Debian,
Ubuntu and Alpine. The macOS binaries link only `libSystem` and `libz`, which
every Mac has.

## What is in the build

A small, fixed set of libraries. Everything else is off (`--disable-autodetect`),
so the build host cannot add features without a change here.

| Library    | Used for                      |
| ---------- | ----------------------------- |
| libx264    | H.264 encoding                |
| libsvtav1  | AV1 encoding (including AVIF) |
| libdav1d   | AV1 decoding                  |
| libmp3lame | MP3 encoding                  |
| OpenSSL    | `https://` inputs             |
| zlib       | PNG, compressed MP4 headers   |

ffmpeg's built-in codecs, muxers and filters (AAC, MJPEG, HLS, `showinfo`,
`scale`, ...) are all present. There is no hardware acceleration and no `ffplay`.
Exact versions are in [`versions.env`](versions.env); `test.sh` lists every
feature that CI checks.

## Use

Docker:

```dockerfile
COPY --from=ghcr.io/gvtlabs/ffmpeg:7.1.5 /ffmpeg /ffprobe /usr/local/bin/
```

mise:

```toml
[tools]
"github:GVTLabs/ffmpeg" = "7.1.5"
```

## Build locally

```sh
# Linux, in Docker (writes bin/ and licenses/ to out/)
docker buildx build --platform linux/arm64 --target dist --output type=local,dest=out .

# macOS (needs cmake, meson, ninja, pkgconf)
./build.sh out && ./test.sh out/bin
```

## Release

1. Change [`versions.env`](versions.env) in a PR. CI builds and tests every platform.
2. After merge, tag `main` with `v<FFMPEG_VERSION>`, for example `v7.1.5`. To
   rebuild the same ffmpeg version with changed libraries, use `v<FFMPEG_VERSION>-<n>`.
3. The tag workflow publishes the GitHub release and `ghcr.io/gvtlabs/ffmpeg:<tag without v>`.

Releases are immutable: do not move or delete a tag that images or `mise.lock`
already use.

## Licence

The binaries are GPL v3 (`--enable-gpl --enable-version3`: x264 is GPL, and
OpenSSL 3's Apache 2.0 licence is only compatible with GPL v3). Each release
tarball and image includes the licence of every linked library in `licenses/`,
and each release publishes `ffmpeg-<version>-source.tar.xz` with the complete
corresponding source (`versions.env`, `build.sh` and every upstream source
tree). Do not add `--enable-nonfree` libraries such as `libfdk_aac`: the result
cannot be distributed, and this repository and its releases are public.

The build scripts in this repository are under the [MIT licence](LICENSE).
