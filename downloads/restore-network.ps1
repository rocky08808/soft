# ReProxy - restore local network (clear stale system proxy / PAC)
$ErrorActionPreference = "Stop"

$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
$clientDir = Join-Path $env:LOCALAPPDATA "ReProxyClient"
$backupFile = Join-Path $clientDir "proxy-backup.json"
$pacFile = Join-Path $clientDir "proxy.pac"

function Refresh-InternetSettings {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinInet {
  [DllImport("wininet.dll", SetLastError=true)]
  public static extern bool InternetSetOption(IntPtr h, int opt, IntPtr buf, int len);
}
"@
    [WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
    [WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
}

Write-Host "ReProxy: restoring local network..." -ForegroundColor Cyan

if (Test-Path $backupFile) {
    try {
        $backup = Get-Content -Raw $backupFile | ConvertFrom-Json
        if ($backup.active) {
            Set-ItemProperty -Path $regPath -Name ProxyEnable -Value ([int]$backup.enabled)
            if ($backup.autoConfigURL) {
                Set-ItemProperty -Path $regPath -Name AutoConfigURL -Value $backup.autoConfigURL
            } else {
                Remove-ItemProperty -Path $regPath -Name AutoConfigURL -ErrorAction SilentlyContinue
            }
            if ($backup.server) {
                Set-ItemProperty -Path $regPath -Name ProxyServer -Value $backup.server
            } else {
                Remove-ItemProperty -Path $regPath -Name ProxyServer -ErrorAction SilentlyContinue
            }
            if ($backup.override) {
                Set-ItemProperty -Path $regPath -Name ProxyOverride -Value $backup.override
            }
            Remove-Item $backupFile -Force -ErrorAction SilentlyContinue
            Remove-Item $pacFile -Force -ErrorAction SilentlyContinue
            Refresh-InternetSettings
            Write-Host "ReProxy: restored previous Windows proxy settings." -ForegroundColor Green
            Write-Host "Restart Chrome/Edge completely." -ForegroundColor Yellow
            exit 0
        }
    } catch {
        Write-Host "ReProxy: backup read failed, forcing clear..." -ForegroundColor Yellow
    }
}

$autoURL = (Get-ItemProperty -Path $regPath -Name AutoConfigURL -ErrorAction SilentlyContinue).AutoConfigURL
$server = (Get-ItemProperty -Path $regPath -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer
$isOurs = ($autoURL -match "ReProxyClient.*proxy\.pac") -or ($server -match "socks=127\.0\.0\.1")

if ($isOurs -or (Test-Path $pacFile)) {
    Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 0
    Remove-ItemProperty -Path $regPath -Name AutoConfigURL -ErrorAction SilentlyContinue
    if ($server -match "socks=127\.0\.0\.1") {
        Remove-ItemProperty -Path $regPath -Name ProxyServer -ErrorAction SilentlyContinue
    }
    Remove-Item $pacFile -Force -ErrorAction SilentlyContinue
    Remove-Item $backupFile -Force -ErrorAction SilentlyContinue
    Refresh-InternetSettings
    Write-Host "ReProxy: system proxy disabled." -ForegroundColor Green
} else {
    Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 0
    Remove-ItemProperty -Path $regPath -Name AutoConfigURL -ErrorAction SilentlyContinue
    Refresh-InternetSettings
    Write-Host "ReProxy: ProxyEnable set to 0. Check VPN/other proxy apps if still offline." -ForegroundColor Yellow
}

Write-Host "Restart Chrome/Edge completely." -ForegroundColor Yellow
