# CamNexo for Linux

The Linux desktop app is the same Flutter app as on Windows (`apps/desktop`) with a Linux receiver
(`receiver/receiver_linux.cpp`) in place of the Windows one. The picture and effects code
(`../windows/vcam/src/draw.cpp`, `effects.cpp`) is shared.

```
phone --TCP 7878--> receiver --FFmpeg H.264 decode--> compositor (layouts, effects)
                                                        |--> /dev/videoN  (v4l2loopback, "CamNexo")
                                                        '--> Unix socket   (preview in the app window)
```

## Build

```bash
sudo apt install build-essential cmake pkg-config libavcodec-dev libavutil-dev libavahi-client-dev
cmake -S native/linux -B native/linux/build -DCMAKE_BUILD_TYPE=Release
cmake --build native/linux/build -j
native/linux/build/camnexo_receiver --simulate 2 --no-v4l2 --snap /tmp/frame.bmp   # test cameras, no phone needed
```

Options: `--port N`, `--no-discovery`, `--no-v4l2`, `--device /dev/videoN`, `--out WxH` (size of the virtual camera
picture, default 1920x1080), `--snap file.bmp`, `--preview-socket path`, `--simulate N`,
`--fx-test in.png out.bmp <0 none|1 blur|2 replace|3 filters> [background.png]`.

## The virtual camera

The camera is a `v4l2loopback` device whose card label is `CamNexo`. The receiver looks for it by that label
and writes YUYV pictures into it. It looks again every two seconds, so loading the module while the app is
running is enough.

```bash
sudo apt install v4l2loopback-dkms
sudo modprobe v4l2loopback devices=1 video_nr=10 card_label=CamNexo exclusive_caps=1
```

To load it at every start, put `options v4l2loopback devices=1 video_nr=10 card_label=CamNexo exclusive_caps=1`
in `/etc/modprobe.d/camnexo.conf` and `v4l2loopback` in `/etc/modules-load.d/camnexo.conf`.

**Secure Boot:** with Secure Boot on, the kernel only loads signed modules. Ubuntu and Debian sign DKMS modules
with a key you enrol once (`mokutil`, asked for during the `v4l2loopback-dkms` install, and approved at the next
boot). On other distributions follow their DKMS or MOK instructions.

## Effects

Background blur and replacement need ONNX Runtime and the MODNet model (about 31 MB). They are not part of the
package: the desktop app downloads them once into `~/.local/share/camnexo/effects` when Effects is first used.
Build the archive with `make-effects-pack.sh` and publish it as described in that script.

## Licenses of what we use

- FFmpeg (libavcodec, libavutil): LGPL-2.1 or later when built without GPL parts. Packages built for
  distribution must link it dynamically and use an LGPL build.
- Avahi client: LGPL-2.1 or later.
- ONNX Runtime: MIT. MODNet: Apache-2.0. stb_image (`third_party/stb`, v2.30, public domain / MIT):
  sha256 `594c2fe35d49488b4382dbfaec8f98366defca819d916ac95becf3e75f4200b3`.
