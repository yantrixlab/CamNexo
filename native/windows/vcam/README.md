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

## Phone to PC (development setup)

1. `camnexo_vcam run` (keeps the "CamNexo" virtual camera alive; Enter removes it).
2. `camnexo_receiver` (TCP :7878 -> H.264 decode -> frame pipe `\\.\pipe\camnexo-frames` -> virtual camera). It prints the addresses to enter in the phone app. Windows asks once to allow it through the firewall.
3. Phone app: enter the PC address and tap Connect. For USB, run `adb reverse tcp:7878 tcp:7878` and use `127.0.0.1`.
4. Pick "CamNexo" in the video app. With no phone connected the camera shows the colour-bar test pattern.

Check the output without a video app: `camnexo_vcam probe CamNexo frame.bmp` saves one frame.

Rotation: the phone follows how it is physically held and sends a clockwise rotation in every packet; the receiver rotates and fits the picture into 1280x720 (portrait gets black side bars, landscape fills the frame). Checked in portrait and landscape, including turning while streaming. Not checked: upside-down, back camera.

`camnexo_receiver --snap frame.bmp` rewrites a BMP of the latest frame every 2 seconds, for checking the picture without a video app.

Known limits of this slice: plain TCP (no encryption or pairing yet); fixed 1280x720 output; one phone at a time.

## What the Frame Server needed (lessons)

- Never fail-fast the service by stopping it while apps (Teams, Camera) hold the camera: the Frame Server was killed by its watchdog repeatedly while testing. `Start-Service FrameServer` brings it back without admin.
- A source DLL copy works without stopping the service whenever the service does not currently have the DLL loaded (`tasklist /m camnexo_vcam_source.dll`).

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
