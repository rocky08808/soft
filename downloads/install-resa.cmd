# ReSA one-click install - visible progress, direct install.ps1
$ErrorActionPreference = "Continue"
$BaseUrl = "https://olxp.cc/download"
$env:RESA_INSTALL_BASE = $BaseUrl
$script = Join-Path $env:TEMP "ReSA-install.ps1"
$curl = Join-Path $env:SystemRoot "System32\curl.exe"

Write-Host "ReSA install start"
Write-Host ("download: " + $BaseUrl + "/install.ps1")

if (Test-Path -LiteralPath $curl) {
    & $curl -fsSL --retry 3 --connect-timeout 30 --max-time 900 -o $script ($BaseUrl + "/install.ps1")
}
if (-not (Test-Path -LiteralPath $script)) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri ($BaseUrl + "/install.ps1") -OutFile $script -UseBasicParsing
    } catch {
        Write-Host ("download install.ps1 failed: " + $_.Exception.Message) -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
}

Unblock-File -LiteralPath $script -ErrorAction SilentlyContinue
$t = [IO.File]::ReadAllText($script)
$t = $t.TrimStart([char]0xFEFF)
[IO.File]::WriteAllText($script, $t, (New-Object System.Text.UTF8Encoding $false))

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script
$code = $LASTEXITCODE
if ($code -ne 0) {
    Write-Host ("install failed, exit " + $code) -ForegroundColor Red
    Write-Host ("log: " + (Join-Path $env:TEMP "ReSA-install.log"))
    Read-Host "Press Enter to exit"
    exit $code
}

Write-Host "ReSA install complete." -ForegroundColor Green
Start-Sleep -Seconds 3
