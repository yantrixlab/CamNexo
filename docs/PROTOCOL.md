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
| 24 | 4 | reserved (zero) |

The header is followed by `payload_len` bytes (one encoded access unit, or a control message).

## Transport

MVP: one Noise-encrypted TCP session (Wi-Fi socket, or `adb reverse` / usbmuxd tunnel). The sender drops stale frames instead of queueing when the link slows. A `Transport` trait keeps UDP as a later option without touching video code.

## Control messages (to be specified)

hello/caps, pair, set-camera, zoom, focus/exposure lock, torch, mirror, rotation, bitrate/fps/resolution change, request-keyframe, stats report (RTT, loss), battery/thermal warning, ping.

## Pairing and security

Desktop shows a QR with address, port and one-time key. Noise XX on first pairing, IK on reconnect with stored public keys. Only paired phones may connect; no port is exposed beyond the LAN by default.
