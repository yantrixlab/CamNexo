# Windows virtual camera spike (Phase 0, Gate 0)

A Media Foundation virtual camera (`MFCreateVirtualCamera`, Windows 11) that shows a 1280x720 NV12 test pattern at 30 fps: rotating colour bars plus a moving white box. It proves the "appear in Zoom/Meet/OBS/Teams" path before any phone or networking code exists.

- `src/source.cpp` - `camnexo_vcam_source.dll`: media source + stream, loaded by the Windows Frame Server.
- `src/vcam_main.cpp` - `camnexo_vcam.exe`: `register`, `unregister`, `run`.
- Static CRT, so the DLL only imports `MFPlat` and `KERNEL32`.

## Build

```powershell
cmake -S . -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
```

## Test (Windows 11)

1. Admin PowerShell, from this folder: `.\build\Release\camnexo_vcam.exe register`
   (copies the DLL to `C:\ProgramData\CamNexo\vcam` and writes `HKLM\Software\Classes\CLSID\{5E6B7C2A-...}`).
2. Normal PowerShell: `.\build\Release\camnexo_vcam.exe run`, then leave it open.
3. Open the Windows Camera app, then Zoom, Meet (browser), Teams, OBS. Select **CamNexo**.
4. Press Enter in the `run` window to remove the camera. `camnexo_vcam.exe unregister` (admin) removes the registration.

Debug output from the source uses `OutputDebugString` (view with DebugView, "Capture Global Win32").

## Gate 0 results (fill in)

| App | Win11 | Notes |
|---|---|---|
| Windows Camera | Pass (2026-10-31) | Colour bars + moving box visible, 30 fps |
| Chrome / Meet | | |
| Zoom | | |
| Teams | | |
| OBS | | |

## What the Frame Server needed (lessons)

- The registered CLSID must be an `IMFActivate`; `ActivateObject` returns the media source (otherwise `E_NOINTERFACE`).
- Source also implements `IMFMediaSource2`, `IMFGetService`, `IKsControl`, `IMFSampleAllocatorControl`; stream implements `IMFMediaStream2`.
- Stream descriptor needs `MF_DEVICESTREAM_STREAM_CATEGORY` (`PINNAME_VIDEO_CAPTURE`), `STREAM_ID`, `FRAMESERVER_SHARED`, `FRAMESOURCE_TYPES`.
- Source attributes carry a sensor-profile collection (Legacy + HighFrameRate).
- **Sample timestamps must be absolute system time** (`MFGetSystemTime()`), not time since start. Relative stamps are dropped silently and `ReadSample` fails with `0xC00D3EA2` after a long wait.
- The Frame Server holds the DLL loaded: replace it with `dev-reload.ps1` (admin). Logs: `%ProgramData%\CamNexo\vcam\vcam-<pid>.log`, one file per process.
- Diagnostics: `camnexo_vcam selftest` (in-process), `camnexo_vcam probe [name]` (reads frames like an app does).

## Known gaps

- Fixed 1280x720 NV12 only; no frame input yet (the real source will read decoded frames from shared memory).
- Session-lifetime camera; the real app will manage lifetime from the desktop app.
- Windows 10 needs a separate DirectShow source filter (not started).
- No logging to file: the Frame Server runs as LocalService and cannot write to user folders.
