# Fix ReSA offline / failed install (base_library.zip / _MEI* / download errors)
$ErrorActionPreference = "Continue"

$Dir = Join-Path $env:LOCALAPPDATA "ReSA"
$Exe = Join-Path $Dir "ReSA.exe"
$Log = Join-Path $Dir "agent.log"
$InstallLog = Join-Path $env:TEMP "ReSA-install.log"
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
        $iwrArgs = @{
            Uri = $Url
            OutFile = $OutFile
            UseBasicParsing = $true
        }
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            $iwrArgs.UserAgent = "ReSA-Fix/1.0"
        }
        Invoke-WebRequest @iwrArgs | Out-Null
        return (Test-Path -LiteralPath $OutFile)
    } catch {
        return $false
    }
}

function Remove-PyiExtractDirs {
    param([string]$ParentDir)
    if (-not $ParentDir -or -not (Test-Path -LiteralPath $ParentDir)) {
        return
    }
    Get-ChildItem -LiteralPath $ParentDir -Directory -Filter "_MEI*" -ErrorAction SilentlyContinue |
        ForEach-Object {
            Write-Step ("remove: " + $_.FullName)
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
}

Write-Step "Stopping ReSA..."
Get-Process -Name "ReSA" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

Write-Step "Clearing PyInstaller extract dirs..."
Remove-PyiExtractDirs -ParentDir $Dir
Remove-PyiExtractDirs -ParentDir $env:TEMP

try {
    Add-MpPreference -ExclusionPath $Dir -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionProcess "ReSA.exe" -ErrorAction SilentlyContinue
} catch {
    $null = $_
}

$installScript = Join-Path $env:TEMP "ReSA-install.ps1"
$installUrl = $BaseUrl + "/install.ps1"
Write-Step ("Downloading " + $installUrl)
if (-not (Download-File -Url $installUrl -OutFile $installScript)) {
    Write-Host ("download install.ps1 failed: " + $installUrl) -ForegroundColor Red
    exit 1
}

Unblock-File -LiteralPath $installScript -ErrorAction SilentlyContinue
$env:RESA_INSTALL_BASE = $BaseUrl

Write-Step "Running install.ps1 (ReSA.exe ~55MB, may take 1-3 min)..."
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript
$code = $LASTEXITCODE
if ($code -ne 0) {
    Write-Host ("install failed, exit code: " + $code) -ForegroundColor Red
    if (Test-Path -LiteralPath $InstallLog) {
        Write-Host ""
        Write-Host "Install log:"
        Get-Content -LiteralPath $InstallLog -Tail 20
    }
    exit $code
}

Start-Sleep -Seconds 5
if (Test-Path -LiteralPath $Log) {
    Write-Host ""
    Write-Host "Agent log:"
    Get-Content -LiteralPath $Log -Tail 8
} elseif (-not (Test-Path -LiteralPath $Exe)) {
    Write-Host "ReSA.exe not found after install." -ForegroundColor Red
    exit 1
} else {
    Write-Host "ReSA.exe installed. agent.log will appear after first connect."
}

Write-Host ""
Write-Host "Done. Check viewer for online status." -ForegroundColor Green
