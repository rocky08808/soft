# Register agent to run at user logon (Task Scheduler)
param(
    [string]$DeviceId = "PC-001",
    [string]$Server = "ws://localhost:8080",
    [string]$Token = "remote-screen-dev"
)

$ErrorActionPreference = "Stop"
$AgentDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $Python) { throw "Python not found in PATH" }

$ConfigPath = Join-Path $AgentDir "agent.config.json"
@{
    server   = $Server
    deviceId = $DeviceId
    token    = $Token
    monitor  = 1
    fps      = 12
    quality  = 55
} | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8

$TaskName = "RemoteScreenAgent"
$Action = New-ScheduledTaskAction -Execute $Python -Argument "`"$AgentDir\agent.py`" --config `"$ConfigPath`"" -WorkingDirectory $AgentDir
$Trigger = New-ScheduledTaskTrigger -AtLogOn
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Force | Out-Null
Write-Host "Installed scheduled task: $TaskName"
Write-Host "Config: $ConfigPath"
Write-Host "Start now: Start-ScheduledTask -TaskName $TaskName"
