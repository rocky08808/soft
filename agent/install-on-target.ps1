# Run on the target PC (not the build machine). Put this next to RemoteScreenAgent.exe.
param(
    [switch]$NoAutostart
)

$ErrorActionPreference = "Stop"
$Here = $PSScriptRoot
$SourceExe = Join-Path $Here "RemoteScreenAgent.exe"
$InstallDir = Join-Path $env:LOCALAPPDATA "RemoteScreenAgent"
$InstallExe = Join-Path $InstallDir "RemoteScreenAgent.exe"
$TaskName = "RemoteScreenAgent"

if (-not (Test-Path $SourceExe)) {
    Write-Host "ERROR: RemoteScreenAgent.exe not found in: $Here" -ForegroundColor Red
    pause
    exit 1
}

Write-Host "Installing RemoteScreenAgent..."
Write-Host "Source: $SourceExe"
Write-Host "Target: $InstallDir"
Write-Host ""

Unblock-File -Path $SourceExe -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -Force $SourceExe $InstallExe
Unblock-File -Path $InstallExe -ErrorAction SilentlyContinue

if (-not $NoAutostart) {
    $Action = New-ScheduledTaskAction -Execute $InstallExe -WorkingDirectory $InstallDir
    $Trigger = New-ScheduledTaskTrigger -AtLogOn
    $Settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Force | Out-Null
    Write-Host "Scheduled task registered: $TaskName"
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "Agent started."
} else {
    Start-Process -FilePath $InstallExe -WorkingDirectory $InstallDir
    Write-Host "Agent launched once (no autostart)."
}

Write-Host ""
Write-Host "Done. Device ID file: $InstallDir\device.id"
Write-Host "Log file: $InstallDir\agent.log"
Write-Host ""
Write-Host "If Windows still shows SmartScreen, click 更多信息 -> 仍要运行 (one time only)."
pause
