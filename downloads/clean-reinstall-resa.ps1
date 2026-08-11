# Full clean + reinstall ReSA (run in PowerShell, not silent one-liner)
param(
    [string]$BaseUrl = "https://olxp.cc/download"
)

$ErrorActionPreference = "Continue"
$BaseUrl = $BaseUrl.Trim().TrimEnd("/")

Write-Host "=== ReSA clean reinstall ===" -ForegroundColor Cyan
Write-Host ""

$uninstallScript = Join-Path $PSScriptRoot "uninstall.ps1"
$installScript = Join-Path $PSScriptRoot "install.ps1"

if (-not (Test-Path -LiteralPath $uninstallScript)) {
    Write-Host "Downloading uninstall.ps1..." -ForegroundColor Gray
    $uninstallScript = Join-Path $env:TEMP "uninstall.ps1"
    & "$env:SystemRoot\System32\curl.exe" -fsSL -o $uninstallScript ($BaseUrl + "/uninstall.ps1")
}
if (-not (Test-Path -LiteralPath $installScript)) {
    Write-Host "Downloading install.ps1..." -ForegroundColor Gray
    $installScript = Join-Path $env:TEMP "install.ps1"
    & "$env:SystemRoot\System32\curl.exe" -fsSL -o $installScript ($BaseUrl + "/install.ps1")
}

Write-Host "Step 1: Uninstall (tasks, process, folder)..." -ForegroundColor Yellow
& powershell -NoProfile -ExecutionPolicy Bypass -File $uninstallScript -Product ReSA
Write-Host ""

Write-Host "Step 2: Install..." -ForegroundColor Yellow
$env:RESA_INSTALL_BASE = $BaseUrl
& powershell -NoProfile -ExecutionPolicy Bypass -File $installScript
$code = $LASTEXITCODE
Write-Host ""

$log = Join-Path $env:TEMP "ReSA-install.log"
$dir = Join-Path $env:LOCALAPPDATA "ReSA"
$exe = Join-Path $dir "ReSA.exe"

Write-Host "=== Result ===" -ForegroundColor Cyan
if ($code -eq 0 -and (Test-Path -LiteralPath $exe)) {
    $size = (Get-Item -LiteralPath $exe).Length
    Write-Host ("OK: " + $exe + " (" + $size + " bytes)") -ForegroundColor Green
    Write-Host ("Log: " + $log) -ForegroundColor Gray
    exit 0
}

Write-Host "FAILED. Check log:" -ForegroundColor Red
Write-Host $log -ForegroundColor Yellow
if (Test-Path -LiteralPath $log) {
    Get-Content -LiteralPath $log -Tail 15 | ForEach-Object { Write-Host $_ }
}
exit 1
