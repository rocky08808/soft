# ReST uninstall
param(
    [switch]$Quiet
)

$ErrorActionPreference = "Continue"

$AgentProfiles = @(
    @{
        Label = "ReST"
        ProcessName = "ReST"
        TaskName = "ReST"
        InstallDirName = "ReST"
        RunKeyName = "ReST"
        StartupLinkName = "ReST.lnk"
    }
)

$RunKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$failures = @()

function Write-Step {
    param(
        [string]$Text,
        [string]$Color = "Gray"
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
        $script:failures += "task still exists: $TaskName"
        return $false
    }

    Write-Step -Text "removed task: $TaskName" -Color "Green"
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
            Write-Step -Text "stopped process: $ProcessName" -Color "Green"
            return $true
        }
    }

    cmd /c "taskkill /F /T /IM $exeName" 1>$null 2>$null
    Start-Sleep -Milliseconds 500

    if (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue) {
        $script:failures += "process still running: $ProcessName"
        return $false
    }

    Write-Step -Text "stopped process: $ProcessName" -Color "Green"
    return $true
}

function Remove-AgentRunKey {
    param([string]$Name)

    try {
        $props = Get-ItemProperty -Path $RunKeyPath -ErrorAction SilentlyContinue
        if (-not $props -or -not ($props.PSObject.Properties.Name -contains $Name)) {
            return $false
        }
        Remove-ItemProperty -Path $RunKeyPath -Name $Name -ErrorAction SilentlyContinue
        Write-Step -Text "removed run key: $Name" -Color "Green"
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
        Write-Step -Text "removed startup link: $LinkName" -Color "Green"
        return $true
    } catch {
        $script:failures += "startup link failed: $LinkName"
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
            Write-Step -Text "removed folder: $InstallDir" -Color "Green"
            return $true
        }
    }

    cmd /c "rd /s /q `"$InstallDir`"" 1>$null 2>$null
    Start-Sleep -Milliseconds 300

    if (Test-Path -LiteralPath $InstallDir) {
        $script:failures += "folder still exists: $InstallDir"
        return $false
    }

    Write-Step -Text "removed folder: $InstallDir" -Color "Green"
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
        Write-Step -Text "not found: $($Profile.Label)" -Color "Gray"
    }

    return $changed
}

Write-Step -Text "" -Color "Gray"
Write-Step -Text "=== ReST Uninstall ===" -Color "Cyan"
Write-Step -Text "" -Color "Gray"

$anyFound = $false
foreach ($profile in $AgentProfiles) {
    if (-not $Quiet) {
        Write-Step -Text "-- $($profile.Label) --" -Color "Cyan"
    }
    if (Remove-AgentProfile -Profile $profile) {
        $anyFound = $true
    }
    if (-not $Quiet) {
        Write-Step -Text "" -Color "Gray"
    }
}

Write-Step -Text "" -Color "Gray"
if ($failures.Count -gt 0) {
    Write-Step -Text "Uninstall incomplete. Close ReST and retry, or run as Administrator." -Color "Yellow"
    foreach ($item in $failures) {
        Write-Step -Text "  - $item" -Color "Yellow"
    }
    exit 1
}

if ($anyFound) {
    Write-Step -Text "Uninstall complete." -Color "Green"
} else {
    Write-Step -Text "No ReST installation found." -Color "Yellow"
}

Write-Step -Text "" -Color "Gray"
exit 0
