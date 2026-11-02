#!/usr/bin/env bash
# Builds a small, LGPL-only FFmpeg for the receiver: just the H.264 decoder, in shared libavcodec and
# libavutil. Packages carry these two libraries next to the receiver, so one package works on every
# distribution (the FFmpeg that distributions ship has a different, incompatible version on each of them).
#
#   native/linux/build-ffmpeg.sh        -> native/linux/third_party/ffmpeg/install  (lib/, include/, lib/pkgconfig/)
#
# Needs: a C compiler, make, nasm (for the fast x86 code), curl, xz. No GPL parts are enabled, so the result
# is LGPL-2.1-or-later and may be linked dynamically from Apache-2.0 code. The receiver's source is public and
# FFmpeg's source for this exact version is the tarball named below; the package carries FFmpeg's license text.
set -euo pipefail

VERSION=7.1.5
SHA256=de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f

here="$(cd "$(dirname "$0")" && pwd)"
work="$here/third_party/ffmpeg"
prefix="$work/install"
tarball="$work/ffmpeg-$VERSION.tar.xz"

if [ -f "$prefix/lib/libavcodec.so" ] && [ -f "$prefix/lib/pkgconfig/libavcodec.pc" ]; then
  echo "FFmpeg $VERSION already built in $prefix"
  exit 0
fi

mkdir -p "$work"
if [ ! -f "$tarball" ]; then
  curl -fsSL -o "$tarball" "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
fi
echo "$SHA256  $tarball" | sha256sum -c - >/dev/null || { rm -f "$tarball"; echo "FFmpeg download does not match the pinned checksum." >&2; exit 1; }

rm -rf "$work/src"
mkdir -p "$work/src"
tar -xJf "$tarball" -C "$work/src" --strip-components=1
cd "$work/src"

./configure \
  --prefix="$prefix" \
  --enable-shared --disable-static --enable-pic \
  --disable-programs --disable-doc --disable-debug \
  --disable-avdevice --disable-avformat --disable-avfilter --disable-swscale --disable-swresample \
  --disable-network --disable-autodetect \
  --disable-everything --enable-decoder=h264 --enable-parser=h264

make -j"$(nproc)"
make install
cp COPYING.LGPLv2.1 "$prefix/LICENSE-ffmpeg.txt"
echo "FFmpeg $VERSION installed in $prefix"
