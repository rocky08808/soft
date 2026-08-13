# ReProxy - add Windows Defender exclusions for Proxy.exe and ProxyClient.exe
$ErrorActionPreference = "Continue"

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host "Tip: run PowerShell as Administrator for exclusions to apply." -ForegroundColor Yellow
    Write-Host ""
}

$paths = @(
    (Join-Path $env:LOCALAPPDATA "ReProxy"),
    (Join-Path $env:LOCALAPPDATA "ReProxyClient")
)
$processes = @("Proxy.exe", "ProxyClient.exe")

foreach ($p in $paths) {
    if (-not (Test-Path -LiteralPath $p)) {
        New-Item -ItemType Directory -Force -Path $p | Out-Null
    }
    try {
        Add-MpPreference -ExclusionPath $p -ErrorAction Stop
        Write-Host "OK path: $p" -ForegroundColor Green
    } catch {
        Write-Host "SKIP path $p : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

foreach ($proc in $processes) {
    try {
        Add-MpPreference -ExclusionProcess $proc -ErrorAction Stop
        Write-Host "OK process: $proc" -ForegroundColor Green
    } catch {
        Write-Host "SKIP process $proc : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "If Defender already quarantined files, open Windows Security -> Protection history -> Restore/Allow." -ForegroundColor Cyan
