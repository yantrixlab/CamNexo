# Builds the downloadable "effects pack": ONNX Runtime and the person-matting model that the receiver
# loads for background blur and replacement. They are not part of the installer (that keeps it small);
# the desktop app downloads this zip the first time someone turns on Effects.
#
#   .\make-effects-pack.ps1            -> installer\windows\output\CamNexo-Effects-<PackVersion>.zip
#
# Publish the zip on the website (web/downloads/effects/), then put its URL, size and SHA-256 (printed
# at the end) into apps/desktop/lib/effects_pack.dart. Change PackVersion whenever the contents change.
param([int]$PackVersion = 1)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Resolve-Path (Join-Path $here "..\..")
$vcam = Join-Path $root "native\windows\vcam"
$stage = Join-Path $here "effects-stage"
$out = Join-Path $here "output"
$zip = Join-Path $out "CamNexo-Effects-$PackVersion.zip"

& "$vcam\fetch-onnxruntime.ps1"

Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$stage\models", $out | Out-Null
foreach ($f in "onnxruntime.dll", "onnxruntime_providers_shared.dll") {
  Copy-Item "$vcam\third_party\onnxruntime\bin\$f" $stage
}
Copy-Item "$vcam\models\modnet.onnx" "$stage\models"
Copy-Item "$vcam\third_party\onnxruntime\LICENSE" "$stage\LICENSE-onnxruntime.txt"
Copy-Item "$vcam\models\README.md" "$stage\NOTICE-models.txt"

Remove-Item $zip -Force -ErrorAction SilentlyContinue
# bsdtar (tar.exe, part of Windows 10 and later) writes forward-slash paths, which every unzip tool reads the same way.
Push-Location $stage
& "$env:WINDIR\System32\tar.exe" -a -c -f $zip *
$code = $LASTEXITCODE
Pop-Location
if ($code) { throw "tar failed ($code)" }
Remove-Item $stage -Recurse -Force

$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
$len = (Get-Item $zip).Length
Write-Host ""
Write-Host "Effects pack: $zip"
Write-Host "  size   : $len bytes ($([math]::Round($len / 1MB, 1)) MB)"
Write-Host "  sha256 : $hash"
