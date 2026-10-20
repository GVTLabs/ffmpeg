# syntax=docker/dockerfile:1

FROM alpine:3.22 AS build
RUN apk add --no-cache \
	bash build-base cmake curl git linux-headers meson nasm ninja perl pkgconf tar xz \
	zlib-dev zlib-static
WORKDIR /src
COPY versions.env build.sh ./
RUN ./build.sh /out
COPY test.sh ./
RUN apk add --no-cache binutils && ./test.sh /out/bin

# `docker buildx build --target dist --output type=local,dest=DIR` writes the
# release contents (bin/, licenses/) to DIR.
FROM scratch AS dist
COPY --from=build /out/ /

# Published as ghcr.io/gvtlabs/ffmpeg:<version>. Images take the binaries with
#   COPY --from=ghcr.io/gvtlabs/ffmpeg:<version> /ffmpeg /ffprobe /usr/local/bin/
FROM scratch AS image
COPY --from=build /out/bin/ffmpeg /out/bin/ffprobe /
COPY --from=build /out/licenses/ /licenses/
