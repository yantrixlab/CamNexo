# CamNexo wire protocol v1

Implemented in `core/camnexo-proto`. All integers little-endian.

## Frame header (28 bytes)

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | version (1) |
| 1 | 1 | packet type: 0 video, 1 keyframe, 2 control |
| 2 | 1 | codec: 0 H.264, 1 H.265 |
| 3 | 1 | flags |
| 4 | 4 | seq |
| 8 | 8 | timestamp_us (sender clock) |
| 16 | 2 | width |
| 18 | 2 | height |
| 20 | 4 | payload_len (max 16 MiB) |
| 24 | 2 | rotation: clockwise degrees (0, 90, 180, 270) that make the decoded picture upright |
| 26 | 2 | reserved (zero) |

The header is followed by `payload_len` bytes (one encoded access unit, or a control message).

`flags` bit 0 (`FLAG_CONFIG`): the payload is H.264 SPS/PPS in Annex B form. The sender emits it once after the encoder starts; the receiver prepends the latest config to every keyframe before decoding.

Video payloads are Annex B H.264 (start codes), Baseline profile, no B-frames, 1 s keyframe interval. The sender drops frames when its queue is full and then waits for the next keyframe (requested immediately).

## MVP connection (development)

The phone connects to `PC_IP:7878` over plain TCP (or `127.0.0.1:7878` through `adb reverse tcp:7878 tcp:7878`). Encryption, QR pairing and mDNS discovery are not implemented yet.

## Transport

MVP: one Noise-encrypted TCP session (Wi-Fi socket, or `adb reverse` / usbmuxd tunnel). The sender drops stale frames instead of queueing when the link slows. A `Transport` trait keeps UDP as a later option without touching video code.

## Control messages

Packet type 2. The first payload byte is the message kind. All numbers are little endian.

| Kind | Direction | Payload | Meaning |
|---|---|---|---|
| 1 | computer to phone | `{1, mode, flip}` | Orientation. The receiver always sends mode 0: the phone follows its own sensor and sends an upright picture. |
| 2 | computer to phone | `{2, u16 width, u16 height}` | Capture size. 0x0 means Auto. |
| 3 | phone to computer | `{3, count, count x (u16 w, u16 h), u16 curW, u16 curH, auto}` | The sizes the phone supports, the one in use, and whether Auto is on. Re-sent every few seconds. |
| 4 | phone to computer | `{4, utf-8 text}` | The name of the phone (for example its model), shown in the camera list. |

Not yet specified: pair, set-camera, zoom, focus/exposure lock, torch, mirror, bitrate/fps change, request-keyframe, stats report (RTT, loss), battery/thermal warning, ping.

## Several phones

The receiver accepts up to 8 phones at once. Each connection has its own decoder and a number (shown as `[src N]` in the receiver log). The receiver composes the latest picture of every phone into one 16:9 output frame, following a layout the desktop app sends on the receiver's standard input:

```
layout <n> {<src> <x> <y> <w> <h> <cover>} x n
```

x, y, w and h are fractions of the frame; `cover` 1 fills the cell and crops, 0 fits the whole picture; `src` -1 leaves the cell black. That frame is what the virtual camera shows. With one camera the frame follows the picture size (up to 4K); with several it is 1920x1080. Other commands: `resolution <src> auto|<w> <h>`, `flip <src> <0|1>`, `disconnect <src>`, `simulate <n>` (test cameras).

## Pairing and security

Desktop shows a QR with address, port and one-time key. Noise XX on first pairing, IK on reconnect with stored public keys. Only paired phones may connect; no port is exposed beyond the LAN by default.
