# Builds the Windows installer: installer\windows\output\CamNexo-Setup-<version>.exe
# Needs Flutter, the native helpers built (native\windows\vcam\build\Release) and Inno Setup 6.
#
# Code signing (optional, removes the "unknown publisher" warnings once you own a certificate):
#   .\build.ps1 -Version 0.2.0 -SignArgs "/sha1 <certificate-thumbprint> /fd SHA256 /tr http://timestamp.digicert.com /td SHA256"
# SignArgs is passed to signtool.exe (Windows SDK) unchanged, so it also works with cloud signing services.
param([string]$Version = "0.1.0", [switch]$SkipFlutterBuild, [string]$SignArgs = "")
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Resolve-Path (Join-Path $here "..\..")
$stage = Join-Path $here "stage"

if (-not $SkipFlutterBuild) {
  Push-Location (Join-Path $root "apps\desktop"); flutter build windows --release; if ($LASTEXITCODE) { throw "flutter build failed" }; Pop-Location
}

Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$stage\app", "$stage\helpers" | Out-Null
Copy-Item "$root\apps\desktop\build\windows\x64\runner\Release\*" "$stage\app" -Recurse
# Flutter apps need the Visual C++ runtime; ship it next to the program so nothing else has to be installed.
foreach ($dll in "vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll") { Copy-Item "$env:WINDIR\System32\$dll" "$stage\app" }
foreach ($f in "camnexo_receiver.exe", "camnexo_vcam.exe", "camnexo_vcam_source.dll") {
  Copy-Item "$root\native\windows\vcam\build\Release\$f" "$stage\helpers"
}

# Background effects (ONNX Runtime and the person-matting model, about 27 MB) are NOT in the installer: the
# desktop app downloads them the first time Effects is used. See make-effects-pack.ps1. Only the licence
# text goes in here, as the notice for what that download contains.
Copy-Item "$root\native\windows\vcam\third_party\onnxruntime\LICENSE" "$stage\helpers\LICENSE-onnxruntime.txt"

function Sign-Files([string[]]$files) {
  if (-not $SignArgs) { return }
  $signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
  if (-not $signtool) { throw "signtool.exe not found. Install the Windows 10/11 SDK (Signing Tools)." }
  foreach ($f in $files) {
    & $signtool.FullName sign ($SignArgs -split " ") $f
    if ($LASTEXITCODE) { throw "Signing failed for $f" }
  }
}
# Our own binaries first, so the installer carries signed files.
Sign-Files @(
  "$stage\app\camnexo_desktop.exe", "$stage\app\window_manager_plugin.dll", "$stage\app\screen_retriever_windows_plugin.dll",
  "$stage\helpers\camnexo_receiver.exe", "$stage\helpers\camnexo_vcam.exe", "$stage\helpers\camnexo_vcam_source.dll")

$iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw "Inno Setup 6 not found. Install it with: winget install JRSoftware.InnoSetup" }
Push-Location $here
& $iscc "/DAppVersion=$Version" "/DStage=$stage" camnexo.iss
if ($LASTEXITCODE) { throw "Inno Setup failed" }
Pop-Location
Sign-Files @((Join-Path $here "output\CamNexo-Setup-$Version.exe"))
Get-Item (Join-Path $here "output\CamNexo-Setup-$Version.exe") | Select-Object FullName, Length
