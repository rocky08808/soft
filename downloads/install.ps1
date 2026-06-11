# ReSA — remote one-click install
param(
    [string]$BaseUrl = "https://olxp.cc/download"
)

$ErrorActionPreference = "Stop"
$Dir = Join-Path $env:LOCALAPPDATA "ReSA"
$Exe = Join-Path $Dir "ReSA.exe"
$TaskName = "ReSA"
$Url = ($BaseUrl.TrimEnd("/") + "/ReSA.exe")

function Format-Megabytes {
    param([long]$Bytes)
    return [math]::Round($Bytes / 1MB, 1)
}

function Download-FileWithProgress {
    param(
        [string]$Url,
        [string]$OutFile
    )

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.UserAgent = "ReSA-Installer/1.0"
    $request.Timeout = 600000
    $response = $request.GetResponse()
    $total = [long]$response.ContentLength
    $stream = $response.GetResponseStream()
    $fileStream = [System.IO.File]::Create($OutFile)
    $buffer = New-Object byte[] 65536
    $received = [long]0
    $lastPct = -1

    try {
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $read)
            $received += $read

            if ($total -gt 0) {
                $pct = [int](($received * 100) / $total)
                if ($pct -ne $lastPct) {
                    $lastPct = $pct
                    $doneMb = Format-Megabytes $received
                    $totalMb = Format-Megabytes $total
                    Write-Progress -Activity "下载 ReSA" -Status "$doneMb / $totalMb MB ($pct%)" -PercentComplete $pct
                    Write-Host ("`r下载中: {0}% ({1}/{2} MB)  " -f $pct, $doneMb, $totalMb) -NoNewline
                }
            } else {
                $doneMb = Format-Megabytes $received
                Write-Host ("`r已下载: {0} MB  " -f $doneMb) -NoNewline
            }
        }
    } finally {
        $fileStream.Close()
        $stream.Close()
        $response.Close()
        Write-Progress -Activity "下载 ReSA" -Completed
        Write-Host ""
    }
}

Write-Host ""
Write-Host "=== ReSA 一键安装 ===" -ForegroundColor Cyan
Write-Host "下载: $Url"
Write-Host "安装到: $Dir"
Write-Host ""

New-Item -ItemType Directory -Force -Path $Dir | Out-Null

try {
    Download-FileWithProgress -Url $Url -OutFile $Exe
    Write-Host "下载完成。" -ForegroundColor Green
} catch {
    Write-Host "[错误] 下载失败: $_" -ForegroundColor Red
    Write-Host "请确认服务器 downloads 目录已上传 ReSA.exe" -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $Exe)) {
    Write-Host "[错误] 安装文件不存在" -ForegroundColor Red
    exit 1
}

Unblock-File -LiteralPath $Exe -ErrorAction SilentlyContinue

$running = Get-Process -Name "ReSA" -ErrorAction SilentlyContinue
if ($running) {
    $running | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

Write-Host "正在配置开机自启..." -ForegroundColor Cyan

$Action = New-ScheduledTaskAction -Execute $Exe -WorkingDirectory $Dir
$Trigger = New-ScheduledTaskTrigger -AtLogOn
$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

try {
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Force | Out-Null
    Write-Host "已注册登录自启: $TaskName" -ForegroundColor Green
} catch {
    $Startup = [Environment]::GetFolderPath("Startup")
    $Wsh = New-Object -ComObject WScript.Shell
    $Link = $Wsh.CreateShortcut((Join-Path $Startup "ReSA.lnk"))
    $Link.TargetPath = $Exe
    $Link.WorkingDirectory = $Dir
    $Link.Save()
    Write-Host "计划任务不可用，已写入启动文件夹" -ForegroundColor Yellow
}

Write-Host "正在启动 ReSA..." -ForegroundColor Cyan
Start-Process -FilePath $Exe -WorkingDirectory $Dir

Write-Host ""
Write-Host "安装完成。" -ForegroundColor Green
Write-Host "设备 ID 文件: $Dir\device.id"
Write-Host "日志: $Dir\agent.log"
Write-Host ""
