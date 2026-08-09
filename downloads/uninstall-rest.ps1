# ReST-only wrapper — unified logic lives in uninstall.ps1
param(
    [switch]$Quiet
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $here "uninstall.ps1") -Product ReST @PSBoundParameters
exit $LASTEXITCODE
