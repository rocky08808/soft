# RemoteScreen Agent — one-line install (run on target Windows PC)
param(
    [string]$BaseUrl = "https://olxp.cc/download"
)

$ErrorActionPreference = "Stop"
$Dir = Join-Path $env:LOCALAPPDATA "RemoteScreenAgent"
$Exe = Join-Path $Dir "RemoteScreenAgent.exe"
$TaskName = "RemoteScreenAgent"
$Url = ($BaseUrl.TrimEnd("/") + "/RemoteScreenAgent.exe")

Write-Host ""
Write-Host "=== RemoteScreen Agent online install ===" -ForegroundColor Cyan
Write-Host "Download: $Url"
Write-Host "Install to: $Dir"
Write-Host ""

New-Item -ItemType Directory -Force -Path $Dir | Out-Null

try {
    Invoke-WebRequest -Uri $Url -OutFile $Exe -UseBasicParsing
} catch {
    Write-Host "[ERROR] Download failed: $_" -ForegroundColor Red
    exit 1
}

Unblock-File -LiteralPath $Exe -ErrorAction SilentlyContinue

$Action = New-ScheduledTaskAction -Execute $Exe -WorkingDirectory $Dir
$Trigger = New-ScheduledTaskTrigger -AtLogOn
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

try {
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Force | Out-Null
    Write-Host "Scheduled task registered: $TaskName"
} catch {
    $Startup = [Environment]::GetFolderPath("Startup")
    $Wsh = New-Object -ComObject WScript.Shell
    $Link = $Wsh.CreateShortcut((Join-Path $Startup "RemoteScreenAgent.lnk"))
    $Link.TargetPath = $Exe
    $Link.WorkingDirectory = $Dir
    $Link.Save()
    Write-Host "Using Startup folder instead of scheduled task"
}

Start-Process -FilePath $Exe -WorkingDirectory $Dir

Write-Host "Done. Device ID: $Dir\device.id"
Write-Host "Log: $Dir\agent.log"
