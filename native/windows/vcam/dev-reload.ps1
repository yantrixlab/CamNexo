#Requires -RunAsAdministrator
# Dev helper: the Frame Server keeps camnexo_vcam_source.dll loaded, so replacing it needs the service stopped.
# Briefly interrupts every camera app. Usage (admin PowerShell, from this folder): .\dev-reload.ps1
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'build\Release\camnexo_vcam_source.dll'
$dir = Join-Path $env:ProgramData 'CamNexo\vcam'
$dst = Join-Path $dir 'camnexo_vcam_source.dll'
if (-not (Test-Path $src)) { throw "Build first: $src not found" }
New-Item -ItemType Directory -Force $dir | Out-Null

function Get-Fs { Get-CimInstance Win32_Service -Filter "Name='FrameServer'" }
Write-Host "FrameServer before: $((Get-Fs).State) pid $((Get-Fs).ProcessId)"

# Stop the service and its monitor; if the host process lingers, end it.
Stop-Service FrameServerMonitor -Force -ErrorAction SilentlyContinue
Stop-Service FrameServer -Force
$oldPid = (Get-Fs).ProcessId
for ($i = 0; $i -lt 20 -and (Get-Fs).State -ne 'Stopped'; $i++) { Start-Sleep -Milliseconds 500 }
if ((Get-Fs).State -ne 'Stopped') { throw "FrameServer did not stop (state $((Get-Fs).State))" }
if ($oldPid) { Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue }

Copy-Item $src $dst -Force
Remove-Item (Join-Path $dir 'vcam*.log') -ErrorAction SilentlyContinue
$same = (Get-FileHash $src).Hash -eq (Get-FileHash $dst).Hash
if (-not $same) { throw "Copy did not take effect: hashes differ" }

Start-Service FrameServer
Start-Service FrameServerMonitor -ErrorAction SilentlyContinue
Write-Host "FrameServer after: $((Get-Fs).State) pid $((Get-Fs).ProcessId)"
Write-Host "Reloaded $src -> $dst (hash verified)"
