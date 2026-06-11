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

if (-not $DeviceId) {
    $DeviceId = $env:COMPUTERNAME
}

if (-not $Token) {
    $Token = Read-Host "Enter ACCESS_TOKEN (same as server)"
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -Force $DistExe (Join-Path $InstallDir "RemoteScreenAgent.exe")

@{
    server   = $Server
    deviceId = $DeviceId
    token    = $Token
    monitor  = 1
    fps      = 12
    quality  = 55
} | ConvertTo-Json | Set-Content -Path $SettingsPath -Encoding UTF8

Write-Host "Installed to: $InstallDir"
Write-Host "Settings: $SettingsPath (auto-managed, no manual config)"

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
