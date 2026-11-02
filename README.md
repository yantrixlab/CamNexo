# CamNexo

Use your phone as a high-quality webcam. CamNexo streams your phone's camera to your computer
over your own Wi-Fi and shows up there as a normal camera in Zoom, Google Meet, Teams, OBS and
your browser. No account, no cloud: video goes straight from your phone to your computer.

Made by [Yantrix Labs](https://camnexo.yantrixlab.com). Licensed under the [Apache License 2.0](LICENSE).

## Status

Early access. What works today:

| Part | State |
|---|---|
| Phone app | Android 7+, [on Google Play](https://play.google.com/store/apps/details?id=com.camnexo.webcam). Camera, hardware H.264 encoding, front and back camera switching, background streaming, automatic discovery and reconnect |
| Desktop app | Windows 11. Live preview, several phones with layouts, background blur and replacement, colour looks, virtual camera |
| macOS, Linux, iOS | Planned, not started |
| Pairing and encryption | Not implemented yet. The stream is not encrypted. Use trusted networks only (see [SECURITY.md](SECURITY.md)) |

Download the Windows installer and read the safety notes at <https://camnexo.yantrixlab.com>.

## How it works

```
phone camera -> hardware H.264 encoder -> TCP over your Wi-Fi
   -> receiver (decode) -> frame pipe -> Windows virtual camera (Media Foundation)
   -> Zoom / Meet / Teams / OBS
```

The phone is found automatically with mDNS (`_camnexo._tcp`). The desktop app controls
resolution and frame orientation, and the phone follows. The wire format is documented in
[docs/PROTOCOL.md](docs/PROTOCOL.md) and the design in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Repository layout

| Folder | What is in it |
|---|---|
| `apps/mobile` | Flutter phone app, with Kotlin code for CameraX capture, the H.264 encoder, the foreground service and network discovery |
| `apps/desktop` | Flutter Windows app (preview and controls) |
| `native/windows/vcam` | C++ receiver, H.264 decoding and the Windows virtual camera source |
| `core` | Rust workspace: protocol definitions and shared code |
| `installer/windows` | Inno Setup script and build script for the Windows installer |
| `brand` | Logo and the script that generates every icon size |
| `docs` | Architecture and protocol documents |
| `tools` | Small developer tools |

## Build from source

You need Flutter (stable), Rust (stable), CMake, Visual Studio Build Tools with the C++ workload
(Windows), the Android SDK and Inno Setup 6 (for the installer).

```powershell
# Rust protocol tests
cd core; cargo test

# Windows native helpers: receiver, virtual camera launcher and source
cd native/windows/vcam
cmake -S . -B build -A x64
cmake --build build --config Release

# Windows desktop app and installer
cd installer/windows
./build.ps1 -Version 0.1.0     # output: installer/windows/output/CamNexo-Setup-0.1.0.exe

# Android phone app
cd apps/mobile
flutter build apk --release
```

Details for the virtual camera are in [native/windows/vcam/README.md](native/windows/vcam/README.md).

## Contributing

Bug reports, ideas and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).
Report security problems privately, as described in [SECURITY.md](SECURITY.md).

## Code signing

See [CODE_SIGNING_POLICY.md](CODE_SIGNING_POLICY.md).

## License and trademarks

Copyright 2026 Yantrix Labs. The code and the logo files in this repository are released under the
Apache License 2.0. As the license says (section 6), it does not give you the right to use the
CamNexo name or logo to suggest that your build or product is the official one. Please rename
and rebrand forks and modified builds.
