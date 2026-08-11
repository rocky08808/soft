# Fix ReSA watchdog flash: switch from PowerShell to ReSA.exe -watchdog
$ErrorActionPreference = "Continue"

$Dir = Join-Path $env:LOCALAPPDATA "ReSA"
$Exe = Join-Path $Dir "ReSA.exe"
$TaskName = "ReSA-Watchdog"

if (-not (Test-Path -LiteralPath $Exe)) {
    Write-Host "ReSA not found: $Exe" -ForegroundColor Red
    exit 1
}

Remove-Item -LiteralPath (Join-Path $Dir "watchdog.ps1") -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $Dir "watchdog.vbs") -Force -ErrorAction SilentlyContinue

$Action = New-ScheduledTaskAction -Execute $Exe -Argument "-watchdog" -WorkingDirectory $Dir
$Trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3650)
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
$Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal -Force | Out-Null

Write-Host "ReSA-Watchdog updated: no more PowerShell flash." -ForegroundColor Green
