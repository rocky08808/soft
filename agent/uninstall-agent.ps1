# ReSA — uninstall (dev/build machine)
$ErrorActionPreference = "Stop"
$UninstallScript = Join-Path $PSScriptRoot "..\downloads\uninstall.ps1"
& $UninstallScript
