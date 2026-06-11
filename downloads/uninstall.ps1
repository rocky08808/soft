# ReSA — uninstall (includes legacy RemoteScreenAgent)
param(
    [switch]$Quiet
)

$ErrorActionPreference = "Continue"

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

$RunKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$failures = New-Object System.Collections.Generic.List[string]

function Write-Step {
    param(
        [string]$Text,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    if (-not $Quiet) {
        Write-Host $Text -ForegroundColor $Color
    }
}

function Test-ScheduledTaskExists {
    param([string]$TaskName)

    try {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            return $true
        }
    } catch {}

    schtasks /Query /TN $TaskName 1>$null 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Remove-AgentScheduledTask {
    param([string]$TaskName)

    if (-not (Test-ScheduledTaskExists -TaskName $TaskName)) {
        return $false
    }

    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    } catch {}

    if (Test-ScheduledTaskExists -TaskName $TaskName) {
        schtasks /Delete /TN $TaskName /F 1>$null 2>$null
    }

    if (Test-ScheduledTaskExists -TaskName $TaskName) {
        $failures.Add("计划任务仍存在: $TaskName")
        return $false
    }

    Write-Step "已删除计划任务: $TaskName"
    return $true
}

function Stop-AgentProcess {
    param([string]$ProcessName)

    $exeName = "$ProcessName.exe"
    if (-not (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
        return $false
    }

    for ($i = 0; $i -lt 8; $i++) {
        Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 300
        if (-not (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
            Write-Step "已停止进程: $ProcessName"
            return $true
        }
    }

    cmd /c "taskkill /F /T /IM $exeName" 1>$null 2>$null
    Start-Sleep -Milliseconds 500

    if (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue) {
        $failures.Add("进程仍在运行: $ProcessName")
        return $false
    }

    Write-Step "已停止进程: $ProcessName"
    return $true
}

function Remove-AgentRunKey {
    param([string]$Name)

    try {
        $value = Get-ItemProperty -Path $RunKeyPath -Name $Name -ErrorAction SilentlyContinue
        if (-not $value) { return $false }
        Remove-ItemProperty -Path $RunKeyPath -Name $Name -ErrorAction SilentlyContinue
        Write-Step "已删除注册表自启: $Name"
        return $true
    } catch {
        return $false
    }
}

function Remove-AgentStartupLink {
    param([string]$LinkName)

    $startupLink = Join-Path ([Environment]::GetFolderPath("Startup")) $LinkName
    if (-not (Test-Path -LiteralPath $startupLink)) {
        return $false
    }

    try {
        Remove-Item -LiteralPath $startupLink -Force -ErrorAction Stop
        Write-Step "已删除启动快捷方式: $LinkName"
        return $true
    } catch {
        $failures.Add("启动快捷方式删除失败: $LinkName")
        return $false
    }
}

function Remove-AgentDirectory {
    param([string]$InstallDir)

    if (-not (Test-Path -LiteralPath $InstallDir)) {
        return $false
    }

    for ($i = 0; $i -lt 6; $i++) {
        try {
            Get-ChildItem -LiteralPath $InstallDir -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Attributes = "Normal" }
            Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop
        } catch {
            Start-Sleep -Milliseconds 500
        }

        if (-not (Test-Path -LiteralPath $InstallDir)) {
            Write-Step "已删除安装目录: $InstallDir"
            return $true
        }
    }

    cmd /c "rd /s /q `"$InstallDir`"" 1>$null 2>$null
    Start-Sleep -Milliseconds 300

    if (Test-Path -LiteralPath $InstallDir) {
        $failures.Add("安装目录仍存在: $InstallDir")
        return $false
    }

    Write-Step "已删除安装目录: $InstallDir"
    return $true
}

function Remove-AgentProfile {
    param([hashtable]$Profile)

    $changed = $false
    $installDir = Join-Path $env:LOCALAPPDATA $Profile.InstallDirName

    if (Remove-AgentScheduledTask -TaskName $Profile.TaskName) { $changed = $true }
    if (Remove-AgentRunKey -Name $Profile.RunKeyName) { $changed = $true }
    if (Remove-AgentStartupLink -LinkName $Profile.StartupLinkName) { $changed = $true }
    if (Stop-AgentProcess -ProcessName $Profile.ProcessName) { $changed = $true }
    if (Remove-AgentDirectory -InstallDir $installDir) { $changed = $true }

    if (-not $changed -and -not $Quiet) {
        Write-Step "未发现 $($Profile.Label) 相关项"
    }

    return $changed
}

Write-Step ""
Write-Step "=== ReSA 卸载 ===" Cyan
Write-Step "将清理 ReSA 及旧版 RemoteScreenAgent（如存在）"
Write-Step ""

$anyFound = $false
foreach ($profile in $AgentProfiles) {
    if (-not $Quiet) {
        Write-Step "-- $($profile.Label) --" Cyan
    }
    if (Remove-AgentProfile -Profile $profile) {
        $anyFound = $true
    }
    if (-not $Quiet) {
        Write-Step ""
    }
}

Write-Step ""
if ($failures.Count -gt 0) {
    Write-Step "卸载未完全成功，请关闭相关程序后重试，或以管理员身份运行。" Yellow
    foreach ($item in $failures) {
        Write-Step "  - $item" Yellow
    }
    exit 1
}

if ($anyFound) {
    Write-Step "卸载完成。" Green
} else {
    Write-Step "未发现已安装的 ReSA / RemoteScreenAgent。" Yellow
}

Write-Step ""
exit 0
