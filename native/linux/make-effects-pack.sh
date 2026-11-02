#!/usr/bin/env bash
# Builds the downloadable "effects pack" for Linux: ONNX Runtime (MIT) and the MODNet person-matting
# model (Apache-2.0) that the receiver loads for background blur and replacement. The package does not
# carry them (that keeps it small); the desktop app downloads this archive the first time Effects is used.
#
#   native/linux/make-effects-pack.sh        -> native/linux/dist/CamNexo-Effects-linux-x64-<PACK_VERSION>.tar.gz
#
# Publish the archive on the website (web/downloads/effects/), then put its URL, size and SHA-256 (printed
# at the end) into apps/desktop/lib/effects_pack.dart. Change PACK_VERSION whenever the contents change.
set -euo pipefail

PACK_VERSION=1
ORT_VERSION=1.22.0
ORT_SHA256=8344d55f93d5bc5021ce342db50f62079daf39aaafb5d311a451846228be49b3  # onnxruntime-linux-x64

here="$(cd "$(dirname "$0")" && pwd)"
vcam="$here/../windows/vcam"
cache="$here/third_party/onnxruntime/cache"
stage="$here/dist/stage"
out="$here/dist/CamNexo-Effects-linux-x64-$PACK_VERSION.tar.gz"
tgz="$cache/onnxruntime-linux-x64-$ORT_VERSION.tgz"

mkdir -p "$cache" "$here/dist"
if [ ! -f "$tgz" ]; then
  curl -fsSL -o "$tgz" "https://github.com/microsoft/onnxruntime/releases/download/v$ORT_VERSION/onnxruntime-linux-x64-$ORT_VERSION.tgz"
fi
echo "$ORT_SHA256  $tgz" | sha256sum -c - >/dev/null || { rm -f "$tgz"; echo "ONNX Runtime download does not match the pinned checksum." >&2; exit 1; }

rm -rf "$stage"
mkdir -p "$stage/models" "$cache/x"
# Only the real library file (the archive also has symlinks to it, which not every system can unpack).
tar -xzf "$tgz" -C "$cache/x" "onnxruntime-linux-x64-$ORT_VERSION/lib/libonnxruntime.so.$ORT_VERSION" "onnxruntime-linux-x64-$ORT_VERSION/LICENSE"
src="$cache/x/onnxruntime-linux-x64-$ORT_VERSION"
cp "$src/lib/libonnxruntime.so.$ORT_VERSION" "$stage/libonnxruntime.so"
cp "$src/LICENSE" "$stage/LICENSE-onnxruntime.txt"
cp "$vcam/models/modnet.onnx" "$stage/models/modnet.onnx"
cp "$vcam/models/README.md" "$stage/NOTICE-models.txt"
rm -rf "$cache/x"

rm -f "$out"
tar -czf "$out" -C "$stage" .
rm -rf "$stage"

size=$(stat -c %s "$out")
echo
echo "Effects pack: $out"
echo "  size   : $size bytes"
echo "  sha256 : $(sha256sum "$out" | cut -d' ' -f1)"
