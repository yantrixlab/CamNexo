# ONNX Runtime

`include/onnxruntime_c_api.h` is the C API header from ONNX Runtime 1.22.0 (MIT License, see `LICENSE`).
The receiver loads `onnxruntime.dll` at run time and works without it (effects are then switched off).
The DLL is not stored in the repository: `fetch-onnxruntime.ps1` downloads the official release archive
(checked against a pinned SHA-256) and `installer/windows/build.ps1` ships it next to the receiver.
