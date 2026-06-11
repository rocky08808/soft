# Unblock RemoteScreenAgent.exe (removes download zone marker)
param(
    [string]$Path = (Join-Path $PSScriptRoot "dist\RemoteScreenAgent.exe")
)

if (-not (Test-Path $Path)) {
    Write-Error "File not found: $Path"
    exit 1
}

Unblock-File -Path $Path
Write-Host "Unblocked: $Path"
Write-Host "If SmartScreen still appears, click 更多信息 -> 仍要运行"
