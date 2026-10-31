# CamNexo architecture

Phone: capture -> optional GPU effects -> hardware H.264/H.265 encode -> framed, encrypted stream.
Desktop: receive -> jitter buffer (1-2 frames) -> hardware decode (NV12) -> virtual camera.
No video passes through any server.

| Platform | UI | Camera / codec | Virtual camera |
|---|---|---|---|
| Android | Flutter | CameraX/Camera2 + MediaCodec | none (sender) |
| iOS | Flutter | AVFoundation + VideoToolbox | none (sender) |
| Windows | Flutter | Media Foundation (FFmpeg fallback) | MF virtual camera (Win11), DirectShow filter (Win10) |
| macOS | Flutter | VideoToolbox | CoreMediaIO Camera Extension |
| Linux | Flutter | FFmpeg / VA-API | v4l2loopback |

Shared Rust core (`core/`) exposes discovery, pairing, encryption, framing, jitter buffer and stats to Flutter via flutter_rust_bridge.

Targets: under 150 ms glass-to-screen on Wi-Fi, under 80 ms on USB, 1080p30 default. Adaptive quality lowers bitrate, then fps, then resolution.

Full plan, phases and gates: see the approved plan (Phase 0 starts with the Windows virtual camera spike).
