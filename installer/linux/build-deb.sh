#!/usr/bin/env bash
# Builds the Debian package: installer/linux/output/camnexo_<version>_amd64.deb
#
# Needs (all built first): the Flutter bundle (apps/desktop: flutter build linux --release), the receiver
# (native/linux, with -DCAMNEXO_BUNDLED_LIBS=ON) and FFmpeg (native/linux/build-ffmpeg.sh).
#   installer/linux/build-deb.sh 0.1.0
set -euo pipefail

version="${1:-0.1.0}"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
bundle="$root/apps/desktop/build/linux/x64/release/bundle"
receiver="$root/native/linux/build/camnexo_receiver"
ffmpeg="$root/native/linux/third_party/ffmpeg/install"
pkg="$here/stage/camnexo_${version}_amd64"
out="$here/output"

for f in "$bundle/camnexo_desktop" "$receiver" "$ffmpeg/lib/libavcodec.so" "$root/brand/play-store-icon-512.png"; do
  [ -e "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

rm -rf "$here/stage"
mkdir -p "$pkg/DEBIAN" "$pkg/opt/camnexo/helpers/lib" "$pkg/usr/bin" "$pkg/usr/share/applications" \
  "$pkg/usr/share/icons/hicolor/512x512/apps" "$pkg/usr/share/doc/camnexo" "$pkg/etc/modprobe.d" "$pkg/etc/modules-load.d" "$out"

cp -a "$bundle/." "$pkg/opt/camnexo/"
install -m 755 "$receiver" "$pkg/opt/camnexo/helpers/camnexo_receiver"
cp -a "$ffmpeg"/lib/libavcodec.so* "$ffmpeg"/lib/libavutil.so* "$pkg/opt/camnexo/helpers/lib/"
cp "$ffmpeg/LICENSE-ffmpeg.txt" "$pkg/opt/camnexo/helpers/lib/"
cp "$root/native/windows/vcam/third_party/onnxruntime/LICENSE" "$pkg/opt/camnexo/helpers/LICENSE-onnxruntime.txt"
strip --strip-unneeded "$pkg/opt/camnexo/helpers/camnexo_receiver" "$pkg"/opt/camnexo/helpers/lib/libav*.so.* 2>/dev/null || true

ln -s /opt/camnexo/camnexo_desktop "$pkg/usr/bin/camnexo"
install -m 644 "$here/camnexo.desktop" "$pkg/usr/share/applications/camnexo.desktop"
install -m 644 "$root/brand/play-store-icon-512.png" "$pkg/usr/share/icons/hicolor/512x512/apps/camnexo.png"
install -m 644 "$here/copyright" "$pkg/usr/share/doc/camnexo/copyright"
echo 'options v4l2loopback devices=1 video_nr=10 card_label=CamNexo exclusive_caps=1' > "$pkg/etc/modprobe.d/camnexo.conf"
echo 'v4l2loopback' > "$pkg/etc/modules-load.d/camnexo.conf"
chmod 644 "$pkg/etc/modprobe.d/camnexo.conf" "$pkg/etc/modules-load.d/camnexo.conf"

size_kb=$(du -sk "$pkg" | cut -f1)
cat > "$pkg/DEBIAN/control" <<CONTROL
Package: camnexo
Version: $version
Section: video
Priority: optional
Architecture: amd64
Depends: libc6 (>= 2.35), libgtk-3-0, libavahi-client3
Recommends: v4l2loopback-dkms, avahi-daemon
Installed-Size: $size_kb
Maintainer: Yantrix Labs <yantrixlab@gmail.com>
Homepage: https://camnexo.yantrixlab.com
Description: Use your phone as a webcam for this computer
 CamNexo sends your phone's camera to this computer over your own Wi-Fi and shows it as a normal
 camera called CamNexo in Zoom, Google Meet, Teams, OBS and your browser. No account, no cloud.
 The virtual camera needs the v4l2loopback kernel module (package v4l2loopback-dkms).
CONTROL
cat > "$pkg/DEBIAN/conffiles" <<CONF
/etc/modprobe.d/camnexo.conf
/etc/modules-load.d/camnexo.conf
CONF
cat > "$pkg/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
  modprobe v4l2loopback >/dev/null 2>&1 || true
fi
exit 0
POST
chmod 755 "$pkg/DEBIAN/postinst"

find "$pkg" -type d -exec chmod 755 {} +
dpkg-deb --build --root-owner-group "$pkg" "$out/camnexo_${version}_amd64.deb"
ls -l "$out/camnexo_${version}_amd64.deb"
