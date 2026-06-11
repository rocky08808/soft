# Install RemoteScreenAgent — double-click exe, no config file needed
param(
    [string]$Server = "wss://olxp.cc",
    [string]$DeviceId = "",
    [string]$Token = "",
    [switch]$NoAutostart
)

$ErrorActionPreference = "Stop"
$AgentDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DistExe = Join-Path $AgentDir "dist\RemoteScreenAgent.exe"
$InstallDir = Join-Path $env:LOCALAPPDATA "RemoteScreenAgent"
$SettingsPath = Join-Path $InstallDir "settings.json"
$TaskName = "RemoteScreenAgent"

if (-not (Test-Path $DistExe)) {
    throw "Not found: $DistExe`nRun build.bat first."
}

if (-not $Token) {
    $Token = Read-Host "Enter ACCESS_TOKEN (same as server)"
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$InstallExe = Join-Path $InstallDir "RemoteScreenAgent.exe"
Copy-Item -Force $DistExe $InstallExe
# Remove "Mark of the Web" so SmartScreen is less likely to block copied files.
if (Get-Command Unblock-File -ErrorAction SilentlyContinue) {
    Unblock-File -Path $DistExe -ErrorAction SilentlyContinue
    Unblock-File -Path $InstallExe -ErrorAction SilentlyContinue
}

$settings = @{
    server  = $Server
    token   = $Token
    monitor = 1
    fps         = 12
    quality     = 55
    streamWidth = 0
}
if ($DeviceId) {
    $settings.deviceId = $DeviceId
}
$settings | ConvertTo-Json | Set-Content -Path $SettingsPath -Encoding UTF8

Write-Host "Installed to: $InstallDir"
Write-Host "Settings: $SettingsPath"
if ($DeviceId) {
    Write-Host "Device ID: $DeviceId"
} else {
    Write-Host "Device ID: auto-generated on first run (see device.id)"
}

if (-not $NoAutostart) {
    $ExePath = Join-Path $InstallDir "RemoteScreenAgent.exe"
    $Action = New-ScheduledTaskAction -Execute $ExePath -WorkingDirectory $InstallDir
    $Trigger = New-ScheduledTaskTrigger -AtLogOn
    $Settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Force | Out-Null
    Write-Host "Scheduled task: $TaskName (run at logon)"
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "Agent started."
} else {
    Write-Host "Run: $InstallDir\RemoteScreenAgent.exe"
}
