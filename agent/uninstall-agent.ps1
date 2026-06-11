$TaskName = "ReSA"
$InstallDir = Join-Path $env:LOCALAPPDATA "ReSA"

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "ReSA" -ErrorAction SilentlyContinue
if (Test-Path $InstallDir) {
    Remove-Item -Recurse -Force $InstallDir
}
Write-Host "ReSA uninstalled."
