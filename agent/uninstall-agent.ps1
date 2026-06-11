$TaskName = "RemoteScreenAgent"
$InstallDir = Join-Path $env:LOCALAPPDATA "RemoteScreenAgent"

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "RemoteScreenAgent" -ErrorAction SilentlyContinue
if (Test-Path $InstallDir) {
    Remove-Item -Recurse -Force $InstallDir
}
Write-Host "RemoteScreenAgent uninstalled."
