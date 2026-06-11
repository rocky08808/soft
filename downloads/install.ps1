# RemoteScreen Agent — remote one-click install
param(
    [string]$BaseUrl = "https://olxp.cc/download"
)

$ErrorActionPreference = "Stop"
$Dir = Join-Path $env:LOCALAPPDATA "RemoteScreenAgent"
$Exe = Join-Path $Dir "RemoteScreenAgent.exe"
$TaskName = "RemoteScreenAgent"
$Url = ($BaseUrl.TrimEnd("/") + "/RemoteScreenAgent.exe")

Write-Host ""
Write-Host "=== RemoteScreen Agent 一键安装 ===" -ForegroundColor Cyan
Write-Host "下载: $Url"
Write-Host "安装到: $Dir"
Write-Host ""

New-Item -ItemType Directory -Force -Path $Dir | Out-Null

$ProgressPreference = "SilentlyContinue"
try {
    Invoke-WebRequest -Uri $Url -OutFile $Exe -UseBasicParsing
} catch {
    Write-Host "[错误] 下载失败: $_" -ForegroundColor Red
    Write-Host "请确认服务器 downloads 目录已上传 RemoteScreenAgent.exe" -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $Exe)) {
    Write-Host "[错误] 安装文件不存在" -ForegroundColor Red
    exit 1
}

Unblock-File -LiteralPath $Exe -ErrorAction SilentlyContinue

$running = Get-Process -Name "RemoteScreenAgent" -ErrorAction SilentlyContinue
if ($running) {
    $running | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

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
    $Link = $Wsh.CreateShortcut((Join-Path $Startup "RemoteScreenAgent.lnk"))
    $Link.TargetPath = $Exe
    $Link.WorkingDirectory = $Dir
    $Link.Save()
    Write-Host "计划任务不可用，已写入启动文件夹" -ForegroundColor Yellow
}

Start-Process -FilePath $Exe -WorkingDirectory $Dir

Write-Host ""
Write-Host "安装完成。" -ForegroundColor Green
Write-Host "设备 ID 文件: $Dir\device.id"
Write-Host "日志: $Dir\agent.log"
Write-Host ""
