# ReSA — uninstall (includes legacy RemoteScreenAgent)
param(
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

$AgentProfiles = @(
    @{
        Label = "ReSA"
        ProcessName = "ReSA"
        TaskName = "ReSA"
        InstallDirName = "ReSA"
        RunKeyName = "ReSA"
        StartupLinkName = "ReSA.lnk"
    },
    @{
        Label = "RemoteScreenAgent"
        ProcessName = "RemoteScreenAgent"
        TaskName = "RemoteScreenAgent"
        InstallDirName = "RemoteScreenAgent"
        RunKeyName = "RemoteScreenAgent"
        StartupLinkName = "RemoteScreenAgent.lnk"
    }
)

function Write-Step {
    param(
        [string]$Text,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    if (-not $Quiet) {
        Write-Host $Text -ForegroundColor $Color
    }
}

function Remove-AgentProfile {
    param(
        [hashtable]$Profile
    )

    $removed = $false
    $label = $Profile.Label
    $installDir = Join-Path $env:LOCALAPPDATA $Profile.InstallDirName
    $startupLink = Join-Path ([Environment]::GetFolderPath("Startup")) $Profile.StartupLinkName

    $process = Get-Process -Name $Profile.ProcessName -ErrorAction SilentlyContinue
    if ($process) {
        $process | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Step "已停止进程: $($Profile.ProcessName)"
        $removed = $true
    }

    $task = Get-ScheduledTask -TaskName $Profile.TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $Profile.TaskName -Confirm:$false | Out-Null
        Write-Step "已删除计划任务: $($Profile.TaskName)"
        $removed = $true
    }

    $runKey = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" `
        -Name $Profile.RunKeyName -ErrorAction SilentlyContinue
    if ($runKey) {
        Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" `
            -Name $Profile.RunKeyName -ErrorAction SilentlyContinue
        Write-Step "已删除注册表自启: $($Profile.RunKeyName)"
        $removed = $true
    }

    if (Test-Path $startupLink) {
        Remove-Item -Force $startupLink
        Write-Step "已删除启动快捷方式: $($Profile.StartupLinkName)"
        $removed = $true
    }

    if (Test-Path $installDir) {
        Remove-Item -Recurse -Force $installDir
        Write-Step "已删除安装目录: $installDir"
        $removed = $true
    }

    if (-not $removed -and -not $Quiet) {
        Write-Step "未发现 $label 相关文件"
    }

    return $removed
}

Write-Step ""
Write-Step "=== ReSA 卸载 ===" Cyan
Write-Step "将清理 ReSA 及旧版 RemoteScreenAgent（如存在）"
Write-Step ""

$anyRemoved = $false
foreach ($profile in $AgentProfiles) {
    if (-not $Quiet) {
        Write-Step "-- $($profile.Label) --" Cyan
    }
    if (Remove-AgentProfile -Profile $profile) {
        $anyRemoved = $true
    }
    if (-not $Quiet) {
        Write-Step ""
    }
}

if ($anyRemoved) {
    Write-Step "卸载完成。" Green
} else {
    Write-Step "未发现已安装的 ReSA / RemoteScreenAgent。" Yellow
}

Write-Step ""

if (-not $Quiet) {
    Read-Host "按 Enter 键关闭"
}
