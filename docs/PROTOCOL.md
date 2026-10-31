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

## Control messages (to be specified)

hello/caps, pair, set-camera, zoom, focus/exposure lock, torch, mirror, rotation, bitrate/fps/resolution change, request-keyframe, stats report (RTT, loss), battery/thermal warning, ping.

## Pairing and security

Desktop shows a QR with address, port and one-time key. Noise XX on first pairing, IK on reconnect with stored public keys. Only paired phones may connect; no port is exposed beyond the LAN by default.
