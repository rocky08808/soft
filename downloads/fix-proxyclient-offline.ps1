# Fix ProxyClient killed by Defender (control PC)
$ErrorActionPreference = "Continue"

$Dir = Join-Path $env:LOCALAPPDATA "ReProxyClient"
$Exe = Join-Path $Dir "ProxyClient.exe"
$InstallLog = Join-Path $env:TEMP "ProxyClient-install.log"
$BaseUrl = $env:RESA_INSTALL_BASE
if (-not $BaseUrl) {
    $BaseUrl = "https://olxp.cc/download"
}
$BaseUrl = $BaseUrl.Trim().TrimEnd("/")
if ($BaseUrl -match "^http://" -and $BaseUrl -notmatch "localhost|127\.0\.0\.1") {
    $BaseUrl = $BaseUrl -replace "^http://", "https://"
}

function Write-Step {
    param([string]$Text)
    Write-Host $Text
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Add-DefenderExclusion {
    param(
        [string]$Path,
        [string]$ExePath
    )

    try {
        Add-MpPreference -ExclusionPath $Path -ErrorAction Stop
        Write-Step ("defender path ok: " + $Path)
    } catch {
        Write-Host ("defender path skipped: " + $_.Exception.Message) -ForegroundColor Yellow
    }

    try {
        Add-MpPreference -ExclusionProcess "ProxyClient.exe" -ErrorAction Stop
        Write-Step "defender process ok: ProxyClient.exe"
    } catch {
        Write-Host ("defender process skipped: " + $_.Exception.Message) -ForegroundColor Yellow
    }

    if ($ExePath -and (Test-Path -LiteralPath $ExePath)) {
        try {
            Add-MpPreference -ExclusionPath $ExePath -ErrorAction Stop
            Write-Step ("defender file ok: " + $ExePath)
        } catch {
            Write-Host ("defender file skipped: " + $_.Exception.Message) -ForegroundColor Yellow
        }
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
        & $curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 30 --max-time 600 -o $OutFile $Url
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $OutFile)) {
            return $true
        }
    }
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing | Out-Null
        return (Test-Path -LiteralPath $OutFile)
    } catch {
        return $false
    }
}

Write-Step "ProxyClient fix start"
if (-not (Test-IsAdmin)) {
    Write-Host ""
    Write-Host "Tip: run PowerShell as Administrator so Defender exclusions apply." -ForegroundColor Yellow
    Write-Host "If Defender quarantined ProxyClient.exe: Windows Security -> Protection history -> Restore/Allow." -ForegroundColor Cyan
    Write-Host ""
}

Write-Step "Stopping ProxyClient..."
Get-Process -Name "ProxyClient" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Add-DefenderExclusion -Path $Dir -ExePath $Exe

$installScript = Join-Path $env:TEMP "ProxyClient-install.ps1"
$installUrl = $BaseUrl + "/install-proxyclient.ps1"
Write-Step ("Downloading " + $installUrl)
if (-not (Download-File -Url $installUrl -OutFile $installScript)) {
    Write-Host ("download install-proxyclient.ps1 failed: " + $installUrl) -ForegroundColor Red
    exit 1
}

Unblock-File -LiteralPath $installScript -ErrorAction SilentlyContinue
$env:RESA_INSTALL_BASE = $BaseUrl

Write-Step "Running install-proxyclient.ps1..."
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript
$code = $LASTEXITCODE
if ($code -ne 0) {
    Write-Host ("install failed, exit code: " + $code) -ForegroundColor Red
    if (Test-Path -LiteralPath $InstallLog) {
        Write-Host ""
        Write-Host "Install log:"
        Get-Content -LiteralPath $InstallLog -Tail 25
    }
    exit $code
}

Add-DefenderExclusion -Path $Dir -ExePath $Exe
Start-Sleep -Seconds 2

if (-not (Get-Process -Name "ProxyClient" -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $Exe)) {
    Write-Step "ProxyClient not running, starting again..."
    try {
        Start-Process -FilePath $Exe -WorkingDirectory $Dir
    } catch {
        Write-Host ("start failed: " + $_.Exception.Message) -ForegroundColor Red
    }
    Start-Sleep -Seconds 3
}

if (Get-Process -Name "ProxyClient" -ErrorAction SilentlyContinue) {
    Write-Host ""
    Write-Host "ProxyClient.exe is running. Browser UI should open shortly." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "ProxyClient.exe still not running. Defender may have blocked it again." -ForegroundColor Red
    Write-Host "Open Windows Security -> Protection history, restore ProxyClient.exe, then rerun this script as Administrator." -ForegroundColor Cyan
}

Write-Host ""
Write-Host ("Program: " + $Exe)
Write-Host ("Settings: " + (Join-Path $Dir "settings.json"))
Write-Host ""
Write-Host "Done." -ForegroundColor Green
