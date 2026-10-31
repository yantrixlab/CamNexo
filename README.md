# CamNexo

Turn your phone into a webcam for Windows, macOS and Linux. By Yantrix Labs.

- Phone app (Android, iOS): capture, effects, hardware encode, stream.
- Desktop app (Windows, macOS, Linux): receive, decode, expose as a virtual camera.
- Shared Rust core (`core/`) for discovery, pairing, encryption, framing, jitter buffer and stats.
- Flutter UIs (`apps/`), native camera/codec/virtual-camera code (`native/`).

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Toolchain needed

Rust (stable), Flutter (stable), CMake, Android SDK (adb is already present), Visual Studio Build Tools (Windows virtual camera).
