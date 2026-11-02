#!/usr/bin/env bash
# CI: loads v4l2loopback, runs the Linux receiver with one test camera and captures three frames from the
# virtual camera, so the whole path "receiver -> /dev/videoN -> a reader" is checked.
set -euxo pipefail

sudo apt-get install -y v4l2loopback-dkms v4l-utils "linux-headers-$(uname -r)" || sudo apt-get install -y v4l2loopback-dkms v4l-utils
dkms status || true
sudo modprobe v4l2loopback devices=1 video_nr=10 card_label=CamNexo exclusive_caps=1
cat /sys/class/video4linux/video10/name

cd native/linux/build
(./camnexo_receiver --simulate 1 --no-discovery --port 7998 --preview-socket /tmp/camnexo-ci2.sock > /tmp/receiver2.log 2>&1 &)
sleep 5
cat /tmp/receiver2.log
grep -q "\[v4l2\] ready /dev/video10" /tmp/receiver2.log
v4l2-ctl -d /dev/video10 --get-fmt-video
v4l2-ctl -d /dev/video10 --stream-mmap --stream-count=3 --stream-to=/tmp/cam.raw
size=$(stat -c %s /tmp/cam.raw)
echo "captured $size bytes (3 frames of 1920x1080 YUYV are 12441600)"
test "$size" -eq 12441600
pkill camnexo_receiver || true
