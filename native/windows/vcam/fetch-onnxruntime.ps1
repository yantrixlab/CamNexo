# Downloads the official ONNX Runtime 1.22.0 release for Windows (MIT license), checks it against a
# pinned SHA-256 and puts onnxruntime.dll next to where the build expects it.
# Run once before building the receiver and the installer:  .\fetch-onnxruntime.ps1
$ErrorActionPreference = "Stop"
$version = "1.22.0"
$sha256 = "174C616EFC0271194488642A72F1A514E01487DA4DFE84C49296D66E40EBE0DA"
$root = Join-Path $PSScriptRoot "third_party\onnxruntime"
$bin = Join-Path $root "bin"
if ((Test-Path "$bin\onnxruntime.dll") -and (Test-Path "$bin\onnxruntime_providers_shared.dll")) { Write-Host "ONNX Runtime already fetched."; return }
$cache = Join-Path $root "cache"
New-Item -ItemType Directory -Force $cache, $bin | Out-Null
$zip = Join-Path $cache "onnxruntime-win-x64-$version.zip"
if (-not (Test-Path $zip)) {
  Invoke-WebRequest -Uri "https://github.com/microsoft/onnxruntime/releases/download/v$version/onnxruntime-win-x64-$version.zip" -OutFile $zip -UseBasicParsing
}
if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $sha256) { Remove-Item $zip; throw "ONNX Runtime download does not match the pinned checksum." }
$tmp = Join-Path $cache "x"
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive $zip -DestinationPath $tmp
Copy-Item "$tmp\onnxruntime-win-x64-$version\lib\onnxruntime.dll", "$tmp\onnxruntime-win-x64-$version\lib\onnxruntime_providers_shared.dll" $bin
Remove-Item $tmp -Recurse -Force
Write-Host "ONNX Runtime $version ready in $bin"
